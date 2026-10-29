# Jira submissions — exact text, in posting order

**Team decision (D6): approved in person on 2026-10-29 by Vedant, Janhavi and Pranesh.** The two technical
gates were already closed — the prior-art search, and the reduction to
[`../sql/retrieval/minimal_repro.sql`](../sql/retrieval/minimal_repro.sql). What remained was the judgement
call, and all three of us agreed to post, with the three caveats named in
[`bug_report_draft.md`](bug_report_draft.md) carried into the text.

Posting order is deliberate and is argued in `bug_report_draft.md`: two contributions to open work first,
the opinion about a default last. Filing the default first, into a project that has twice declined recall
reports, would spend our credibility on the weakest of the three.

The SQL below is a compacted form of `sql/retrieval/minimal_repro.sql` — same data, same query, explanatory
comments stripped so it fits in a comment box. It was run on 12.3.3 immediately before being pasted here and
reproduced 6 of 8, matching the committed version exactly.

| # | Where | What | Posted |
|---|---|---|---|
| 1 | comment on [MDEV-37709](https://jira.mariadb.org/browse/MDEV-37709) | the missing minimal test case | ☐ |
| 2 | comment on [MDEV-34774](https://jira.mariadb.org/browse/MDEV-34774) | still present after the 11.7.1 fix | ☐ |
| 3 | a new issue | `mhnsw_default_m = 6` is too low for real text | ☐ |

Tick each box and record the comment URL or MDEV number as it goes up, so the process write-up can cite it
rather than describe it.

---

## 1 — Comment on MDEV-37709

Attach `sql/retrieval/minimal_repro.sql` to the ticket as well as pasting this; the inline copy is for
whoever reads the comment without downloading anything.

```
h3. The same symptom, with the minimal test case this ticket was closed for wanting

We hit exactly this on a RAG project over Wikipedia (a Constructor University capstone, with the MariaDB
Foundation) and reduced it to 2,048 rows of pure SQL, since this ticket was closed Incomplete only because
the 250 MB dump could not be shrunk. No corpus, no embedding model, no Python, no RAND() -- every vector is
a deterministic function of its row id, so it loads byte-identical anywhere. Runs in about a second.

{code:sql}
DROP DATABASE IF EXISTS mdev_repro;
CREATE DATABASE mdev_repro;
USE mdev_repro;

CREATE TABLE t (
  id  INT PRIMARY KEY,
  cat TINYINT NOT NULL,
  v   VECTOR(16) NOT NULL,
  KEY ix_cat (cat),
  VECTOR INDEX (v) M=6 DISTANCE=cosine
) ENGINE=InnoDB;

-- 2048 rows, 8 clusters of 256. Component j of row i is a shared common
-- direction + a per-category phase offset + small deterministic jitter.
INSERT INTO t (id, cat, v)
SELECT r.seq, MOD(r.seq, 8),
       VEC_FromText(CONCAT('[', GROUP_CONCAT(
           ROUND(  (0.5 + 0.3 * SIN(d.seq))
                 + 0.35 * SIN(2 * PI() * MOD(r.seq, 8) / 8 + d.seq * 1.1)
                 + 0.08 * (MOD(r.seq * 7919 + d.seq * 104729, 2003) / 2003.0 - 0.5)
           , 6) ORDER BY d.seq SEPARATOR ','), ']'))
FROM seq_1_to_2048 r JOIN seq_1_to_16 d
GROUP BY r.seq;

-- Query vector = the exact centroid of cluster 0.
SET @q = (SELECT CONCAT('[', GROUP_CONCAT(
            ROUND((0.5 + 0.3 * SIN(d.seq)) + 0.35 * SIN(d.seq * 1.1), 6)
            ORDER BY d.seq SEPARATOR ','), ']') FROM seq_1_to_16 d);

SELECT VERSION() AS server, @@mhnsw_ef_search AS ef_search;
EXPLAIN SELECT id FROM t WHERE cat = 4
        ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10;

CREATE TABLE result (cat TINYINT PRIMARY KEY, matching INT, nearest DECIMAL(8,4),
                     unhinted INT, forced INT, exhaustive INT);
DELIMITER $$
CREATE PROCEDURE measure()
BEGIN
  DECLARE c TINYINT DEFAULT 0;
  WHILE c < 8 DO
    INSERT INTO result SELECT c,
      (SELECT COUNT(*) FROM t WHERE cat = c),
      (SELECT MIN(VEC_DISTANCE_COSINE(v, VEC_FromText(@q))) FROM t WHERE cat = c),
      (SELECT COUNT(*) FROM (SELECT id FROM t WHERE cat = c
         ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10) a),
      (SELECT COUNT(*) FROM (SELECT id FROM t FORCE INDEX (ix_cat) WHERE cat = c
         ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10) b),
      (SELECT COUNT(*) FROM (SELECT id FROM t IGNORE INDEX (v) WHERE cat = c
         ORDER BY VEC_DISTANCE_COSINE(v, VEC_FromText(@q)) LIMIT 10) e);
    SET c = c + 1;
  END WHILE;
END$$
DELIMITER ;
CALL measure();
SELECT * FROM result ORDER BY nearest;
SELECT IF(MIN(unhinted) < 10,
          CONCAT('REPRODUCED: ', SUM(unhinted < 10), ' of 8 categories returned fewer than the 10 requested; worst returned ', MIN(unhinted)),
          'NOT reproduced -- check EXPLAIN above chose index v') AS verdict
FROM result;
DROP DATABASE mdev_repro;
{code}

On 12.3.3, six of the eight filter values return *zero* rows for LIMIT 10, while 256 rows -- 12.5% of the
table -- match each of them. There is no error and SHOW WARNINGS is empty.

||cat||matching||nearest distance||unhinted||FORCE INDEX (ix_cat)||IGNORE INDEX (v)||
|0|256|0.0005|10|10|10|
|7|256|0.0326|*0*|10|10|
|1|256|0.0332|10|10|10|
|6|256|0.1274|*0*|10|10|
|2|256|0.1337|*0*|10|10|
|5|256|0.2468|*0*|10|10|
|3|256|0.2644|*0*|10|10|
|4|256|0.3161|*0*|10|10|

Three notes that may save a triager time:

* *The table has to be big enough for the vector plan to win on cost.* At 512 rows the optimizer picks
ix_cat (ref + filesort) and every category correctly returns 10. From 768 rows it switches to index v and
the shortfall appears. We suspect that is why shrinking the original case made the bug disappear, and it is
why the script prints EXPLAIN -- so a reader can check which plan they actually got rather than trust us.
* *It is not selectivity.* All eight categories are exactly 12.5% of the table and they do not behave alike.
* *It is not a clean threshold in distance either.* Categories 7 and 1 are 0.0326 and 0.0332 from the query,
2% apart, and one returns nothing while the other returns everything. Distance from the query ranks the risk
much better than selectivity does, but we could not draw a line and do not claim one.

Also reproduced on ubuntu-latest in GitHub Actions with the official images, so it is not specific to our
machine: 6 of 8 categories short on mariadb:11.8 and mariadb:12.3, and *7 of 8 on mariadb:latest*.

Neither documented mitigation is reliable here. mhnsw_ef_search at 10, 100 and 2000 -- the size of the entire
table -- all return 0 rows for category 4. Raising M helps but is not monotonic: at M=16 category 1 breaks
although it worked at M=6, and category 2 is short at every M from 6 to 64. FORCE INDEX on the filter column
returns all 10 everywhere, which is a usable workaround, but only when the filter column lives on the same
table as the vector index.

One question: is this the same defect as MDEV-34774, which is marked fixed in 11.7.1? We still reproduce
that ticket's exact shape on 11.8 and later, and have commented there as well.
```

---

## 2 — Comment on MDEV-34774

Post this after 1, replacing the placeholder with the real link to the comment from step 1.

```
h3. Still reproducing on 11.8, 12.3 and the current release

This is marked Fixed in 11.7.1, but the shape described here -- a WHERE on a non-vector column plus
ORDER BY VEC_DISTANCE ... LIMIT returning an empty set while many rows satisfy the predicate -- still
reproduces for us on 11.8, 12.3.3 and mariadb:latest.

We have posted a 2,048-row pure-SQL reproduction on MDEV-37709 (same symptom, closed Incomplete for want of
a test case): <link to comment 1>. It needs no corpus, no embedding model and no RAND(), and runs in about a
second. On 12.3.3, six of eight filter values return zero rows for LIMIT 10 with 256 matching rows each,
while FORCE INDEX on the filter's own index returns all 10. In GitHub Actions on ubuntu-latest: 6 of 8 short
on mariadb:11.8 and mariadb:12.3, 7 of 8 on mariadb:latest.

The one structural difference from the original report is that our reproduction needs roughly 768 rows or
more before the optimizer prefers the vector index. Below that it pre-filters and is exact, so there is
nothing to see.

Happy to open a separate ticket if the 11.7.1 fix addressed a different code path and this is a distinct
defect -- we would rather flag it on the existing ticket than file a duplicate.
```

---

## 3 — New issue

Only after 1 and 2 are up. **Type:** Task — not Bug; this is a default we believe is set too low, not
incorrect behaviour. **Component:** vector search. **Affects:** 11.8, 12.3.3, current release.

**Summary line:**

```
mhnsw_default_m = 6 cannot reach 98% recall on a real text corpus at any mhnsw_ef_search
```

**Description:**

```
This is measured on *1,289 real Wikipedia articles embedded with BAAI/bge-small-en-v1.5 (384 dimensions),
18,651 chunks* -- not on uniformly distributed random vectors. We lead with that because MDEV-35071 and
MDEV-36317 were both closed Won't Fix on the reasoning that "many algorithms perform poorly on uniformly
distributed random vectors", with a suggestion to test on realistic clusters instead. This is that test.

Varying only mhnsw_default_m, rebuilding the index each time, measuring recall@10 against exhaustive search
over the same rows with the same embeddings:

||mhnsw_default_m||recall@10 at default ef_search = 20||mean query ms||smallest ef_search reaching 0.98||
|*6 (shipped default)*|*0.8333*|0.112|*never* -- 0.937 at ef_search 1000|
|16|0.9944|0.215|10|
|32|0.9981|0.568|10|

At the shipped default roughly one correct result in six is missing, and no ef_search recovers it: the
ceiling is the graph's connectivity, not the width of the search. M=16 costs about 0.1 ms per query and a
one-off 19 seconds of index build on this corpus, and 16-32 is what the HNSW literature and most other
implementations use as a default.

Recall here is a question about the index, not about the embedding model: the ground truth is exhaustive
search over the identical vectors.

*Suggestion:* consider raising the default, or documenting that 6 is tuned for index build time rather than
recall and that text-retrieval workloads should raise it. A user who takes the defaults currently gets 83%
recall with nothing in the output to indicate it.

Method, the full sweep and the harness are public:
https://github.com/Vedant-Bhagat/capstone-project-1-primary

Two caveats we would rather state than have found. All latency figures come from a single Windows laptop, so
the ms column is relative and is not a benchmark. And the recall numbers are from one corpus with one
embedding model -- which is the point of the report, but also its limit.
```

---

## Caveats we agreed to carry into all three

Named in `bug_report_draft.md`, and not to be dropped when posting:

1. **We have been wrong about this finding twice already**, in public, in this repository's own history:
   finding 7c was withdrawn as a false negative, and "deterministic" was withdrawn after 10/0/2/3/0 across
   five rebuilds. The posts claim only what the scripts show.
2. **The run-to-run instability we also saw is unexplained.** MDEV-37559's Bloom-filter-over-addresses
   theory is the best candidate and we did not verify it — it needs a debug build, not a SQL query. So it
   is not offered as a cause in any of the three posts: the minimal case is perfectly repeatable and is the
   wrong evidence for that half of the problem.
3. **MariaDB's documentation describes silent truncation for distance-threshold filters.** That text is not
   about ordinary column filters, but a triager could reasonably extend it, which is why post 1 shows
   EXPLAIN, the row-count crossover and the `ef_search` and `M` sweeps rather than simply asserting a
   defect.
