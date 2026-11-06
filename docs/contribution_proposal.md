# Filtered vector search: defect report and contribution proposal

**To:** MariaDB Server engineering
**From:** Team Golden Record — Vedant Bhagat, Janhavi, Pranesh (Constructor University), capstone with the MariaDB Foundation
**Date:** 2026-11-06
**Repo:** https://github.com/Vedant-Bhagat/capstone-project-1-primary

We built a RAG retrieval system on MariaDB vector search and hit a wrong-results bug. We have reduced it to
a one-second SQL script, reproduced it in CI on three server versions, and found seven existing Jira tickets
around it. This document is the technical write-up plus three specific pieces of work we are offering to do.

**Nothing is posted to your tracker yet.** We wanted a maintainer to see it first.

---

## 1. Verify it in one command

Any server 11.7 or newer. No corpus, no Python, no download beyond the repo.

```
mariadb -u root < sql/retrieval/minimal_repro.sql
```

166 lines. Creates its own database, generates 2,048 sixteen-dimensional vectors deterministically in SQL
(no `RAND()`), prints `EXPLAIN`, prints a verdict table, drops everything. Runs in about one second.

Expected output: **6 of 8 categories return 0 rows**, where 256 rows match each.

---

## 2. The defect

```sql
SELECT id FROM t
 WHERE grp = 4                                  -- 256 of 2,048 rows match
 ORDER BY VEC_DISTANCE_COSINE(v, @q)
 LIMIT 10;                                      -- Empty set. SHOW WARNINGS is empty.
```

A `WHERE` on a non-vector column combined with `ORDER BY VEC_DISTANCE... LIMIT k` returns fewer than `k`
rows — frequently zero — when far more than `k` rows satisfy the predicate. No error, no warning, exit
status 0. The filter is applied to candidates the HNSW walk has already chosen; when none survive, nothing
widens the search.

**Affects:** 11.8, 12.3.3, 13.0.2, current release. Linux (`ubuntu-latest`, official images) and Windows.
Marked fixed in 11.7.1 by MDEV-34774; still present.

### Evidence

| Observation | Result |
|---|---|
| Unhinted, `DISTANCE=cosine`, `LIMIT 10` | 6 of 8 groups return 0 |
| `DISTANCE=euclidean` (the shipped default) | **7 of 8** groups return 0 |
| `LIMIT 1` | 7 of 8 — MDEV-34774's exact reported shape |
| `FORCE INDEX` on the filter column | 10 of 10, identical to exhaustive search, every group |
| `IGNORE INDEX (v)` | 10 of 10, every group |
| Drop the b-tree on the filter column | unchanged, 6 of 8 — `EXPLAIN` shows `possible_keys NULL, key v` |
| `mariadb:11.8` / `12.3` / `latest` in CI | reproduced on all three; `latest` is worst at 7 of 8 |

Three things worth knowing before anyone tries to predict this:

- **Not selectivity.** All eight groups are exactly 12.5% of the table and they behave differently.
- **Not a distance threshold either.** Groups at 0.0326 and 0.0332 from the query — 2% apart — one returns
  everything, the other nothing. Distance ranks risk better than selectivity does, but we cannot draw a line
  and do not claim one.
- **Small tables do not reproduce it.** At 512 rows the optimizer picks `ref` on the b-tree with filesort and
  is correct. At 768 and above it picks `key v` and the shortfall appears. This is very likely why
  MDEV-37709's reporter could not shrink a 250 MB dump and had the ticket closed Incomplete.

### `mhnsw_default_m = 6` is a separate finding

On 18,651 chunks of real Wikipedia text embedded with `BAAI/bge-small-en-v1.5` (384 dims), varying only `m`:

| `mhnsw_default_m` | recall@10 at default `ef_search=20` | mean query ms | smallest `ef` reaching 0.98 |
|---|---|---|---|
| **6 (shipped)** | **0.8333** | 0.112 | **never** — 0.937 at `ef` 1000 |
| 16 | 0.9944 | 0.215 | 10 |
| 32 | 0.9981 | 0.568 | 10 |

At the shipped default one correct result in six is missing, and no `ef_search` recovers it — the ceiling is
graph connectivity, not search width. Recall is measured against exhaustive search over the same vectors, so
this is a statement about the index, not about the embedding model.

We know MDEV-35071 and MDEV-36317 were closed Won't Fix on the grounds that the reporter used uniformly
random vectors. That is a fair objection and it does not apply here. This is real text.

---

## 3. Where this sits in your tracker

Seven tickets, one fix, and no test case anybody could run.

| Ticket | Status | Relation |
|---|---|---|
| MDEV-34774 | Fixed in 11.7.1 | Our exact symptom. We reproduce it on 11.8 through current. |
| MDEV-37709 | Closed, Incomplete | Same symptom, closed only because a 250 MB dump could not be shrunk. |
| MDEV-41342 | Confirmed, open | `LIMIT N` under-returns after DELETE/INSERT churn. Same shortfall, no filter. |
| MDEV-41227 | Confirmed, open | Rows unreachable through a cosine index after `ON DELETE CASCADE`. |
| MDEV-41321 | Confirmed, open | Stale RR view leaks into the shared MHNSW cache. Not our case, but the same cache. |
| MDEV-37559 | Stalled | Bloom filter keyed on vector *addresses*. Best available explanation of our instability. |
| MDEV-35071, MDEV-36317 | Won't Fix | Recall reports dismissed over random-vector data. |
| MDEV-41649 | Stalled | Better default for `mhnsw_max_cache_size`. Our real index is 27.3 MB against a 16 MB default. |

The missing piece was always a case small enough that somebody would actually run it. That is what we have.

---

## 4. What we are offering

Three items. Take any subset. Each is scoped so you can judge it in a minute.

### A. A regression test in your own suite

| | |
|---|---|
| **Deliverable** | A `mysql-test-run` `.test` + `.result` pair reproducing the under-return deterministically |
| **Our effort** | A few days |
| **What we need** | Point us at a comparable test so we match house style, and tell us where it belongs |
| **Done when** | It runs in your CI, fails on current `main`, and passes once the behaviour is fixed |
| **Risk** | The 768-row threshold is cost-model dependent, so the test may need an `optimizer_switch` or a hint to stay stable across versions. We will flag that rather than paper over it. |

Highest value, lowest cost. It converts a closed-Incomplete ticket into something your CI watches.

### B. A realistic-embedding recall benchmark

| | |
|---|---|
| **Deliverable** | 18,651 chunks of real text, pre-embedded at 384 dims, with exhaustive-search ground truth, plus the harness that computes recall@k and latency across `m` and `ef_search` |
| **Our effort** | A few weeks, mostly packaging and corpus licensing — the harness already exists |
| **What we need** | A decision on format and hosting: in-tree fixture, downloadable archive, or something you host |
| **Done when** | A maintainer runs one command and gets a recall/latency table for any build |
| **Risk** | Size. The embeddings are the bulk of it; we can ship a reduced subset if in-tree is preferred. |

This exists so that the next recall ticket does not get closed over the data. Random vectors were not
convincing — agreed. Here is the alternative.

### C. The experiment we cannot run ourselves

| | |
|---|---|
| **Deliverable** | Measurements from an instrumented build, on whatever you want counted |
| **Our effort** | You tell us what to measure |
| **What we need** | What to instrument, and which branch |
| **Done when** | You have numbers that confirm or kill MDEV-37559's visited-set theory |
| **Risk** | None to you. If it goes nowhere it cost us, not your team. |

On the real corpus the failure moves between identical runs, and raising `mhnsw_max_cache_size` from 16 MB to
128 MB changed *which* groups failed without fixing anything. MDEV-37559 explains that — a Bloom filter
hashing memory addresses — but it cannot be tested through SQL. We can build the server and count things.

---

## 5. What we need from you

Four answers, in order of how much they unblock:

1. **Is `WHERE` on a non-vector column plus `ORDER BY VEC_DISTANCE... LIMIT` a supported pattern, or is the
   index hint the intended answer today?** This changes how we document our own system and how we word the
   Jira comments. We would rather hear it than guess in public.
2. **Which of A, B and C do you want**, and should the bug go on MDEV-37709, MDEV-34774, or a new ticket?
3. **For A:** an example test to copy, and where it lives.
4. **For B:** what format you would actually accept.

## 6. Questions we would ask if there is time

- Can `EXPLAIN`/`ANALYZE` be made to report what the vector index did — candidates visited, candidates
  discarded by the filter, result truncated? This bug would have been self-diagnosing.
- Is index build meant to be deterministic? Five `DROP`/`ADD INDEX` cycles over identical rows gave us 10,
  0, 2, 3, 0 for the same query. We do not know whether to file that or document it.
- Is `mhnsw_default_distance = euclidean` deliberate? Text embeddings almost always want cosine, and
  euclidean fails worse in our test. Most models including ours emit unit-length vectors, where the two rank
  identically — does MHNSW exploit that?
- Is one vector index per table a permanent design decision? It stopped us doing coarse-to-fine retrieval.
- What is the sizing rule for `mhnsw_max_cache_size`? We were over the default without knowing.

---

## 7. Capacity, and honesty about limits

Three final-year students, supervised, through the end of this academic term. We are not offering to patch
the optimizer — we have not read that code and would only waste your review time. We are offering test
cases, data and measurement: the part a student team can do well, and the part missing from all seven
tickets above.

Two things we got wrong and corrected ourselves, so you know what our numbers are worth:

- We first said the failure tracked a distance threshold. It does not, cleanly. Retracted above.
- We first said raising `M` fixes it. It does not — it reshuffles which groups fail. Group 1 works at `M=6`
  and breaks at `M=16`.

We also cannot verify MDEV-37559's theory, and we say so rather than implying otherwise.

---

## Where everything is

| | |
|---|---|
| One-command repro | [`sql/retrieval/minimal_repro.sql`](../sql/retrieval/minimal_repro.sql) |
| Full defect write-up with prior art | [`docs/bug_report_draft.md`](bug_report_draft.md) |
| Measurements and method | [`docs/findings.md`](findings.md) |
| What we could not establish | [`docs/limitations.md`](limitations.md) |
| Jira text, ready to post | [`docs/jira_submissions.md`](jira_submissions.md) |
| Plain-English version of the bug | [`docs/bug_explainer.html`](bug_explainer.html) |
| System design | [`docs/main_dish_spec/`](main_dish_spec/) |

Reachable at vedant.work543@gmail.com, or on the Foundation's Zulip.
