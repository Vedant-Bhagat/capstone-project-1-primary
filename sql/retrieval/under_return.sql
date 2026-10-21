-- ===========================================================================
-- under_return.sql -- the filtered-search shortfall, checked at 384
-- dimensions against the real schema.
--
-- Spec: docs/main_dish_spec/06_retrieval.md section 4,
--       docs/main_dish_spec/09_verified_findings.md findings 7 and 7b.
-- Run:  mariadb -u root < sql/retrieval/under_return.sql
--
-- BACKGROUND. On a 3-dimensional synthetic harness
-- (docs/main_dish_spec/probe/), a vector query filtered on a column the
-- optimizer would not pre-filter silently returned fewer rows than requested
-- -- between 0 and 7 of 10, varying per index build, because HNSW assigns
-- node levels randomly on insert. Janhavi then showed the mitigation we had
-- proposed stops working above ~7% selectivity.
--
-- THIS FILE IS THE 384-DIMENSION CHECK, and its honest result is a
-- NON-REPRODUCTION: every configuration below returns the full 10 rows. That
-- is recorded rather than quietly dropped, because the README makes a claim
-- about MariaDB and this is evidence about its scope.
-- ===========================================================================

USE wikirag;
SET @q = (SELECT embedding FROM eval_queries WHERE id = 1);   -- birds probe
SET mhnsw_ef_search = 20;                                      -- the default

SELECT 'A. indexed filter, 6.4% -- below the crossover' AS scenario;
EXPLAIN SELECT c.id FROM chunks c WHERE c.category='birds'
        ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10;
SELECT COUNT(*) AS returned, 10 AS requested,
       (SELECT COUNT(*) FROM chunks WHERE category='birds') AS matching
FROM (SELECT c.id FROM chunks c WHERE c.category='birds'
      ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) t;

SELECT 'B. UNINDEXED filter, 12.5%, uncorrelated with the query' AS scenario;
EXPLAIN SELECT c.id FROM chunks c WHERE c.section='Section 3'
        ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10;
SELECT COUNT(*) AS returned, 10 AS requested,
       (SELECT COUNT(*) FROM chunks WHERE section='Section 3') AS matching
FROM (SELECT c.id FROM chunks c WHERE c.section='Section 3'
      ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) t;

SELECT 'C. UNINDEXED filter selecting only rows FAR from the query' AS scenario;
-- The worst case for post-filtering: the graph walk heads towards `birds`,
-- while the predicate keeps only `compilers`. If post-filtering is going to
-- exhaust its candidates anywhere, it is here.
EXPLAIN SELECT c.id FROM chunks c WHERE c.body LIKE '%compilers passage%'
        ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10;
SELECT COUNT(*) AS returned, 10 AS requested,
       (SELECT COUNT(*) FROM chunks WHERE body LIKE '%compilers passage%') AS matching
FROM (SELECT c.id FROM chunks c WHERE c.body LIKE '%compilers passage%'
      ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) t;

SELECT 'D. the forced plan -- exact, and identical to exhaustive search' AS scenario;
SELECT IF(
  (SELECT GROUP_CONCAT(id ORDER BY id) FROM (SELECT c.id FROM chunks c FORCE INDEX (ix_category)
      WHERE c.category='birds' ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) a)
  =
  (SELECT GROUP_CONCAT(id ORDER BY id) FROM (SELECT c.id FROM chunks c IGNORE INDEX (embedding)
      WHERE c.category='birds' ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) b),
  'MATCH -- forced plan equals exhaustive', 'DIFFERS') AS forced_vs_exhaustive;

-- WHAT TO CONCLUDE.
--   * The shortfall is real -- it was observed and is reproducible at 3
--     dimensions by docs/main_dish_spec/probe/vector_probe.sql.
--   * It did not reproduce here at 384 dimensions, on 2,000 clustered
--     synthetic vectors, in any of A-C.
--   * So the defect is NOT established as general MariaDB behaviour, and the
--     README says so. It must be re-checked once component A produces real
--     embeddings; synthetic clustered vectors are not real ones either.
--   * FORCE INDEX stays in hybrid_filter.sql regardless: it costs nothing and
--     buys a guaranteed exact plan instead of a cost estimate.
