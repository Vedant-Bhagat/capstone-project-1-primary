-- ===========================================================================
-- hybrid_filter.sql -- "absolute, then fluffy": a relational predicate and a
-- vector search in ONE statement. This is the capability a bolt-on vector
-- service cannot have, because it does not know your other tables.
--
-- Spec: docs/main_dish_spec/06_retrieval.md section 2.
-- Run:  mariadb -u root < sql/retrieval/hybrid_filter.sql
-- ===========================================================================

USE wikirag;
SET @q = (SELECT embedding FROM eval_queries WHERE id = 5);   -- composers probe

-- ---------------------------------------------------------------------------
-- The query.
--
-- FORCE INDEX (ix_category) is deliberate. On a 3-dimensional synthetic
-- harness, a filtered vector query above ~7% selectivity silently returned
-- too few rows -- sometimes zero -- because the optimizer chose the vector
-- index and post-filtered. Forcing the btree made it exact and deterministic.
-- See docs/main_dish_spec/09_verified_findings.md finding 7b.
--
-- That shortfall DOES reproduce at 384 dimensions, on real embeddings, and on
-- this corpus. An earlier version of this comment said it did not, on the
-- strength of finding 7c, which was withdrawn as a false negative on
-- 2026-10-22: its test filters happened to point the same way as the query
-- vector. So the hint is not a free precaution here, it is load-bearing --
-- without it, two of the nine categories returned zero rows at default
-- settings. See docs/findings.md and sql/retrieval/minimal_repro.sql.
-- Test T9 asserts the hint is still present so nobody tidies it away.
-- ---------------------------------------------------------------------------
SELECT a.title,
       c.category,
       c.section,
       LEFT(c.body, 60)                             AS preview,
       a.url,
       ROUND(VEC_DISTANCE_COSINE(c.embedding, @q), 6) AS distance
FROM chunks c FORCE INDEX (ix_category)
JOIN articles a ON a.id = c.article_id
WHERE c.category = 'composers'        -- absolute: indexed, same table as the vector
  AND c.word_count >= 100            -- absolute: no stubs
ORDER BY distance
LIMIT 10;

-- ---------------------------------------------------------------------------
-- The three-way plan contrast. This is the clearest depth evidence in the
-- project: same query shape, three different access paths.
-- ---------------------------------------------------------------------------
SELECT '1. unfiltered -> HNSW graph walk (approximate)' AS plan;
EXPLAIN SELECT c.id FROM chunks c
        ORDER BY VEC_DISTANCE_COSINE(c.embedding, @q) LIMIT 10;

SELECT '2. filtered, no hint -> optimizer decides' AS plan;
EXPLAIN SELECT c.id FROM chunks c WHERE c.category = 'composers'
        ORDER BY VEC_DISTANCE_COSINE(c.embedding, @q) LIMIT 10;

SELECT '3. filtered, FORCE INDEX -> btree pre-filter, then exact distances' AS plan;
EXPLAIN SELECT c.id FROM chunks c FORCE INDEX (ix_category) WHERE c.category = 'composers'
        ORDER BY VEC_DISTANCE_COSINE(c.embedding, @q) LIMIT 10;

-- The counter-intuitive part, worth stating in the README: plan 3 is EXACT.
-- Brute force over 6% of the corpus is cheap, so the filtered query is more
-- accurate than the unfiltered one -- and the vector index contributes
-- nothing to it. MariaDB's vector index does not currently serve selective
-- filtered queries; it is the relational index that does the work.
SELECT (SELECT COUNT(*) FROM chunks)                            AS total_chunks,
       (SELECT COUNT(*) FROM chunks WHERE category='composers') AS matching,
       ROUND(100 * (SELECT COUNT(*) FROM chunks WHERE category='composers')
                 / (SELECT COUNT(*) FROM chunks), 2)            AS pct;
