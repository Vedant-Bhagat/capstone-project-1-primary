-- ===========================================================================
-- selectivity_probe.sql
--
-- Tests the schema's mitigation from 05_schema.md at the corpus's planned
-- selectivity. vector_probe.sql only tests an INDEXED filter at 1% (20 of
-- 2,000 rows) and at 99% (section 11d). Our real `category` filter will match
-- ~12% of chunks (03_corpus.md), so this uses an indexed column matching 250
-- of 2,000 rows (12.5%), same patterned 3-dimensional harness.
--
-- Run it several times: each run rebuilds the index, and HNSW builds differ.
--
-- Run:   mariadb -u root -t < selectivity_probe.sql
--   PowerShell:   Get-Content selectivity_probe.sql | mariadb -u root -t
--
-- Creates and drops a scratch database called `vecprobe12`. Touches nothing else.
--
-- OBSERVED on MariaDB 12.3.3, Windows 11, 2026-10-15, three builds:
--   EXPLAIN every time: type=index  key=v  rows=80  Using where
--     -> the optimizer chose the VECTOR index and post-filters, even though
--        `category` is indexed. Not the pre-filter 05_schema.md relies on.
--   build 1: returned 0 rows      (250 rows match the filter)
--   build 2: returned 10, identical to the exact top 10
--   build 3: returned 10, NONE of them in the exact top 10
--
-- CAVEAT: same as 09_verified_findings.md -- 3 dimensions, patterned vectors.
-- The counts may not transfer to 384 dimensions; the plan choice should be
-- re-checked on real embeddings.
-- ===========================================================================

DROP DATABASE IF EXISTS vecprobe12;
CREATE DATABASE vecprobe12;
USE vecprobe12;
CREATE TABLE docs (
    id INT NOT NULL PRIMARY KEY,
    category VARCHAR(16) NOT NULL,
    v VECTOR(3) NOT NULL,
    VECTOR INDEX (v) DISTANCE=cosine,
    INDEX (category)
);
SET max_recursive_iterations = 100000;
INSERT INTO docs (id, category, v)
WITH RECURSIVE n AS (SELECT 1 AS i UNION ALL SELECT i+1 FROM n WHERE i < 2000)
SELECT i, IF(i % 8 = 0, 'mid', 'other'),
       VEC_FromText(CONCAT('[', RAND(i)*2-1, ',', RAND(i*7)*2-1, ',', RAND(i*13)*2-1, ']'))
FROM n;
ANALYZE TABLE docs PERSISTENT FOR ALL;
SET @q = VEC_FromText('[1,0,0]');
SET mhnsw_ef_search = 20;
SELECT SUM(category='mid') AS matching_rows FROM docs;
EXPLAIN SELECT id FROM docs WHERE category='mid' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10;
SELECT COUNT(*) AS returned FROM (SELECT id FROM docs WHERE category='mid' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
SELECT GROUP_CONCAT(id ORDER BY id) AS indexed FROM (SELECT id FROM docs WHERE category='mid' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
SELECT GROUP_CONCAT(id ORDER BY id) AS exact FROM (SELECT id FROM docs IGNORE INDEX (v) WHERE category='mid' ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
DROP DATABASE vecprobe12;
