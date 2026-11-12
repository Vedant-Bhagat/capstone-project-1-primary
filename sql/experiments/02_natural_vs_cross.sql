-- The objection: the worst cases pair a bird question with the ethics filter,
-- and nobody runs that. So split the 486 filtered queries into
--   NATURAL    -- the filter is the query's own topic (its true nearest chunk
--                 overall lives in that category)
--   CROSS      -- the filter is some other topic
-- and ask whether the defect survives on the natural ones alone.
USE wikirag;

DROP TABLE IF EXISTS query_home;
CREATE TABLE query_home (
  qid INT PRIMARY KEY,
  home VARCHAR(32)
);

-- A query's home category = the category of its true nearest chunk in the
-- whole corpus, computed exhaustively so the index cannot influence it.
INSERT INTO query_home
SELECT e.id,
       (SELECT c.category FROM chunks c IGNORE INDEX (embedding)
         ORDER BY VEC_DISTANCE_COSINE(c.embedding, e.embedding) LIMIT 1)
FROM eval_queries e;

SELECT '=== how many queries land in each home category ===' AS '';
SELECT home, COUNT(*) AS queries FROM query_home GROUP BY home ORDER BY queries DESC;

SELECT '=== NATURAL vs CROSS: the headline split ===' AS '';
SELECT IF(r.category = h.home, 'natural (own topic)', 'cross (other topic)') AS kind,
       COUNT(*)                                        AS filtered_queries,
       SUM(r.returned = 0)                             AS returned_zero,
       SUM(r.returned > 0 AND r.returned < r.truth_n)  AS partial,
       SUM(r.returned = r.truth_n)                     AS full_looking,
       SUM(r.returned = r.truth_n AND r.overlap < 10)  AS full_but_wrong,
       SUM(r.returned = r.truth_n AND r.overlap = 0)   AS not_one_right_row,
       ROUND(SUM(r.overlap) / (COUNT(*) * 10), 4)      AS recall_at_10
FROM real_sweep r JOIN query_home h ON h.qid = r.qid
GROUP BY kind;

SELECT '=== natural pairs only: how far off, when wrong ===' AS '';
SELECT COUNT(*) AS wrong_natural_cases,
       SUM(ABS(r.got_worst - r.tru_worst) < 1e-12) AS exact_ties,
       SUM(r.got_worst > r.tru_worst + 1e-9)       AS genuinely_worse,
       ROUND(AVG((r.got_mean - r.tru_mean) / r.tru_mean * 100), 1) AS mean_pct_further,
       MIN(r.overlap) AS fewest_genuine
FROM real_sweep r JOIN query_home h ON h.qid = r.qid
WHERE r.category = h.home AND r.returned = r.truth_n AND r.overlap < 10;

SELECT '=== every natural pair, worst first ===' AS '';
SELECT r.qid, LEFT(e.query_text, 50) AS query, r.category,
       r.returned, r.truth_n, r.overlap AS genuine_of_10,
       ROUND((r.got_mean - r.tru_mean) / NULLIF(r.tru_mean, 0) * 100, 1) AS pct_further
FROM real_sweep r
JOIN query_home h ON h.qid = r.qid
JOIN eval_queries e ON e.id = r.qid
WHERE r.category = h.home
ORDER BY r.overlap ASC, r.returned ASC
LIMIT 20;

SELECT '=== unfiltered control: does plain top-10 with no WHERE work? ===' AS '';
-- If the unfiltered query is fine, the filter is the trigger and nothing else.
DROP TABLE IF EXISTS control;
CREATE TABLE control (qid INT PRIMARY KEY, returned INT, overlap INT);
DROP PROCEDURE IF EXISTS do_control;
DELIMITER $$
CREATE PROCEDURE do_control()
BEGIN
  DECLARE d INT DEFAULT 0;
  DECLARE q INT;
  DECLARE cur CURSOR FOR SELECT id FROM eval_queries ORDER BY id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET d = 1;
  OPEN cur;
  l: LOOP
    FETCH cur INTO q;
    IF d THEN LEAVE l; END IF;
    SET @qv = (SELECT embedding FROM eval_queries WHERE id = q);
    SET @g = (SELECT GROUP_CONCAT(id) FROM
        (SELECT id FROM chunks ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) a);
    SET @t = (SELECT GROUP_CONCAT(id) FROM
        (SELECT id FROM chunks IGNORE INDEX (embedding)
          ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) b);
    INSERT INTO control VALUES (q,
      IF(@g IS NULL, 0, LENGTH(@g) - LENGTH(REPLACE(@g, ',', '')) + 1),
      (SELECT COUNT(*) FROM chunks WHERE FIND_IN_SET(id, @g) AND FIND_IN_SET(id, @t)));
  END LOOP l;
  CLOSE cur;
END$$
DELIMITER ;
CALL do_control();

SELECT COUNT(*) AS unfiltered_queries,
       SUM(returned < 10) AS short,
       ROUND(SUM(overlap) / (COUNT(*) * 10), 4) AS recall_at_10
FROM control;
