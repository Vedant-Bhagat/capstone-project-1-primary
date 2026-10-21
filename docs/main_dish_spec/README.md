# Main dish — specification

**Project area 4 of the MariaDB student database projects, 2026-09: "Vector search and RAG, natively".**
Team Golden Record — Constructor University Capstone Project I, in partnership with the MariaDB Foundation.

This folder is the full specification for the main dish. It is written before implementation so that
the graded requirements, the schema, and the measurement methodology are fixed in advance rather than
reverse-engineered from whatever we happen to build.

## Read in this order

| # | File | What it settles |
|---|---|---|
| 00 | [`00_overview.md`](00_overview.md) | What we are building, in plain words. The "explain it to a parent" version. |
| 01 | [`01_requirements.md`](01_requirements.md) | Every requirement, traced to its source. The definition of done. |
| 02 | [`02_architecture.md`](02_architecture.md) | Components, data flow, and the boundary between Python and SQL. |
| 03 | [`03_corpus.md`](03_corpus.md) | Which Wikipedia articles, how they are fetched, how a reader reproduces it. |
| 04 | [`04_chunking_embedding.md`](04_chunking_embedding.md) | Chunk size and overlap; the embedding-model decision and its consequences. |
| 05 | [`05_schema.md`](05_schema.md) | The DDL, with every constraint verified against a live server. |
| 06 | [`06_retrieval.md`](06_retrieval.md) | Query patterns, hybrid search, and the `ef_search` dial. |
| 07 | [`07_evaluation.md`](07_evaluation.md) | Recall methodology, the brute-force baseline, the benchmark harness, CI gates. |
| 08 | [`08_rag_pipeline.md`](08_rag_pipeline.md) | Turning retrieved chunks into a cited answer, and judging it. |
| 09 | [`09_verified_findings.md`](09_verified_findings.md) | **What we already proved on a live server, including a defect.** |
| 10 | [`10_risks.md`](10_risks.md) | What can go wrong, and what we do about it. |
| 11 | [`11_deliverables.md`](11_deliverables.md) | File inventory, milestones, acceptance criteria. |
| 12 | [`12_open_decisions.md`](12_open_decisions.md) | What is still undecided, including work distribution. |

Supporting material: [`probe/vector_probe.sql`](probe/vector_probe.sql) — the reproducible script behind every
claim in file 09.

## The one-paragraph version

MariaDB 11.8 added a native `VECTOR` type with an HNSW index, so semantic search runs inside the database
instead of in a separate vector service beside it. We embed a corpus of at least 1,000 Wikipedia articles
into roughly 10,000 chunks, store the embeddings in a `VECTOR` column with a cosine `VECTOR INDEX`, and
retrieve by `ORDER BY VEC_DISTANCE_COSINE(...) LIMIT k`. We then do the part that makes it a database project
rather than an AI demo: measure recall against an exhaustive baseline, show where the approximate index
loses answers, demonstrate genuine hybrid queries that combine a relational predicate with vector
similarity in one statement, and end the pipeline in a generated, cited answer.

## Why this is not just a RAG tutorial

Three things separate this from the thousands of RAG walkthroughs online, and all three are the reason the
work is gradeable:

1. **The retrieval is approximate and we quantify it.** HNSW is fast because it does not look at every row.
   That means it sometimes misses the true nearest neighbour. We measure how often, against an exhaustive
   baseline, across the full range of the `mhnsw_ef_search` dial. The deliverable is a curve, not a number.
2. **Hybrid search is the capability a bolt-on vector service cannot have.** A standalone vector database
   does not know about your other tables, so it cannot filter on them in the same query. MariaDB can.
3. **We already found a defect.** Before writing a line of implementation we reproduced a case where a
   filtered vector query silently returns fewer rows than requested — sometimes zero when twenty rows
   match. See file 09. This is the single most valuable thing in the project and it shapes the schema.

## Status

Specification. No implementation started. Written 2026-10-15.

The verified findings in file 09 were obtained against **MariaDB 12.3.3** on 2026-10-15 using
`probe/vector_probe.sql`. Everything stated there was observed, not recalled; everything stated elsewhere
as a design intention is marked as such.
