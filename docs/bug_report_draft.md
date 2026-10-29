# Bug report — approved for filing 2026-10-29

**Status: the team decision is made.** Vedant, Janhavi and Pranesh agreed in person on 2026-10-29 to post,
which closes [D6](main_dish_spec/12_open_decisions.md). This file stays as the reasoning and the evidence;
the text that actually goes to Jira, in posting order and with a checkbox per post, is
[`jira_submissions.md`](jira_submissions.md).

Both technical gates were closed before that decision:

- [x] **Search MariaDB's Jira for an existing report.** Done 2026-10-28. It changed what this report is —
      see *Prior art* below, which is now the most important section in this file.
- [x] **Reduce to the smallest reproduction.** Done: [`../sql/retrieval/minimal_repro.sql`](../sql/retrieval/minimal_repro.sql)
      is 2,048 rows of 16-dimensional vectors generated in pure SQL. No corpus, no embedding model, no
      Python, about one second to run.

What remains is a judgement call for the three of us, not more measurement.

---

## Prior art — read this before filing

The Jira search found that **this symptom has been reported three times and is not fixed.** That makes our
position considerably stronger than "we found a bug", and it tells us exactly what to supply.

| Ticket | Status | Why it matters to us |
|---|---|---|
| [MDEV-34774](https://jira.mariadb.org/browse/MDEV-34774) | **Closed, Fixed in 11.7.1** | Our exact symptom: `WHERE` on a non-vector column plus `ORDER BY VEC_DISTANCE ... LIMIT 1` returned an empty set. **We reproduce it on 11.8, 12.3 and the current release.** So either that fix is incomplete or this is a regression. |
| [MDEV-37709](https://jira.mariadb.org/browse/MDEV-37709) | **Closed, Incomplete** | Same symptom with extra column filters. Closed *only* because the reporter could not shrink a 250 MB dump to a test case. This is the gap our `minimal_repro.sql` fills. |
| [MDEV-41342](https://jira.mariadb.org/browse/MDEV-41342) | Confirmed, open | `LIMIT N` larger than the table returns fewer rows than the table holds, after repeated DELETE/INSERT cycles. Same shortfall, different trigger (churn, no filter). |
| [MDEV-41227](https://jira.mariadb.org/browse/MDEV-41227) | Confirmed, open | Rows unreachable through a cosine index after `ON DELETE CASCADE`. Same family: reachability. |
| [MDEV-41321](https://jira.mariadb.org/browse/MDEV-41321) | Confirmed, open | A stale REPEATABLE READ view leaks into the shared MHNSW cache; all sessions then miss committed rows until `FLUSH TABLES`. Not our case — we never write — but it is the clearest evidence that this cache is a source of wrong results. |
| [MDEV-37559](https://jira.mariadb.org/browse/MDEV-37559) | **Stalled** | **The best lead we have on our own unexplained instability.** See below. |
| [MDEV-35071](https://jira.mariadb.org/browse/MDEV-35071), [MDEV-36317](https://jira.mariadb.org/browse/MDEV-36317) | **Closed, Won't Fix** | Both are poor-recall reports, both dismissed. This shapes part 2 of our report and is the single biggest risk to it. |
| [MDEV-39822](https://jira.mariadb.org/browse/MDEV-39822) | Open | Wrong results for M ≥ 128: the per-layer neighbour count overflows one byte. Not us — we deliberately swept M only to 64 — but worth knowing before anyone recommends a large M. |
| [MDEV-41649](https://jira.mariadb.org/browse/MDEV-41649) | Stalled | "Better default for `mhnsw_max_cache_size`". Adjacent to our observation that the real index is 27.3 MB against a 16 MB default. |

### Our "we do not know the cause" now has a named candidate

`docs/limitations.md` recorded that two of nine categories flipped between identical runs and that we could
not explain it. MDEV-37559 offers an explanation from a MariaDB developer. Sergei Golubchik, 2026-01-29:

> Currently vector_mhnsw.cc relies on a Bloom filter to detect visited graph nodes. [...] In the current
> implementation it operated directly on vector addresses in memory. It hashes addresses and looks in a
> bitmap. Bloom filter is a probabilistic structure, sometimes it can produce false positives. [...]
> depending on where a next malloc() places the vector data, hash values may happen to be particularly
> unlucky

A visited-set false positive makes the search skip a node it never actually visited. Because the hash is over
**memory addresses**, the outcome depends on allocation placement, which is exactly the kind of thing that
differs between runs of an identical query. It also fits the observation that puzzled us most: raising
`mhnsw_max_cache_size` from 16 MB to 128 MB changed *which* categories failed without fixing the problem — a
different cache size means different allocations, so different unlucky hashes.

**This is his hypothesis, not a confirmed diagnosis** — his own comment opens "Presuming this theory is
correct" — and the ticket is Stalled, not fixed. We should cite it as a likely mechanism and say plainly
that we did not verify it, because we cannot: it needs a debug build, not a SQL query.

### The documentation complicates our "silent and undocumented" claim

MariaDB's vector overview says, of a `WHERE` on an `ORDER BY ... LIMIT` vector query:

> The `LIMIT` is a hard cap on how many rows the index returns *before* the threshold is applied [...]
> otherwise qualifying rows beyond the limit are silently dropped.

That passage is about a **distance threshold** (`WHERE VEC_DISTANCE(...) < x`), not a filter on an ordinary
column, so it does not describe our case. But it is close enough that a triager could reasonably close our
report as documented behaviour, and we should pre-empt that in the report rather than be surprised by it.
The honest framing: the mechanism is documented for threshold filters; the same silent truncation for an
ordinary indexed column filter is not documented anywhere we could find, and that is the report.

---

## 1. A filtered vector query silently returns fewer rows than `LIMIT`, sometimes zero

**Affects:** 11.8, 12.3.3, 13.0.2 and the current release. Reproduced on Windows and on Linux
(`ubuntu-latest` in CI), so it is not platform-specific. Marked fixed in 11.7.1 by MDEV-34774; still present.

### Summary

A `SELECT ... WHERE <predicate> ORDER BY VEC_DISTANCE_COSINE(col, ?) LIMIT k` against a table with a
`VECTOR INDEX` can return **fewer than `k` rows — including zero — when far more than `k` rows satisfy the
predicate**. No error, no warning, and `SHOW WARNINGS` is empty. The same query with `IGNORE INDEX` on the
vector column, or `FORCE INDEX` on the predicate's index, returns all `k`.

The optimizer post-filters through the HNSW graph: it walks the neighbourhood of the query vector and
discards candidates that fail the predicate, rather than widening the search when the surviving set is
short. When the predicate selects rows *far* from the query, every candidate is discarded and the result is
empty.

### Minimal reproduction

[`../sql/retrieval/minimal_repro.sql`](../sql/retrieval/minimal_repro.sql) — 2,048 rows, 16 dimensions, 8
categories of 256, `M=6`, vectors generated deterministically in SQL with no `RAND()`. On 12.3.3:

| cat | matching | distance to query | unhinted | `FORCE INDEX (ix_cat)` | `IGNORE INDEX (v)` |
|---|---|---|---|---|---|
| 0 | 256 (12.5%) | 0.0005 | 10 | 10 | 10 |
| 7 | 256 (12.5%) | 0.0326 | **0** | 10 | 10 |
| 1 | 256 (12.5%) | 0.0332 | 10 | 10 | 10 |
| 6 | 256 (12.5%) | 0.1274 | **0** | 10 | 10 |
| 2 | 256 (12.5%) | 0.1337 | **0** | 10 | 10 |
| 5 | 256 (12.5%) | 0.2468 | **0** | 10 | 10 |
| 3 | 256 (12.5%) | 0.2644 | **0** | 10 | 10 |
| 4 | 256 (12.5%) | 0.3161 | **0** | 10 | 10 |

**Six of eight categories return nothing at all** while 256 rows match each of them.

Two details that matter for anyone trying to predict this:

- **It is not selectivity.** Every category here is exactly 12.5% of the table and they do not behave alike.
- **It is not a clean distance threshold either.** Categories 7 and 1 are 0.0326 and 0.0332 from the query —
  a 2% difference — and one returns nothing while the other returns everything. Distance *ranks* risk much
  better than selectivity does, but we cannot draw a line, and we should not claim to. This is a correction
  to our own earlier framing, which the real corpus (where the table happened to be monotonic in distance)
  had let us state too strongly.

### Reproduced in CI on three server versions, on hardware that is not ours

`minimal_repro.sql` runs in the CI matrix as a reporting step, so every push produces this on
`ubuntu-latest` with the official `mariadb` images. Run 2026-10-29:

| server | verdict |
|---|---|
| `mariadb:11.8` | REPRODUCED — 6 of 8 categories short, worst returned 0 |
| `mariadb:12.3` | REPRODUCED — 6 of 8 categories short, worst returned 0 |
| `mariadb:latest` | REPRODUCED — **7 of 8** categories short, worst returned 0 |

`FORCE INDEX` and `IGNORE INDEX` returned all 10 for every category on all three. This matters for the
report in two ways: the version claim is now checkable by anyone from a public log rather than resting on
our laptop, and **the newest release is the worst of the three**, which is the opposite of what a reader
would assume about a defect marked fixed in 11.7.1.

### The table must be large enough for the vector plan to be chosen

Worth stating because it is the first thing that will make a reproduction attempt fail:

| rows | plan chosen (`EXPLAIN`) | result |
|---|---|---|
| 512 | `ref` on `ix_cat`, with filesort | correct, 10 for every category |
| 768 and above | `index`, key `v` | the shortfall appears |

Below the cost crossover the optimizer pre-filters and is exact. There is no bug to see on a small table —
which is very likely why MDEV-37709's reporter could not shrink their case and had the ticket closed.

### Expected

Either `k` rows when at least `k` satisfy the predicate, or a warning that the result was truncated. Silent
truncation gives the caller no way to detect that anything happened.

### Workarounds, both of which work

- `FORCE INDEX (<predicate index>)` — returned results **identical to exhaustive search** in all nine real
  categories and all eight synthetic ones we tested. Requires the filter column to be on the same table as
  the vector index, since a hint cannot name an index on another table.
- Raise `mhnsw_ef_search` — **but only sometimes, and you cannot tell in advance.** On the real corpus every
  category was whole by 200. On this minimal case **no value up to 2000, the size of the whole table,
  recovers a single row.** An operator cannot rely on it.
- Raise `M`. Also unreliable: see below.

### Raising `M` helps, is not monotonic, and never fully fixes it

Same data, same query, varying only `M` in the index definition. Rows returned per category, id order:

| `M` | per-category result |
|---|---|
| 6 | 10, 10, **0**, **0**, **0**, **0**, **0**, **0** |
| 16 | 10, **0**, **0**, 10, 10, 10, 10, 10 |
| 32 | 10, 10, **0**, 10, 10, 10, 10, 10 |
| 64 | 10, 10, **0**, 10, 10, 10, 10, 10 |

Category 1 **breaks** when `M` goes from 6 to 16, having worked at 6. Category 2 is short at every `M` from
6 to 64. So "raise `M`" is not a fix, it is a reshuffle that happens to help on average.

### What we have not established

- **Why it is not perfectly repeatable on real data.** On the real corpus, five identical runs were stable
  for seven of nine categories and flipped for two. MDEV-37559's Bloom-filter-over-addresses theory is the
  best available explanation and we did not verify it. **Note that the minimal case above is perfectly
  repeatable** — identical across five runs and five index rebuilds — so it reproduces the under-return but
  not the instability, and is the wrong test case for that half of the problem.
- **Genuinely random vectors.** Deliberately not used: see MDEV-35071's rationale for closing.

---

## 2. `mhnsw_default_m = 6` cannot reach 98% recall on a normal text corpus

Not a defect — a default we believe is set too low, reported separately for that reason.

**Before filing this half, read [MDEV-35071](https://jira.mariadb.org/browse/MDEV-35071) and
[MDEV-36317](https://jira.mariadb.org/browse/MDEV-36317).** Both are poor-recall reports and both were
closed **Won't Fix**, MDEV-35071 with the reasoning that "many algorithms perform poorly on uniformly
distributed random vectors" and a suggestion to test on realistic clusters instead. That reply does not
apply to us and the report must make that unmissable in its first line: our measurement is on **1,289 real
Wikipedia articles embedded with `BAAI/bge-small-en-v1.5`**, not on random vectors. If this is filed as "low
recall" without that framing, it will be closed in one comment.

On 18,651 real chunks, varying only `mhnsw_default_m`:

| `mhnsw_default_m` | recall@10 at default `ef_search = 20` | mean query ms | smallest `ef` reaching 0.98 |
|---|---|---|---|
| **6 (shipped default)** | **0.8333** | 0.112 | **never** — 0.937 at `ef` 1000 |
| 16 | **0.9944** | 0.215 | 10 |
| 32 | 0.9981 | 0.568 | 10 |

At the shipped default, **one correct result in six is missing**, and no `ef_search` recovers it: the ceiling
is the graph's connectivity, not the width of the search. `m = 16` costs 0.1 ms per query and 19 seconds of
one-off index build on this corpus, and is what the HNSW literature and other implementations typically
default to (16–32).

Recall is measured against exhaustive search over the same data with the same embeddings — a question about
the index, not about the embedding model. Method and the full sweep are in [`findings.md`](findings.md).

### Suggestion

Consider raising the default, or documenting that 6 is tuned for index build time rather than recall and
that text-retrieval workloads should raise it. A user who takes the defaults currently gets 83% recall with
nothing to indicate it.

---

## If we file: what to send where

1. **A comment on [MDEV-37709](https://jira.mariadb.org/browse/MDEV-37709)** with `minimal_repro.sql`
   attached. That ticket was closed for want of exactly this, and reopening an existing report costs a
   triager less than reading a new one. This is the highest-value single action available to us.
2. **A comment on [MDEV-34774](https://jira.mariadb.org/browse/MDEV-34774)** noting that the symptom is back
   or never fully went, on 11.8 through the current release, with the same script.
3. **Part 2 as its own new issue**, framed as "default too low for real text embeddings", leading with the
   corpus and explicitly distinguishing itself from MDEV-35071 and MDEV-36317.

Ordering matters: 1 and 2 are contributions to open work, 3 is a fresh opinion about a default. Filing 3
first, into a project that has twice declined recall reports, would spend our credibility on the weakest of
the three.
