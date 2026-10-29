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

## Quickstart

**Requirements:** MariaDB **11.8 or later** (`VECTOR` does not exist before it) and Python **3.11**. No API
key, and no account anywhere: every measured number below is produced with `--no-llm`.

```bash
pip install -r requirements.txt            # pinned; see .env.example for connection settings
mariadb -u root < sql/schema.sql           # creates the `wikirag` database and every table
```

`schema.sql` is idempotent and creates its own database, so that one command is the whole database setup.
**On PowerShell `<` does not redirect** — use `Get-Content sql/schema.sql | mariadb -u root`.

> **Both of those are destructive, by design.** `schema.sql` begins `DROP DATABASE IF EXISTS wikirag`, and
> `sql/fixture.sql` below does `DELETE FROM chunks` — the fixture and the real corpus share one set of
> tables. That is what makes them idempotent and safe to re-run while developing, but it means **running
> either one after a full ingest destroys the corpus**, which costs about 25 minutes to rebuild. If you have
> ingested already and only want the synthetic examples, point the tools at a scratch database with
> `WIKIRAG_DB` instead.

### Try the feature in 30 seconds, without building the corpus

```bash
mariadb -u root -t < sql/fixture.sql                   # 2,000 synthetic chunks, ~11 s
mariadb -u root -t < sql/retrieval/semantic.sql        # plain top-k semantic search
mariadb -u root -t < sql/retrieval/hybrid_filter.sql   # vector + a SQL predicate, one statement
mariadb -u root -t < sql/retrieval/minimal_repro.sql   # the defect below, self-contained
```

The fixture's vectors are generated, not embedded, so **it demonstrates the SQL and proves nothing about
quality** — `docs/limitations.md` §3 is blunt about this. It exists so you can see the feature work without
waiting on an ingest.

### Build the real corpus and ask it questions

```bash
python -m python.ingest --manifest corpus_manifest.csv   # the exact 1,289 articles we measured
python -m python.answer "why can't penguins fly?" --no-llm
python -m python.answer "which birds did Linnaeus name in 1758?" --category birds --no-llm
```

Expect **about 25 minutes** with a GPU and **two hours or so** on a CPU. Wikipedia is fetched one request
per second by courtesy, which is most of the first number; embedding 18,651 chunks is 3 minutes on an
RTX 3050 against 90 on eight CPU threads (`docs/limitations.md` §5). The ingest caches to `raw/` and is
resumable, so an interrupted run continues rather than restarting. Drop `--manifest` to build from today's
Wikipedia instead of our pinned revisions — faster to start, but the numbers will not match ours exactly.

Omit `--no-llm` to have an answering model write a cited answer from the retrieved passages. That is the
**only** step needing a key; set `GEMINI_API_KEY` or `ANTHROPIC_API_KEY` in the environment (see
`.env.example`), and without one `answer.py` prints the passages and says so rather than failing.

### Reproduce the measurements

```bash
mariadb -u root -t < sql/evaluation/ground_truth.sql   # exact neighbours by brute force
mariadb -u root -t < sql/evaluation/recall_sweep.sql   # recall and latency across ef_search
mariadb -u root -t < sql/evaluation/tests.sql          # T1-T10; fails the build on a regression
python -m unittest discover -s python -p "test_*.py"   # 36 unit tests, no database needed
python -m python.grade_answers --no-llm                # retrieval hit@k against known source chunks
```

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

**Complete and measured.** 1,289 Wikipedia articles, **18,651 chunks**, real `bge-small-en-v1.5`
embeddings, CI green on MariaDB 11.8, 12.3 and the current release.

### The result

**MariaDB's default `mhnsw_default_m = 6` cannot reach 98% recall@10 on this corpus at any `ef_search`.
Setting `m = 16` reaches 99.4% at the default `ef_search`, for 0.1 ms more per query.**

| `mhnsw_default_m` | recall@10 at default `ef_search` | mean ms | smallest `ef` reaching 0.98 |
|---|---|---|---|
| **6 — the shipped default** | **0.8333** | 0.112 | **never** (0.937 at `ef` 1000) |
| **16 — our recommendation** | **0.9944** | 0.215 | **10** |

At the shipped default, one correct result in six is missing and no amount of search width recovers it —
the ceiling is the graph, not the search. One `SET GLOBAL` and 19 seconds of extra index build fixes it.

**The index does earn its place at this scale:** 0.179 ms against 14.45 ms for exhaustive search, **81×
faster** for 1.1% of the correct results given up. On our 2,000-chunk fixture it did not — brute force took
2.2 ms there, and we say so.

**The pipeline ends in a generated answer, and refuses when it should.** Asked something the corpus cannot
answer, retrieval still returns its nearest passage — it always does — and the model declines rather than
confabulating from it. Every citation in every answer resolved to a passage actually shown. Generation is
optional: `--no-llm` needs no API key, and every number in this repository is reproducible without one.

**And filtered semantic search is still not trustworthy without an index hint.** On real embeddings, at the
shipped default, a `LIMIT 10` query filtered to a category distant from the question returned **0 rows for
two of nine categories** with no error. What predicts it is the filter's *distance from the query*, not its
selectivity — the 5%-selectivity category returned nothing while the 16.7% one returned everything. See
[`docs/findings.md`](docs/findings.md).

| | Component | Owner | State |
|---|---|---|---|
| **A** | Corpus & ingest | Pranesh | `python/` fetches by pinned revision, chunks, embeds and loads; 36 unit tests |
| **B** | Schema & retrieval | Vedant | `sql/schema.sql` and four retrieval queries, each one statement |
| **C** | Evaluation & CI | Janhavi | brute-force ground truth, recall sweep, T1–T10, three-version CI |

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

Probing and development: **12.3.3**. CI **runs** against **11.8, 12.3 and the current release** on every
push, and the whole test suite is green on all three.

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
13.0.2, confirming it on a third version — and a review note of his about category naming is what exposed
the false negative described next.

### What actually governs it is the direction of the filter, not the dimensionality

We first re-checked this at **384 dimensions** and recorded that it did not reproduce. **That was a false
negative, and we found it ourselves two days later.** Two of the three test scenarios had filtered on the
same category the query vector pointed at — easy cases that looked like hard ones. Rebuilding the fixture on
the real nine-category corpus made the test honest, and the result inverted:

| | filter | selectivity | points | returned |
|---|---|---|---|---|
| A | `category`, indexed | 11.2% | **toward** the query | 10 of 10 |
| D | `category`, indexed | 10.8% | **away** from it | **0 of 10** |
| E | as D, at `mhnsw_ef_search` 50 / 500 / 2000 | 10.8% | away | **0, 0, 0** |
| F | as D, with `FORCE INDEX (ix_category)` | 10.8% | away | 10 of 10, equal to exhaustive |

A and D are a controlled pair — same column, same index, same selectivity to within half a point. Only the
direction differs.

**It varies per index build, as it does at 3 dimensions.** Five rebuilds of the same index on the same data
returned **10, 0, 2, 3, 0** rows for D. We first called this deterministic on the strength of four
consecutive failing builds; widening to five found the good one. A single build decides nothing, which is
why the CI test for it rebuilds the index until it sees the shortfall or runs out of attempts.

The mechanism follows: post-filtering explores the graph near the query and discards rows failing the
predicate. When the predicate keeps only distant rows, every candidate is discarded and the query returns an
empty set rather than widening its search.

**`mhnsw_ef_search` does not mitigate it.** At 2000 — more than the entire table — the answer is still zero.
That is the part with teeth: this is not a point on a recall/latency curve that tuning can move. `FORCE
INDEX` is the only mitigation we have found, which makes it load-bearing rather than merely prudent, because
nine categories put every filter in our corpus above the 7% crossover.

**It is still synthetic.** The fixture's clusters are near-orthogonal; real embeddings are not. Reproducing
this on real BGE vectors is the open item that decides whether it gets reported, and the checklist at the end
of [`09_verified_findings.md`](docs/main_dish_spec/09_verified_findings.md) gates it — real embeddings,
genuinely random vectors, 11.8 and the current release, Linux, and a search of MariaDB's Jira for duplicates.

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

python/                     component A: the ingest. Runs with no API key
  config.py                 every tunable parameter, and nowhere else
  fetch.py                  Wikipedia by pinned revision id, cached and resumable
  htmltotext.py             rendered HTML to plain text, standard library only
  chunk.py                  pure function, 300 words with 50 overlap, unit-tested
  embed.py                  BAAI/bge-small-en-v1.5 locally; GPU if there is one
  ingest.py                 one command: fetch, chunk, embed, load, then index
  answer.py                 retrieval in one SQL statement, generation optional
  grade_answers.py          answer grading; level 0 needs no API key
  test_chunk.py             15 tests
  test_htmltotext.py        21 tests, each drop rule mutation-checked

sql/schema.sql              all tables; idempotent
sql/fixture.sql             2,000 synthetic chunks, so no component waits on the ingest
sql/retrieval/
  semantic.sql              plain top-k semantic search
  hybrid_filter.sql         relational predicate + vector, one statement
  hybrid_fulltext.sql       full-text + vector, fused with RRF
  under_return.sql          the filtered-search behaviour, on the real corpus
  minimal_repro.sql         the same defect in 2,048 rows of pure SQL, no corpus needed
sql/evaluation/
  ground_truth.sql          exact neighbours by brute force; the index is graded against this
  recall_sweep.sql          recall and latency across ef_search, with variance
  tests.sql                 T1-T10, gating CI via SIGNAL SQLSTATE '45000'

.github/workflows/ci.yml    11.8, 12.3 and current; unit tests, then every SQL script
docs/findings.md            every measured number, with the method that produced it
docs/limitations.md         what this does NOT establish, and where the numbers stop
docs/bug_report_draft.md    the defect write-up, with the Jira prior art. Not filed
corpus_manifest.csv         revision id and text SHA-256 per article; reproducibility
eval_queries.csv            54 evaluation questions, six per category
eval_qa_pairs.csv           30 QA pairs with known source chunks, plus 10 unanswerable
.env.example                connection settings; shows which steps need no key
requirements.txt            pinned, because unpinned deps make a corpus unreproducible

self_assessment/            weekly self-assessment, one section per contributor
WORK_DIVISION.md            who owns which component, and how to start
AI_USE_LOG.md               record of AI tool use, traced per change
CONTRIBUTING.md             branching, commits, PR and review workflow
```

Both of the things this section used to list as "still to come" now exist. The real-corpus numbers are in
[`docs/findings.md`](docs/findings.md), and the under-return survived every check in
[`09_verified_findings.md`](docs/main_dish_spec/09_verified_findings.md), so
[`docs/bug_report_draft.md`](docs/bug_report_draft.md) is written.

**It has not been filed, deliberately.** Searching MariaDB's Jira first — which we had set ourselves as a
precondition — found the symptom already reported three times and still unfixed, including one ticket
(MDEV-37709) closed only because its reporter could not shrink a 250 MB dump into a test case. So the draft
now recommends commenting on that ticket with `sql/retrieval/minimal_repro.sql` rather than opening a fourth
report, and posting anything is a decision for all three of us.

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
