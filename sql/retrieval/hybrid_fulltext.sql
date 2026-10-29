-- ===========================================================================
-- hybrid_fulltext.sql -- combine full-text and vector results into one answer
-- with Reciprocal Rank Fusion. The second valid hybrid shape Kaj named.
--
-- Spec: docs/main_dish_spec/06_retrieval.md section 3.
-- Run:  mariadb -u root < sql/retrieval/hybrid_fulltext.sql
--
-- Why bother: keyword search misses paraphrases; semantic search misses exact
-- strings -- rare proper nouns, identifiers, numbers -- because they carry
-- little embedding signal. Each covers the other's failure mode. RRF scores a
-- row 1/(k+rank) in each list and sums, so appearing in both beats topping
-- one.
--
-- Note what this needs: window functions, CTEs, FULLTEXT and VECTOR indexes
-- on the same table, all cooperating in one statement. (Verified that
-- FULLTEXT and VECTOR indexes may coexist -- only MULTIPLE vector indexes are
-- rejected, with ERROR 1235.)
-- ===========================================================================

USE wikirag;
SET @q  = (SELECT embedding FROM eval_queries WHERE id = 5);
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

SET @kw = 'composers conductors';
SET @k  = 60;     -- the conventional RRF constant from the original paper

-- The merge is a UNION of ids followed by two LEFT JOINs. A single LEFT JOIN
-- from the semantic list would score only rows the vector search already
-- found, which defeats the point -- and MariaDB has no FULL OUTER JOIN.
WITH semantic AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY d) AS rk
    FROM (SELECT id, VEC_DISTANCE_COSINE(embedding, @q) AS d
          FROM chunks ORDER BY d LIMIT 30) s
),
keyword AS (
    SELECT id, ROW_NUMBER() OVER (ORDER BY sc DESC) AS rk
    FROM (SELECT id, MATCH(body) AGAINST (@kw IN NATURAL LANGUAGE MODE) AS sc
          FROM chunks
          WHERE MATCH(body) AGAINST (@kw IN NATURAL LANGUAGE MODE)
          ORDER BY sc DESC LIMIT 30) k
),
merged AS (SELECT id FROM semantic UNION SELECT id FROM keyword)
SELECT a.title,
       c.category,
       s.rk AS semantic_rank,
       k.rk AS keyword_rank,
       ROUND(COALESCE(1.0/(@k + s.rk), 0) + COALESCE(1.0/(@k + k.rk), 0), 5) AS rrf_score
FROM merged m
LEFT JOIN semantic s ON s.id = m.id
LEFT JOIN keyword  k ON k.id = m.id
JOIN chunks   c ON c.id = m.id
JOIN articles a ON a.id = c.article_id
ORDER BY rrf_score DESC, m.id
LIMIT 10;

-- Gotcha worth documenting: InnoDB full-text ignores tokens shorter than
-- innodb_ft_min_token_size (default 3) and anything in its stopword list, so
-- short or very common query words match nothing and the keyword half of the
-- fusion silently contributes zero.
SELECT @@innodb_ft_min_token_size AS ft_min_token_size,
       (SELECT COUNT(*) FROM chunks
         WHERE MATCH(body) AGAINST (@kw IN NATURAL LANGUAGE MODE)) AS keyword_matches;
