-- ===========================================================================
-- cascade_repro.sql -- an ON DELETE CASCADE into a vector-indexed table leaves
-- the index unable to reach rows that still exist. Same symptom as
-- MDEV-41227 (Confirmed, open): https://jira.mariadb.org/browse/MDEV-41227
--
-- Run:  mariadb -u root -t < sql/retrieval/cascade_repro.sql
--   PowerShell:  Get-Content sql/retrieval/cascade_repro.sql | mariadb -u root -t
--
-- Self-contained, like minimal_repro.sql: it creates and uses its own
-- database, `cascade_repro`, and never touches `wikirag`. No corpus, no
-- embedding model, no plugin. It leaves `cascade_repro` behind so the result
-- can be inspected; `DROP DATABASE cascade_repro` removes it.
--
-- WHAT IT DOES. A parent table of 250 rows and a child table of 2,000
-- 384-dimensional vectors, generated with sql/fixture.sql's own
-- deterministic function, loaded first and then given a cosine VECTOR INDEX
-- with M=6 (written into the DDL, so mhnsw_default_m cannot change it). The
-- query is the fixture's first evaluation query. Then, on a fresh build each
-- time:
--
--   E  DELETE parent 1, so ON DELETE CASCADE removes its 8 child rows
--   F  the control: DELETE the same 8 child rows directly
--
-- and counts the rows an unfiltered `ORDER BY VEC_DISTANCE_COSINE ... LIMIT 10`
-- returns through the index and through an exact IGNORE INDEX scan. With
-- 1,992 rows left, both should return 10. Each variant runs on three builds,
-- because HNSW assigns node levels randomly on insert.
--
-- It REPORTS rather than gates, like minimal_repro.sql: a fixed server would
-- correctly return 10, and the verdict line says which this server did.
--
-- Not a cause. MDEV-41227 reports that direct DELETE is unaffected and that
-- rebuilding the index restores correct results; this script checks the
-- first of those, and nothing here explains why.
-- ===========================================================================

DROP DATABASE IF EXISTS cascade_repro;
CREATE DATABASE cascade_repro;
USE cascade_repro;

DELIMITER $$

-- Verbatim from sql/fixture.sql.
CREATE FUNCTION fixture_vec(p_cat INT, p_seed INT, p_dims INT)
RETURNS TEXT DETERMINISTIC
BEGIN
    DECLARE s TEXT DEFAULT '';
    DECLARE j INT DEFAULT 0;
    DECLARE lo INT DEFAULT p_cat * 42;
    DECLARE v DOUBLE;
    WHILE j < p_dims DO
        SET v = IF(j >= lo AND j < lo + 42, 1.0, 0.0)
                + (RAND(p_seed * 1000 + j) * 0.4 - 0.2);
        SET s = CONCAT(s, IF(j = 0, '', ','), ROUND(v, 4));
        SET j = j + 1;
    END WHILE;
    RETURN CONCAT('[', s, ']');
END $$

CREATE TABLE result (
    variant   CHAR(1),
    build     INT,
    deleted   VARCHAR(40),
    rows_left INT,
    via_index INT,
    exact     INT
) $$

-- A clean build: parents, then 2,000 children, THEN the index.
CREATE PROCEDURE fresh_build()
BEGIN
    DECLARE i INT DEFAULT 0;
    DROP TABLE IF EXISTS c;
    DROP TABLE IF EXISTS p;
    CREATE TABLE p (id INT NOT NULL AUTO_INCREMENT PRIMARY KEY) ENGINE=InnoDB;
    CREATE TABLE c (
        id  INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
        pid INT NOT NULL,
        v   VECTOR(384) NOT NULL,
        CONSTRAINT fk_c_p FOREIGN KEY (pid) REFERENCES p(id) ON DELETE CASCADE
    ) ENGINE=InnoDB;
    WHILE i < 250 DO
        INSERT INTO p () VALUES ();
        SET i = i + 1;
    END WHILE;
    SET i = 0;
    WHILE i < 2000 DO
        -- fixture.sql: chunk i belongs to article (i MOD 250) + 1, cluster ((i MOD 250) MOD 9)
        INSERT INTO c (pid, v) VALUES ((i MOD 250) + 1,
            VEC_FromText(fixture_vec((i MOD 250) MOD 9, i + 1, 384)));
        SET i = i + 1;
    END WHILE;
    ALTER TABLE c ADD VECTOR INDEX (v) M=6 DISTANCE=cosine;
END $$

CREATE PROCEDURE measure(p_variant CHAR(1), p_build INT, p_deleted VARCHAR(40))
BEGIN
    INSERT INTO result
    SELECT p_variant, p_build, p_deleted,
           (SELECT COUNT(*) FROM c),
           (SELECT COUNT(*) FROM (SELECT id FROM c
                                  ORDER BY VEC_DISTANCE_COSINE(v, @q) LIMIT 10) a),
           (SELECT COUNT(*) FROM (SELECT id FROM c IGNORE INDEX (v)
                                  ORDER BY VEC_DISTANCE_COSINE(v, @q) LIMIT 10) b);
END $$

CREATE PROCEDURE run_all()
BEGIN
    DECLARE b INT DEFAULT 1;
    WHILE b <= 3 DO
        CALL fresh_build();
        DELETE FROM p WHERE id = 1;            -- E: the cascade removes 8 rows
        CALL measure('E', b, 'parent 1, by cascade');

        CALL fresh_build();
        DELETE FROM c WHERE pid = 1;           -- F: the same 8 rows, directly
        CALL measure('F', b, 'the same rows, directly');
        SET b = b + 1;
    END WHILE;
END $$

DELIMITER ;

-- The fixture's first evaluation query (sql/fixture.sql, eval query 1).
SET @q = VEC_FromText(fixture_vec(0, 500000, 384));

SELECT 'Building and measuring six fresh indexes; this takes a minute or so' AS progress;
CALL run_all();

SELECT variant, build, deleted, rows_left, via_index, exact
FROM result ORDER BY variant, build;

SELECT VERSION() AS server,
       CASE
         WHEN (SELECT COUNT(*) FROM result WHERE variant = 'F' AND via_index < exact) > 0
           THEN 'INCONCLUSIVE: the direct-delete control also came back short, so the cascade is not isolated as the trigger.'
         WHEN (SELECT COUNT(*) FROM result WHERE variant = 'E' AND via_index < exact) > 0
           THEN CONCAT('REPRODUCED: after one cascade delete, the index returned fewer rows than the exact scan in ',
                       (SELECT COUNT(*) FROM result WHERE variant = 'E' AND via_index < exact), ' of 3 builds (worst ',
                       (SELECT MIN(via_index) FROM result WHERE variant = 'E'), ' of 10). Deleting the same rows directly returned 10 in all 3.')
         ELSE 'NOT REPRODUCED: the index returned 10 after the cascade delete in all 3 builds.'
       END AS verdict;
