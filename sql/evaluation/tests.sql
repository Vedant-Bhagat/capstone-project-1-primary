-- ===========================================================================
-- tests.sql -- assertions that gate CI. Any failure raises SQLSTATE 45000 at
-- the end, so the mariadb client exits non-zero and the workflow goes red.
-- Same pattern as the starter's test_aggregates.sql.
--
-- Spec: docs/main_dish_spec/07_evaluation.md, "Tests that gate CI".
-- Run:  mariadb -u root -t < sql/evaluation/tests.sql
--   PowerShell:  Get-Content sql/evaluation/tests.sql | mariadb -u root -t
--
-- Prerequisite: schema.sql and a corpus (fixture.sql or the real ingest).
-- T5 additionally needs ground_truth.sql and recall_sweep.sql to have run.
--
--   T1  corpus_meta.embed_dims matches the declared VECTOR(n) columns
--   T2  no chunk has a zero vector
--   T3  chunks.category agrees with articles.category
--   T4  indexed top-10 == brute-force top-10 for a fixed query at high ef
--   T5  recall@10 >= 0.98 at the documented ef_search   (opt-in, see below)
--   T6  the FORCE INDEX hybrid query returns the exact top-k, per category
--   T7  the documented under-return still reproduces on the real schema
--   T8  semantic search uses the vector index           -> ci.yml (EXPLAIN)
--   T9  every committed hybrid query keeps FORCE INDEX   -> ci.yml (grep)
--   T10 category selectivity vs the crossover            (reports, never fails)
--
-- T8 and T9 inspect EXPLAIN output and file text, which SQL cannot read, so
-- they are thin shell assertions in .github/workflows/ci.yml instead.
-- ===========================================================================

USE wikirag;

SET @failures = 0;

-- ---------------------------------------------------------------------------
-- T1: the model's dimension matches the schema's
-- ---------------------------------------------------------------------------
-- A model swap without a schema migration is the failure that produces
-- confident nonsense: the insert would fail loudly, but a corpus_meta that
-- disagrees with the columns means someone is about to embed queries with
-- the wrong model.
SELECT 'T1: corpus_meta.embed_dims matches VECTOR(n) columns' AS test;

SELECT COUNT(*) INTO @t1_bad
FROM information_schema.COLUMNS col
JOIN corpus_meta m
WHERE col.TABLE_SCHEMA = 'wikirag'
  AND col.TABLE_NAME IN ('chunks', 'eval_queries')
  AND col.COLUMN_NAME = 'embedding'
  AND CAST(REGEXP_SUBSTR(col.COLUMN_TYPE, '[0-9]+') AS UNSIGNED) <> m.embed_dims;

SELECT COUNT(*) INTO @t1_meta FROM corpus_meta;
SET @t1_fail = (@t1_bad > 0 OR @t1_meta <> 1);
SELECT IF(@t1_fail, CONCAT('FAIL: ', @t1_bad, ' column(s) disagree, corpus_meta rows = ', @t1_meta),
                    'PASS') AS result;
SET @failures = @failures + @t1_fail;

-- ---------------------------------------------------------------------------
-- T2: no zero vectors
-- ---------------------------------------------------------------------------
-- A zero vector has no direction, so its cosine distance to everything is
-- undefined. It is what a silently failed embedding call tends to leave.
SELECT 'T2: no chunk has a zero vector' AS test;

SET @zero = VEC_FromText(CONCAT('[', REPEAT('0,', (SELECT embed_dims FROM corpus_meta) - 1), '0]'));
SELECT COUNT(*) INTO @t2_bad
FROM chunks IGNORE INDEX (embedding)
WHERE VEC_DISTANCE_EUCLIDEAN(embedding, @zero) < 1e-9;

SET @t2_fail = (@t2_bad > 0);
SELECT IF(@t2_fail, CONCAT('FAIL: ', @t2_bad, ' zero vector(s)'), 'PASS') AS result;
SET @failures = @failures + @t2_fail;

-- ---------------------------------------------------------------------------
-- T3: the denormalised category has not drifted
-- ---------------------------------------------------------------------------
-- chunks.category is copied from articles on purpose (05_schema.md): an index
-- hint cannot name an index on another table. This guards the copy.
SELECT 'T3: chunks.category agrees with articles.category' AS test;

SELECT COUNT(*) INTO @t3_bad
FROM chunks c JOIN articles a ON a.id = c.article_id
WHERE c.category <> a.category;

SET @t3_fail = (@t3_bad > 0);
SELECT IF(@t3_fail, CONCAT('FAIL: ', @t3_bad, ' chunk(s) disagree'), 'PASS') AS result;
SET @failures = @failures + @t3_fail;

-- ---------------------------------------------------------------------------
-- T4: at a wide search, the index agrees with brute force exactly
-- ---------------------------------------------------------------------------
-- Catches index corruption and a metric mismatch. Compared as sets of ids, so
-- a tie reordered at equal distance does not fail it.
SELECT 'T4: indexed top-10 == brute-force top-10 at ef_search = 1000' AS test;

SET SESSION mhnsw_ef_search = 1000;
SET @qv = (SELECT embedding FROM eval_queries ORDER BY id LIMIT 1);
SELECT GROUP_CONCAT(id ORDER BY id) INTO @t4_indexed
FROM (SELECT id FROM chunks ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) a;
SELECT GROUP_CONCAT(id ORDER BY id) INTO @t4_exact
FROM (SELECT id FROM chunks IGNORE INDEX (embedding)
      ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) b;
SET SESSION mhnsw_ef_search = DEFAULT;

SET @t4_fail = (@t4_indexed IS NULL OR NOT (@t4_indexed <=> @t4_exact));
SELECT IF(@t4_fail, CONCAT('FAIL: indexed [', IFNULL(@t4_indexed, 'none'),
                           '] vs exact [', IFNULL(@t4_exact, 'none'), ']'),
                    'PASS') AS result;
SET @failures = @failures + @t4_fail;

-- ---------------------------------------------------------------------------
-- T5: the headline claim -- recall@10 >= 0.98 at the documented ef_search
-- ---------------------------------------------------------------------------
-- Opt-in, because it is only meaningful on the real corpus after a full
-- sweep (07: "Manual / weekly"). The weekly workflow sets:
--     SET @run_t5 = 1; SET @documented_ef = <the value in docs/findings.md>;
-- On the fixture it prints SKIP rather than passing vacuously.
SELECT 'T5: recall@10 >= 0.98 at the documented ef_search' AS test;

SET @run_t5 = IFNULL(@run_t5, 0);
SELECT ROUND(AVG(hits / k), 4) INTO @t5_recall
FROM recall_runs WHERE k = 10 AND ef_search = @documented_ef;

SET @t5_fail = IF(@run_t5 = 1, (@t5_recall IS NULL OR @t5_recall < 0.98), 0);
SELECT CASE
         WHEN @run_t5 <> 1 THEN 'SKIP: set @run_t5 = 1 and @documented_ef on the real corpus'
         WHEN @t5_recall IS NULL THEN CONCAT('FAIL: no recall_runs at ef_search = ', IFNULL(@documented_ef, 'NULL'),
                                             ' -- run recall_sweep.sql first')
         WHEN @t5_fail THEN CONCAT('FAIL: recall@10 = ', @t5_recall, ' at ef_search = ', @documented_ef)
         ELSE CONCAT('PASS: recall@10 = ', @t5_recall, ' at ef_search = ', @documented_ef)
       END AS result;
SET @failures = @failures + @t5_fail;

-- ---------------------------------------------------------------------------
-- T6: the hybrid query returns the exact top-k, for every category
-- ---------------------------------------------------------------------------
-- The query shape of sql/retrieval/hybrid_filter.sql, including its
-- FORCE INDEX. Asserts ROW IDENTITY with exhaustive search, not just the row
-- count: a run has been observed returning 10 rows of which none were in the
-- exact top 10 (09_verified_findings.md, 7b). Checked per category because
-- selectivity differs between them.
SELECT 'T6: FORCE INDEX hybrid query == exhaustive search, every category' AS test;

SET @t6_bad = 0;
SET @t6_detail = '';
SET @qv = (SELECT embedding FROM eval_queries ORDER BY id LIMIT 1);

DELIMITER //
BEGIN NOT ATOMIC
    DECLARE done  INT DEFAULT 0;
    DECLARE v_cat VARCHAR(32);
    DECLARE v_forced, v_exact TEXT;
    DECLARE v_n, v_expect INT;
    DECLARE cur CURSOR FOR SELECT DISTINCT category FROM chunks ORDER BY category;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    cat_loop: LOOP
        FETCH cur INTO v_cat;
        IF done THEN LEAVE cat_loop; END IF;

        SELECT GROUP_CONCAT(id ORDER BY id), COUNT(*) INTO v_forced, v_n
        FROM (SELECT c.id FROM chunks c FORCE INDEX (ix_category)
              WHERE c.category = v_cat AND c.word_count >= 100
              ORDER BY VEC_DISTANCE_COSINE(c.embedding, @qv) LIMIT 10) f;

        SELECT GROUP_CONCAT(id ORDER BY id) INTO v_exact
        FROM (SELECT c.id FROM chunks c IGNORE INDEX (embedding)
              WHERE c.category = v_cat AND c.word_count >= 100
              ORDER BY VEC_DISTANCE_COSINE(c.embedding, @qv) LIMIT 10) e;

        SELECT LEAST(10, COUNT(*)) INTO v_expect
        FROM chunks WHERE category = v_cat AND word_count >= 100;

        IF v_n <> v_expect OR NOT (v_forced <=> v_exact) THEN
            SET @t6_bad = @t6_bad + 1;
            SET @t6_detail = CONCAT(@t6_detail, ' ', v_cat, '(', v_n, '/', v_expect, ')');
        END IF;
    END LOOP;
    CLOSE cur;
END //
DELIMITER ;

SET @t6_fail = (@t6_bad > 0);
SELECT IF(@t6_fail, CONCAT('FAIL: ', @t6_bad, ' category(ies) differ:', @t6_detail), 'PASS') AS result;
SET @failures = @failures + @t6_fail;

-- ---------------------------------------------------------------------------
-- T7: the documented under-return still reproduces
-- ---------------------------------------------------------------------------
-- A test that asserts a defect still EXISTS. The README makes a claim about
-- MariaDB's behaviour; this test's job is to say when that claim stops being
-- true. If it fails, MariaDB has changed and the write-up needs updating.
--
-- WHERE it is asserted changed on 2026-10-28. This test originally built a
-- separate 3-dimension harness in a scratch database, because finding 7c
-- recorded a NON-reproduction at 384 dimensions. 7c was withdrawn: the
-- shortfall does reproduce at 384 dimensions, so the test now runs against the
-- real schema and the scratch database is gone.
--
-- THE RETRY LOOP IS KEPT, and the reason is worth recording. A first attempt
-- at this test asserted a single index build, on the strength of four
-- consecutive builds that all under-returned. Widening to five builds gave
-- 10, 0, 2, 3, 0 -- so a single build really is a coin toss at 384 dimensions
-- too, exactly as it is at 3, and the original author's loop was right. HNSW
-- assigns node levels randomly per build, and `fixture.sql`'s own index build
-- is as likely as any other to be a good one.
--
-- The filter is the category whose nearest chunk is FURTHEST from the query:
-- post-filtering explores the graph near the query and discards what fails the
-- predicate, so a predicate keeping only distant rows is what starves it.
-- Chosen by measurement rather than hardcoded, so the test still means
-- something when the corpus changes or on real embeddings.
--
-- NOTE: this rebuilds the vector index, up to @t7_builds times. Later tests
-- see the last build. It is the only test that mutates the index.
SELECT 'T7: under-return still reproduces on the real schema' AS test;

SET @t7_builds = IFNULL(@t7_builds, 5);
SET @qv = (SELECT embedding FROM eval_queries ORDER BY id LIMIT 1);

-- The category pointing furthest away from this query.
SELECT category INTO @t7_far
FROM (SELECT c.category, MIN(VEC_DISTANCE_COSINE(c.embedding, @qv)) AS d
      FROM chunks c IGNORE INDEX (embedding)
      GROUP BY c.category) s
ORDER BY d DESC
LIMIT 1;

SELECT COUNT(*) INTO @t7_match FROM chunks WHERE category = @t7_far;

SET @t7_min = 10;
SET @t7_seen = '';

DELIMITER //
BEGIN NOT ATOMIC
    DECLARE b INT DEFAULT 0;
    DECLARE v_got INT;
    SET SESSION mhnsw_ef_search = 20;
    WHILE b < @t7_builds AND @t7_min = 10 DO
        IF b > 0 THEN
            ALTER TABLE chunks DROP INDEX embedding;
            ALTER TABLE chunks ADD VECTOR INDEX (embedding) DISTANCE=cosine;
        END IF;
        SELECT COUNT(*) INTO v_got
        FROM (SELECT c.id FROM chunks c
              WHERE c.category = @t7_far
              ORDER BY VEC_DISTANCE_COSINE(c.embedding, @qv) LIMIT 10) t;
        SET @t7_seen = CONCAT(@t7_seen, IF(b = 0, '', ','), v_got);
        SET @t7_min = LEAST(@t7_min, v_got);
        SET b = b + 1;
    END WHILE;
    SET SESSION mhnsw_ef_search = DEFAULT;
END //
DELIMITER ;

-- @t7_match guards against passing for the trivial reason that the category
-- holds fewer than the 10 rows requested.
SET @t7_fail = (@t7_match < 10 OR @t7_min >= 10);
SELECT CASE
         WHEN @t7_match < 10
           THEN CONCAT('FAIL: category ', @t7_far, ' has only ', @t7_match,
                       ' chunks -- cannot test a LIMIT 10 shortfall')
         WHEN @t7_min >= 10
           THEN CONCAT('FAIL: ', @t7_builds, ' builds on ', @t7_far,
                       ' all returned the full 10 (', @t7_seen,
                       ') -- the documented defect no longer reproduces;',
                       ' update 09_verified_findings.md 7c and the README')
         ELSE CONCAT('PASS: unhinted filter on ', @t7_far,
                     ' returned ', @t7_seen, ' of 10 requested across builds, ',
                     @t7_match, ' rows matching')
       END AS result;
SET @failures = @failures + @t7_fail;

-- ---------------------------------------------------------------------------
-- T10: category selectivity vs the optimizer's crossover -- REPORT ONLY
-- ---------------------------------------------------------------------------
-- Above ~7% an equality filter stops being pre-filtered and the unhinted
-- query can silently under-return (09_verified_findings.md, 7b). FORCE INDEX
-- protects the committed queries either way (T6, T9); this test guards the
-- corpus sizing assumption in 03_corpus.md.
--
-- SETTLED 2026-10-22: this REPORTS, it does not gate. Janhavi raised the
-- question in the PR that added it -- 03_corpus.md plans nine categories at
-- ~11% each, deliberately above the crossover, so as a gate T10 would fail
-- every run on the real corpus for a condition the design knowingly accepts.
--
-- Retiring it outright would lose the number, which is worth watching: it says
-- how far above the crossover the corpus sits, and therefore how much the
-- design is leaning on FORCE INDEX. So it prints the selectivity of every
-- category and never fails. T9 (the hint is present) and T6 (the hinted query
-- is exact) are the gates that the design actually rests on.
SELECT 'T10: category selectivity vs the optimizer crossover (report only)' AS test;

SET @crossover_pct = IFNULL(@crossover_pct, 7.0);

SELECT category,
       ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM chunks), 2) AS pct_of_corpus,
       IF(100 * COUNT(*) / (SELECT COUNT(*) FROM chunks) > @crossover_pct,
          'above -- relies on FORCE INDEX', 'below -- pre-filtered either way') AS vs_crossover
FROM chunks
GROUP BY category
ORDER BY pct_of_corpus DESC;

SELECT COUNT(*) INTO @t10_above
FROM (SELECT category, 100 * COUNT(*) / (SELECT COUNT(*) FROM chunks) AS pct
      FROM chunks GROUP BY category) s
WHERE pct > @crossover_pct;

SELECT CONCAT('REPORT: ', @t10_above, ' of ',
              (SELECT COUNT(DISTINCT category) FROM chunks),
              ' categories sit above ', @crossover_pct,
              '% selectivity, so FORCE INDEX is load-bearing for them') AS result;

-- ---------------------------------------------------------------------------
-- Fail the run if anything above failed
-- ---------------------------------------------------------------------------
-- SIGNAL makes the client exit non-zero, which is what CI checks. Without it
-- a failing test would print "FAIL" and the build would still go green.
SELECT @failures AS failed_tests;

DELIMITER //
BEGIN NOT ATOMIC
    IF @failures > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Evaluation tests failed -- see the FAIL lines above';
    END IF;
END //
DELIMITER ;

SELECT 'All SQL tests passed (T8 and T9 run in CI).' AS result;
