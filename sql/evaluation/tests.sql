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
--   T7  the documented under-return still reproduces at 3 dimensions
--   T8  semantic search uses the vector index           -> ci.yml (EXPLAIN)
--   T9  every committed hybrid query keeps FORCE INDEX   -> ci.yml (grep)
--   T10 no category exceeds the optimizer crossover selectivity
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
-- Where it is tested matters. Finding 7c: at 384 dimensions on the fixture the
-- shortfall does NOT reproduce, so asserting it on `wikirag` would fail for
-- the wrong reason. It is asserted where it was established -- the 3-dimension
-- harness of docs/main_dish_spec/probe/vector_probe.sql, sections 8 and 13 --
-- in a scratch database that is dropped afterwards.
--
-- HNSW levels are random per build, so a single build is a coin toss. The
-- index is rebuilt up to three times and the test passes if ANY build returns
-- fewer than the 10 rows requested (20 match). Across 11 builds observed so
-- far at ef_search = 20, none returned 10.
--
-- Whether it reproduces on REAL embeddings is the open question (finding 7c);
-- under_return.sql answers that once component A's corpus is loaded.
SELECT 'T7: under-return still reproduces on the 3-dimension harness' AS test;

DROP DATABASE IF EXISTS wikirag_t7;
CREATE DATABASE wikirag_t7;
SET @t7_min = 10;
SET @t7_seen = '';

DELIMITER //
BEGIN NOT ATOMIC
    DECLARE b INT DEFAULT 0;
    DECLARE v_got INT;
    SET max_recursive_iterations = 100000;
    SET SESSION mhnsw_ef_search = 20;
    WHILE b < 3 AND @t7_min = 10 DO
        DROP TABLE IF EXISTS wikirag_t7.docs;
        CREATE TABLE wikirag_t7.docs (
            id  INT         NOT NULL PRIMARY KEY,
            tag VARCHAR(16) NOT NULL,                 -- UNINDEXED filter column
            v   VECTOR(3)   NOT NULL,
            VECTOR INDEX (v) DISTANCE=cosine
        );
        INSERT INTO wikirag_t7.docs (id, tag, v)
        WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i + 1 FROM n WHERE i < 2000)
        SELECT i, IF(i % 100 = 0, 'needle', 'bulk'),
               VEC_FromText(CONCAT('[', RAND(i)*2-1, ',', RAND(i*7)*2-1, ',', RAND(i*13)*2-1, ']'))
        FROM n;

        SET @q3 = VEC_FromText('[1,0,0]');
        SELECT COUNT(*) INTO v_got
        FROM (SELECT id FROM wikirag_t7.docs WHERE tag = 'needle'
              ORDER BY VEC_DISTANCE_COSINE(v, @q3) LIMIT 10) t;

        SET @t7_seen = CONCAT(@t7_seen, IF(b = 0, '', ','), v_got);
        SET @t7_min = LEAST(@t7_min, v_got);
        SET b = b + 1;
    END WHILE;
    SET SESSION mhnsw_ef_search = DEFAULT;
END //
DELIMITER ;

DROP DATABASE wikirag_t7;
USE wikirag;

SET @t7_fail = (@t7_min >= 10);
SELECT IF(@t7_fail,
          CONCAT('FAIL: three builds returned the full 10 (', @t7_seen,
                 ') -- the documented defect no longer reproduces; update 09_verified_findings.md and the README'),
          CONCAT('PASS: rows returned per build: ', @t7_seen, ' of 10 requested, 20 matching')) AS result;
SET @failures = @failures + @t7_fail;

-- ---------------------------------------------------------------------------
-- T10: no category is above the optimizer's crossover selectivity
-- ---------------------------------------------------------------------------
-- Above ~7% an equality filter stops being pre-filtered and the unhinted
-- query can silently under-return (09_verified_findings.md, 7b). FORCE INDEX
-- protects the committed queries either way (T6, T9); this test guards the
-- corpus sizing assumption in 03_corpus.md.
--
-- NOTE: 03_corpus.md now plans nine categories at ~11.6% each, deliberately
-- above the crossover and relying on the hint. On that corpus this test FAILS
-- by design. The threshold is a session variable so the team can settle it --
-- either re-measure the crossover at 384 dimensions (09 checklist) and set
-- @crossover_pct to the measured value, or retire T10 in favour of T9.
SELECT 'T10: no category exceeds the crossover selectivity' AS test;

SET @crossover_pct = IFNULL(@crossover_pct, 7.0);
SELECT COUNT(*), IFNULL(GROUP_CONCAT(CONCAT(category, '=', pct, '%') ORDER BY pct DESC), '')
  INTO @t10_bad, @t10_detail
FROM (SELECT category, ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM chunks), 2) AS pct
      FROM chunks GROUP BY category) s
WHERE pct > @crossover_pct;

SELECT ROUND(MAX(pct), 2) INTO @t10_max
FROM (SELECT 100 * COUNT(*) / (SELECT COUNT(*) FROM chunks) AS pct FROM chunks GROUP BY category) s;

SET @t10_fail = (@t10_bad > 0);
SELECT IF(@t10_fail,
          CONCAT('FAIL: ', @t10_bad, ' category(ies) above ', @crossover_pct, '%: ', @t10_detail),
          CONCAT('PASS: largest category is ', @t10_max, '% (threshold ', @crossover_pct, '%)')) AS result;
SET @failures = @failures + @t10_fail;

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
