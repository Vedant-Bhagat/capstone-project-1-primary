# Findings

Every measured result in the project, with the method that produced it. Spec:
[`main_dish_spec/07_evaluation.md`](main_dish_spec/07_evaluation.md).

**Status (2026-10-23): the harness is built and validated; the headline numbers do not exist yet.** They need
component A's real corpus. Everything below that carries a number was measured on the synthetic fixture
(`sql/fixture.sql`), whose vectors are generated, not embedded — so those numbers show that the measurement
works, **not** how MariaDB's vector index performs on text. Do not quote them as results.

## How to reproduce

```bash
mariadb -u root < sql/schema.sql
mariadb -u root < sql/fixture.sql                 # or the real ingest, once it lands
mariadb -u root -t < sql/evaluation/ground_truth.sql
mariadb -u root -t < sql/evaluation/recall_sweep.sql
mariadb -u root -t < sql/evaluation/tests.sql
```

In PowerShell, `<` does not redirect: `Get-Content sql/schema.sql | mariadb -u root`, and so on.

## Method

- **Ground truth** — `ground_truth.sql`. Exact top-50 per evaluation query by brute force: a window function
  over a cross join of `eval_queries` and `chunks`, which cannot use the vector index (confirmed by `EXPLAIN`:
  `type: ALL` on both tables). Ranked by distance, then chunk id, so it is deterministic. It also reports ties
  at the rank-10 boundary, which would otherwise quietly depress recall.
- **Recall** — `recall_sweep.sql`. recall@k = |indexed top-k ∩ exact top-k| / k, averaged over queries. It
  measures the HNSW index against exhaustive search with the embedding model held fixed — a question about
  MariaDB, not about the model.
- **Returned rows** — recorded separately from hits. `truncated_queries` counts queries that came back with
  fewer than k rows, which is the under-return behaviour of finding 7 in
  [`09_verified_findings.md`](main_dish_spec/09_verified_findings.md). A recall metric alone cannot see it.
- **Latency** — one untimed warm-up per query and configuration, then `@reps` timed repetitions (10 by
  default). Timed as `SELECT COUNT(*) INTO` a local variable, so no result set is sent to the client.
  `mhnsw_ef_search` is set explicitly for every configuration. Mean, min, max and `STDDEV_SAMP` are over every
  repetition of every query.
- **Brute force** — the same query with `IGNORE INDEX (embedding)`, recorded as `ef_search = 0` and shown as
  `brute force`. Its recall must be exactly 1.0; if it is not, the ground truth is wrong.
- **Cache** — `mhnsw_max_cache_size` is a global variable, so the sweep reports it and does not change it.
  Measuring with the cache raised means `SET GLOBAL mhnsw_max_cache_size = <bytes>` and re-running.

## Hardware and configuration

| | |
|---|---|
| Machine | Janhavi's laptop: AMD Ryzen 5 5625U, 7.3 GB RAM, Windows 11 Home |
| Server | MariaDB 12.3.3 (Win64), default configuration, port 3307 |
| `mhnsw_default_m` | 6 (default) |
| `mhnsw_max_cache_size` | 16,777,216 (default, 16 MB) |
| Corpus | **synthetic fixture** — 2,000 chunks, 16 categories, 384 dimensions, 16 queries |
| Repetitions | 10 per query per configuration |

## Recall and latency — fixture, harness check only

Measured 2026-10-23. **Not a result** — see the status note at the top.

| `ef_search` | recall@10 | mean ms | min ms | max ms | sd ms | truncated |
|---|---|---|---|---|---|---|
| 10 | 0.9563 | 0.131 | 0.100 | 0.287 | 0.034 | 0 |
| 20 (default) | 0.9563 | 0.131 | 0.102 | 0.251 | 0.027 | 0 |
| 50 | 0.9563 | 0.200 | 0.120 | 0.583 | 0.062 | 0 |
| 100 | 1.0000 | 0.243 | 0.151 | 0.704 | 0.079 | 0 |
| 200 | 1.0000 | 0.292 | 0.211 | 0.620 | 0.048 | 0 |
| 500 | 1.0000 | 0.482 | 0.394 | 0.801 | 0.077 | 0 |
| 1000 | 1.0000 | 1.049 | 0.749 | 22.180 | 1.691 | 0 |
| brute force | 1.0000 | 1.901 | 1.747 | 3.062 | 0.237 | 0 |

What this does establish, about the harness rather than about MariaDB:

- **Brute force scores exactly 1.0**, so the ground truth and the scoring agree.
- **Recall responds to the dial** — below 0.98 up to `ef_search = 50`, 1.0 from 100. The sweep is sensitive
  enough to find a crossover when there is one.
- **No query was truncated** at any setting, consistent with finding 7c (no under-return at 384 dimensions on
  this fixture).
- One sample at `ef_search = 1000` took 22 ms against a mean of 1 ms — a single outlier that is why `sd_ms` is
  reported and a single timing would have been misleading.

At 2,000 chunks brute force takes under 2 ms, so the index cannot earn its place on this fixture whatever the
curve says. Whether it does on ~12,000 real chunks is exactly what the real run must answer.

## Real corpus — to be filled when component A lands

| `ef_search` | recall@10 | mean ms | min ms | max ms | sd ms | truncated |
|---|---|---|---|---|---|---|
| 10 | | | | | | |
| 20 (default) | | | | | | |
| 50 | | | | | | |
| 100 | | | | | | |
| 200 | | | | | | |
| 500 | | | | | | |
| 1000 | | | | | | |
| brute force | 1.0000 | | | | | |

**Smallest `ef_search` with recall@10 ≥ 0.98:** _pending_. Per-category recall@10: _pending_ (each query is
assigned the category of its exact nearest chunk, since `eval_queries` has no category column).

## Tests

`sql/evaluation/tests.sql`, with T8 and T9 in `.github/workflows/ci.yml`. On the fixture, 2026-10-23:

| # | Result | Note |
|---|---|---|
| T1 dims match | PASS | |
| T2 no zero vectors | PASS | |
| T3 category agrees | PASS | |
| T4 index == brute force at ef 1000 | PASS | |
| T5 recall@10 ≥ 0.98 | SKIP | Opt-in: `SET @run_t5 = 1; SET @documented_ef = …` on the real corpus |
| T6 forced hybrid == exhaustive, per category | PASS | Asserts row identity, not just the count |
| T7 under-return still reproduces | PASS | 3-dimension harness; returned 4 and 2 of 10 on two runs |
| T8 semantic search uses the index | PASS | `EXPLAIN` key `embedding` |
| T9 hybrid queries keep `FORCE INDEX` | PASS | |
| T10 no category above crossover | PASS | Largest category 6.40%, threshold 7% |

**The tests were checked to fail.** With one chunk's category deliberately corrupted, T5 enabled at
`ef_search = 20`, and the T10 threshold lowered to 5%, T3, T5 and T10 reported FAIL and the client exited
with status 1 (`ERROR 1644 (45000)`). A test suite that has never been seen to fail has not been tested.

## Open questions for the team

1. **T10 will fail on the real corpus, by design.** `03_corpus.md` now plans nine categories at ~11.6% each,
   deliberately above the ~7% crossover and relying on `FORCE INDEX`. Either re-measure the crossover at 384
   dimensions (it is on the file-09 checklist) and set `@crossover_pct` to the measured value, or retire T10
   in favour of T9, which is the guard the design actually relies on.
2. **The evaluation questions need embedding.** `eval_queries.csv` holds 54 questions, six per category. They
   have to be embedded with the same model as the corpus **and with the query prefix** (`QUERY_PREFIX` in
   `python/config.py`) and loaded into `eval_queries`. That belongs in component A's ingest.
3. **T7 asserts the defect on the 3-dimension harness**, because finding 7c showed it does not reproduce at 384
   dimensions on the fixture. Whether it reproduces on real embeddings is still open; `under_return.sql`
   answers that once the real corpus is loaded, and T7 should then move to whichever setting reproduces it,
   if any.
4. **No full-corpus workflow yet.** The spec's weekly run (full corpus, whole sweep, T5) needs the ingest to
   exist; it is a small addition to `ci.yml` once it does.
