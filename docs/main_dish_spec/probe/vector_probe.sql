-- ===========================================================================
-- vector_probe.sql
--
-- Reproduces every claim in docs/main_dish_spec/09_verified_findings.md.
-- Written and run against MariaDB 12.3.3 on 2026-10-15.
--
-- Run:   mariadb -u root -t < vector_probe.sql
--   PowerShell:   Get-Content vector_probe.sql | mariadb -u root -t
--
-- Creates and drops a scratch database called `vecprobe`. Touches nothing else.
--
-- Statements marked EXPECT-ERROR are supposed to fail. Run with -f (--force)
-- to continue past them, or run the sections separately.
-- ===========================================================================

SELECT VERSION() AS server_version;

-- ---------------------------------------------------------------------------
-- 1. Server defaults
-- ---------------------------------------------------------------------------
SELECT '=== 1. mhnsw defaults ===' AS probe;
SHOW VARIABLES LIKE 'mhnsw%';
-- OBSERVED: mhnsw_default_distance=euclidean, mhnsw_default_m=6,
--           mhnsw_ef_search=20, mhnsw_max_cache_size=16777216

DROP DATABASE IF EXISTS vecprobe;
CREATE DATABASE vecprobe;
USE vecprobe;

-- ---------------------------------------------------------------------------
-- 2. Scalar function behaviour
-- ---------------------------------------------------------------------------
SELECT '=== 2. scalar functions ===' AS probe;
SELECT VEC_ToText(VEC_FromText('[1,2,3]'))                                AS roundtrip;
SELECT VEC_DISTANCE_COSINE(VEC_FromText('[1,0,0]'), VEC_FromText('[0,1,0]')) AS cosine_orthogonal;
SELECT VEC_DISTANCE_EUCLIDEAN(VEC_FromText('[0,0,0]'), VEC_FromText('[3,4,0]')) AS euclid_345;
SELECT VEC_DISTANCE_COSINE(VEC_FromText('[1,2,3]'), VEC_FromText('[2,4,6]')) AS cosine_scale_invariant;
-- OBSERVED: [1,2,3] | 1 | 5 | 0
-- The last one is why pre-normalising vectors is unnecessary with cosine.

-- ---------------------------------------------------------------------------
-- 3. EXPECT-ERROR: a nullable column cannot be vector-indexed  (limitation C2)
-- ---------------------------------------------------------------------------
SELECT '=== 3. nullable vector column ===' AS probe;
CREATE TABLE t_nullable (id INT PRIMARY KEY, v VECTOR(3), VECTOR INDEX (v));
-- OBSERVED: ERROR 1252 (42000): All parts of a VECTOR index must be NOT NULL

-- ---------------------------------------------------------------------------
-- 4. EXPECT-ERROR: only one vector index per table  (limitation C1)
-- ---------------------------------------------------------------------------
SELECT '=== 4. two vector indexes ===' AS probe;
CREATE TABLE t_two (id INT PRIMARY KEY, a VECTOR(3) NOT NULL, b VECTOR(3) NOT NULL,
                    VECTOR INDEX (a) DISTANCE=cosine, VECTOR INDEX (b) DISTANCE=cosine);
-- OBSERVED: ERROR 1235 (42000): This version of MariaDB doesn't yet support
--           'multiple VECTOR indexes'

-- ---------------------------------------------------------------------------
-- 5. Dimension limits
-- ---------------------------------------------------------------------------
SELECT '=== 5. dimension limits ===' AS probe;
CREATE TABLE d768  (id INT PRIMARY KEY, v VECTOR(768)  NOT NULL, VECTOR INDEX (v) DISTANCE=cosine);
CREATE TABLE d1536 (id INT PRIMARY KEY, v VECTOR(1536) NOT NULL, VECTOR INDEX (v) DISTANCE=cosine);
SELECT '768 and 1536 both accepted' AS result;
-- EXPECT-ERROR:
CREATE TABLE dbig (id INT PRIMARY KEY, v VECTOR(65533) NOT NULL, VECTOR INDEX (v) DISTANCE=cosine);
-- OBSERVED: ERROR 1074 (42000): Column length too big for column 'v'
--           (max = 16383); use BLOB or TEXT instead

-- ---------------------------------------------------------------------------
-- 6. How the index definition is stored
-- ---------------------------------------------------------------------------
SELECT '=== 6. stored index definition ===' AS probe;
CREATE TABLE t_cos (id INT PRIMARY KEY, v VECTOR(3) NOT NULL, VECTOR INDEX (v) DISTANCE=cosine);
SHOW CREATE TABLE t_cos;
-- OBSERVED: VECTOR KEY `v` (`v`) `DISTANCE`='cosine'

-- ---------------------------------------------------------------------------
-- 7. FULLTEXT and VECTOR on one table; ADD VECTOR INDEX after load
-- ---------------------------------------------------------------------------
SELECT '=== 7. index coexistence and post-load indexing ===' AS probe;
CREATE TABLE both_idx (
    id   INT         NOT NULL PRIMARY KEY,
    body TEXT        NOT NULL,
    cat  VARCHAR(16) NOT NULL,
    v    VECTOR(4)   NOT NULL,
    VECTOR INDEX (v) DISTANCE=cosine,
    FULLTEXT (body),
    INDEX (cat)
);
SELECT 'FULLTEXT + VECTOR + BTREE coexist: OK' AS result;

CREATE TABLE later (id INT PRIMARY KEY, v VECTOR(4) NOT NULL);
INSERT INTO later VALUES (1, VEC_FromText('[1,0,0,0]')), (2, VEC_FromText('[0,1,0,0]'));
ALTER TABLE later ADD VECTOR INDEX (v) DISTANCE=cosine;
SELECT 'ALTER TABLE ADD VECTOR INDEX on populated table: OK' AS result;

-- ===========================================================================
-- The main harness: 2,000 rows, one cosine index, two filter columns.
--
-- CAVEAT: these vectors are 3-dimensional and generated from seeded RAND(),
-- so they are PATTERNED, not realistic. The mechanisms below are structural
-- and will transfer to real embeddings; the specific row counts will not.
-- See the caveats section of 09_verified_findings.md.
-- ===========================================================================
SELECT '=== 8. building the 2000-row harness ===' AS probe;

CREATE TABLE docs (
    id       INT         NOT NULL PRIMARY KEY,
    category VARCHAR(16) NOT NULL,          -- INDEXED filter column
    tag      VARCHAR(16) NOT NULL,          -- UNINDEXED filter column
    v        VECTOR(3)   NOT NULL,
    VECTOR INDEX (v) DISTANCE=cosine,
    INDEX (category)
);

SET max_recursive_iterations = 100000;      -- default 1000 is too low for 2000 rows

INSERT INTO docs (id, category, tag, v)
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i+1 FROM n WHERE i < 2000)
SELECT i,
       IF(i % 100 = 0, 'rare', 'common'),
       IF(i % 100 = 0, 'needle', 'bulk'),
       VEC_FromText(CONCAT('[', RAND(i)*2-1, ',', RAND(i*7)*2-1, ',', RAND(i*13)*2-1, ']'))
FROM n;

SELECT COUNT(*) AS total,
       SUM(category = 'rare')   AS rare_rows,
       SUM(tag = 'needle')      AS needle_rows
FROM docs;
-- OBSERVED: 2000 | 20 | 20   (the two filters select the same 20 rows)

SET @q = VEC_FromText('[1,0,0]');

-- ---------------------------------------------------------------------------
-- 9. Metric mismatch: the index is silently abandoned  (limitation C3)
-- ---------------------------------------------------------------------------
SELECT '=== 9. matched vs mismatched distance function ===' AS probe;
EXPLAIN SELECT id FROM docs ORDER BY VEC_DISTANCE_COSINE(v, @q)    LIMIT 5;
-- OBSERVED: type=index  key=v     rows=5                      <- index used
EXPLAIN SELECT id FROM docs ORDER BY VEC_DISTANCE_EUCLIDEAN(v, @q) LIMIT 5;
-- OBSERVED: type=ALL    key=NULL  rows=2000  Using filesort   <- full scan
--
-- Results stay CORRECT (a full scan is exact); only the index is lost.
-- Kaj warned results would be "meaningless"; on 12.3.3 it is a silent
-- performance cliff instead.

-- ---------------------------------------------------------------------------
-- 10. IGNORE INDEX gives an exact baseline, and unfiltered recall is 1.00
-- ---------------------------------------------------------------------------
SELECT '=== 10. brute-force baseline and unfiltered recall ===' AS probe;
EXPLAIN SELECT id FROM docs IGNORE INDEX (v) ORDER BY VEC_DISTANCE_COSINE(v, @q) LIMIT 10;
-- OBSERVED: type=ALL  key=NULL  rows=2000  Using filesort

SET @q2 = VEC_FromText('[0.3,-0.7,0.2]');
SELECT GROUP_CONCAT(id ORDER BY id) AS indexed_top10
  FROM (SELECT id FROM docs                  ORDER BY VEC_DISTANCE_COSINE(v,@q2) LIMIT 10) t;
SELECT GROUP_CONCAT(id ORDER BY id) AS brute_top10
  FROM (SELECT id FROM docs IGNORE INDEX (v) ORDER BY VEC_DISTANCE_COSINE(v,@q2) LIMIT 10) t;
-- OBSERVED: both 382,386,390,394,398,1749,1753,1757,1761,1765  -> recall 1.00
-- (The two tight runs of consecutive ids are the patterned-data artifact.)

-- ---------------------------------------------------------------------------
-- 11. THE HEADLINE FINDING: filtered queries can silently under-return
-- ---------------------------------------------------------------------------
SELECT '=== 11a. INDEXED filter column -> pre-filter -> correct ===' AS probe;
SELECT COUNT(*) AS rows_returned
  FROM (SELECT id FROM docs WHERE category='rare'
        ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
-- OBSERVED: 10   (correct)
EXPLAIN SELECT id FROM docs WHERE category='rare' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10;
-- OBSERVED: type=ref  key=category  rows=20
--           Using index condition; Using where; Using filesort
--           -> pre-filters on the btree, then computes exact distances

SELECT '=== 11b. UNINDEXED filter column -> post-filter -> SILENTLY WRONG ===' AS probe;
SELECT COUNT(*) AS rows_returned
  FROM (SELECT id FROM docs WHERE tag='needle'
        ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
-- OBSERVED: 7    <-- asked for 10, twenty rows match, got 7. No error.
EXPLAIN SELECT id FROM docs WHERE tag='needle' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10;
-- OBSERVED: type=index  key=v  rows=10  Using where
SHOW WARNINGS;
-- OBSERVED: empty. Nothing tells the caller the result was truncated.

SELECT '=== 11c. FORCE INDEX changes nothing ===' AS probe;
SELECT COUNT(*) AS rows_returned
  FROM (SELECT id FROM docs FORCE INDEX (v) WHERE tag='needle'
        ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
-- OBSERVED: 7   -> access-path behaviour, not a planner misjudgement

SELECT '=== 11d. weak filter (1980 of 2000) uses the vector index and post-filters ===' AS probe;
SELECT COUNT(*) AS rows_returned
  FROM (SELECT id FROM docs WHERE category='common'
        ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
-- OBSERVED: 10  (only 1% excluded, so the candidate list survives)
EXPLAIN SELECT id FROM docs WHERE category='common' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10;
-- OBSERVED: type=index  key=v  Using where

-- ---------------------------------------------------------------------------
-- 12. ef_search does not reliably fix it, and is not monotonic
-- ---------------------------------------------------------------------------
SELECT '=== 12. ef_search sweep on the under-return ===' AS probe;
SET mhnsw_ef_search = 20;
SELECT   20 AS ef, COUNT(*) AS got FROM (SELECT id FROM docs WHERE tag='needle' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
SET mhnsw_ef_search = 50;
SELECT   50 AS ef, COUNT(*) AS got FROM (SELECT id FROM docs WHERE tag='needle' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
SET mhnsw_ef_search = 100;
SELECT  100 AS ef, COUNT(*) AS got FROM (SELECT id FROM docs WHERE tag='needle' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
SET mhnsw_ef_search = 200;
SELECT  200 AS ef, COUNT(*) AS got FROM (SELECT id FROM docs WHERE tag='needle' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
SET mhnsw_ef_search = 500;
SELECT  500 AS ef, COUNT(*) AS got FROM (SELECT id FROM docs WHERE tag='needle' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
SET mhnsw_ef_search = 1000;
SELECT 1000 AS ef, COUNT(*) AS got FROM (SELECT id FROM docs WHERE tag='needle' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
SET mhnsw_ef_search = 20;
--
-- IMPORTANT: the numbers from this sweep are NOT STABLE between runs,
-- because the index is rebuilt each time this script runs (see section 13).
-- Three separate runs produced:
--     run 1 (ef 20/50/100/200/500/1000) ->  7, 10,  0,  0, 10, 10
--     run 2                             ->  2,  2,  2,  0,  0, 10
--     run 3                             ->  0,  0,  0,  0,  0,  0
--
-- What IS consistent across every run:
--   * the count is short of the 10 requested at most settings;
--   * raising ef_search does not reliably increase it -- no run was monotonic;
--   * zero rows is a frequent outcome, while 20 rows satisfy the predicate.
--
-- Do not quote any single row of this sweep as "the" result. Section 13 is
-- the stable, quotable experiment.

-- ---------------------------------------------------------------------------
-- 13. THE STABLE EXPERIMENT: the shortfall is nondeterministic per index build
--
-- Section 12 wobbles because HNSW assigns each node a random level on insert,
-- so every build produces a different graph and a different candidate set.
-- This section isolates that. Run the whole script 5 times and compare.
-- ---------------------------------------------------------------------------
SELECT '=== 13. one row per filter strategy; compare across repeated runs ===' AS probe;
SET mhnsw_ef_search = 20;
SELECT (SELECT COUNT(*) FROM (SELECT id FROM docs WHERE tag='needle'
            ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) a) AS unindexed_filter,
       (SELECT COUNT(*) FROM (SELECT id FROM docs WHERE category='rare'
            ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) b) AS indexed_filter,
       (SELECT COUNT(*) FROM (SELECT id FROM docs
            ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) c) AS unfiltered;
--
-- OBSERVED over five consecutive full rebuilds of the identical table and data
-- (all three columns ask for LIMIT 10; both filters match exactly 20 rows):
--
--     build | unindexed_filter | indexed_filter | unfiltered
--     ------+------------------+----------------+-----------
--       1   |        2         |       10       |     10
--       2   |        1         |       10       |     10
--       3   |        7         |       10       |     10
--       4   |        3         |       10       |     10
--       5   |        2         |       10       |     10
--
-- The unindexed-filter column is nondeterministic and always short.
-- The indexed-filter column is correct every single time.
-- That contrast is the finding, and it is what the schema in file 05 is
-- designed around.

-- ---------------------------------------------------------------------------
-- Clean up
-- ---------------------------------------------------------------------------
DROP DATABASE IF EXISTS vecprobe;
SELECT 'probe complete; vecprobe dropped' AS result;
