-- The same question on REAL embeddings: 54 real queries x 9 real categories.
--
-- For each (query, category) pair: what does the optimizer return for
-- LIMIT 10, and is it the true nearest 10 within that category?
-- Ground truth is IGNORE INDEX (embedding) -- a full scan with exact cosine
-- distances over the 18,651 chunks.
USE wikirag;

DROP TABLE IF EXISTS real_sweep;
CREATE TABLE real_sweep (
  qid       INT,
  category  VARCHAR(32),
  matching  INT,          -- chunks in that category
  returned  INT,          -- rows the optimizer gave back
  truth_n   INT,          -- rows exhaustive search gave back
  overlap   INT,          -- how many returned rows are in the true top 10
  got_mean  DOUBLE,
  tru_mean  DOUBLE,
  got_worst DOUBLE,
  tru_worst DOUBLE,
  PRIMARY KEY (qid, category)
);

DROP PROCEDURE IF EXISTS real_sweep_all;
DELIMITER $$
CREATE PROCEDURE real_sweep_all()
BEGIN
  DECLARE done1 INT DEFAULT 0;
  DECLARE done2 INT DEFAULT 0;
  DECLARE q INT;
  DECLARE cat VARCHAR(32);
  DECLARE g TEXT;
  DECLARE tr TEXT;
  DECLARE cur_q CURSOR FOR SELECT id FROM eval_queries ORDER BY id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET done1 = 1;

  OPEN cur_q;
  q_loop: LOOP
    FETCH cur_q INTO q;
    IF done1 THEN LEAVE q_loop; END IF;

    SET @qv = (SELECT embedding FROM eval_queries WHERE id = q);

    BEGIN
      DECLARE cur_c CURSOR FOR SELECT DISTINCT category FROM chunks ORDER BY category;
      DECLARE CONTINUE HANDLER FOR NOT FOUND SET done2 = 1;
      SET done2 = 0;
      OPEN cur_c;
      c_loop: LOOP
        FETCH cur_c INTO cat;
        IF done2 THEN LEAVE c_loop; END IF;

        SET @gl = (SELECT GROUP_CONCAT(id) FROM
            (SELECT id FROM chunks WHERE category = cat
               ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) a);
        SET @tl = (SELECT GROUP_CONCAT(id) FROM
            (SELECT id FROM chunks IGNORE INDEX (embedding) WHERE category = cat
               ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) b);

        INSERT INTO real_sweep VALUES (
          q, cat,
          (SELECT COUNT(*) FROM chunks WHERE category = cat),
          IF(@gl IS NULL, 0, LENGTH(@gl) - LENGTH(REPLACE(@gl, ',', '')) + 1),
          IF(@tl IS NULL, 0, LENGTH(@tl) - LENGTH(REPLACE(@tl, ',', '')) + 1),
          IF(@gl IS NULL OR @tl IS NULL, 0,
             (SELECT COUNT(*) FROM chunks
               WHERE FIND_IN_SET(id, @gl) AND FIND_IN_SET(id, @tl))),
          (SELECT AVG(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @gl)),
          (SELECT AVG(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @tl)),
          (SELECT MAX(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @gl)),
          (SELECT MAX(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @tl)));
        SET done2 = 0;
      END LOOP c_loop;
      CLOSE cur_c;
    END;
    SET done1 = 0;
  END LOOP q_loop;
  CLOSE cur_q;
END$$
DELIMITER ;

CALL real_sweep_all();

SELECT '=== REAL DATA: 54 queries x 9 categories ===' AS '';
SELECT COUNT(*) AS filtered_queries,
       SUM(returned = 0)                        AS returned_zero,
       SUM(returned > 0 AND returned < truth_n) AS returned_partial,
       SUM(returned = truth_n)                  AS returned_full
FROM real_sweep;

SELECT '=== recall@10 over all filtered queries ===' AS '';
SELECT ROUND(SUM(overlap) / (COUNT(*) * 10), 4) AS recall_at_10
FROM real_sweep;

SELECT '=== of the FULL-looking results, how many are the right 10? ===' AS '';
SELECT SUM(returned = truth_n)                                   AS full_results,
       SUM(returned = truth_n AND overlap = 10)                  AS correct,
       SUM(returned = truth_n AND overlap < 10)                  AS WRONG,
       SUM(returned = truth_n AND overlap = 0)                   AS not_one_correct_row,
       ROUND(AVG(IF(returned = truth_n, overlap, NULL)), 2)      AS mean_genuine_of_10
FROM real_sweep;

SELECT '=== are the wrong ones genuinely worse, or ties? ===' AS '';
SELECT COUNT(*) AS wrong_cases,
       SUM(ABS(got_worst - tru_worst) < 1e-12)  AS exact_ties,
       SUM(got_worst > tru_worst + 1e-9)        AS genuinely_worse,
       ROUND(AVG((got_mean - tru_mean) / tru_mean * 100), 1) AS mean_pct_further
FROM real_sweep
WHERE returned = truth_n AND overlap < 10;

SELECT '=== worst individual cases on real text ===' AS '';
SELECT r.qid, LEFT(e.query_text, 44) AS query, r.category, r.matching,
       r.returned, r.overlap AS genuine_of_10,
       ROUND((r.got_mean - r.tru_mean) / r.tru_mean * 100, 1) AS pct_further
FROM real_sweep r JOIN eval_queries e ON e.id = r.qid
WHERE r.returned = r.truth_n AND r.overlap < 10
ORDER BY r.overlap ASC, pct_further DESC LIMIT 12;

SELECT '=== does category size predict it? ===' AS '';
SELECT category, matching,
       COUNT(*) AS queries,
       SUM(returned = 0) AS zero,
       SUM(returned = truth_n AND overlap < 10) AS full_but_wrong,
       ROUND(SUM(overlap) / (COUNT(*) * 10), 3) AS recall_at_10
FROM real_sweep GROUP BY category, matching ORDER BY matching DESC;
