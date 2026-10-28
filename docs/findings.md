# Findings

Every measured result in the project, with the method that produced it. Spec:
[`main_dish_spec/07_evaluation.md`](main_dish_spec/07_evaluation.md).

**Status (2026-10-28): complete.** The corpus is ingested — 1,289 Wikipedia articles, 18,651 chunks, real
`bge-small-en-v1.5` embeddings — and every number below is measured.

**The one-sentence result: MariaDB's default `mhnsw_default_m = 6` cannot reach 98% recall@10 on this corpus
at any `ef_search`, and `m = 16` reaches 99.4% at the default `ef_search` for 0.1 ms more per query.**

Two sections follow. The **fixture** numbers come from `sql/fixture.sql`, whose vectors are generated rather
than embedded — they show the measurement works, **not** how the index performs on text, and must not be
quoted as results. The **real corpus** numbers are the result.

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

## Fixture — harness check only, not a result

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

## Real corpus — measured 2026-10-28

1,289 Wikipedia articles, **18,651 chunks**, 54 evaluation questions, `BAAI/bge-small-en-v1.5` at 384
dimensions. Six articles produced no chunk and were skipped. Hardware and server as in the table above;
`mhnsw_max_cache_size` left at its 16 MB default, which is below the 27.3 MB index.

### The headline: MariaDB's default `mhnsw_default_m = 6` cannot reach 98% recall

This is the most useful thing we measured, and it is a one-line fix for anyone using the feature.

| `mhnsw_default_m` | index build | **recall@10 at the default `ef_search = 20`** | mean ms | smallest `ef` reaching 0.98 |
|---|---|---|---|---|
| **6 — MariaDB's default** | 6.8 s | **0.8333** | 0.112 | **never** (0.937 at `ef` 1000) |
| **16 — our recommendation** | 25.4 s | **0.9944** | 0.215 | **10** |
| 32 | 161.3 s | 0.9981 | 0.568 | 10 |

At `m = 6` a filtered-free semantic search loses **one correct result in six** at default settings, and no
`ef_search` recovers it — the ceiling is the graph, not the search width. Raising `m` to 16 costs **0.1 ms
per query and 19 seconds of one-off index build**, and takes recall from 0.83 to 0.99.

`m = 32` buys another 0.4 points of recall for 6× the build time and 2.6× the latency. Not worth it here.

### Recall and latency at `m = 16`, k = 10

| `ef_search` | recall@10 | mean ms | min ms | max ms | sd ms | truncated |
|---|---|---|---|---|---|---|
| 10 | 0.9889 | 0.179 | 0.076 | 4.141 | 0.303 | 0 |
| **20 (default)** | **0.9944** | **0.215** | 0.095 | 5.586 | 0.409 | 0 |
| 50 | 0.9963 | 0.300 | 0.132 | 7.773 | 0.570 | 0 |
| 100 | 0.9981 | 0.385 | 0.164 | 8.066 | 0.732 | 0 |
| 200 | 1.0000 | 0.617 | 0.237 | 12.851 | 1.382 | 0 |
| 500 | 1.0000 | 2.360 | 0.326 | 27.159 | 5.397 | 0 |
| 1000 | 1.0000 | 8.916 | 0.588 | 71.239 | 12.821 | 0 |
| **brute force** | 1.0000 | **14.450** | 12.790 | 34.636 | 1.685 | 0 |

**Smallest `ef_search` with recall@10 ≥ 0.98: 10**, at 0.179 ms — **81× faster than exhaustive search** for
1.1% of the correct results given up.

**The index earns its place on this corpus**, which it did not on the 2,000-chunk fixture where brute force
took 2.2 ms. At 18,651 chunks exhaustive search costs 14.5 ms and the index costs 0.2 ms. That is the
honest form of the answer: *at this scale, with this many dimensions*.

Note `ef_search = 1000` is **slower than brute force would suggest it should be** — 8.9 ms against 14.5 ms —
so the useful range of the dial is narrow. Past about 200 the graph walk is visiting enough of the index
that it stops being a shortcut.

### Per-category recall@10 at `m = 16`, `ef_search = 20`

| category | recall@10 |
|---|---|
| `architecture`, `birds`, `composers`, `diseases`, `prog_lang`, `space_telescopes` | 1.0000 |
| `ethics`, `physics`, `political_philosophy` | 0.9833 |

For comparison, the same table at MariaDB's default `m = 6` ranges from **0.5167** (`prog_lang`) to 1.0000
(`birds`) — a spread that a single mean of 0.83 completely hides.

### Filtered search on real embeddings — the defect reproduces

The open question since 2026-10-21 was whether the under-return affects real embeddings. **It does.** Query:
*"Which birds were first given scientific names by Linnaeus in 1758?"*, `LIMIT 10`, `ef_search = 20`, at
MariaDB's default `m = 6`:

| category | selectivity | distance to query | unhinted | `ef` 2000 | `FORCE INDEX` |
|---|---|---|---|---|---|
| `birds` | 16.72% | 0.2419 | 10 | 10 | 10 ✓ |
| `diseases` | 8.66% | 0.3965 | 10 | 10 | 10 ✓ |
| `prog_lang` | 9.19% | 0.4271 | 10 | 10 | 10 ✓ |
| `political_philosophy` | 12.76% | 0.4292 | 10 | 10 | 10 ✓ |
| `physics` | 7.63% | 0.4351 | 10 | 10 | 10 ✓ |
| `architecture` | 11.27% | 0.4366 | **4** | 10 | 10 ✓ |
| `ethics` | 9.99% | 0.4563 | **2** | 10 | 10 ✓ |
| `composers` | 18.78% | 0.4583 | **0** | 10 | 10 ✓ |
| `space_telescopes` | **5.00%** | 0.4624 | **0** | 10 | 10 ✓ |

Three things this settles:

1. **Distance from the query predicts the shortfall; selectivity does not.** Sorted by distance the table is
   monotonic. `space_telescopes` at 5% selectivity — *below* the ~7% crossover of finding 7b — returns
   nothing, while `birds` at 16.7% returns everything. The crossover framing was measuring a correlate.
2. **On real embeddings `ef_search` does recover it** (every category is whole by `ef` 200). On the
   synthetic near-orthogonal fixture it never did, at any value. The fixture was the harsher geometry, and
   our earlier "tuning cannot fix this" was true only there. Corrected.
3. **`FORCE INDEX` returned the exact answer in all nine cases**, identical to exhaustive search.

At `m = 16` the shortfall mostly disappears — only `prog_lang` (2 of 10) and `space_telescopes` (8 of 10)
remain short — which is consistent with it being a reachability problem that MariaDB's low default `m`
makes much worse. It does not disappear entirely, so `FORCE INDEX` stays.

**Stability.** Repeating the identical query five times on one index build, most categories are stable
(`composers` 0,0,0,0,0; `architecture` 4,4,4,4,4) but two of nine flipped on the fifth run. Raising
`mhnsw_max_cache_size` from 16 MB to 128 MB — above the 27.3 MB index — changed *which* categories failed
without removing the instability. **We cannot currently explain that**, and it is recorded as an open
question rather than attributed to a cause we have not demonstrated.

## Answer generation — end to end, 2026-10-29

Requirement B4: the pipeline must end in a generated answer. It does.
`python/answer.py` retrieves in one SQL statement, formats the passages with article and section labels,
applies the prompt from [`08_rag_pipeline.md`](main_dish_spec/08_rag_pipeline.md) unchanged, and checks that
every `[n]` citation resolves to a passage that was actually shown.

Generated with Gemini (`gemini-flash-latest`) at temperature 0. **The whole step is optional**: without a key
`--no-llm` prints the passages, and every measured number above is reproducible with no account.

| # | question | result | citations |
|---|---|---|---|
| 1 | *How tall and how heavy is the common ostrich?* | **Answered**, correct, grounded | all resolve |
| 2 | *What is the difference between a compiled and an interpreted programming language?* | **Answered**, correct, grounded | all resolve |
| 3 | *What makes the ostrich different from most other birds?* | **Refused** | — |
| 4 | *What was the closing price of Tesla stock last Friday?* | **Refused** | — |

Answer 2, in full, from `prog_lang` passages — so retrieval and grounding are not bird-specific:

> In compilation, programs are translated ahead-of-time into machine code, whereas in interpretation,
> programs are directly executed [2]. Additionally, a compiler translates source code into an executable
> machine code, which runs more quickly than with other implementation methods [1].

**Citation faithfulness: no out-of-range citation in any answer.** This is the check worth automating — it
is objective, needs no judgement, and catches a model citing a passage it was never shown.

**Case 4 is the one that matters most.** A question the corpus cannot possibly answer retrieved a spacecraft
cancellation notice at cosine 0.419 — retrieval always returns *something* — and the model refused with the
exact string rather than confabulating from it. That is the failure mode RAG exists to prevent, and it is the
cheapest thing in this project to measure.

**Case 3 is an honest negative.** The question is answerable from the retrieved passages: one of them states
the ostrich is the tallest and heaviest living bird. The model refused anyway. So the prompt's combination of
*"use only information in the passages"* and an explicit refusal string buys safety at the cost of some
abstention on questions it could have answered. With four questions we cannot put a rate on that, and we do
not. It is a prompt-design trade-off, visible because the refusal string is exact and countable.

### Answer grading, level 0: retrieval hit@k against known source chunks

`eval_qa_pairs.csv` now exists — 30 answerable questions, each written from one specific chunk whose id is
recorded, plus 10 questions the corpus cannot answer. `python -m python.grade_answers --no-llm` grades the
part that **needs no API key**, which file 08 calls the retrieval-quality metric that actually matters: did
the chunk the answer was written from come back in the top k at all?

| metric | result |
|---|---|
| hit@10 | **30 / 30 = 1.000** |
| hit@1 | 23 / 30 = 0.767 |

**Read that 1.000 with the caveat it deserves, because it is partly an artifact of how the pairs were
built.** Each question was written *from* its source chunk, so its wording is closer to that chunk than a
real user's question would be. The number is therefore an **upper bound** on retrieval difficulty, not a
realistic estimate: it says the system reliably finds a passage when asked something that passage obviously
answers. It is still worth having, for two reasons. A failure here would have been damning — it would mean
an apparently correct answer had come from the model's memory rather than the corpus — and hit@1 at 0.767
shows the metric is not saturated, so the ranking still has something to say. A harder set would need
questions written by someone who had not seen the chunk.

The 10 unanswerable questions exist for the abstention test, which file 08 rates as the single most valuable
check and which is cheap: 10 generation calls.

**Still not done: levels 1 and 3, both of which need an API key.** `grade_answers.py` implements them
(`--abstention`, `--answers`, `--judge`) and they have not been run, because the key is deliberately never
stored in this repository and the environment it was set in is gone. Concretely missing: the abstention rate
over the 10 unanswerable questions, and answer correctness.

**Scope decided 2026-10-28: 10 graded prompts, not 30.** File 08 proposed 30 QA pairs for answer
correctness; the team's judgement is that 10 is sufficient for what this half of the project is worth, and
the free tier's 503s make a larger run slow rather than informative. So the intended run is:

```
python -m python.grade_answers --abstention            # 10 calls, all 10 unanswerable questions
python -m python.grade_answers --answers --limit 10    # 10 calls, the first 10 answerable pairs
```

All 30 pairs stay committed, because level 0 is free and uses all of them, and because a later run can widen
the sample without rebuilding the set. **What 10 graded answers cannot support is a per-category breakdown**
— that would be one or two questions per category — so the result should be reported as one aggregate figure
with its sample size attached, and not sliced. Four hand-checked questions
(above) demonstrate the pipeline; they do not measure it.

One honesty constraint is wired into the tool rather than left to the writer. `--judge` is a model grading a
model, which file 08 says must be validated against human scores before publication. It is not validated, so
the script labels every judge number unvalidated in its own output and writes an empty `human` column for a
hand-scored sample. **No judge figure should reach the README until that agreement rate exists.**

## Tests

`sql/evaluation/tests.sql`, with T8 and T9 in `.github/workflows/ci.yml`. On the **real corpus**, 2026-10-28, exit status 0:

| # | Result | Note |
|---|---|---|
| T1 dims match | PASS | |
| T2 no zero vectors | PASS | |
| T3 category agrees | PASS | |
| T4 index == brute force at ef 1000 | PASS | |
| T5 recall@10 ≥ 0.98 | **PASS** | **0.9944 at `ef_search` 20** on the real corpus, `m = 16`. Fails at MariaDB's default `m = 6` |
| T6 forced hybrid == exhaustive, per category | PASS | Asserts row identity, not just the count |
| T7 under-return still reproduces | PASS | Real corpus; unhinted filter on `space_telescopes` returned 10, 10, **8** across three index builds. The retry loop earned itself again — one build would have reported no defect |
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
2. ~~**The evaluation questions need embedding.**~~ **Done 2026-10-28** — `python/ingest.py` embeds all 54
   with `encode_queries()`, which applies the prefix on the query side only, and loads them into
   `eval_queries`.
3. ~~**T7 asserts the defect on the 3-dimension harness.**~~ **Moved 2026-10-28.** Finding 7c, which recorded
   that the shortfall did not reproduce at 384 dimensions, has been withdrawn as a false negative — its test
   filters pointed the same way as the query vector. T7 now runs against the real schema and the scratch
   database is gone. **The retry loop was kept, and it earned it:** an attempt to assert a single index build,
   on the strength of four consecutive failing ones, was wrong — a fifth build came back full, and five builds
   give 10, 0, 2, 3, 0. Whether it reproduces on real *embeddings* is still the open question.
4. **Why two of nine categories flip between identical runs** (see the stability note above) is unexplained.
   The cache was the obvious suspect and is not the cause. This is the most interesting loose end left.
5. **No full-corpus workflow yet.** The spec's weekly run (full corpus, whole sweep, T5) needs the ingest to
   exist; it is a small addition to `ci.yml` once it does.
