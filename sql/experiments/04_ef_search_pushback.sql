-- Does tuning fix it? Two pushbacks, measured.
--   1. "Raise mhnsw_ef_search."   -- no rebuild needed
--   2. "Use a bigger M."         -- needs an index rebuild
--
-- Same 54 queries x 3 tenants = 162 filtered queries each time, so every row
-- of the final table is comparable with every other.
USE wikirag;

DROP TABLE IF EXISTS pushback;
CREATE TABLE pushback (
  setting   VARCHAR(40),
  qid INT, tenant TINYINT,
  returned INT, truth_n INT, overlap INT,
  got_mean DOUBLE, tru_mean DOUBLE,
  PRIMARY KEY (setting, qid, tenant)
);

DROP PROCEDURE IF EXISTS sweep3;
DELIMITER $$
CREATE PROCEDURE sweep3(IN label VARCHAR(40))
BEGIN
  DECLARE d INT DEFAULT 0;
  DECLARE q INT;
  DECLARE tn TINYINT;
  DECLARE cur CURSOR FOR SELECT id FROM eval_queries ORDER BY id;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET d = 1;
  OPEN cur;
  l: LOOP
    FETCH cur INTO q;
    IF d THEN LEAVE l; END IF;
    SET @qv = (SELECT embedding FROM eval_queries WHERE id = q);
    SET tn = 0;
    WHILE tn < 3 DO
      SET @g = (SELECT GROUP_CONCAT(id) FROM
          (SELECT id FROM chunks WHERE tenant = tn
             ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) a);
      SET @t = (SELECT GROUP_CONCAT(id) FROM
          (SELECT id FROM chunks IGNORE INDEX (embedding) WHERE tenant = tn
             ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) b);
      INSERT INTO pushback VALUES (label, q, tn,
        IF(@g IS NULL, 0, LENGTH(@g) - LENGTH(REPLACE(@g, ',', '')) + 1),
        IF(@t IS NULL, 0, LENGTH(@t) - LENGTH(REPLACE(@t, ',', '')) + 1),
        IF(@g IS NULL OR @t IS NULL, 0,
           (SELECT COUNT(*) FROM chunks WHERE FIND_IN_SET(id, @g) AND FIND_IN_SET(id, @t))),
        (SELECT AVG(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @g)),
        (SELECT AVG(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @t)));
      SET tn = tn + 1;
    END WHILE;
  END LOOP l;
  CLOSE cur;
END$$
DELIMITER ;

SET @@mhnsw_ef_search = 20;   CALL sweep3('M=6 (shipped), ef_search=20');
SET @@mhnsw_ef_search = 100;  CALL sweep3('M=6, ef_search=100');
SET @@mhnsw_ef_search = 500;  CALL sweep3('M=6, ef_search=500');
SET @@mhnsw_ef_search = 2000; CALL sweep3('M=6, ef_search=2000');
SET @@mhnsw_ef_search = 20;

SELECT '=== raising ef_search only ===' AS '';
SELECT setting,
       COUNT(*) AS queries,
       SUM(returned < truth_n)                  AS short_or_zero,
       SUM(returned = truth_n AND overlap < 10)  AS full_but_wrong,
       SUM(returned = truth_n AND overlap = 0)   AS not_one_right_row,
       ROUND(SUM(overlap) / (COUNT(*) * 10), 4)  AS recall_at_10
FROM pushback GROUP BY setting ORDER BY setting;
