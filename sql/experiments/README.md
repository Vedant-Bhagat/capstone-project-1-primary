# Filtered vector search: the measurement scripts

These four scripts are how the filtered-search claims in this repository were
measured. They were run against the real corpus — 1,289 articles, 18,651
chunks, `BAAI/bge-small-en-v1.5` at 384 dimensions — on a local MariaDB
**12.3.3** server. They are committed because a result nobody else can re-run
is not evidence.

Ground truth in every script is `IGNORE INDEX (embedding)`: a full scan with
exact cosine distances over all 18,651 chunks. The scripts never compare the
index against itself.

## What they measure

Each (query, filter-value) pair is run twice, once letting the optimizer use
the vector index and once forcing the exhaustive scan, and the two sets of ten
ids are compared. The interesting quantity is not how many rows came back but
**how many of the returned rows are the right rows**.

## Run them in order

Order matters — 02 reads `real_sweep` from 01, 03 reads both, and 04 needs the
`tenant` column that 03 adds.

| | Script | Measures | Runtime |
|---|---|---|---|
| 01 | `01_category_filter_sweep.sql` | 54 queries × 9 categories, the shipped `category` filter | ~25 min |
| 02 | `02_natural_vs_cross.sql` | splits 01 into filters that match the query's own topic vs filters that don't, plus an unfiltered control | ~6 min |
| 03 | `03_tenant_filter.sql` | 54 queries × 9 synthetic tenants — a filter uncorrelated with meaning | ~25 min |
| 04 | `04_ef_search_pushback.sql` | whether raising `mhnsw_ef_search` recovers it | ~35 min |
| 99 | `99_teardown.sql` | removes everything the above add | seconds |

Prerequisites: a loaded corpus (`sql/schema.sql`, then the ingest — see
*Quickstart* in the top-level README) with `eval_queries` populated, 54 rows
with embeddings. The runtimes are dominated by the exhaustive ground-truth
scans, not by the index.

```
mariadb -u root < sql/experiments/01_category_filter_sweep.sql
```

PowerShell needs `Get-Content <file> | mariadb -u root` instead of `<`.

## What they change in your database

**Script 03 alters a table that `sql/schema.sql` owns.** It adds a `tenant
TINYINT NOT NULL DEFAULT 0` column to `chunks`, sets it to `MOD(id, 9)`, and
indexes it as `ix_tenant`.

This is deliberately **not** in `sql/schema.sql`. A tenant id is not part of
the product; it exists only to get a filter that is uncorrelated with query
meaning at the same ~11% selectivity as a category, because that is what a
production filter (a permission group, a language, a date range) actually looks
like. Putting it in the schema would imply the RAG pipeline has tenants, which
it does not. `99_teardown.sql` removes it.

The scripts also create five result tables — `real_sweep`, `query_home`,
`control`, `tenant_sweep`, `pushback` — and four procedures. All are dropped by
the teardown. Every script is re-runnable: the tables are `DROP`ped and the
procedures `DROP PROCEDURE IF EXISTS`ed at the top.

Script 04 sets `@@mhnsw_ef_search` to 100, 500 and 2000 in turn and restores it
to 20 at the end. It is a session variable; nothing persists past the
connection.

## Results as measured, 2026-11-06, MariaDB 12.3.3

Re-derived from the result tables on 2026-11-12 before being written here.
`recall@10` is (genuine rows returned) / (10 × queries).

**The shipped `category` filter** — 486 pairs:

| | pairs | returned 0 rows | returned a full 10 | of those, wrong 10 | recall@10 |
|---|---|---|---|---|---|
| all pairs | 486 | 129 | 244 | 222 | 0.1344 |

Of the 222 full-but-wrong results: **0 exact ties**, all 222 genuinely
farther from the query, **15.9%** farther on average and up to **42.6%**.
A tie would have made the result harmless; there were none.

**Split by whether the filter matches the query's topic** (script 02):

| filter | pairs | returned 0 | full but wrong | recall@10 |
|---|---|---|---|---|
| the query's own topic | 54 | 0 | 32 | **0.8926** |
| some other topic | 432 | 129 | 190 | **0.0396** |
| no filter at all (control) | 54 | 0 | — | 0.8722, then 0.7704 — see below |

This is the honest decomposition and it cuts the claim in half. Filtering on
the query's own topic is **fine**: 0.8926, at or above the unfiltered baseline.

**The unfiltered baseline is itself unstable, and that is worth more than the
comparison it was meant to support.** Script 02 was re-run on 2026-11-12 to check
it still works. The natural/cross split came back identical to the digit, because
it reads the stored `real_sweep` table and recomputes `query_home` exhaustively.
The control does not: it re-measures an unfiltered top-10 *through the index*, and
it returned **0.7704** where the earlier run gave **0.8722**. Same server, same
corpus, same script, no rebuild in between. That is the MHNSW run-to-run variation
already recorded in this repository against MDEV-37559, showing up in the one
number we were using as a fixed reference point. Treat the unfiltered baseline as
a range of roughly 0.77–0.87, not a constant — and note that the
natural-filter figure of 0.8926 sits at the top of it.

The damage is in the 432 cross-topic pairs. Anyone dismissing the finding by
saying "nobody filters a bird question to the ethics category" is making a fair
point about script 01 taken alone, which is why script 03 exists.

**A filter uncorrelated with meaning** (script 03), 486 pairs at ~11%
selectivity each:

| | pairs | returned 0 | returned a full 10 | of those, wrong 10 | none right | recall@10 |
|---|---|---|---|---|---|---|
| tenant | 486 | **0** | 477 | **344** | 54 | 0.7469 |

This is the result that matters. Not one query returned short — the
under-return symptom in the existing Jira tickets never appears — and yet 344
of the 477 complete-looking results are the wrong ten rows, 54 of them with not
a single correct row. Again **0 exact ties**, 6.5% farther on average, up to
54.0%. The server gives no signal: no error, no warning, no short row count.

**Does tuning fix it** (script 04), 54 queries × 3 tenants = 162 pairs:

| `mhnsw_ef_search` | short or zero | full but wrong | recall@10 |
|---|---|---|---|
| 20 (default) | 3 | 112 | 0.7617 |
| 100 | 0 | 76 | 0.8840 |
| 500 | 0 | 39 | 0.9710 |
| 2000 | 0 | 10 | 0.9932 |

For a scattered filter, tuning does recover it — 0.76 to 0.99. So for this
filter shape the defect is a bad default and a missing signal rather than a
broken index. The cross-topic clustered case is the harder one: its recall@10
is 0.0396 at the default, and script 01 is where that is measured.

## Limits of these measurements

- **One server, one corpus, one machine.** 12.3.3 on a Windows laptop. No
  other version, no other embedding model, no second corpus.
- **`M` was never varied.** Every number above is at the shipped
  `mhnsw_default_m = 6`. An `M=16` rebuild is the obvious next run and has not
  been done, so nothing here says whether a larger `M` recovers the clustered
  case.
- **`tenant = MOD(id, 9)` is synthetic.** It is uncorrelated with meaning by
  construction, which is the point, but it is not a filter from a real
  application.
- **The ef_search sweep covers 3 tenants, not 9**, to keep the four-setting run
  under an hour. The 162 pairs are the same across all four settings, so the
  rows are comparable with each other but not with the 486-pair tables above.
- **The unfiltered control is not reproducible run to run** (0.8722, then 0.7704),
  because it queries through the vector index. Only the exhaustive ground truth is
  stable. Any single run of it is one sample, not a baseline.
- `query_home` in script 02 defines a query's "own topic" as the category of
  its single nearest chunk corpus-wide. A query whose subject genuinely spans
  two categories gets assigned one of them.

The synthetic counterpart to these scripts is
[`../retrieval/minimal_repro.sql`](../retrieval/minimal_repro.sql), which needs
no corpus and runs in about a second. It reproduces the under-return symptom,
not the wrong-rows one.
