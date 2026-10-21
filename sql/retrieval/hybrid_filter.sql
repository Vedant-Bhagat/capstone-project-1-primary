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
-- That shortfall does NOT reproduce at 384 dimensions (see under_return.sql),
-- so today the hint changes nothing here. It stays because it costs nothing,
-- it guarantees the exact plan rather than relying on a cost estimate, and
-- the behaviour it defends against was really observed. Test T9 asserts it is
-- still present so nobody tidies it away.
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
