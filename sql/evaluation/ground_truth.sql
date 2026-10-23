-- ===========================================================================
-- ground_truth.sql -- the exact nearest neighbours of every evaluation query,
-- by brute force. Recall is measured against this table.
--
-- Spec: docs/main_dish_spec/07_evaluation.md, "Building the ground truth".
-- Run:  mariadb -u root < sql/evaluation/ground_truth.sql
--   PowerShell:  Get-Content sql/evaluation/ground_truth.sql | mariadb -u root
--
-- Prerequisite: schema.sql, then a corpus (fixture.sql, or the real ingest),
-- which also fills eval_queries.
--
-- WHY A CROSS JOIN. The vector index only serves `ORDER BY VEC_DISTANCE_*
-- (col, <constant>) LIMIT k` against a single constant vector. Here the
-- second argument is a column of eval_queries, so the index CANNOT be used:
-- every query is compared against every chunk. That is the point -- this is
-- the exhaustive answer the approximate index is graded against. The EXPLAIN
-- at the end confirms it (type: ALL on chunks, no `embedding` key).
--
-- Set-based on purpose, not a Python loop: a window function partitioned over
-- a cross join of vector distances, in one statement.
--
-- TIES. Rows are ranked by distance, then by chunk id, so the ranking is
-- deterministic. If two chunks sit at exactly the same distance across the
-- rank-k boundary, the indexed query may legitimately return the other one
-- and be counted as a miss. The tie check at the end reports how often that
-- can happen, so a recall figure is never quietly depressed by it.
-- ===========================================================================

USE wikirag;

-- Stored to depth 50, so recall@1, @5, @10 and @20 all come from one build.
SET @gt_depth = 50;

DELETE FROM eval_ground_truth;

INSERT INTO eval_ground_truth (query_id, rank_pos, chunk_id, distance)
SELECT query_id, rank_pos, chunk_id, distance
FROM (
    SELECT q.id  AS query_id,
           c.id  AS chunk_id,
           VEC_DISTANCE_COSINE(c.embedding, q.embedding) AS distance,
           ROW_NUMBER() OVER (
               PARTITION BY q.id
               ORDER BY VEC_DISTANCE_COSINE(c.embedding, q.embedding), c.id
           ) AS rank_pos
    FROM eval_queries q
    CROSS JOIN chunks c
) ranked
WHERE rank_pos <= @gt_depth;

-- ---------------------------------------------------------------------------
-- Checks
-- ---------------------------------------------------------------------------
SELECT (SELECT COUNT(*) FROM eval_queries)                     AS queries,
       (SELECT COUNT(*) FROM chunks)                           AS chunks,
       (SELECT COUNT(*) FROM eval_queries) * (SELECT COUNT(*) FROM chunks)
                                                               AS distances_computed,
       SUM(per_query)                                          AS ground_truth_rows,
       MIN(per_query)                                          AS min_depth,
       MAX(per_query)                                          AS max_depth
FROM (SELECT query_id, COUNT(*) AS per_query
      FROM eval_ground_truth GROUP BY query_id) d;

-- Ties across the rank-10 boundary: queries whose 10th and 11th neighbours
-- are at the same distance. Expected 0 on real embeddings.
SELECT COUNT(*) AS queries_with_tie_at_rank_10
FROM eval_ground_truth a
JOIN eval_ground_truth b
  ON b.query_id = a.query_id AND a.rank_pos = 10 AND b.rank_pos = 11
WHERE a.distance = b.distance;

-- Confirms the brute force really is brute force: no vector index in the plan.
EXPLAIN
SELECT q.id, c.id,
       ROW_NUMBER() OVER (PARTITION BY q.id
                          ORDER BY VEC_DISTANCE_COSINE(c.embedding, q.embedding), c.id)
FROM eval_queries q CROSS JOIN chunks c;
