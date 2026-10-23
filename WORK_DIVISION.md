# Work division

Three components, one each. The specification in [`docs/main_dish_spec/`](docs/main_dish_spec/) is the plan
— this file only says **who** does what and **how to start**. If the spec and this file ever disagree, the
spec wins and this file is wrong.

| | Component | Owner | Spec files |
|---|---|---|---|
| **B** | Schema & retrieval | **Vedant** | 05, 06, 09 |
| **A** | Corpus & ingest | **Pranesh** | 03, 04 |
| **C** | Evaluation & CI | **Janhavi** | 07 |

Vedant integrates at the end.

---

## B — Schema & retrieval — DONE, so A and C are unblocked

Already on `main`:

```
sql/schema.sql                   all tables; idempotent; run this first
sql/fixture.sql                  2,000 synthetic chunks so nobody waits on the ingest
sql/retrieval/semantic.sql       plain top-k
sql/retrieval/hybrid_filter.sql  relational predicate + vector, one statement
sql/retrieval/hybrid_fulltext.sql  full-text + vector, fused with RRF
sql/retrieval/under_return.sql   the filtered-search behaviour, checked at 384 dims
```

**Set up in four commands.** No Python, no embedding model, no network:

```bash
mariadb -u root < sql/schema.sql
mariadb -u root < sql/fixture.sql          # ~11 seconds
mariadb -u root -t < sql/retrieval/semantic.sql
mariadb -u root -t < sql/retrieval/hybrid_filter.sql
```

In PowerShell `<` does not redirect — use `Get-Content sql/schema.sql | mariadb -u root`.

For a fast run, `CALL load_fixture(200);` instead of re-running `fixture.sql`.

**What the fixture is and is not.** 2,000 chunks, the real corpus's 9 categories at ~11% each, 384-dimension vectors that are
deterministic and loosely clustered per category, with real words in `body` so `FULLTEXT` works. It exercises
schema, query syntax and the measurement harness. **Any retrieval-quality number from it is meaningless** —
the vectors are synthetic. It exists so A and C can work in parallel, and it gets replaced by A's real
ingest.

---

## A — Corpus & ingest — Pranesh

**Deliver:** `python/config.py`, `fetch.py`, `chunk.py`, `embed.py`, `ingest.py`, `corpus_manifest.csv`,
`requirements.txt`.

**Read first:** `03_corpus.md` (which articles, and reproducibility) and `04_chunking_embedding.md` (chunk
size and the model decision). Both already state the parameters and the reasoning — you are implementing a
decision, not making one. If you disagree with a parameter, change the spec in the same PR and say why.

**How to start:**

1. `mariadb -u root < sql/schema.sql` — your target tables already exist. Do not change `schema.sql`; if you
   need a column, ask Vedant so the change lands once.
2. Write `chunk.py` first and make it a **pure function, no I/O**. It is the only part with real logic, and
   it is the only part that is cheap to unit-test. The spec's chunking experiments are impossible if it
   touches the network.
3. Then `fetch.py` (cache to `raw/`, gitignored, resumable), then `embed.py` (batched, progress shown,
   resumable), then `ingest.py` to orchestrate.
4. Write `corpus_meta` as part of ingest — model name, dimensions, query prefix, chunk size. The query path
   reads it to refuse mismatched embeddings, and without it the corpus is unreproducible.
5. **Add the vector index last**, after the rows are in: `ALTER TABLE chunks ADD VECTOR INDEX (embedding)
   DISTANCE=cosine;`. `fixture.sql` does the same — copy that line. Time it both ways if it is cheap; the
   spec flags it as a free measurement.

**Three things that will bite you:**

- **`category` is on `chunks` as well as `articles`.** Denormalised on purpose, write both.
- **The embedding model must be identical at ingest and query time**, and BGE models want the instruction
  prefix on the **query** side only. Getting this wrong produces confident nonsense with no error.
- **Do not commit the corpus.** `raw/`, `embeddings/`, `models/` are already gitignored. The manifest of
  revision ids is what makes it reproducible, and that *is* committed.

**Keep the Python thin.** It is the component most likely to sprawl and it earns the fewest marks — all the
graded depth is in SQL. No abstraction layers, no plugin architecture for embedding backends, no CLI
framework. One script that runs start to finish.

**Done when:** a clean machine runs `python -m python.ingest` from the README and ends up with ~12,000
indexed chunks, and `sql/retrieval/semantic.sql` returns sensible neighbours on real text.

---

## C — Evaluation & CI — Janhavi

**Deliver:** `sql/evaluation/ground_truth.sql`, `recall_sweep.sql`, `tests.sql`,
`.github/workflows/ci.yml`, `eval_queries.csv`, `docs/findings.md`.

**Read first:** `07_evaluation.md`. It has the method, the SQL sketches and the test list. Your `recall_runs`
table already exists in `schema.sql`, so nothing blocks you.

**How to start:**

1. `mariadb -u root < sql/schema.sql && mariadb -u root < sql/fixture.sql`. The fixture ships 16 evaluation
   queries so `ground_truth.sql` has input on day one.
2. `ground_truth.sql` — the cross-join form in the spec. It **cannot** use the vector index, which is the
   point. Keep it set-based rather than looping in Python.
3. `recall_sweep.sql` — the stored procedure. **Record `returned` as well as `hits`.** A silent truncation is
   invisible to a recall metric that divides by what it received, and that column is the only thing that
   catches it.
4. `tests.sql` — T1–T10, using `SIGNAL SQLSTATE '45000'` inside `BEGIN NOT ATOMIC` so the client exits
   non-zero. Same pattern as the starter's `test_aggregates.sql`.
5. `ci.yml` — matrix on **11.8, 12.3 and the current release**. Not 11.4: it predates the `VECTOR` type. Use
   `fixture.sql` with a small count in CI, not the real ingest.

**Two things to get right:**

- **Warm up before timing, then repeat.** One untimed pass, then 10 runs with mean, min, max and
  `STDDEV_SAMP`, and state the hardware. A single timing is not a measurement.
- **`mhnsw_ef_search` must be set explicitly in every measurement.** Inheriting the default silently makes
  the results depend on server config instead of on stated parameters.
- **Do not treat `ef_search` as the remedy for the under-return.** Finding 7c measured it at 50, 500 and
  2000 — more than the whole table — and the shortfall stayed at 0 of 10. Recall and the under-return are
  two different axes, and a sweep that conflates them reports a tuning problem where there is a correctness
  one. Report `returned` alongside `hits` at every point, which is what separates them.

**The deliverable is a curve, not a number:** the smallest `ef_search` at which recall@10 ≥ 0.98, with its
latency cost. Include a brute-force row — if exhaustive search is already fast enough, the index is not
earning its place on this corpus and we say so.

**Done when:** the recall/latency table in `docs/findings.md` is filled with real numbers from A's corpus,
and CI is green on all three versions.

**One ask specifically for you.** You have now twice caught us generalising from a single test point — the
IATA join in the starter, and the selectivity crossover in this spec. Component C is that instinct as a
deliverable.

Worth knowing before you start: finding 7c originally recorded that the shortfall **did not** reproduce at
384 dimensions. That was a false negative of ours, withdrawn on 2026-10-22 — the test's filters happened to
point the same way as the query vector, so all three scenarios were easy cases dressed as hard ones. It now
reproduces deterministically, and the governing variable turns out to be the filter's *direction*, not
dimensionality or selectivity.

Which is to say the failure mode your instinct guards against has now bitten us twice from the inside. T7 is
where it gets settled on real embeddings, and the case you construct matters more than the number of runs:
a filter correlated with the query will pass no matter how many times you repeat it.

---

## Sequencing

```
  B (done) ──┬──> A ──┐
             │        ├──> integration (Vedant) ──> README, write-up
             └──> C ──┘
```

A and C run in parallel, both against the fixture, and neither waits for the other. C switches from the
fixture to A's real corpus when it lands — that swap is a one-line change of which loader was run, which is
why the fixture matters.

**The RAG pipeline (file 08) is deliberately unassigned.** It is small and late. Whoever finishes first takes
it, or Vedant does as integrator. Do not start it early — it earns no MariaDB depth marks.

## Rules that apply to everyone

- Branch as `<yourname>/<thing>`, PR into `main`, **another contributor reviews before merge**. Rotate
  reviewers; code review between contributors is a graded requirement and was our weakest area in the
  starter.
- **Only touch your own component's files.** If you need a change in `schema.sql` or anything under
  `sql/retrieval/`, ask Vedant. One person owning the schema is what stops the merge conflicts we had on the
  AI log last time.
- Add your `AI_USE_LOG.md` row **in the same commit** as the change, not at the end of the week.
- Fill your own section of the current `self_assessment/` file before each meeting.
- Anything you measure gets repetitions, variance and the hardware stated.
- Unflattering results get published. The starter's headline was that its custom aggregate ran 2.4× slower
  than the inline formula, and saying so is the most credible thing in that README.
