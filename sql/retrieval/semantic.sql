-- ===========================================================================
-- semantic.sql -- plain top-k semantic search. The baseline everything else
-- is compared against. Spec: docs/main_dish_spec/06_retrieval.md section 1.
--
-- Run:  mariadb -u root < sql/retrieval/semantic.sql
--
-- @q is the question's embedding. In the real query path python/answer.py
-- binds it as a parameter; here we borrow a fixture probe vector so the file
-- runs standalone.
-- ===========================================================================

USE wikirag;
SET @q = (SELECT embedding FROM eval_queries WHERE id = 1);
-- A NULL @q is the one failure this script must not pass off as a result: the
-- distances all come back NULL, ORDER BY leaves the rows in storage order, and
-- ten plausible-looking rows are printed. Fail instead.
DELIMITER //
BEGIN NOT ATOMIC
    IF @q IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'No such eval query -- run python -m python.ingest, or mariadb < sql/fixture.sql, before this script';
    END IF;
END //
DELIMITER ;


-- Three things worth noticing, and they are the whole value proposition:
--
--   1. The JOIN is free. Vector search and article metadata come back in one
--      round trip. A separate vector store returns ids, and you then query
--      your real database for the titles -- two systems, two latencies.
--   2. `ORDER BY ... LIMIT` is the entire API. No special search syntax.
--   3. This is APPROXIMATE. The ordering is HNSW's best guess, and how often
--      it is right is measured in sql/evaluation/ (component C).
SELECT a.title,
       c.category,
       c.section,
       LEFT(c.body, 60)                             AS preview,
       a.url,
       ROUND(VEC_DISTANCE_COSINE(c.embedding, @q), 6) AS distance
FROM chunks c
JOIN articles a ON a.id = c.article_id
ORDER BY distance
LIMIT 10;

-- Confirms the index is used: expect `key: embedding`, not `type: ALL`.
EXPLAIN SELECT c.id FROM chunks c ORDER BY VEC_DISTANCE_COSINE(c.embedding, @q) LIMIT 10;

-- The dial. Session-scoped, so a reader can change it and re-run the query
-- above to watch recall move. Default is 20.
SELECT @@mhnsw_ef_search AS ef_search_in_effect;
