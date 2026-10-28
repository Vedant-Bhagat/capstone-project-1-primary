# 05 — Schema

Every constraint asserted here was checked against MariaDB 12.3.3 on 2026-10-15. The exact probe is
[`probe/vector_probe.sql`](probe/vector_probe.sql) and the raw results are in file 09.

## The DDL

```sql
-- sql/schema.sql — idempotent; drops and recreates everything it owns.

DROP DATABASE IF EXISTS wikirag;
CREATE DATABASE wikirag;
USE wikirag;

-- ---------------------------------------------------------------------------
-- corpus_meta: one row. Records how the vectors were made.
-- Without this, a corpus is unreproducible and a query path can silently
-- embed questions with the wrong model. See file 04.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- articles: metadata only. No vector here (see "the one-index rule" below).
-- ---------------------------------------------------------------------------
CREATE TABLE articles (
    id          INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    pageid      INT          NOT NULL,
    revid       BIGINT       NOT NULL,          -- pins the exact revision
    title       VARCHAR(255) NOT NULL,
    url         VARCHAR(512) NOT NULL,
    category    VARCHAR(32)  NOT NULL,
    word_count  INT          NOT NULL,
    fetched_at  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE KEY uq_pageid (pageid),
    KEY ix_category (category)
);

-- ---------------------------------------------------------------------------
-- chunks: the retrieval unit, and the only table with a vector index.
-- ---------------------------------------------------------------------------
CREATE TABLE chunks (
    id          INT           NOT NULL AUTO_INCREMENT PRIMARY KEY,
    article_id  INT           NOT NULL,
    section     VARCHAR(255)  NOT NULL DEFAULT '',
    ordinal     SMALLINT      NOT NULL,
    body        TEXT          NOT NULL,
    word_count  SMALLINT      NOT NULL,

    -- Denormalised from articles. Deliberate. See "why category is duplicated".
    category    VARCHAR(32)   NOT NULL,

    -- NOT NULL is mandatory, not stylistic: a nullable column cannot be
    -- vector-indexed. Verified: ERROR 1252 "All parts of a VECTOR index
    -- must be NOT NULL".
    embedding   VECTOR(384)   NOT NULL,

    CONSTRAINT fk_chunk_article FOREIGN KEY (article_id)
        REFERENCES articles(id) ON DELETE CASCADE,

    KEY ix_article (article_id),

    -- Load-bearing for correctness, not just speed. See below.
    KEY ix_category (category),

    FULLTEXT KEY ft_body (body)
);

-- Added AFTER the bulk load, by python/ingest.py step 5:
--   ALTER TABLE chunks ADD VECTOR INDEX (embedding) DISTANCE=cosine;
-- Verified that ALTER TABLE ... ADD VECTOR INDEX works on a populated table.

-- ---------------------------------------------------------------------------
-- Evaluation. Two distinct sets; see file 03 for why they are not one set.
-- ---------------------------------------------------------------------------
CREATE TABLE eval_queries (          -- for recall: no labelled answer needed
    id          INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    query_text  VARCHAR(512) NOT NULL,
    embedding   VECTOR(384)  NOT NULL          -- no index; we never search these
);

CREATE TABLE eval_ground_truth (     -- exact top-k per query, from brute force
    query_id    INT      NOT NULL,
    rank_pos    SMALLINT NOT NULL,
    chunk_id    INT      NOT NULL,
    distance    DOUBLE   NOT NULL,
    PRIMARY KEY (query_id, rank_pos),
    KEY ix_qc (query_id, chunk_id)
);

CREATE TABLE eval_qa_pairs (         -- for answer quality
    id            INT          NOT NULL AUTO_INCREMENT PRIMARY KEY,
    question      VARCHAR(512) NOT NULL,
    expected      TEXT         NOT NULL,
    source_chunk  INT          NULL,            -- nullable: no vector index here
    KEY ix_src (source_chunk)
);
```

## Why `category` is duplicated onto `chunks`

This is the most important decision in the schema, and it exists because of a defect we reproduced before
writing any of it.

The natural design puts `category` only on `articles` and filters through the join:

```sql
SELECT c.id FROM chunks c JOIN articles a ON a.id = c.article_id
WHERE a.category = 'physics'
ORDER BY VEC_DISTANCE_COSINE(c.embedding, ?) LIMIT 10;
```

The filter is then on a *different table* from the vector index, so MariaDB cannot pre-filter `chunks` before
walking the HNSW graph. It walks the graph, collects candidates, and applies the filter afterwards. When the
filter rejects most candidates, **the query silently returns fewer rows than requested** — in our probe,
7 rows when 10 were asked for and 20 matched, and at some `mhnsw_ef_search` settings **0 rows**. No error,
no warning (file 09).

Denormalising `category` onto `chunks` **and indexing it** lets the optimizer pre-filter instead: it uses
`ix_category` to narrow to the matching chunks, then computes distances exactly over that subset. The plan
changes from `key: embedding, Extra: Using where` to `key: ix_category, Extra: Using filesort`.

**But indexing the column is not enough on its own.** An earlier version of this file claimed it was, on the
strength of a probe at 1% selectivity. Janhavi tested the same mitigation at ~12% — the selectivity file 03
actually plans — and found the optimizer abandons the pre-filter and goes back to post-filtering through the
vector index, with the same silent nondeterministic shortfall. The crossover sits around **7%**. Finding 7b
in file 09 has the sweep.

So the rule the schema encodes has two halves, and both are required:

> **1. Any column used to filter a vector query must live on the same table as the vector index, and must
> be indexed.** Otherwise the query can under-return without telling you — and an index hint cannot name an
> index on another table, so this is what makes the second half possible at all.
>
> **2. The query must force that index.** Above roughly 7% selectivity the optimizer will not choose it,
> and `FORCE INDEX` is what makes the plan deterministic. Verified over four rebuilds at 12.5%: forced
> gives 10 of 10 every time and results identical to exhaustive search, while the default plan returned 0
> on three of those four.

The cost is an exhaustive scan over the matching subset instead of a graph walk. On ~1,440 chunks that is
cheap, and the result is **exact rather than approximate** — a better answer, not a worse one. The price is
that the vector index contributes nothing to a filtered query, which is a real limitation of the feature and
is written up as such in file 09.

Nothing in MariaDB's documentation told us any of this. We found it by probing, Janhavi found the hole in
our first conclusion by probing further, and the schema is shaped by what the server actually did. That is
the single most defensible design decision in the project, and the README should present it exactly that
way — including the part where our first answer was wrong.

The normalisation purist's objection is real and should be answered in the README rather than dodged:
`chunks.category` can drift from `articles.category`. Our corpus is immutable after ingest so it cannot
drift in practice, and a test asserts the two agree. Were this a mutable production system, a trigger or a
generated column would be the right answer.

## The one-index rule and what it forces

```
ERROR 1235 (42000): This version of MariaDB doesn't yet support 'multiple VECTOR indexes'
```

Verified by attempting two `VECTOR INDEX` declarations on one table.

Consequences:

1. `articles` has **no** embedding column. An article-level vector for coarse-to-fine retrieval would need a
   third table, `article_embeddings`, with its own index. Noted as a stretch goal in file 12.
2. We cannot index both `body` and, say, a summary embedding on `chunks`. One vector per row, chosen
   deliberately.
3. `eval_queries.embedding` is a `VECTOR` column with **no index** — which is fine, and worth noting in the
   README, because it shows the type and the index are separable. We store those vectors to compare against,
   never to search.

The phrase "doesn't **yet** support" in MariaDB's own error message suggests this is a current limitation
rather than a design decision, which is worth quoting in the limitations write-up.

## Index parameters (requirement A6)

| Parameter | Default (verified) | Our value | Reasoning |
|---|---|---|---|
| `DISTANCE` | `euclidean` | **`cosine`** | Cosine is the right metric for text embeddings, and models like BGE are trained for it. **The default is the wrong one for our use**, which is why it is stated explicitly. See the trap below. |
| `mhnsw_default_m` | `6` | `6` initially, swept | The graph's connections per node. Higher means better recall and a bigger index. We sweep it in file 07 rather than guess. |
| `mhnsw_ef_search` | `20` | **determined by experiment** | The recall/latency dial. Finding its right value *is* the project's central result. |
| `mhnsw_max_cache_size` | `16777216` (16 MB) | **raised, value measured** | Our index exceeds 16 MB at 384 dims over ~13,000 chunks (file 03; an unverified estimate until the first full ingest). Leaving the default means paying disk I/O on every search, which would make every latency number we publish a measurement of the wrong thing. |
| `VECTOR` max dims | `16383` | 384 used | Verified: `VECTOR(65533)` fails with `ERROR 1074 ... max = 16383`. Ample headroom; recorded for completeness. |

### The trap worth the most marks

`mhnsw_default_distance` is **`euclidean`**. So this innocuous DDL —

```sql
VECTOR INDEX (embedding)          -- no DISTANCE clause
```

— builds a Euclidean index. Query it with `VEC_DISTANCE_COSINE` and MariaDB **silently stops using the
index** and falls back to a full table scan with a filesort. The answers stay correct; the performance
collapses, and nothing says why.

Kaj warned us the results would be "meaningless" if the metric mismatched. On 12.3.3 that turns out to be
the kinder outcome: it is a silent performance cliff, not silent corruption (file 09). Either way, the
defence is the same — always write `DISTANCE=cosine` explicitly, and check `EXPLAIN` shows `key: embedding`
rather than `type: ALL`.

This is a good README item because it is the sort of thing that would cost a reader a day, and because it is
a case where we can report that the documented warning was pessimistic. Being able to say *we tested the
warning and here is what actually happens* is worth more than repeating it.

## Engine and charset

InnoDB, `utf8mb4`. Wikipedia text contains the full range of Unicode and anything narrower mangles it.
No `COMPRESSED` row format: it would add CPU to every page read and confound the latency measurements.
