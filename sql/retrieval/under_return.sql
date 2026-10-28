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
-- THIS FILE IS THE 384-DIMENSION CHECK. It reproduces the shortfall, and it
-- identifies what actually governs it -- which is NOT dimensionality:
--
--   the predicate's correlation with the query direction.
--
-- Filter on the category the query points at and you get 10 of 10. Filter on a
-- distant category, at the same 11.2% selectivity, on the same indexed column,
-- and you can get 0 of 10. Across five rebuilds of the same index on the same
-- data the far-filter count was 10, 0, 2, 3, 0 -- so it VARIES PER INDEX BUILD,
-- exactly as finding 7 does at 3 dimensions. On a build where it occurs, every
-- `mhnsw_ef_search` from 20 up to 2000 -- more than the whole table -- still
-- returns 0, so it is not an approximation that tuning reaches.
-- It is not an approximation that can be tuned away; the post-filter walks the
-- graph near the query and every candidate it finds fails the predicate.
--
-- This supersedes finding 7c, which recorded a non-reproduction at 384
-- dimensions. That test was wrong, not the server: its filters happened to be
-- correlated with the query. Correcting it is the point of this file.
-- ===========================================================================

USE wikirag;
SET @q = (SELECT embedding FROM eval_queries WHERE id = 1);   -- birds probe
SET mhnsw_ef_search = 20;                                      -- the default

-- 11.2% -- ABOVE the ~7% crossover, which is where the real 9-category corpus
-- sits. EXPLAIN shows the optimizer choosing `embedding` over `ix_category`, so
-- 7b's plan crossover reproduces at 384 dimensions too. Here the filter points
-- the SAME way as the query, so post-filtering still finds its 10 rows. This is
-- the case that made 7c look like a non-reproduction.
SELECT 'A. indexed filter, 11.2%, CORRELATED with the query -- 10 of 10' AS scenario;
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
-- while the predicate keeps only `architecture`, the most distant cluster. If
-- post-filtering is going to exhaust its candidates anywhere, it is here.
EXPLAIN SELECT c.id FROM chunks c WHERE c.body LIKE '%architecture passage%'
        ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10;
SELECT COUNT(*) AS returned, 10 AS requested,
       (SELECT COUNT(*) FROM chunks WHERE body LIKE '%architecture passage%') AS matching
FROM (SELECT c.id FROM chunks c WHERE c.body LIKE '%architecture passage%'
      ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) t;

-- The controlled comparison against A, and the result that overturns 7c.
-- Identical column, identical index, identical selectivity (11.2% vs 10.8%);
-- only the DIRECTION differs. A returns 10, this returns 0.
SELECT 'D. INDEXED filter, 10.8%, ANTI-CORRELATED -- 0 of 10' AS scenario;
EXPLAIN SELECT c.id FROM chunks c WHERE c.category='architecture'
        ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10;
SELECT COUNT(*) AS returned, 10 AS requested,
       (SELECT COUNT(*) FROM chunks WHERE category='architecture') AS matching
FROM (SELECT c.id FROM chunks c WHERE c.category='architecture'
      ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) t;

-- ef_search cannot buy the rows back. 2000 is the entire table.
SELECT 'E. ef_search sweep on D -- tuning does not help' AS scenario;
SET mhnsw_ef_search = 50;
SELECT 50 AS ef_search, COUNT(*) AS returned FROM (SELECT c.id FROM chunks c
  WHERE c.category='architecture' ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) t;
SET mhnsw_ef_search = 500;
SELECT 500 AS ef_search, COUNT(*) AS returned FROM (SELECT c.id FROM chunks c
  WHERE c.category='architecture' ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) t;
SET mhnsw_ef_search = 2000;
SELECT 2000 AS ef_search, COUNT(*) AS returned FROM (SELECT c.id FROM chunks c
  WHERE c.category='architecture' ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) t;
SET mhnsw_ef_search = 20;

-- FORCE INDEX on the anti-correlated case: 0 of 10 becomes 10 of 10, exact.
SELECT 'F. FORCE INDEX rescues D -- 10 of 10, equal to exhaustive' AS scenario;
SELECT (SELECT COUNT(*) FROM (SELECT c.id FROM chunks c FORCE INDEX (ix_category)
          WHERE c.category='architecture'
          ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) t) AS forced_returned,
       IF((SELECT GROUP_CONCAT(id ORDER BY id) FROM (SELECT c.id FROM chunks c FORCE INDEX (ix_category)
             WHERE c.category='architecture' ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) a)
        = (SELECT GROUP_CONCAT(id ORDER BY id) FROM (SELECT c.id FROM chunks c IGNORE INDEX (embedding)
             WHERE c.category='architecture' ORDER BY VEC_DISTANCE_COSINE(c.embedding,@q) LIMIT 10) b),
          'MATCH -- forced plan equals exhaustive', 'DIFFERS') AS vs_exhaustive;

SELECT 'G. the forced plan on the correlated case, for completeness' AS scenario;
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
--   * It reproduces at 384 dimensions (D), and finding 7c -- which said it did
--     not -- was a false negative caused by correlated test filters.
--   * Selectivity is not the variable, and neither is dimensionality. A and D
--     differ only in the direction of the predicate relative to the query.
--   * `mhnsw_ef_search` does not mitigate it at any value up to the table size
--     (E). Treating this as a recall/latency trade-off is therefore wrong: no
--     setting on the curve returns the missing rows.
--   * `FORCE INDEX` does mitigate it, exactly (F), and that is why every
--     filtered query in sql/retrieval/ carries it.
--   * STILL SYNTHETIC. These clusters are near-orthogonal blocks, a harsher
--     geometry than real embeddings. Component A's real BGE vectors are the
--     test that decides whether this is reportable; the checklist at the end of
--     09_verified_findings.md gates it.
--   * So the defect is NOT established as general MariaDB behaviour, and the
--     README says so. It must be re-checked once component A produces real
--     embeddings; synthetic clustered vectors are not real ones either.
--   * FORCE INDEX stays in hybrid_filter.sql regardless: it costs nothing and
--     buys a guaranteed exact plan instead of a cost estimate.
