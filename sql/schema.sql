-- ===========================================================================
-- schema.sql -- the whole schema. Idempotent: drops and recreates everything.
--
-- Run:  mariadb -u root < sql/schema.sql
--   PowerShell:  Get-Content sql/schema.sql | mariadb -u root
--
-- Requires MariaDB 11.8+ (VECTOR type). Spec: docs/main_dish_spec/05_schema.md
--
-- The VECTOR INDEX is NOT created here. It is added after the bulk load, by
-- sql/fixture.sql or by python/ingest.py step 5, because inserting into an
-- already-indexed table rebuilds the HNSW graph on every row.
-- ===========================================================================

DROP DATABASE IF EXISTS wikirag;
CREATE DATABASE wikirag;
USE wikirag;

-- One row. Records how the vectors were made, so a corpus is reproducible and
-- the query path can refuse to embed questions with the wrong model.
CREATE TABLE corpus_meta (
    id              TINYINT      NOT NULL PRIMARY KEY DEFAULT 1,
    embed_model     VARCHAR(128) NOT NULL,
    embed_dims      SMALLINT     NOT NULL,
    query_prefix    VARCHAR(255) NOT NULL DEFAULT '',
    chunk_words     SMALLINT     NOT NULL,
    chunk_overlap   SMALLINT     NOT NULL,
    prepend_title   BOOLEAN      NOT NULL,
    distance_metric VARCHAR(16)  NOT NULL,
    ingested_at     DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT one_row CHECK (id = 1)
);

-- Metadata only. No embedding column here: only one VECTOR index is allowed
-- per table, and it belongs on chunks.
CREATE TABLE articles (
    id          INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    pageid      INT          NOT NULL,
    revid       BIGINT       NOT NULL,          -- pins the exact revision
    title       VARCHAR(255) NOT NULL,
    url         VARCHAR(512) NOT NULL,
    category    VARCHAR(32)  NOT NULL,
    word_count  INT          NOT NULL,

    -- SHA-256 of the extracted text. Lets corpus_manifest.csv be written from
    -- the database rather than from whatever one run happened to fetch, so a
    -- resumed ingest still produces a complete manifest. '' for the fixture.
    text_sha256 CHAR(64)     NOT NULL DEFAULT '',

    fetched_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_pageid (pageid),
    KEY ix_category (category)
);

CREATE TABLE chunks (
    id          INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    article_id  INT           NOT NULL,
    section     VARCHAR(255)  NOT NULL DEFAULT '',
    ordinal     SMALLINT      NOT NULL,
    body        TEXT          NOT NULL,
    word_count  SMALLINT      NOT NULL,

    -- Denormalised from articles on purpose. An index hint cannot name an
    -- index on another table, and filtered vector queries need the hint.
    category    VARCHAR(32)   NOT NULL,

    -- NOT NULL is mandatory: ERROR 1252 if a vector-indexed column is nullable.
    embedding   VECTOR(384)   NOT NULL,

    CONSTRAINT fk_chunk_article FOREIGN KEY (article_id)
        REFERENCES articles(id) ON DELETE CASCADE,
    KEY ix_article (article_id),

    -- Load-bearing for CORRECTNESS, not speed. Every filtered vector query
    -- must FORCE this index or it can silently return too few rows.
    KEY ix_category (category),

    FULLTEXT KEY ft_body (body)
);

-- Evaluation. Two separate query sets on purpose -- recall needs no labels
-- (ground truth is brute force), answer quality does. Spec: 03_corpus.md.
CREATE TABLE eval_queries (
    id          INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    query_text  VARCHAR(512) NOT NULL,
    embedding   VECTOR(384)  NOT NULL      -- no index; we never search these
);

CREATE TABLE eval_ground_truth (
    query_id    INT      NOT NULL,
    rank_pos    SMALLINT NOT NULL,
    chunk_id    INT      NOT NULL,
    distance    DOUBLE   NOT NULL,
    PRIMARY KEY (query_id, rank_pos),
    KEY ix_qc (query_id, chunk_id)
);

CREATE TABLE eval_qa_pairs (
    id            INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    question      VARCHAR(512) NOT NULL,
    expected      TEXT         NOT NULL,
    source_chunk  INT          NULL,
    KEY ix_src (source_chunk)
);

-- Written by the recall harness. Lives here so component C is not blocked on
-- a schema change. `returned` is what catches a silent truncation: any row
-- with returned < k is the under-return defect.
CREATE TABLE recall_runs (
    ef_search   INT      NOT NULL,
    k           SMALLINT NOT NULL,
    query_id    INT      NOT NULL,
    hits        SMALLINT NOT NULL,
    returned    SMALLINT NOT NULL,
    elapsed_us  BIGINT   NOT NULL,
    PRIMARY KEY (ef_search, k, query_id)
);

SELECT 'schema.sql: wikirag created' AS result;
