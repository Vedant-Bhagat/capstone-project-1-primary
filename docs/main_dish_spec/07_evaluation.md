# 07 — Evaluation

The area's criteria ask for "recall and latency against a ground-truth set you built, **not adjectives**."
This file is the method. It is the part of the project most likely to be done badly by others and therefore
the part where we can most easily be better.

## What recall means here, precisely

> **recall@k** = of the k truly nearest chunks, what fraction did the indexed query return?

Measured as set overlap, not rank agreement:

```
recall@10  for one query  =  |indexed_top10  ∩  exact_top10|  /  10
```

averaged over all evaluation queries.

**What this does and does not measure.** It measures *the HNSW index against exhaustive search, holding the
embedding model fixed*. It is a question about MariaDB. It says nothing about whether the embedding model
understands the question, or whether the retrieved chunk answers it — those are file 08's business. Keeping
that boundary clean is why file 03 defines two separate query sets.

This is also why the ground truth needs no human labelling: for this measurement, "correct" is defined as
whatever exhaustive comparison returns. That makes a 50-query set cheap to build and entirely objective.

## Building the ground truth

The baseline must genuinely bypass the index. Two ways, both verified:

```sql
-- Verified: forces type: ALL, Using filesort — no vector index.
EXPLAIN SELECT id FROM chunks IGNORE INDEX (embedding)
ORDER BY VEC_DISTANCE_COSINE(embedding, @q) LIMIT 10;
```

and, more elegantly, a cross join — which **cannot** use the vector index, because the index only serves
`ORDER BY ... LIMIT` against a single constant vector:

```sql
-- sql/evaluation/ground_truth.sql
TRUNCATE TABLE eval_ground_truth;

INSERT INTO eval_ground_truth (query_id, rank_pos, chunk_id, distance)
SELECT query_id, rank_pos, chunk_id, distance
FROM (
    SELECT q.id AS query_id,
           c.id  AS chunk_id,
           VEC_DISTANCE_COSINE(c.embedding, q.embedding) AS distance,
           ROW_NUMBER() OVER (
               PARTITION BY q.id
               ORDER BY VEC_DISTANCE_COSINE(c.embedding, q.embedding)
           ) AS rank_pos
    FROM eval_queries q
    CROSS JOIN chunks c
) ranked
WHERE rank_pos <= 50;          -- 50, so recall@k is available for every k <= 50
```

50 queries x 12,000 chunks is 600,000 distance computations in one statement — slow by design, and the point.
Store to 50 so recall@1, @5, @10 and @20 all come from one build.

Keeping this set-based rather than looping in Python is deliberate. It is the "SQL deep, Python thin"
principle applied where it is least convenient, and the resulting statement — a window function partitioned
over a cross join of vector distances — is itself a demonstration of the feature composing with ordinary SQL.

## Measuring recall at a given `ef_search`

The indexed query needs `ORDER BY ... LIMIT` per query, which cannot be expressed set-wise. So a stored
procedure, in the same style as the starter's `bench.sql`:

```sql
-- sql/evaluation/recall_sweep.sql  (sketch; see repo for the final form)
CREATE OR REPLACE PROCEDURE measure_recall(IN p_ef INT, IN p_k INT)
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE v_qid INT;
    DECLARE v_vec VECTOR(384);
    DECLARE cur CURSOR FOR SELECT id, embedding FROM eval_queries ORDER BY id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    SET SESSION mhnsw_ef_search = p_ef;

    DELETE FROM recall_runs WHERE ef_search = p_ef AND k = p_k;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO v_qid, v_vec;
        IF done THEN LEAVE read_loop; END IF;

        SET @t0 = NOW(6);
        CREATE OR REPLACE TEMPORARY TABLE got AS
            SELECT id FROM chunks
            ORDER BY VEC_DISTANCE_COSINE(embedding, v_vec)
            LIMIT p_k;
        SET @elapsed_us = TIMESTAMPDIFF(MICROSECOND, @t0, NOW(6));

        INSERT INTO recall_runs (ef_search, k, query_id, hits, returned, elapsed_us)
        SELECT p_ef, p_k, v_qid,
               (SELECT COUNT(*) FROM got g
                 JOIN eval_ground_truth t
                   ON t.chunk_id = g.id AND t.query_id = v_qid AND t.rank_pos <= p_k),
               (SELECT COUNT(*) FROM got),
               @elapsed_us;
    END LOOP;
    CLOSE cur;
END;
```

Note `returned` is recorded as well as `hits`. That column is what catches the under-return defect
automatically: any row where `returned < k` is a silent truncation, and the test in the next section fails
the build on it. We would not have thought to record it had we not probed first.

The `DECLARE CONTINUE HANDLER FOR NOT FOUND` cursor pattern is the same one the team already used for
`FETCH GROUP NEXT ROW` in the starter — familiar ground, reused.

## The sweep, and the headline deliverable

Run `measure_recall` across `ef_search` in `{10, 20, 50, 100, 200, 500, 1000}` and `k` in `{1, 10}`, then:

```sql
SELECT ef_search,
       k,
       ROUND(AVG(hits / k), 4)            AS recall,
       ROUND(AVG(elapsed_us) / 1000, 2)   AS mean_ms,
       ROUND(MIN(elapsed_us) / 1000, 2)   AS min_ms,
       ROUND(MAX(elapsed_us) / 1000, 2)   AS max_ms,
       ROUND(STDDEV_SAMP(elapsed_us) / 1000, 2) AS sd_ms,
       SUM(returned < k)                  AS truncated_queries
FROM recall_runs
GROUP BY ef_search, k
ORDER BY k, ef_search;
```

This table is the project's single most important artifact and belongs high in the README:

| `ef_search` | recall@10 | mean ms | sd ms | truncated |
|---|---|---|---|---|
| 10 | ? | ? | ? | ? |
| 20 (default) | ? | ? | ? | ? |
| 50 | ? | ? | ? | ? |
| 100 | ? | ? | ? | ? |
| 200 | ? | ? | ? | ? |
| 500 | ? | ? | ? | ? |
| 1000 | ? | ? | ? | ? |
| brute force | 1.0000 | ? | ? | 0 |

The brute-force row matters as much as the rest: it is the "is the index earning its place?" check. If
exhaustive search over 12,000 chunks is already fast enough, the index is not justified on this corpus and
we must say so plainly — which would mean growing the corpus until it is, or reporting the crossover point
as the finding. Either is honest; silently omitting the comparison is not.

### What we are looking for

The deliverable is **the smallest `ef_search` at which recall@10 >= 0.98**, with its latency cost stated.
That one sentence is requirement B2, and arriving at it by measurement rather than assertion is the whole
difference between this project and a tutorial.

Per-category recall is a cheap second cut — group by `category` and report it. The prediction from file 03
is that `philosophy` and `physics` will trail `birds` and `composers`. Confirmed or refuted, it is a result.

## Measuring latency honestly

Carried over from the starter, where it was already proven:

1. **Warm up first.** One untimed pass per configuration. A cold InnoDB buffer pool and a cold
   `mhnsw` cache make the first query unrepresentative by an order of magnitude.
2. **Repeat and report variance.** 10 runs minimum; mean, min, max and `STDDEV_SAMP`. A single timing is
   not a measurement, and the starter's benchmark showed a 9 ms standard deviation on a 131 ms query.
3. **State the hardware.** The starter's README does; this must too.
4. **Measure the query, not the transfer.** Wrap in `SELECT COUNT(*) INTO sink FROM (...)` so result
   serialisation is not timed.
5. **`mhnsw_max_cache_size` must be set explicitly and stated.** With a ~18 MB index and a 16 MB default
   cache, the default measures partial-cache behaviour. Both values are worth reporting — "with the default
   cache" and "with the cache raised" is a legitimate second finding.

## Experiments beyond the headline sweep

Each is cheap because the harness exists, and each produces a stated parameter with reasoning (A6):

| Experiment | Varies | Question answered |
|---|---|---|
| `ef_search` sweep | 10 -> 1000 | **The headline.** Where does recall cross 98%, and what does it cost? |
| `m` sweep | `mhnsw_default_m` 4, 6, 12 | Does a denser graph beat a wider search? Requires a full index rebuild per value. |
| Title prepending A/B | `PREPEND_TITLE` on/off | Does the file-04 context trick actually help on our corpus? |
| Chunk size | 150 / 300 / 600 words | Needs re-embedding; the most expensive experiment. Run once, late. |
| Model comparison | BGE vs MiniLM | Validates the file-04 claim on our data rather than on published benchmarks. |
| Index build order | before vs after bulk load | Tests the file-02 hypothesis. Nearly free — we load anyway. |
| Cache size | 16 MB vs index-sized | Isolates how much of the latency is disk I/O. |

If time runs short, the first and the last two are the ones to keep: they are the cheapest and they
underpin claims made elsewhere in the spec.

## Tests that gate CI

`sql/evaluation/tests.sql`, using the starter's proven pattern — `SIGNAL SQLSTATE '45000'` inside
`BEGIN NOT ATOMIC`, which makes the `mariadb` client exit non-zero and fails the workflow.

| # | Assertion | Catches |
|---|---|---|
| T1 | `corpus_meta.embed_dims` equals the declared dimension of `chunks.embedding` | A model swap without a schema migration — the failure that produces confident nonsense |
| T2 | No `chunks` row has a zero vector | Silent embedding failures; a zero vector has undefined cosine distance to everything |
| T3 | `chunks.category` agrees with `articles.category` for every row | Drift in the file-05 denormalisation |
| T4 | Indexed top-10 matches brute-force top-10 **exactly** for a fixed query at high `ef_search` | Index corruption, or a metric mismatch |
| T5 | `recall@10 >= 0.98` at the documented `ef_search` | Regression in the headline claim |
| T6 | The hybrid query **with `FORCE INDEX`** returns exactly `k` rows, and the same rows as exhaustive search | The under-return defect appearing where we claimed to have fixed it. Must assert row identity, not just the count — Janhavi observed a run returning the right count with none of the right rows |
| T7 | The unindexed-filter query **still under-returns** | That the documented defect is still real. If MariaDB fixes it, this test fails and tells us to update the write-up |
| T9 | Every committed hybrid query text contains `FORCE INDEX` | Someone "tidying up" the hint, which would reintroduce the defect silently. The cheapest possible guard against our own future selves |
| T10 | Measured at ingest: no category exceeds the crossover selectivity on the real corpus | File 03's sizing assumption drifting as the corpus changes |
| T8 | `EXPLAIN` on `semantic.sql` shows the vector index in use | A plan regression quietly turning every query into a table scan |

T7 is worth dwelling on: it is a test that asserts a bug still exists. That is the right design, because our
README will make a claim about MariaDB's behaviour, and the test's job is to tell us when that claim stops
being true. Tests encoding documented behaviour — including documented defects — is a point worth making
explicitly in the write-up.

T8 needs `EXPLAIN` output parsed in SQL, which is awkward; `information_schema` or a thin Python assertion
in CI is the likely fallback. Flagged rather than assumed.

## CI corpus

A full 1,200-article ingest on every push is too slow and hammers Wikipedia. CI uses a
**100-article subset pinned by the committed manifest**, enough for every test except the recall threshold,
which needs the real corpus to be meaningful.

So two workflows:

- **On every push** — schema, 100-article ingest, T1–T4 and T6–T8, on a MariaDB version matrix.
- **Manual / weekly** — the full corpus, the whole sweep, and T5.

Version matrix: **11.8 (the first LTS with `VECTOR`), 12.3, and the current release.** Note this differs
from the starter's 11.4/12.3/13.0 — 11.4 predates vector support and must be dropped, which is itself
worth a line in the README about why the minimum version differs between the two projects.
