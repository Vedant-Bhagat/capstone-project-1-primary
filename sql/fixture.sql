-- ===========================================================================
-- fixture.sql -- a synthetic corpus, so components A and C are not blocked on
-- each other. Pure SQL: no Python, no embedding model, no network.
--
-- Run:  mariadb -u root < sql/schema.sql
--       mariadb -u root < sql/fixture.sql
--   PowerShell:  Get-Content sql/fixture.sql | mariadb -u root
--
-- Default 2000 chunks across the same 9 categories as the real corpus
-- (03_corpus.md), so each is ~11% of the table -- deliberately ABOVE the ~7%
-- optimizer crossover in docs/main_dish_spec/09_verified_findings.md 7b, which
-- is the regime the real corpus is in. A filtered query measured here without
-- FORCE INDEX will under-return, and that is correct behaviour to reproduce.
-- For a fast CI run:  CALL load_fixture(200);
--
-- shortcut: the vectors are synthetic and only loosely clustered by category,
-- so retrieval QUALITY numbers from this fixture mean nothing -- it exists to
-- exercise schema, query syntax and the measurement harness. Replace with the
-- real ingest (component A) before quoting any recall or hit@k figure.
-- ===========================================================================

USE wikirag;

DELIMITER $$

-- Deterministic pseudo-random 384-dim vector, loosely clustered on the
-- category so nearest-neighbour results are at least eyeballable.
DROP FUNCTION IF EXISTS fixture_vec $$
CREATE FUNCTION fixture_vec(p_cat INT, p_seed INT, p_dims INT)
RETURNS TEXT DETERMINISTIC
BEGIN
    DECLARE s TEXT DEFAULT '';
    DECLARE j INT DEFAULT 0;
    DECLARE lo INT DEFAULT p_cat * 42;
    DECLARE v DOUBLE;
    WHILE j < p_dims DO
        -- 42 dimensions per category sit high; the rest is noise. 9 * 42 = 378,
        -- so the clusters span nearly the whole vector rather than its head.
        SET v = IF(j >= lo AND j < lo + 42, 1.0, 0.0)
                + (RAND(p_seed * 1000 + j) * 0.4 - 0.2);
        SET s = CONCAT(s, IF(j = 0, '', ','), ROUND(v, 4));
        SET j = j + 1;
    END WHILE;
    RETURN CONCAT('[', s, ']');
END $$

DROP PROCEDURE IF EXISTS load_fixture $$
CREATE PROCEDURE load_fixture(IN p_chunks INT)
BEGIN
    DECLARE i INT DEFAULT 0;
    DECLARE n_art INT;
    DECLARE cat VARCHAR(32);
    DECLARE nxt VARCHAR(32);
    DECLARE c INT;
    DECLARE art INT;

    SET n_art = CEIL(p_chunks / 8);          -- ~8 chunks per article

    DELETE FROM eval_ground_truth;
    DELETE FROM recall_runs;
    DELETE FROM eval_queries;
    DELETE FROM chunks;
    DELETE FROM articles;
    DELETE FROM corpus_meta;

    ALTER TABLE chunks DROP INDEX IF EXISTS embedding;

    INSERT INTO corpus_meta (embed_model, embed_dims, query_prefix,
                             chunk_words, chunk_overlap, prepend_title,
                             distance_metric)
    VALUES ('SYNTHETIC-FIXTURE (not a real model)', 384, '',
            300, 50, TRUE, 'cosine');

    -- Articles
    SET i = 0;
    WHILE i < n_art DO
        SET c   = i MOD 9;
        SET cat = ELT(c + 1, 'birds','physics','composers','prog_lang',
                      'space_telescopes','diseases','political_philosophy',
                      'ethics','architecture');
        INSERT INTO articles (pageid, revid, title, url, category, word_count)
        VALUES (100000 + i, 900000000 + i,
                CONCAT(cat, ' article ', i),
                CONCAT('https://en.wikipedia.org/wiki/Fixture_', cat, '_', i),
                cat, 2400);
        SET i = i + 1;
    END WHILE;

    -- Chunks
    SET i = 0;
    WHILE i < p_chunks DO
        SET art = (i MOD n_art) + 1;
        SELECT a.category INTO cat FROM articles a WHERE a.id = art;
        SET c   = (art - 1) MOD 9;
        SET nxt = ELT(((c + 1) MOD 9) + 1, 'birds','physics','composers',
                      'prog_lang','space_telescopes','diseases',
                      'political_philosophy','ethics','architecture');
        INSERT INTO chunks (article_id, section, ordinal, body, word_count,
                            category, embedding)
        VALUES (art,
                CONCAT('Section ', (i DIV n_art) + 1),
                (i DIV n_art) + 1,
                -- Real words so FULLTEXT has something to match. Shared terms
                -- plus a token unique to the chunk.
                CONCAT(cat, ' passage ', i, ' discusses ', cat,
                       ' alongside ', nxt, ' concepts and marker', i),
                300, cat,
                VEC_FromText(fixture_vec(c, i + 1, 384)));
        SET i = i + 1;
    END WHILE;

    -- Index AFTER the load: inserting into an indexed table rebuilds the
    -- HNSW graph per row. python/ingest.py does the same at its step 5.
    ALTER TABLE chunks ADD VECTOR INDEX (embedding) DISTANCE=cosine;

    -- A few evaluation queries, one per category centre, so component C has
    -- something to measure against immediately.
    SET i = 0;
    WHILE i < 9 DO
        INSERT INTO eval_queries (query_text, embedding)
        VALUES (CONCAT('fixture probe for category ', i),
                VEC_FromText(fixture_vec(i, 500000 + i, 384)));
        SET i = i + 1;
    END WHILE;
END $$

DELIMITER ;

CALL load_fixture(2000);

SELECT (SELECT COUNT(*) FROM articles)     AS articles,
       (SELECT COUNT(*) FROM chunks)       AS chunks,
       (SELECT COUNT(*) FROM eval_queries) AS eval_queries,
       (SELECT COUNT(DISTINCT category) FROM chunks) AS categories,
       (SELECT ROUND(100 * COUNT(*) / (SELECT COUNT(*) FROM chunks), 2)
          FROM chunks WHERE category = 'birds')      AS pct_per_category;
