A project for area 4, "Vector search and RAG, natively" for the [MariaDB student database projects, 2026-09](https://mariadb.org/bachelor_hackathon_2026-09/)

# Golden Record — Vector Search and RAG in MariaDB

MariaDB 11.8 LTS added a native `VECTOR` type with HNSW indexing, so semantic search runs inside the
database instead of in a separate vector service beside it:

```sql
CREATE TABLE chunks (
    id        INT         NOT NULL AUTO_INCREMENT PRIMARY KEY,
    body      TEXT        NOT NULL,
    embedding VECTOR(384) NOT NULL,
    VECTOR INDEX (embedding) DISTANCE=cosine
);

SELECT body FROM chunks ORDER BY VEC_DISTANCE_COSINE(embedding, @query) LIMIT 10;
```

Until that existed, doing this meant running a second database next to your real one — Pinecone, Qdrant,
Weaviate, or FAISS inside a Python process. Two systems to deploy, two to back up, two to keep in sync, and
a permanent split where your facts live in one place and your meanings live in another.

This repository builds a question-answering system over Wikipedia where every retrieval step is a single
SQL statement, then measures honestly what the approximate index costs in accuracy.

**Capstone Project I**, Constructor University, in partnership with the MariaDB Foundation.

## Explained without the jargon

> Imagine every paragraph of Wikipedia being given a position on an enormous map — not a map of the world,
> but a map of meaning, where paragraphs about similar things sit near each other. Paragraphs about
> penguins sit near paragraphs about ostriches, because both are about birds that do not fly, even though
> neither mentions the other.
>
> When you ask a question, we work out where your question sits on that map and hand back the paragraphs
> standing nearest to it. Then we give those paragraphs to an AI and ask it to write the answer using only
> them, so it can show you where each part of the answer came from.
>
> The interesting bit is that the whole map lives inside the database, next to the ordinary data. That is
> new. It means you can ask "find me paragraphs that *mean* roughly this, but only from physics articles"
> in a single question — because the thing that understands meaning and the thing that knows the
> categories are, for the first time, the same thing.

## Status

**Specification complete. Schema and retrieval (component B) implemented; ingest and evaluation in
progress.**

Work is split three ways — see [`WORK_DIVISION.md`](WORK_DIVISION.md) for who owns what and how to start.

The full specification is in [`docs/main_dish_spec/`](docs/main_dish_spec/) — 14 documents plus a runnable
probe script, written before any implementation so that the graded requirements, the schema and the
measurement methodology are fixed in advance rather than reverse-engineered afterwards.

Start at [`docs/main_dish_spec/README.md`](docs/main_dish_spec/README.md).

## Team

| Name | GitHub |
|---|---|
| Vedant | [`Vedant-Bhagat`](https://github.com/Vedant-Bhagat) |
| Janhavi | [`janhavi8112`](https://github.com/janhavi8112) |
| Pranesh | [`Pranesh-Navneeth`](https://github.com/Pranesh-Navneeth) |

## MariaDB version

Requires **11.8 or later**. `VECTOR`, `VECTOR INDEX` and `VEC_DISTANCE_COSINE` were introduced in 11.8 LTS,
so nothing in this repository runs on anything earlier.

Note this is a higher floor than our starter project, which runs on 10.3 or later. The starter's CI matrix
includes 11.4; that version predates the vector type entirely and had to be dropped here.

Probing and development so far: **12.3.3**. CI will run against **11.8, 12.3 and the current release**.

## What we have already verified

Before writing the specification we probed MariaDB 12.3.3's vector support against a live server rather
than working from documentation. [`docs/main_dish_spec/probe/vector_probe.sql`](docs/main_dish_spec/probe/vector_probe.sql)
reproduces all of it, and [`09_verified_findings.md`](docs/main_dish_spec/09_verified_findings.md) is the
write-up.

**The three documented limitations are real**, with exact errors recorded: a vector-indexed column must be
`NOT NULL` (`ERROR 1252`), only one vector index is permitted per table (`ERROR 1235`), and the maximum is
16,383 dimensions (`ERROR 1074`).

**One documented warning turned out to be pessimistic.** We were told a mismatched distance function
produces meaningless results. On 12.3.3 it does not: the optimizer silently declines to use the index and
falls back to a full table scan with a filesort, so the answers stay correct and only the performance
collapses. A silent performance cliff, not silent corruption.

**And we found behaviour that is not in the documentation.** A vector query filtered on a column that is
not indexed on the vector-indexed table silently returns fewer rows than requested — no error, no warning.
Asking for 10 rows where 20 satisfy the predicate returned anywhere from 0 to 7 across eight builds, and
the count varies between rebuilds of the same index on the same data, because HNSW assigns node levels
randomly on insert. Filtering on an indexed column on the same table returned the correct count every
single time.

| build | unindexed filter | indexed filter | unfiltered |
|---|---|---|---|
| 1 | 2 | 10 | 10 |
| 2 | 1 | 10 | 10 |
| 3 | 7 | 10 | 10 |
| 4 | 3 | 10 | 10 |
| 5 | 2 | 10 | 10 |

*Five consecutive rebuilds of an identical table with identical data. Each query asks for `LIMIT 10`; both
filters match exactly 20 rows.*

### Indexing the filter column is necessary but not sufficient

Our first conclusion from the table above was that indexing the filter column fixes the problem. **That was
wrong, and a teammate's review caught it.** The probe above used a filter matching 1% of rows. Janhavi
tested the same mitigation at ~12% — the selectivity our corpus actually plans to use — and found the
optimizer abandons the pre-filter and goes back to post-filtering through the vector index.

Sweeping the selectivity of an equality predicate, three rebuilds at each point:

| matching rows | selectivity | plan chosen | rows returned |
|---|---|---|---|
| 20 | 1.0% | btree — pre-filter | 10, 10, 10 |
| 125 | 6.2% | btree — pre-filter | 10, 10, 10 |
| 166 | 8.3% | **vector index — post-filter** | **0, 2, 0** |
| 250 | 12.5% | **vector index — post-filter** | **0, 10, 10** |

**The crossover sits around 7%.** Below it the plan is exact. Above it the plan is silently unreliable, and
Janhavi also observed a run returning the right *number* of rows with none of the *right* rows — which no
row count would betray.

The fix is to stop trusting the optimizer and write the hint into the query. At 12.5%, four rebuilds:

| | run 1 | run 2 | run 3 | run 4 |
|---|---|---|---|---|
| default plan | **0** | **0** | **0** | 10 |
| `FORCE INDEX (ix_category)` | 10 | 10 | 10 | 10 |

The forced results are identical to exhaustive search, not merely the right count.

So the honest headline, which is sharper than what we started with: **MariaDB's vector index does not
currently serve selective filtered queries.** You either accept approximate results that are sometimes
empty, or you force an exact scan over the filtered subset and the vector index contributes nothing. For a
12% slice of ~13,000 chunks the exact scan is cheap and is clearly the right trade — but it is a real
limitation of the feature, not a detail.

This is why the schema denormalises the filter column onto the vector-indexed table *and* why every hybrid
query carries `FORCE INDEX`. Both halves are required: the hint cannot name an index on another table. The
reasoning is in [`05_schema.md`](docs/main_dish_spec/05_schema.md) and the measurements in
[`09_verified_findings.md`](docs/main_dish_spec/09_verified_findings.md), finding 7b.

Credit: Janhavi found this reviewing the specification, and it is the second time her review has caught us
generalising from one convenient test — the first was an IATA-code join in the starter that silently
inflated 66,770 routes to 76,277 rows. Pranesh independently reproduced the original defect on MariaDB
13.0.2, confirming it on a third version.

**This is not a claim about MariaDB in general — and we have since narrowed it ourselves.** It was observed
on 12.3.3 on Windows with 3-dimensional synthetic vectors. Re-checked at **384 dimensions** against the real
schema and a 2,000-chunk fixture, **it did not reproduce**: every configuration returned the full 10 rows,
including a filter deliberately selecting only rows far from the query. So the shortfall is low-dimensional
behaviour on current evidence, not a defect we are prepared to report, and whether it affects real
embeddings is still open (finding 7c). There is a six-item verification checklist at the end of
[`09_verified_findings.md`](docs/main_dish_spec/09_verified_findings.md) — reproduce at 384 dimensions on
real embeddings, with genuinely random vectors, on 11.8 and the current release, on Linux, and search
MariaDB's Jira for duplicates — which gates it before it goes anywhere public.

## Repository layout

```
docs/main_dish_spec/        the specification; start at its README
  00_overview.md            what we are building, in plain words
  01_requirements.md        every requirement traced to its source
  02_architecture.md        components and the Python/SQL boundary
  03_corpus.md              which Wikipedia articles, and reproducibility
  04_chunking_embedding.md  chunk size and the embedding-model decision
  05_schema.md              the DDL, with constraints verified on a server
  06_retrieval.md           query patterns and hybrid search
  07_evaluation.md          recall methodology and the benchmark harness
  08_rag_pipeline.md        answer generation and how it is judged
  09_verified_findings.md   what we proved on a live server
  10_risks.md               what can go wrong, and the response
  11_deliverables.md        file inventory, milestones, acceptance criteria
  12_open_decisions.md      what is still open, including the work split
  probe/vector_probe.sql        reproduces findings 1-7
  probe/selectivity_probe.sql   reproduces finding 7b (Janhavi)

sql/schema.sql              all tables; idempotent
sql/fixture.sql             2,000 synthetic chunks, so no component waits on the ingest
sql/retrieval/
  semantic.sql              plain top-k semantic search
  hybrid_filter.sql         relational predicate + vector, one statement
  hybrid_fulltext.sql       full-text + vector, fused with RRF
  under_return.sql          the filtered-search behaviour, checked at 384 dims

self_assessment/            weekly self-assessment, one section per contributor
WORK_DIVISION.md            who owns which component, and how to start
AI_USE_LOG.md               record of AI tool use, traced per change
CONTRIBUTING.md             branching, commits, PR and review workflow
```

Still to come: `python/` (ingest), `sql/evaluation/` (recall harness) and `.github/workflows/`, per the
milestones in [`11_deliverables.md`](docs/main_dish_spec/11_deliverables.md).

## Our other project

This is the **main dish**. Our **starter** project — area 2, "Custom aggregate functions in SQL" — is a
separate repository: **https://github.com/Vedant-Bhagat/capstone-project-1**

The two are separate because the evaluation prompt requires one declared area on the first line of a
README, and whichever area a README declares is the only one scored. One README cannot truthfully declare
two areas.

Self-assessments for the weeks up to and including 2026-10-15 are in that repository; the weekly record
continues here from 2026-10-22, when main-dish work began in earnest.

## AI use

We use AI tools in a traceable way, per the course's policy. Every use is logged in
[`AI_USE_LOG.md`](AI_USE_LOG.md): the tool, the part of the work it touched, the prompt, and the commit it
produced. AI-assisted commits also carry `Co-Authored-By` trailers, so the record is visible in git history
as well as in the log.

Worth stating plainly for this repository in particular: the findings above were obtained by **running SQL
against a live MariaDB server**, not from a model's prior knowledge, and the script that produces them is
committed so anyone can re-check them. One intermediate result during that probe looked clean and did not
reproduce; the write-up says so and marks those numbers as not quotable.
