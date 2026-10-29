# 02 — Architecture

## The governing principle

**Keep the Python thin and the SQL deep.**

Only the MariaDB side earns marks on the `MARIADB DEPTH` criterion, which is also the criterion that can
fail us outright. Every hour spent on an elegant Python abstraction is an hour not spent on the thing being
graded. The natural failure mode for this project is an impressive-looking application that demonstrates
almost nothing about MariaDB, and the architecture below is shaped to prevent it.

Concretely, that means:

- Python fetches, chunks, embeds and inserts. It does not rank, filter, score or post-process results.
- **All retrieval logic lives in SQL files** under `sql/`, readable and runnable on their own with the
  `mariadb` client. A reader must be able to understand the project's core by reading SQL, not Python.
- Where a choice exists between doing something in Python or in SQL, it goes in SQL — even when Python
  would be shorter. Recall measurement, for instance, is a SQL join between two result sets, not a Python
  set-intersection.

## Components

```
┌──────────────────────────────────────────────────────────────────────────────┐
│ INGEST  (python/ingest.py — run once, ~15 min)                               │
│                                                                              │
│  1. fetch      Wikipedia API -> raw/*.json          (cached on disk)         │
│  2. chunk      raw/*.json    -> chunk records       (pure function)          │
│  3. embed      chunk text    -> 384-float vectors   (local model, batched)   │
│  4. load       records       -> MariaDB             (executemany)            │
│  5. index      ALTER TABLE ... ADD VECTOR INDEX     (after load, not before) │
└──────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│ MARIADB                                                                      │
│                                                                              │
│   articles ──1:N──> chunks                                                   │
│   (metadata)        (text + VECTOR(384) NOT NULL + VECTOR INDEX cosine)      │
│                                                                              │
│   eval_queries ──1:N──> eval_ground_truth                                    │
│   (held-out questions)  (exact top-k per query, from brute force)            │
└──────────────────────────────────────────────────────────────────────────────┘
                     │                          │                    │
         ┌───────────┘              ┌───────────┘          ┌─────────┘
         ▼                          ▼                      ▼
┌──────────────────┐   ┌─────────────────────┐   ┌──────────────────────┐
│ sql/retrieval/   │   │ sql/evaluation/     │   │ python/answer.py     │
│                  │   │                     │   │                      │
│ semantic.sql     │   │ ground_truth.sql    │   │ embed question ->    │
│ hybrid_*.sql     │   │ recall_sweep.sql    │   │ run semantic.sql ->  │
│ under_return.sql │   │ latency.sql         │   │ prompt LLM ->        │
│                  │   │ tests.sql           │   │ cited answer         │
└──────────────────┘   └─────────────────────┘   └──────────────────────┘
```

## Why the index is built after the load, not before

Step 5 is deliberately separate from step 4. Inserting 10,000 rows into a table that already has an HNSW
index means the graph is rebuilt incrementally on every insert. Loading first and indexing afterwards is
the standard bulk-load pattern and should be substantially faster.

**This is a hypothesis, not a measured fact.** It is also a free measurement: we are loading the corpus
anyway, so timing it both ways costs one extra run and yields a genuine finding about MariaDB's vector
index that nobody has published. Recorded as a deliverable in file 11.

## The two-table split, and why it is forced

`articles` and `chunks` are separate tables, and that is not merely tidy normalisation — it is required by
limitation C1, **one vector index per table**.

If we ever want an article-level embedding (a vector of the whole article, for coarse-then-fine retrieval)
alongside the chunk-level embedding, those two vectors *cannot live in the same table*. Verified:

```
ERROR 1235 (42000): This version of MariaDB doesn't yet support 'multiple VECTOR indexes'
```

So the split is the design accommodating a documented server limitation, and the README should say so in
exactly those terms. It is the clearest example in the project of a MariaDB constraint visibly shaping a
schema, which is the kind of thing the depth criterion rewards.

A second consequence: because the vector lives on `chunks` and the human-meaningful metadata (title, URL,
category) lives on `articles`, every useful retrieval query is **a vector search joined back to a relational
table**. That is requirement A4 satisfied by the schema's natural shape rather than bolted on.

## Data flow for a single question

```
  question text
      │
      ▼
  embed with the SAME model used at ingest        <-- non-negotiable; see file 04
      │
      ▼
  VEC_FromText('[0.12,-0.03,...]')  bound as a parameter
      │
      ▼
  SELECT c.id, c.body, a.title, a.url,
         VEC_DISTANCE_COSINE(c.embedding, ?) AS dist
  FROM chunks c
  JOIN articles a ON a.id = c.article_id
  WHERE <optional relational predicate>
  ORDER BY dist
  LIMIT 10
      │
      ▼
  top-k chunks, each with its article title and URL
      │
      ▼
  prompt: "Answer using ONLY these passages. Cite by [n]."
      │
      ▼
  answer + citations the reader can click
```

The query returns the URL as well as the text, so citations are real links rather than invented references.
This matters: a RAG system that cites a source the reader cannot check is indistinguishable from one that
makes sources up.

## Language and dependency choices

| Choice | Decision | Reasoning |
|---|---|---|
| Ingest language | Python 3.11+ | The embedding ecosystem is Python. No real alternative. |
| DB driver | `mariadb` (the official connector) | Official MariaDB connector on a MariaDB project. `PyMySQL` would work but looks careless here. |
| Embedding | local model via `sentence-transformers` | See file 04. Reproducibility and CI, over quality. |
| Answer generation | Claude via the Anthropic API, pluggable | Kaj confirmed the answering model can be any provider or local. Needs a key, so it must be optional — the retrieval half runs without it. |
| Dependency pinning | exact versions in `requirements.txt` | The reproducibility criterion. A spec that says "install sentence-transformers" and breaks in six months fails it. |

**The retrieval half of the project must run with no API key.** Anyone evaluating the repository — including
MariaDB's own LLM evaluator, which may later actually run submissions — should be able to clone, ingest and
measure recall without signing up for anything. Answer generation is the one step that may require a key,
and the README must say so clearly and offer a local-model fallback.

## Repository layout

```
README.md                        area declaration, the plain-words explanation, results
requirements.txt                 pinned dependencies
.env.example                     DB connection and optional LLM key
.github/workflows/ci.yml         ingest a small corpus, run tests, on every push

python/
  config.py                      one place for every tunable; no magic numbers elsewhere
  fetch.py                       Wikipedia -> raw/ (cached, resumable)
  chunk.py                       pure, unit-testable, no I/O
  embed.py                       batched embedding
  ingest.py                      orchestrates 1-5; the only script the README asks you to run
  answer.py                      the query interface a reader can try (A7)

sql/
  schema.sql                     DDL; idempotent
  retrieval/semantic.sql         plain top-k semantic search
  retrieval/hybrid_filter.sql    absolute-then-fluffy, Kaj's shape
  retrieval/hybrid_fulltext.sql  full-text + vector combined
  retrieval/under_return.sql     the defect, reproduced
  evaluation/ground_truth.sql    brute force via IGNORE INDEX
  evaluation/recall_sweep.sql    recall and latency across ef_search
  evaluation/tests.sql           assertions; SIGNAL on failure, gates CI

docs/
  findings.md                    every measured result, with method
  limitations.md                 what the feature will not do
  bug_report_draft.md            the defect write-up and the Jira prior art
  jira_submissions.md            what we post, verbatim, in posting order
```

Mirrors the starter's conventions, so a reader coming from the first repository is already oriented.
