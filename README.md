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

## Try this

The one query worth copying: meaning, a relational filter and a join, in one statement. It runs on the
2,000-chunk fixture, which takes two commands — `mariadb -u root < sql/schema.sql`, then
`mariadb -u root < sql/fixture.sql` (~11 s, per *Quickstart*). **Both wipe the `wikirag` database**; see
*Quickstart* before running them after a real ingest.

```sql
USE wikirag;
SET @q = (SELECT embedding FROM eval_queries ORDER BY id LIMIT 1);

SELECT a.title, c.section, LEFT(c.body, 60) AS preview,
       VEC_DISTANCE_COSINE(c.embedding, @q) AS distance
FROM chunks c FORCE INDEX (ix_category)   -- do not remove: see below
JOIN articles a ON a.id = c.article_id
WHERE c.category = 'composers'
  AND c.word_count >= 100
ORDER BY distance
LIMIT 10;
```

The first query points at `birds` and the filter keeps `composers` — the hard case, a filter pointing away
from the question. Put `EXPLAIN` in front of it, then delete the `FORCE INDEX` line and look again. With the
hint the plan reads `key: ix_category`: the btree selects the composers rows and every distance among them
is computed exactly. Without it the plan reads `key: embedding`: a walk of the HNSW graph near the
question, discarding non-composer rows afterwards. That second plan is the one that can silently return
fewer rows than asked for. Whether rows actually go missing varies with the index build, so the fixture may
well return all ten; [`sql/retrieval/minimal_repro.sql`](sql/retrieval/minimal_repro.sql) is built to show
them going missing, in its own database. The hint is how every query in this repository stays on the first
plan.

On the fixture every chunk is 300 words, so `word_count >= 100` shows the shape of a second predicate
rather than filtering anything.

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

### How the numbers above were produced

So that the method is here and not only behind a link. Full detail, including every figure we withdrew, is
in [`docs/findings.md`](docs/findings.md); what this does **not** establish is in
[`docs/limitations.md`](docs/limitations.md).

- **The ground truth is exhaustive search over the same data with the same embeddings**
  ([`ground_truth.sql`](sql/evaluation/ground_truth.sql)) — a cross join with a window function, with
  `EXPLAIN` committed to prove the vector index cannot serve it, and a tie check at the rank-10 boundary.
  So recall@10 is a question about **the index**, not about the embedding model.
- **Latency is ten timed repetitions after a warm-up**, reporting mean, min, max and `STDDEV_SAMP` rather
  than one number ([`recall_sweep.sql`](sql/evaluation/recall_sweep.sql)). Brute force is recorded as
  `ef_search = 0` and its recall is asserted to be exactly 1.0, which checks the ground truth itself.
- **One variable at a time.** `mhnsw_default_m` and `mhnsw_ef_search` were swept separately, with the corpus,
  the model and the machine held fixed.
- **Repeated where the result varies.** The under-return changes per index build, so it is measured across
  five rebuilds, and `tests.sql` T7 retries rather than asserting one build.
- **Someone else's machine.** CI runs the suite and
  [`minimal_repro.sql`](sql/retrieval/minimal_repro.sql) on 11.8, 12.3 and the current release on Linux, so
  the defect is reproducible from a public log. **Every *timing* figure, though, comes from one Windows
  laptop** — stated wherever those numbers appear.
- **What is weakest.** Answer *quality* is the least measured part: retrieval hit@k is graded with no API
  key (`grade_answers.py --no-llm`, hit@10 1.000 / hit@1 0.767 over 30 pairs with known source chunks), but
  the abstention rate and answer correctness need a key and have not been run over the full set. The hit@10
  of 1.000 is an upper bound, because each question was written from the chunk it is scored against.

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

Each component was built by its owner and landed through a pull request reviewed by another
contributor. Setup for all three is in *Quickstart* above.

The full specification is in [`docs/main_dish_spec/`](docs/main_dish_spec/) — 14 documents plus a runnable
probe script, written before any implementation so that the graded requirements, the schema and the
measurement methodology are fixed in advance rather than reverse-engineered afterwards.

Start at [`docs/main_dish_spec/README.md`](docs/main_dish_spec/README.md).

## What doing this inside MariaDB gave us — and what it didn't

**One statement instead of two systems.** The semantic search, the category filter, the length filter and
the join back to article titles and URLs are one `SELECT` ([`hybrid_filter.sql`](sql/retrieval/hybrid_filter.sql),
and `retrieve()` in [`answer.py`](python/answer.py)). A separate vector store returns ids; you then query
your real database for the titles, and write the code that stitches the two together
([`06_retrieval.md`](docs/main_dish_spec/06_retrieval.md) §1).

**Keywords and meaning in the same table.** A `FULLTEXT` index sits beside the vector index on `chunks`,
and [`hybrid_fulltext.sql`](sql/retrieval/hybrid_fulltext.sql) fuses the two rankings with RRF in SQL.

**Vectors that cannot drift from their rows.** Each article and its chunk vectors are written on one
connection and committed together — "a commit is always a whole article" ([`ingest.py`](python/ingest.py)) —
and the foreign key `fk_chunk_article ... ON DELETE CASCADE` ([`schema.sql`](sql/schema.sql)) removes an
article's vectors with it. There is no second copy to re-sync. How the embeddings were made is stored next
to them in `corpus_meta`, and `answer.py` refuses to query with a different model.

**And the counterpoint our own measurements force.** The vector index does not serve selective filtered
queries. Unhinted, the optimizer post-filters through the HNSW graph and can return 0 rows of 10 with no
error ([`docs/findings.md`](docs/findings.md)). With `FORCE INDEX (ix_category)` the btree selects the
slice and every distance in it is computed exactly — correct, but the vector index contributes nothing
to that query. So for filtered search, what the native approach gave us is not a faster approximate search;
it is that the exact fallback is one hint away, in the same statement, and cheap at this corpus size. It
also cost us something: the hint cannot name an index on another table, so `category` is copied onto
`chunks`, and test T3 exists to catch it drifting from `articles`.

We did not benchmark against a dedicated vector database ([`docs/limitations.md`](docs/limitations.md) §6),
so none of this is a claim that one would be slower or less accurate — only that it could not run the
statement above.

### Chunking, model and index — the short version

- **300-word chunks, 50-word overlap** (~17%), never split mid-sentence, never across a section heading,
  under 40 words discarded. 300 words stays inside the model's 512-token limit so nothing is silently
  truncated; the overlap keeps a fact on a boundary whole in at least one chunk.
- **Each chunk is embedded as "title — section, then body"**, stored bare, so a passage that never names
  its subject can still be found.
- **`BAAI/bge-small-en-v1.5`, 384 dimensions, run locally.** Local because the ingest must run from this
  README with no API key, and a pinned local model gives identical vectors every time. BGE because it is
  trained for retrieval, at half the index size of a 768-dimension model. Its relative quality comes from
  published benchmarks, not our measurement, and the title-prepending choice has not been A/B-tested on
  this corpus.
- **`DISTANCE=cosine`, `m = 16`, `ef_search` at its default.** Cosine ignores vector length, so no
  normalisation step is needed. `m = 16` rather than MariaDB's 6 is the measured result above.

Every value lives in [`python/config.py`](python/config.py); the full reasoning, including the models we
rejected, is in [`04_chunking_embedding.md`](docs/main_dish_spec/04_chunking_embedding.md).

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

**On this fixture, `mhnsw_ef_search` does not mitigate it.** At 2000 — more than the entire table — the
answer is still zero. That turned out to be a property of the fixture's near-orthogonal clusters, not of
the index: on real embeddings every category is whole by `ef_search = 200`
([`docs/findings.md`](docs/findings.md)). The fixture is the harsher geometry. `FORCE INDEX` remains the
only mitigation that returned the exact answer in every case we measured.

**It reproduces on real embeddings.** On the full corpus — 18,651 `bge-small-en-v1.5` chunks, `LIMIT 10`,
MariaDB's defaults — `composers` and `space_telescopes` returned 0 rows, `ethics` 2 and `architecture` 4,
while `FORCE INDEX` returned the exact answer for all nine categories. What predicts the shortfall is the
filter's distance from the query, not its selectivity: the 5.0% category returned nothing and the 16.7%
one returned everything, so the ~7% crossover above was measuring a correlate. At `m = 16` two categories
are still short, which is why the hint stays. The checklist at the end of
[`09_verified_findings.md`](docs/main_dish_spec/09_verified_findings.md) is complete except for two items
it explains: uniform-random vectors, skipped deliberately, and re-sweeping the crossover at 384 dimensions,
still open.

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

sql/experiments/            how the filtered-search numbers were measured; run 01-04 in
                            order, then 99_teardown.sql. Adds a synthetic `tenant`
                            column to chunks; see its README

.github/workflows/ci.yml    11.8, 12.3 and current; unit tests, then every SQL script
docs/findings.md            every measured number, with the method that produced it
docs/limitations.md         what this does NOT establish, and where the numbers stop
docs/bug_report_draft.md    the defect write-up, with the Jira prior art
docs/jira_submissions.md    the three posts as they go to Jira, in order, with a checkbox each
docs/bug_explainer.html     the same case for a reader with no context; open it in a browser
docs/contribution_proposal.md  the defect plus the three pieces of work we offered MariaDB, for a tech lead
corpus_manifest.csv         revision id and text SHA-256 per article; reproducibility
eval_queries.csv            54 evaluation questions, six per category
eval_qa_pairs.csv           30 QA pairs with known source chunks, plus 10 unanswerable
.env.example                connection settings; shows which steps need no key
requirements.txt            pinned, because unpinned deps make a corpus unreproducible

self_assessment/            weekly self-assessment, one section per contributor
AI_USE_LOG.md               record of AI tool use, traced per change
CONTRIBUTING.md             branching, commits, PR and review workflow
```

Both of the things this section used to list as "still to come" now exist. The real-corpus numbers are in
[`docs/findings.md`](docs/findings.md), and the under-return survived every check in
[`09_verified_findings.md`](docs/main_dish_spec/09_verified_findings.md), so
[`docs/bug_report_draft.md`](docs/bug_report_draft.md) is written.

**What goes to MariaDB is not a fourth bug report.** Searching their Jira first — a precondition we had set
ourselves — found the symptom already reported three times and still unfixed, including one ticket
(MDEV-37709) closed only because its reporter could not shrink a 250 MB dump into a test case.
`sql/retrieval/minimal_repro.sql` is that missing test case. So the contribution is: a comment on
MDEV-37709 carrying the script, a comment on MDEV-34774 that the symptom survives the fix marked against it
in 11.7.1, and only then the `mhnsw_default_m = 6` default as its own issue — contributions to open work
first, an opinion about a default last.

The three posts are written out verbatim in
[`docs/jira_submissions.md`](docs/jira_submissions.md), which records which are up. All three of us agreed
in person on 2026-10-29 that they should go, and that the three caveats listed at the end of that file —
including the two retractions in our own history — travel with them.

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
