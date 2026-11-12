-- The decisive case: a filter that is uncorrelated with query meaning AND not
-- semantically clustered -- which is what a real production filter is.
--
-- `category` is a clustered filter: all its rows sit together in vector space.
-- A tenant id, a permission group, a language or a date range is not like
-- that: it picks a scattered subset of the corpus at the same selectivity.
--
-- So: add tenant = id MOD 9 (nine tenants, ~2,072 chunks each, ~11% each,
-- matching the category selectivity) and re-run. If recall collapses here too,
-- the defect hits the filters people actually use. If it does not, the defect
-- is specific to clustered filters and we must say so.
USE wikirag;

ALTER TABLE chunks ADD COLUMN IF NOT EXISTS tenant TINYINT NOT NULL DEFAULT 0;
UPDATE chunks SET tenant = MOD(id, 9);
ALTER TABLE chunks ADD INDEX IF NOT EXISTS ix_tenant (tenant);

SELECT '=== tenant sizes, for comparison with the category sizes ===' AS '';
SELECT tenant, COUNT(*) AS chunks FROM chunks GROUP BY tenant ORDER BY tenant;

DROP TABLE IF EXISTS tenant_sweep;
CREATE TABLE tenant_sweep (
  qid INT, tenant TINYINT,
  returned INT, truth_n INT, overlap INT,
  got_mean DOUBLE, tru_mean DOUBLE, got_worst DOUBLE, tru_worst DOUBLE,
  PRIMARY KEY (qid, tenant)
);

DROP PROCEDURE IF EXISTS tenant_sweep_all;
DELIMITER $$
CREATE PROCEDURE tenant_sweep_all()
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
    WHILE tn < 9 DO
      SET @g = (SELECT GROUP_CONCAT(id) FROM
          (SELECT id FROM chunks WHERE tenant = tn
             ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) a);
      SET @t = (SELECT GROUP_CONCAT(id) FROM
          (SELECT id FROM chunks IGNORE INDEX (embedding) WHERE tenant = tn
             ORDER BY VEC_DISTANCE_COSINE(embedding, @qv) LIMIT 10) b);
      INSERT INTO tenant_sweep VALUES (q, tn,
        IF(@g IS NULL, 0, LENGTH(@g) - LENGTH(REPLACE(@g, ',', '')) + 1),
        IF(@t IS NULL, 0, LENGTH(@t) - LENGTH(REPLACE(@t, ',', '')) + 1),
        IF(@g IS NULL OR @t IS NULL, 0,
           (SELECT COUNT(*) FROM chunks WHERE FIND_IN_SET(id, @g) AND FIND_IN_SET(id, @t))),
        (SELECT AVG(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @g)),
        (SELECT AVG(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @t)),
        (SELECT MAX(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @g)),
        (SELECT MAX(VEC_DISTANCE_COSINE(embedding, @qv)) FROM chunks WHERE FIND_IN_SET(id, @t)));
      SET tn = tn + 1;
    END WHILE;
  END LOOP l;
  CLOSE cur;
END$$
DELIMITER ;

CALL tenant_sweep_all();

SELECT '=== TENANT FILTER: 54 queries x 9 tenants, ~11% selectivity each ===' AS '';
SELECT COUNT(*) AS filtered_queries,
       SUM(returned = 0)                        AS returned_zero,
       SUM(returned > 0 AND returned < truth_n) AS partial,
       SUM(returned = truth_n)                  AS full_looking,
       SUM(returned = truth_n AND overlap < 10) AS full_but_wrong,
       SUM(returned = truth_n AND overlap = 0)  AS not_one_right_row,
       ROUND(SUM(overlap) / (COUNT(*) * 10), 4) AS recall_at_10
FROM tenant_sweep;

SELECT '=== ties, or genuinely worse? ===' AS '';
SELECT COUNT(*) AS wrong_cases,
       SUM(ABS(got_worst - tru_worst) < 1e-12) AS exact_ties,
       SUM(got_worst > tru_worst + 1e-9)       AS genuinely_worse,
       ROUND(AVG((got_mean - tru_mean) / NULLIF(tru_mean,0) * 100), 1) AS mean_pct_further
FROM tenant_sweep WHERE returned = truth_n AND overlap < 10;

SELECT '=== side by side: the three filter kinds ===' AS '';
SELECT 'no filter at all' AS filter_kind, COUNT(*) AS queries,
       SUM(returned < 10) AS short_or_zero, NULL AS full_but_wrong,
       ROUND(SUM(overlap) / (COUNT(*) * 10), 4) AS recall_at_10
FROM control
UNION ALL
SELECT 'topic filter, query own topic', COUNT(*), SUM(r.returned < r.truth_n),
       SUM(r.returned = r.truth_n AND r.overlap < 10),
       ROUND(SUM(r.overlap) / (COUNT(*) * 10), 4)
FROM real_sweep r JOIN query_home h ON h.qid = r.qid WHERE r.category = h.home
UNION ALL
SELECT 'tenant filter (uncorrelated)', COUNT(*), SUM(returned < truth_n),
       SUM(returned = truth_n AND overlap < 10),
       ROUND(SUM(overlap) / (COUNT(*) * 10), 4)
FROM tenant_sweep
UNION ALL
SELECT 'topic filter, other topic', COUNT(*), SUM(r.returned < r.truth_n),
       SUM(r.returned = r.truth_n AND r.overlap < 10),
       ROUND(SUM(r.overlap) / (COUNT(*) * 10), 4)
FROM real_sweep r JOIN query_home h ON h.qid = r.qid WHERE r.category <> h.home;

SELECT '=== worst tenant cases ===' AS '';
SELECT t.qid, LEFT(e.query_text, 46) AS query, t.tenant, t.returned, t.truth_n,
       t.overlap AS genuine_of_10,
       ROUND((t.got_mean - t.tru_mean) / NULLIF(t.tru_mean,0) * 100, 1) AS pct_further
FROM tenant_sweep t JOIN eval_queries e ON e.id = t.qid
ORDER BY t.overlap ASC, pct_further DESC LIMIT 10;
