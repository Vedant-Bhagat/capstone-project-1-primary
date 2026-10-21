# 09 — Verified findings

Everything in this file was **observed on a live server**, not recalled from documentation. Reproduce it
with [`probe/vector_probe.sql`](probe/vector_probe.sql).

**Environment:** MariaDB **12.3.3** (`12.3.3-MariaDB`), Windows 11, AMD Ryzen 7 6800H, 15 GB RAM, default
configuration except where noted. Probed 2026-10-15.

Read the caveats section at the end before quoting any of this. One finding in particular needs
re-verification on the real corpus before it goes in a public README.

## 1. Server defaults

```
+------------------------+-----------+
| Variable_name          | Value     |
+------------------------+-----------+
| mhnsw_default_distance | euclidean |
| mhnsw_default_m        | 6         |
| mhnsw_ef_search        | 20        |
| mhnsw_max_cache_size   | 16777216  |
+------------------------+-----------+
```

Two of these matter to us:

- **`mhnsw_default_distance` is `euclidean`.** Text embeddings want cosine. The default is the wrong one for
  our use case, so `DISTANCE=cosine` must be written explicitly. Finding 5 shows what happens if it is not.
- **`mhnsw_max_cache_size` is 16 MB.** Our index is estimated at ~18 MB (file 03), so at default settings it
  does not fit. Every latency number must state which cache size it was measured at.

## 2. Kaj's limitation C2 confirmed — `NOT NULL` is enforced

```sql
CREATE TABLE t_nullable (id INT PRIMARY KEY, v VECTOR(3), VECTOR INDEX (v));
```
```
ERROR 1252 (42000): All parts of a VECTOR index must be NOT NULL
```

A clean, immediate error at DDL time. This limitation cannot bite you silently.

## 3. Kaj's limitation C1 confirmed — one vector index per table

```sql
CREATE TABLE t_two (id INT PRIMARY KEY, a VECTOR(3) NOT NULL, b VECTOR(3) NOT NULL,
                    VECTOR INDEX (a) DISTANCE=cosine, VECTOR INDEX (b) DISTANCE=cosine);
```
```
ERROR 1235 (42000): This version of MariaDB doesn't yet support 'multiple VECTOR indexes'
```

Also a clean DDL-time error. The wording — "doesn't **yet** support" — is MariaDB's own, and suggests a
current limitation rather than a permanent design decision. Worth quoting in the limitations write-up.

This is what forces the two-table split in file 05.

## 4. Dimension limit

```sql
CREATE TABLE dbig (id INT PRIMARY KEY, v VECTOR(65533) NOT NULL, VECTOR INDEX (v) DISTANCE=cosine);
```
```
ERROR 1074 (42000): Column length too big for column 'v' (max = 16383); use BLOB or TEXT instead
```

**Maximum 16,383 dimensions.** `VECTOR(768)` and `VECTOR(1536)` both accepted without complaint, so every
mainstream embedding model fits comfortably. Recorded because the error message is misleading — it suggests
`BLOB` or `TEXT`, which would of course not be vector-indexable at all.

## 5. Kaj's limitation C3 — confirmed, but the consequence is milder than warned

Kaj told us a mismatched distance function makes results "meaningless". On 12.3.3 that is not what happens.

Same table, one cosine index, two queries:

```sql
EXPLAIN SELECT id FROM docs ORDER BY VEC_DISTANCE_COSINE(v, ...) LIMIT 5;
```
```
type: index   key: v     rows: 5                      <- index used
```

```sql
EXPLAIN SELECT id FROM docs ORDER BY VEC_DISTANCE_EUCLIDEAN(v, ...) LIMIT 5;
```
```
type: ALL     key: NULL  rows: 2000  Extra: Using filesort    <- full scan
```

**The optimizer silently declines to use the index and falls back to a full table scan with a filesort.**
The results are therefore *correct* — a full scan computes exact distances — but the index is bypassed
entirely and the query degrades from a graph walk to 2,000 distance computations.

So the real failure mode is a **silent performance cliff, not silent corruption.** That is better news than
we were given, and it is a genuine refinement of the Foundation's own guidance rather than a repetition of
it. The defence is unchanged: write `DISTANCE=cosine` explicitly, and check `EXPLAIN` shows
`key: <your index>` rather than `type: ALL`.

## 6. `IGNORE INDEX` gives a usable brute-force baseline

```sql
EXPLAIN SELECT id FROM docs IGNORE INDEX (v) ORDER BY VEC_DISTANCE_COSINE(v, @q) LIMIT 10;
```
```
type: ALL   key: NULL   rows: 2000   Extra: Using filesort
```

Confirms the ground-truth method in file 07 works. We can obtain exact nearest neighbours from the same
table, with the same metric, in the same session — no separate baseline table, no Python.

And at default `ef_search = 20` on 2,000 rows, the indexed and exact top-10 were **identical**:

```
indexed : 382,386,390,394,398,1749,1753,1757,1761,1765
brute   : 382,386,390,394,398,1749,1753,1757,1761,1765
```

Recall 1.00 unfiltered. Expected on a corpus this small; the interesting question is what happens at 12,000
rows and 384 dimensions, which is file 07's job.

## 7. The headline finding — filtered vector queries can silently under-return

This is the most important thing in the spec, and it was not documented anywhere we looked.

Setup: 2,000 rows, cosine vector index on `v`, and two filter columns each matching exactly 20 rows —
`category` (**indexed**) and `tag` (**not indexed**).

### With an indexed filter column: correct

```sql
SELECT COUNT(*) FROM (SELECT id FROM docs WHERE category='rare'
                      ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
-- 10
```
```
EXPLAIN: type: ref   key: category   rows: 20
         Extra: Using index condition; Using where; Using filesort
```

MariaDB **pre-filters**: it uses the ordinary index to narrow to the 20 matching rows, then computes exact
distances over them. The vector index is not used, the answer is exact, and the full 10 rows come back.

### With an unindexed filter column: silently wrong

```sql
SELECT COUNT(*) FROM (SELECT id FROM docs WHERE tag='needle'
                      ORDER BY VEC_DISTANCE_COSINE(v,@q) LIMIT 10) t;
-- 7
```
```
EXPLAIN: type: index   key: v   rows: 10   Extra: Using where
```

**Asked for 10. Twenty rows match the filter. Got 7.** No error. No warning — `SHOW WARNINGS` was empty.

The mechanism is visible in the plan: with no index to pre-filter on, MariaDB walks the HNSW graph and
applies `WHERE tag='needle'` to the candidates afterwards. The graph walk yields a bounded candidate list,
most of it fails the filter, and the query runs out of candidates before it has 10 survivors. `FORCE INDEX (v)`
gives the same 7, so this is the access path's behaviour and not a planner misjudgement.

### Raising `ef_search` does not reliably fix it

The obvious mitigation is to widen the search. It does not work, and it is not monotonic. Three runs of the
same sweep, on the same data:

| run | ef 20 | ef 50 | ef 100 | ef 200 | ef 500 | ef 1000 |
|---|---|---|---|---|---|---|
| 1 | 7 | 10 | **0** | **0** | 10 | 10 |
| 2 | 2 | 2 | 2 | **0** | **0** | 10 |
| 3 | **0** | **0** | **0** | **0** | **0** | **0** |

Zero rows returned, repeatedly, while twenty rows satisfy the predicate. No error, no warning, identical
`EXPLAIN` plan at every setting.

**But notice that the three runs disagree with each other**, which is the more important observation, and
the reason none of these rows should be quoted on its own.

### The stable experiment: the shortfall is nondeterministic per index build

The sweep wobbles because **HNSW assigns every node a random level when it is inserted**, so each build of
the index produces a different graph, a different candidate set, and a different number of survivors after
post-filtering.

Isolating that — five consecutive full rebuilds of the identical table with identical data, `ef_search` at
its default 20, each query asking for `LIMIT 10`, both filters matching exactly 20 rows:

| build | unindexed filter | indexed filter | unfiltered |
|---|---|---|---|
| 1 | **2** | 10 | 10 |
| 2 | **1** | 10 | 10 |
| 3 | **7** | 10 | 10 |
| 4 | **3** | 10 | 10 |
| 5 | **2** | 10 | 10 |

This is the quotable result. Three things follow from it:

1. **With an unindexed filter, the row count is both short and nondeterministic.** The same query, on the
   same data, with the same settings, returns a different number of rows depending on how the index happened
   to be built. Across eight builds in total we have observed every value from **0 to 7** of the 10
   requested — including, repeatedly, the empty result.
2. **With an indexed filter on the same table, the answer is correct every single time.** Five for five.
   The mitigation is proven, not conjectured.
3. **Unfiltered search is unaffected.** The defect is specific to filtered vector queries.

Returning 7 of 10 is defensible as approximate-search behaviour. **Returning 1 of 20 matching rows, and a
different count on every rebuild, is not** — no documented property of HNSW predicts it, and a caller has
no way to detect it. This reads as a defect rather than an accuracy trade-off.

### What this changes

1. **Schema.** Any column used to filter a vector query must be on the vector-indexed table and indexed.
   This is why file 05 denormalises `category` onto `chunks`. The design is driven by measured behaviour.
2. **Testing.** Every retrieval measurement records how many rows came back, not just how many were
   correct. A silent truncation is invisible to a recall metric that divides by what it received.
3. **A likely contribution.** This is a strong Jira candidate — and, per `[kaj]` B6, documenting a
   limitation we hit is explicitly rewarded. See file 11.

## 8. Minor confirmations

| Check | Result |
|---|---|
| `VEC_FromText` / `VEC_ToText` round-trip | `'[1,2,3]'` in, `[1,2,3]` out |
| `VEC_DISTANCE_COSINE` of orthogonal vectors | `1` |
| `VEC_DISTANCE_EUCLIDEAN([0,0,0],[3,4,0])` | `5`, as the 3-4-5 triangle requires |
| Cosine is scale-invariant — `[1,2,3]` vs `[2,4,6]` | `0`. **Pre-normalisation is unnecessary with cosine** (file 04) |
| `FULLTEXT` and `VECTOR` index on the same table | Permitted. The hybrid full-text query in file 06 is viable |
| `ALTER TABLE ... ADD VECTOR INDEX` on a populated table | Works. The build-after-load plan in file 02 is viable |
| Index definition as stored | ``VECTOR KEY `v` (`v`) `DISTANCE`='cosine'`` |

## Caveats — read before quoting any of this

The probe was a deliberately minimal harness, and three of its properties limit how far these results
generalise:

1. **3-dimensional vectors, 2,000 rows.** Real embeddings are 384-dimensional over ~12,000 rows. HNSW graph
   behaviour is strongly dimension-dependent, so **none of the recall or under-return numbers should be
   assumed to transfer.** The *mechanisms* — pre-filter versus post-filter, the metric mismatch falling back
   to a scan — are structural and will transfer. The specific counts are not.

2. **The probe vectors are patterned, not random.** They were generated with seeded `RAND(i)` expressions,
   and the ground-truth output shows it: the top-10 arrived as two runs of near-consecutive ids
   (382–398, 1749–1765). That is not what a real embedding distribution looks like, and a patterned
   distribution could plausibly produce an unusual HNSW graph. The five-build experiment controls for this
   — every build used the same patterned data, so the variation between builds is attributable to the index
   rather than the data — but it does not establish that the same thing happens on real embeddings. It has
   to be rerun on the real corpus.

3. **One server, one version, one platform.** 12.3.3 on Windows. Finding 7 must be checked on 11.8 and on
   the current release before any claim about "MariaDB" rather than "MariaDB 12.3.3 on Windows".

### Required before finding 7 goes in a public README or a bug report

- [ ] Reproduce on the real corpus: 384 dimensions, ~12,000 real embeddings
- [ ] Reproduce with genuinely random vectors, to rule out the patterned-data artifact
- [ ] Reproduce on MariaDB 11.8 and the current release
- [ ] Reproduce on Linux, to rule out anything platform-specific
- [ ] Search MariaDB's Jira for an existing report before filing — Robert asked for this explicitly
- [ ] Reduce to the smallest possible reproduction case

Until those boxes are ticked, finding 7 is a strong lead, not a published result. Writing it up as more than
that would be exactly the kind of overclaiming the project is otherwise designed to avoid.
