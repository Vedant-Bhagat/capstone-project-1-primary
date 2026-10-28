-- ===========================================================================
-- recall_sweep.sql -- recall and latency of the vector index across the
-- mhnsw_ef_search dial, against the brute-force ground truth.
--
-- Spec: docs/main_dish_spec/07_evaluation.md, "Measuring recall" through
--       "Measuring latency honestly".
-- Run:  mariadb -u root -t < sql/evaluation/recall_sweep.sql
--   PowerShell:  Get-Content sql/evaluation/recall_sweep.sql | mariadb -u root -t
--
-- Prerequisite: ground_truth.sql has been run on the current corpus.
--
-- The deliverable is the table this prints -- a curve, not a number -- and in
-- particular the smallest ef_search at which recall@10 >= 0.98.
--
-- WHAT IS MEASURED, per (ef_search, k, query):
--   hits      |indexed top-k  ∩  exact top-k|
--   returned  how many rows the indexed query actually returned. Recorded
--             separately from hits because a silent truncation is invisible
--             to a metric that divides by what it received. returned < k is
--             the under-return behaviour of docs/main_dish_spec/09 finding 7.
--   timing    one untimed warm-up, then @reps timed repetitions.
--
-- HOW LATENCY IS MEASURED (07, "Measuring latency honestly"):
--   1. Warm-up first. The first query after a load pays for a cold buffer
--      pool and a cold mhnsw cache.
--   2. Repeated. Every repetition is kept in rep_timings, and the summary
--      reports mean, min, max and STDDEV_SAMP over all of them.
--   3. The query, not the transfer: timed as SELECT COUNT(*) INTO a local
--      variable, so no result set is serialised to the client.
--   4. ef_search is set explicitly for every configuration, never inherited.
--   5. mhnsw_max_cache_size is a GLOBAL variable, so this script does not
--      change it; it reports the value in effect. To measure with the cache
--      raised: SET GLOBAL mhnsw_max_cache_size = <bytes>; then re-run.
--   The hardware is not visible from SQL; docs/findings.md states it.
--
-- BRUTE FORCE is recorded as ef_search = 0: the same query with
-- IGNORE INDEX (embedding). It is the "is the index earning its place?" row.
-- Its recall must be exactly 1.0 -- if it is not, the ground truth is wrong.
-- ===========================================================================

USE wikirag;

-- Repetitions per query per configuration. 10 is the spec's minimum for a
-- reported number; CI passes a smaller value to stay fast.
SET @reps = IFNULL(@reps, 10);

-- One row per timed repetition. TEMPORARY because only this run's summary
-- needs it; recall_runs (in schema.sql) keeps the per-query result.
CREATE OR REPLACE TEMPORARY TABLE rep_timings (
    ef_search   INT      NOT NULL,
    k           SMALLINT NOT NULL,
    query_id    INT      NOT NULL,
    rep         SMALLINT NOT NULL,
    elapsed_us  BIGINT   NOT NULL,
    PRIMARY KEY (ef_search, k, query_id, rep)
);

DELIMITER $$

CREATE OR REPLACE PROCEDURE measure_recall(IN p_ef INT, IN p_k INT, IN p_reps INT)
BEGIN
    DECLARE done   INT DEFAULT 0;
    DECLARE v_qid  INT;
    DECLARE v_vec  VECTOR(384);
    DECLARE v_hits INT;
    DECLARE v_ret  INT;
    DECLARE sink   INT;
    DECLARE r      INT;
    DECLARE t0     DATETIME(6);
    DECLARE cur CURSOR FOR SELECT id, embedding FROM eval_queries ORDER BY id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    -- Explicit, every time. 0 means brute force, which ignores the dial.
    IF p_ef > 0 THEN
        SET SESSION mhnsw_ef_search = p_ef;
    END IF;

    DELETE FROM recall_runs WHERE ef_search = p_ef AND k = p_k;
    DELETE FROM rep_timings WHERE ef_search = p_ef AND k = p_k;

    OPEN cur;
    query_loop: LOOP
        FETCH cur INTO v_qid, v_vec;
        IF done THEN
            LEAVE query_loop;
        END IF;

        -- A user variable rather than the local: this is the form whose plan
        -- is checked by EXPLAIN (key: embedding), so what is timed is the
        -- indexed access path and not something the optimizer chose instead.
        SET @qv = v_vec;

        -- Warm-up, untimed. Also the pass that scores the result: HNSW search
        -- over a fixed graph is deterministic, so the timed repetitions below
        -- return these same rows.
        IF p_ef > 0 THEN
            SELECT COUNT(*), COUNT(t.chunk_id) INTO v_ret, v_hits
            FROM (SELECT id FROM chunks
                  ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT p_k) g
            LEFT JOIN eval_ground_truth t
                   ON t.query_id = v_qid AND t.chunk_id = g.id AND t.rank_pos <= p_k;
        ELSE
            SELECT COUNT(*), COUNT(t.chunk_id) INTO v_ret, v_hits
            FROM (SELECT id FROM chunks IGNORE INDEX (embedding)
                  ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT p_k) g
            LEFT JOIN eval_ground_truth t
                   ON t.query_id = v_qid AND t.chunk_id = g.id AND t.rank_pos <= p_k;
        END IF;

        -- Timed repetitions.
        SET r = 0;
        WHILE r < p_reps DO
            SET t0 = NOW(6);
            IF p_ef > 0 THEN
                SELECT COUNT(*) INTO sink
                FROM (SELECT id FROM chunks
                      ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT p_k) x;
            ELSE
                SELECT COUNT(*) INTO sink
                FROM (SELECT id FROM chunks IGNORE INDEX (embedding)
                      ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT p_k) x;
            END IF;
            INSERT INTO rep_timings (ef_search, k, query_id, rep, elapsed_us)
            VALUES (p_ef, p_k, v_qid, r, TIMESTAMPDIFF(MICROSECOND, t0, NOW(6)));
            SET r = r + 1;
        END WHILE;

        INSERT INTO recall_runs (ef_search, k, query_id, hits, returned, elapsed_us)
        SELECT p_ef, p_k, v_qid, v_hits, v_ret, ROUND(AVG(elapsed_us))
        FROM rep_timings
        WHERE ef_search = p_ef AND k = p_k AND query_id = v_qid;
    END LOOP;
    CLOSE cur;
END $$

CREATE OR REPLACE PROCEDURE recall_sweep(IN p_reps INT)
BEGIN
    DECLARE i INT DEFAULT 1;
    DECLARE v_ef INT;
    -- The dial, 10 -> 1000, spanning the point where recall should cross 98%.
    WHILE i <= 7 DO
        SET v_ef = ELT(i, 10, 20, 50, 100, 200, 500, 1000);
        CALL measure_recall(v_ef, 1,  p_reps);
        CALL measure_recall(v_ef, 10, p_reps);
        SET i = i + 1;
    END WHILE;
    CALL measure_recall(0, 1,  p_reps);       -- brute force
    CALL measure_recall(0, 10, p_reps);
    SET SESSION mhnsw_ef_search = DEFAULT;
END $$

DELIMITER ;

CALL recall_sweep(@reps);

-- ---------------------------------------------------------------------------
-- What this was measured on
-- ---------------------------------------------------------------------------
SELECT VERSION()                                   AS server,
       @@version_compile_os                        AS os,
       (SELECT embed_model FROM corpus_meta)       AS embed_model,
       (SELECT COUNT(*) FROM chunks)               AS chunks,
       (SELECT COUNT(*) FROM eval_queries)         AS queries,
       @reps                                       AS reps_per_query,
       @@mhnsw_default_m                           AS m,
       @@global.mhnsw_max_cache_size               AS mhnsw_max_cache_size;

-- ---------------------------------------------------------------------------
-- The headline table. Latency statistics are over every timed repetition of
-- every query, so sd_ms reflects both run-to-run noise and query-to-query
-- variation.
-- ---------------------------------------------------------------------------
SELECT IF(r.ef_search = 0, 'brute force', CAST(r.ef_search AS CHAR)) AS ef_search,
       r.k,
       ROUND(AVG(r.hits / r.k), 4)          AS recall,
       t.mean_ms, t.min_ms, t.max_ms, t.sd_ms,
       SUM(r.returned < r.k)                AS truncated_queries
FROM recall_runs r
JOIN (SELECT ef_search, k,
             ROUND(AVG(elapsed_us) / 1000, 3)         AS mean_ms,
             ROUND(MIN(elapsed_us) / 1000, 3)         AS min_ms,
             ROUND(MAX(elapsed_us) / 1000, 3)         AS max_ms,
             ROUND(STDDEV_SAMP(elapsed_us) / 1000, 3) AS sd_ms
      FROM rep_timings GROUP BY ef_search, k) t
  ON t.ef_search = r.ef_search AND t.k = r.k
GROUP BY r.ef_search, r.k
ORDER BY r.k, r.ef_search = 0, r.ef_search;

-- The one-sentence result: the smallest ef_search reaching the 98% bar.
SELECT IFNULL(MIN(ef_search), 'none -- recall@10 never reached 0.98') AS smallest_ef_with_recall10_ge_098
FROM (SELECT ef_search FROM recall_runs
      WHERE k = 10 AND ef_search > 0
      GROUP BY ef_search HAVING AVG(hits / k) >= 0.98) ok;

-- Per-category recall@10 at the default ef_search. eval_queries carries no
-- category, so a query is assigned the category of its exact nearest chunk --
-- the topic the corpus itself says the question is about.
SELECT c.category,
       COUNT(*)                     AS queries,
       ROUND(AVG(r.hits / r.k), 4)  AS recall_at_10_ef20
FROM recall_runs r
JOIN eval_ground_truth g ON g.query_id = r.query_id AND g.rank_pos = 1
JOIN chunks c            ON c.id = g.chunk_id
WHERE r.k = 10 AND r.ef_search = 20
GROUP BY c.category
ORDER BY recall_at_10_ef20, c.category;
