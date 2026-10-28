# Bug report — DRAFT, not filed

**Status: not submitted.** Decision D6 in [`main_dish_spec/12_open_decisions.md`](main_dish_spec/12_open_decisions.md)
gates this on two things that are still open:

- [ ] **Search MariaDB's Jira for an existing report.** Robert asked for this explicitly. Not done.
- [ ] **Reduce to the smallest reproduction.** The script below needs a corpus; it should need a table.

Everything else on the file-09 checklist is now ticked. This draft exists so the report is ready when those
two are, not so that it can be sent today.

Two separate things are described here. The first is a defect. The second is a default we think is wrong,
which is a different kind of report and should probably be a separate issue.

---

## 1. A filtered vector query silently returns fewer rows than `LIMIT`, sometimes zero

**Affects:** 11.8, 12.3.3, 13.0.2, and the current release. Reproduced on Windows and on Linux
(`ubuntu-latest` in CI), so it is not platform-specific.

### Summary

A `SELECT ... WHERE <predicate> ORDER BY VEC_DISTANCE_COSINE(col, ?) LIMIT k` against a table with a
`VECTOR INDEX` can return **fewer than `k` rows — including zero — when far more than `k` rows satisfy the
predicate**. No error, no warning, and `SHOW WARNINGS` is empty. The same query with `IGNORE INDEX` on the
vector column, or with `FORCE INDEX` on the predicate's index, returns all `k`.

The optimizer post-filters through the HNSW graph: it walks the neighbourhood of the query vector and
discards candidates failing the predicate, rather than widening the search when the surviving set is short.
When the predicate selects rows *far* from the query, every candidate is discarded and the result is empty.

### Why we think it matters

This is the natural way to write "find me passages that mean roughly this, but only from physics articles" —
the query that makes a native vector type worth having over a separate vector service. It is silent, and the
result is not merely approximate but can be empty.

### Reproduction

Real-world shape, on 18,651 Wikipedia paragraph embeddings (`BAAI/bge-small-en-v1.5`, 384 dimensions),
default server configuration, `mhnsw_ef_search = 20`, `LIMIT 10`:

| `category` filter | rows matching | distance to query | rows returned |
|---|---|---|---|
| `birds` | 3,119 (16.7%) | 0.2419 | 10 |
| `physics` | 1,423 (7.6%) | 0.4351 | 10 |
| `architecture` | 2,102 (11.3%) | 0.4366 | **4** |
| `ethics` | 1,863 (10.0%) | 0.4563 | **2** |
| `composers` | 3,503 (18.8%) | 0.4583 | **0** |
| `space_telescopes` | 932 (5.0%) | 0.4624 | **0** |

Query: *"Which birds were first given scientific names by Linnaeus in 1758?"*

**Selectivity does not predict it — distance from the query does.** The 5.0% category returns nothing while
the 16.7% category returns everything, and sorting by distance makes the table monotonic. We mention this
because our own first hypothesis was selectivity, and it was wrong.

`docs/findings.md` has the full measurement; `sql/retrieval/under_return.sql` reproduces it, and
`sql/evaluation/tests.sql` T7 asserts it in CI across three versions.

### Expected

Either `k` rows when at least `k` satisfy the predicate, or a warning that the result is truncated. Silent
truncation gives the caller no way to detect that anything happened.

### Workarounds, both of which work

- `FORCE INDEX (<predicate index>)` — returns results **identical to exhaustive search** in all nine
  categories we tested. Requires the filter column to be on the same table as the vector index, since a hint
  cannot name an index on another table.
- Raise `mhnsw_ef_search` — every category was whole by 200. Note this did **not** work on synthetic
  near-orthogonal vectors at any value up to the table size, so it may not be reliable in general.

### What we have not established

- The variation is not fully repeatable. Five identical runs against one index build were stable for seven
  of nine categories but flipped for two. Raising `mhnsw_max_cache_size` above the index size changed which
  categories failed without removing the instability, so the cache is not the cause. **We do not know what
  is.**
- Our synthetic reproduction uses seeded `RAND()` vectors, so patterned-data effects are not excluded there.
  The table above, however, is real embeddings.

---

## 2. `mhnsw_default_m = 6` cannot reach 98% recall on a normal text corpus

Not a defect — a default we believe is set too low, reported separately for that reason.

On the same 18,651-chunk corpus, varying only `mhnsw_default_m`:

| `mhnsw_default_m` | recall@10 at default `ef_search = 20` | mean query ms | smallest `ef` reaching 0.98 |
|---|---|---|---|
| **6 (shipped default)** | **0.8333** | 0.112 | **never** — 0.937 at `ef` 1000 |
| 16 | **0.9944** | 0.215 | 10 |
| 32 | 0.9981 | 0.568 | 10 |

At the shipped default, **one correct result in six is missing**, and no `ef_search` recovers it: the ceiling
is the graph's connectivity, not the width of the search. `m = 16` costs 0.1 ms per query and 19 seconds of
one-off index build on this corpus, and is what the HNSW literature and other implementations typically
default to (16–32).

Raising `m` also largely removes the under-return in part 1, which is consistent with both being symptoms of
an under-connected graph.

Recall is measured against exhaustive search over the same data with the same embeddings — a question about
the index, not about the embedding model. Method and the full sweep are in `docs/findings.md`.

### Suggestion

Consider raising the default, or documenting that 6 is tuned for index build time rather than recall and
that text-retrieval workloads should raise it. A user who takes the defaults currently gets 83% recall with
nothing to indicate it.
