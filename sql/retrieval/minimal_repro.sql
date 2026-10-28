-- Minimal reproduction of the filtered vector-search under-return.
--
--     mariadb -u root < sql/retrieval/minimal_repro.sql
--
-- Runs in about a second, needs no corpus, no embedding model and no Python,
-- and creates and drops only its own database `mdev_repro`. This is the file
-- `docs/bug_report_draft.md` was gated on: decision D6 required the report be
-- reduced from "needs 18,651 Wikipedia embeddings" to "needs a table".
--
-- WHY IT LOOKS LIKE THIS, point by point. Each choice answers an objection
-- that closed somebody else's ticket:
--
--   * No RAND(). Every vector is a deterministic function of its row id and
--     dimension index (trig and MOD), so two people on two platforms load
--     byte-identical data. MDEV-37709, the same symptom as this, was closed
--     "Incomplete" because the reporter could not shrink a 250 MB dump.
--     Nothing here needs shipping anywhere.
--
--   * Clustered, not uniform-random, vectors. MDEV-35071 and MDEV-36317 were
--     both closed "Won't Fix" with the reasoning that "many algorithms perform
--     poorly on uniformly distributed random vectors". So every row here is a
--     shared common direction, plus a per-category offset, plus small jitter:
--     the anisotropic clustered geometry real text embeddings actually have.
--
--   * 2048 rows is not padding. Measured: at 512 rows the optimizer picks
--     ix_cat (ref + filesort) and every category correctly returns 10. From
--     768 rows it switches to the vector index and the shortfall appears. The
--     table has to be big enough for the vector plan to win on cost or there
--     is no bug to see. EXPLAIN is printed below so a reader can check which
--     plan they actually got instead of trusting this comment.
--
--   * 16 dimensions, 8 categories, one TINYINT filter column. MDEV-37709's
--     reviewer asked for id and embedding only; a filter column is the single
--     extra thing this defect needs by definition.

DROP DATABASE IF EXISTS mdev_repro;
CREATE DATABASE mdev_repro;
USE mdev_repro;

CREATE TABLE t (
  id  INT PRIMARY KEY,
  cat TINYINT NOT NULL,
  v   VECTOR(16) NOT NULL,
  KEY ix_cat (cat),
  VECTOR INDEX (v) M=6 DISTANCE=cosine   -- M set here, so the server's
) ENGINE=InnoDB;                         -- mhnsw_default_m cannot change it

-- 2048 rows in 8 categories of 256. Component j of row i is
--   common(j) + offset(cat, j) + jitter(i, j)
-- with the categories evenly spaced in phase so that no two clusters coincide.
INSERT INTO t (id, cat, v)
SELECT r.seq,
       MOD(r.seq, 8),
       VEC_FromText(CONCAT('[', GROUP_CONCAT(
           ROUND(
               (0.5 + 0.3 * SIN(d.seq))                               -- common
             + 0.35 * SIN(2 * PI() * MOD(r.seq, 8) / 8 + d.seq * 1.1) -- cluster
             + 0.08 * (MOD(r.seq * 7919 + d.seq * 104729, 2003)
                       / 2003.0 - 0.5)                                -- jitter
           , 6)
           ORDER BY d.seq SEPARATOR ','), ']'))
FROM seq_1_to_2048 r JOIN seq_1_to_16 d
GROUP BY r.seq;

-- The query vector is the exact centroid of category 0, so category 0 is the
-- nearest cluster and the other seven sit at a range of angles from it.
SET @q = (SELECT CONCAT('[', GROUP_CONCAT(
            ROUND((0.5 + 0.3 * SIN(d.seq)) + 0.35 * SIN(d.seq * 1.1), 6)
            ORDER BY d.seq SEPARATOR ','), ']')
          FROM seq_1_to_16 d);

SELECT VERSION() AS server, @@mhnsw_ef_search AS ef_search;
EXPLAIN SELECT id FROM t WHERE cat = 4
        ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10;

-- For each category: how many rows match the filter, how close the nearest of
-- them is, and how many rows each of the three plans returns for LIMIT 10.
CREATE TABLE result (
  cat        TINYINT PRIMARY KEY,
  matching   INT,
  nearest    DECIMAL(8,4),
  unhinted   INT,   -- the optimizer's choice: the vector index
  forced     INT,   -- FORCE INDEX (ix_cat): b-tree, then exact distances
  exhaustive INT    -- IGNORE INDEX (v): full scan, the ground truth
);

DELIMITER $$
CREATE PROCEDURE measure()
BEGIN
  DECLARE c TINYINT DEFAULT 0;
  WHILE c < 8 DO
    INSERT INTO result
    SELECT c,
      (SELECT COUNT(*) FROM t WHERE cat = c),
      (SELECT MIN(VEC_DISTANCE_COSINE(v, VEC_FromText(@q)))
         FROM t WHERE cat = c),
      (SELECT COUNT(*) FROM (SELECT id FROM t WHERE cat = c
         ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10) a),
      (SELECT COUNT(*) FROM (SELECT id FROM t FORCE INDEX (ix_cat) WHERE cat = c
         ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10) b),
      (SELECT COUNT(*) FROM (SELECT id FROM t IGNORE INDEX (v) WHERE cat = c
         ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10) e);
    SET c = c + 1;
  END WHILE;
END$$
DELIMITER ;

CALL measure();
SELECT * FROM result ORDER BY nearest;

SELECT IF(MIN(unhinted) < 10,
          CONCAT('REPRODUCED: ', SUM(unhinted < 10), ' of 8 categories returned ',
                 'fewer than the 10 rows requested; the worst returned ',
                 MIN(unhinted), '. FORCE INDEX and IGNORE INDEX both returned ',
                 '10 for every category.'),
          'NOT reproduced here -- check that EXPLAIN above chose index v')
       AS verdict
FROM result;

-- Does widening the search recover them? On this data, no: not at any
-- ef_search up to the size of the entire table.
SELECT 'ef_search sweep, category 4' AS sweep;
SET SESSION mhnsw_ef_search = 10;
SELECT 10 AS ef, COUNT(*) AS returned FROM (SELECT id FROM t WHERE cat = 4
  ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10) x;
SET SESSION mhnsw_ef_search = 100;
SELECT 100 AS ef, COUNT(*) AS returned FROM (SELECT id FROM t WHERE cat = 4
  ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10) x;
SET SESSION mhnsw_ef_search = 2000;
SELECT 2000 AS ef, COUNT(*) AS returned FROM (SELECT id FROM t WHERE cat = 4
  ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10) x;
SET SESSION mhnsw_ef_search = DEFAULT;

-- What we measured on 12.3.3, recorded so a reader can tell whether their
-- server behaves as ours did:
--
--   cat  matching  nearest  unhinted  forced  exhaustive
--     0       256   0.0005        10      10          10
--     7       256   0.0326         0      10          10
--     1       256   0.0332        10      10          10
--     6       256   0.1274         0      10          10
--     2       256   0.1337         0      10          10
--     5       256   0.2468         0      10          10
--     3       256   0.2644         0      10          10
--     4       256   0.3161         0      10          10
--
-- Look at categories 7 and 1: 0.0326 against 0.0332, a 2% difference in
-- distance, and one returns nothing while the other returns everything. So
-- distance from the query predicts the shortfall far better than selectivity
-- does -- all eight categories here are exactly 12.5% of the table and they do
-- not behave alike -- but it is NOT a clean threshold in distance either. We
-- can rank categories by risk. We cannot draw the line.
--
-- Unlike the real corpus, this case is perfectly repeatable: identical across
-- five consecutive runs and across five DROP/ADD INDEX rebuilds. So it
-- reproduces the under-return but NOT the run-to-run instability we also saw,
-- and it is the wrong test case for that half of the problem.
--
-- Raising M helps, is not monotonic, and never fully fixes it. Rows returned
-- per category in id order:
--   M=6    10, 10,  0,  0,  0,  0,  0,  0
--   M=16   10,  0,  0, 10, 10, 10, 10, 10   <- category 1 BREAKS at M 6 -> 16
--   M=32   10, 10,  0, 10, 10, 10, 10, 10
--   M=64   10, 10,  0, 10, 10, 10, 10, 10
-- Category 2 is short at every M from 6 to 64.
