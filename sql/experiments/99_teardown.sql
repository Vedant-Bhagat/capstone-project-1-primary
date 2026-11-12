-- Undo everything the scripts in this directory add to `wikirag`.
--
-- Run this when you are done measuring. The corpus tables (articles, chunks,
-- eval_queries, corpus_meta, eval_ground_truth) are left alone -- only the
-- experiment's own additions are removed, so a torn-down database is
-- byte-identical in schema to one built by `sql/schema.sql`.
--
-- How to run:
--   Linux/macOS:  mariadb -u root < sql/experiments/99_teardown.sql
--   PowerShell:   Get-Content sql/experiments/99_teardown.sql | mariadb -u root

USE wikirag;

-- Result tables.
DROP TABLE IF EXISTS real_sweep;
DROP TABLE IF EXISTS query_home;
DROP TABLE IF EXISTS control;
DROP TABLE IF EXISTS tenant_sweep;
DROP TABLE IF EXISTS pushback;

-- Procedures.
DROP PROCEDURE IF EXISTS real_sweep_all;
DROP PROCEDURE IF EXISTS do_control;
DROP PROCEDURE IF EXISTS tenant_sweep_all;
DROP PROCEDURE IF EXISTS sweep3;

-- The synthetic filter column added by 03. This is the only change any of
-- these scripts makes to a table that `sql/schema.sql` owns, which is why it
-- is called out here and in the README rather than folded into the schema.
ALTER TABLE chunks DROP INDEX IF EXISTS ix_tenant;
ALTER TABLE chunks DROP COLUMN IF EXISTS tenant;

-- mhnsw_ef_search is a session/global variable, not schema; 04 restores it to
-- 20 itself. This resets it again in case 04 was interrupted part-way.
SET @@mhnsw_ef_search = 20;

SELECT 'teardown complete' AS '';
SHOW COLUMNS FROM chunks LIKE 'tenant';
