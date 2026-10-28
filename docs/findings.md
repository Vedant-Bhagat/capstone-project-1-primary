# Findings

Every measured result in the project, with the method that produced it. Spec:
[`main_dish_spec/07_evaluation.md`](main_dish_spec/07_evaluation.md).

**Status (2026-10-28): the harness is built and validated; the headline numbers do not exist yet.** They need
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
| Machine | Vedant's laptop: AMD Ryzen 7 6800H, 8C/16T, 15.2 GB RAM, Windows 11 Home |
| Server | MariaDB 12.3.3 (Win64), default configuration, port 3306 |
| `mhnsw_default_m` | 6 (default) |
| `mhnsw_max_cache_size` | 16,777,216 (default, 16 MB) |
| Corpus | **synthetic fixture** — 2,000 chunks, 9 categories, 384 dimensions, 9 queries |
| Repetitions | 10 per query per configuration |

The sweep was first run by Janhavi on her laptop (Ryzen 5 5625U, 7.3 GB, port 3307) against the earlier
16-category fixture. Those numbers are superseded: `sql/fixture.sql` was rebuilt on the real corpus's nine
categories on 2026-10-22, which changes both the per-category selectivity and the number of evaluation
queries. The table below is a re-run on the current fixture. Re-running it on her machine is a useful cheap
check that the curve is not hardware-specific.

## Recall and latency — fixture, harness check only

Measured 2026-10-28 on the nine-category fixture. **Not a result** — see the status note at the top.

| `ef_search` | recall@10 | mean ms | min ms | max ms | sd ms | truncated |
|---|---|---|---|---|---|---|
| 10 | 0.8667 | 0.125 | 0.096 | 0.286 | 0.032 | 0 |
| 20 (default) | 0.8667 | 0.127 | 0.100 | 0.308 | 0.037 | 0 |
| 50 | 0.9778 | 0.155 | 0.113 | 0.445 | 0.051 | 0 |
| 100 | 0.9778 | 0.202 | 0.143 | 0.389 | 0.045 | 0 |
| 200 | 0.9778 | 0.229 | 0.192 | 0.488 | 0.045 | 0 |
| 500 | 1.0000 | 0.515 | 0.409 | 1.094 | 0.109 | 0 |
| 1000 | 1.0000 | 0.963 | 0.774 | 1.381 | 0.163 | 0 |
| brute force | 1.0000 | 2.249 | 1.843 | 3.391 | 0.427 | 0 |

**Smallest `ef_search` with recall@10 ≥ 0.98 on this fixture: 500.** At k=1 the curve reaches 1.0 by 50.

Per-category recall@10 at the default `ef_search = 20`, each query assigned the category of its exact
nearest chunk:

| category | recall@10 |
|---|---|
| `space_telescopes` | **0.0000** |
| `architecture` | 0.9000 |
| `ethics` | 0.9000 |
| the other six | 1.0000 |

What this does establish, about the harness rather than about MariaDB:

- **Brute force scores exactly 1.0**, so the ground truth and the scoring agree.
- **Recall responds to the dial** — 0.87 at the default, 0.98 by 50, 1.0 by 500. The sweep is sensitive
  enough to find a crossover when there is one.
- **One query scores 0.0000 at the default `ef_search`.** `space_telescopes` gets ten rows back, none of them
  in its exact top ten. It is one of nine queries on synthetic vectors, so it is not a result about MariaDB —
  but it is the same failure shape Janhavi recorded in finding 7b, where a query returned the right *number*
  of rows and none of the right rows. A mean recall of 0.87 hides it; the per-category table is what shows it,
  which is why the table is here and not just the mean.
- **`truncated` is 0 everywhere, and cannot be anything else in this sweep.** The sweep's queries are
  unfiltered, and the under-return needs a filter — so this column being zero is not evidence about finding 7
  either way. T7 is where that is tested.

At 2,000 chunks brute force takes under 2 ms, so the index cannot earn its place on this fixture whatever the
curve says. Whether it does on ~13,000 real chunks is exactly what the real run must answer.

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

`sql/evaluation/tests.sql`, with T8 and T9 in `.github/workflows/ci.yml`. On the fixture, 2026-10-28:

| # | Result | Note |
|---|---|---|
| T1 dims match | PASS | |
| T2 no zero vectors | PASS | |
| T3 category agrees | PASS | |
| T4 index == brute force at ef 1000 | PASS | |
| T5 recall@10 ≥ 0.98 | SKIP | Opt-in: `SET @run_t5 = 1; SET @documented_ef = …` on the real corpus |
| T6 forced hybrid == exhaustive, per category | PASS | Asserts row identity, not just the count |
| T7 under-return still reproduces | PASS | Real schema, 384 dims; unhinted filter on `ethics` returned 0 of 10 with 216 matching |
| T8 semantic search uses the index | PASS | `EXPLAIN` key `embedding` |
| T9 hybrid queries keep `FORCE INDEX` | PASS | |
| T10 category selectivity | REPORT | Not a gate. 9 of 9 categories above 7%, so `FORCE INDEX` is load-bearing for all of them |

**The tests were checked to fail.** With one chunk's category deliberately corrupted, T5 enabled at
`ef_search = 20`, and the T10 threshold lowered to 5%, T3, T5 and T10 reported FAIL and the client exited
with status 1 (`ERROR 1644 (45000)`). A test suite that has never been seen to fail has not been tested.

## Open questions for the team

1. ~~**T10 will fail on the real corpus, by design.**~~ **Settled 2026-10-28:** T10 now reports and never
   fails. Retiring it outright would have lost the number, which is worth watching — it says how far above the
   crossover the corpus sits, and therefore how much the design leans on the hint. T9 and T6 are the gates
   the design actually rests on. Raising it before the test could redden a build was the right call.
2. **The evaluation questions need embedding.** `eval_queries.csv` holds 54 questions, six per category. They
   have to be embedded with the same model as the corpus **and with the query prefix** (`QUERY_PREFIX` in
   `python/config.py`) and loaded into `eval_queries`. That belongs in component A's ingest.
3. ~~**T7 asserts the defect on the 3-dimension harness.**~~ **Moved 2026-10-28.** Finding 7c, which recorded
   that the shortfall did not reproduce at 384 dimensions, has been withdrawn as a false negative — its test
   filters pointed the same way as the query vector. T7 now runs against the real schema and the scratch
   database is gone. **The retry loop was kept, and it earned it:** an attempt to assert a single index build,
   on the strength of four consecutive failing ones, was wrong — a fifth build came back full, and five builds
   give 10, 0, 2, 3, 0. Whether it reproduces on real *embeddings* is still the open question.
4. **No full-corpus workflow yet.** The spec's weekly run (full corpus, whole sweep, T5) needs the ingest to
   exist; it is a small addition to `ci.yml` once it does.
