# 06 — Retrieval and hybrid search

This file specifies the SQL that is the project. Every query here becomes a committed, runnable file under
`sql/retrieval/`, with the explanation beside it.

## 1. Plain semantic search

`sql/retrieval/semantic.sql` — the baseline everything else is compared against.

```sql
SET @q = VEC_FromText(?);        -- the question's embedding, 384 floats

SELECT a.title,
       c.section,
       LEFT(c.body, 200)                            AS preview,
       a.url,
       VEC_DISTANCE_COSINE(c.embedding, @q)         AS distance
FROM chunks c
JOIN articles a ON a.id = c.article_id
ORDER BY distance
LIMIT 10;
```

Three things to point out to a reader, because they are the whole value proposition:

- **The join is free.** The vector search and the article metadata come back in one round trip. A separate
  vector store returns ids, and you then query your real database for the titles — two systems, two
  latencies, and code to stitch them.
- **`ORDER BY ... LIMIT` is the entire API.** No special search syntax, no client library. `EXPLAIN` shows
  `key: embedding`, confirming the index is used rather than all 12,000 rows being compared.
- **This is approximate.** The ordering is HNSW's best guess. File 07 measures how often it is right.

## 2. Hybrid: the "absolute, then fluffy" shape

`sql/retrieval/hybrid_filter.sql` — the query that satisfies requirement B3, in the shape Kaj described.
His example was a shop where the product category is an absolute fact and the product description is fuzzy;
ours is the same structure with Wikipedia categories.

```sql
SET @q = VEC_FromText(?);

SELECT a.title, c.section, LEFT(c.body, 200) AS preview, a.url,
       VEC_DISTANCE_COSINE(c.embedding, @q) AS distance
FROM chunks c FORCE INDEX (ix_category)   -- NOT optional; see below
JOIN articles a ON a.id = c.article_id
WHERE c.category = 'physics'          -- absolute: indexed, on the same table
  AND c.word_count >= 100            -- absolute: no stubs
ORDER BY distance
LIMIT 10;
```

**`FORCE INDEX` is load-bearing and must not be removed.** Without it, above roughly 7% selectivity the
optimizer picks the vector index and post-filters, and the query silently returns fewer rows than asked for
— frequently zero. Measured over four rebuilds at 12.5% selectivity: the default plan returned 0 rows on
three of them, the forced plan returned the full 10 every time and matched exhaustive search exactly.
Finding 7b in file 09 has the sweep and the crossover.

This is the one place in the project where a query carries a hint, and the README must explain why rather
than leaving something that reads like superstition. A bare `FORCE INDEX` with no justification is worse
than none — a reader will delete it.

**Why this is genuinely hybrid and not a `WHERE` bolted on.** The predicate is not a post-filter applied by
our application after a vector service returned results. It is in the same statement, over the same tables,
and the database combines the relational narrowing with the distance computation itself. A standalone vector
service cannot do this at all, because it does not know what is in `articles` or what `category` means.

The demonstration should show three plans with `EXPLAIN`, side by side:

| query | plan | correct? |
|---|---|---|
| unfiltered | `key: embedding` — HNSW graph walk | approximate, measured in file 07 |
| filtered, no hint | `key: embedding`, `Using where` — post-filter | **no — silently short** |
| filtered, `FORCE INDEX` | `key: ix_category`, `Using filesort` — pre-filter | yes, exhaustive-equivalent |

That three-way contrast is the clearest evidence of depth in the project, and it is more interesting than
the two-way contrast the first draft of this file described, because the middle row is a trap a reader
would otherwise fall into.

The honest summary is counter-intuitive and worth stating plainly: **the filtered query is exact, and the
vector index contributes nothing to it.** Brute force over 12% of the corpus is cheap enough that exactness
is the better trade — but it means MariaDB's vector index does not currently serve selective filtered
queries, and the README should say so rather than implying hybrid search gets the best of both.

## 3. Hybrid: full-text and vector combined

`sql/retrieval/hybrid_fulltext.sql` — the second valid shape Kaj named, combining full-text and vector
results into one answer.

Keyword search and semantic search fail differently. Keyword search misses paraphrases; semantic search
misses exact strings — rare proper nouns, identifiers, numbers — because they carry little embedding signal.
Combining both covers both failure modes. The standard technique is Reciprocal Rank Fusion: score each
result by `1/(k + rank)` in each list and sum.

```sql
SET @q  = VEC_FromText(?);
SET @kw = ?;                     -- the same question as plain text

WITH semantic AS (
    SELECT c.id, ROW_NUMBER() OVER (ORDER BY VEC_DISTANCE_COSINE(c.embedding, @q)) AS rk
    FROM chunks c
    ORDER BY VEC_DISTANCE_COSINE(c.embedding, @q)
    LIMIT 30
),
keyword AS (
    SELECT c.id, ROW_NUMBER() OVER (ORDER BY MATCH(c.body) AGAINST (@kw IN NATURAL LANGUAGE MODE) DESC) AS rk
    FROM chunks c
    WHERE MATCH(c.body) AGAINST (@kw IN NATURAL LANGUAGE MODE)
    LIMIT 30
)
SELECT a.title, c.section, a.url,
       COALESCE(1.0/(60 + s.rk), 0) + COALESCE(1.0/(60 + k.rk), 0) AS rrf_score,
       s.rk AS semantic_rank,
       k.rk AS keyword_rank
FROM semantic s
LEFT JOIN keyword k ON k.id = s.id
JOIN chunks c   ON c.id = s.id
JOIN articles a ON a.id = c.article_id
ORDER BY rrf_score DESC
LIMIT 10;
```

Note what this needs: window functions, CTEs, full-text indexing and vector search, cooperating in one
statement. It is also where the starter's work pays off — the team already knows window functions from
area 2, so this is familiar ground used for a new purpose.

**Implementation notes to resolve, not assumed:**

- The `LEFT JOIN` above only scores items present in the semantic list. A true RRF needs a `FULL OUTER JOIN`,
  which MariaDB lacks; the correct form is a `UNION` of ids followed by two `LEFT JOIN`s. The query above is
  the readable sketch and must be corrected during implementation — flagged here so it is not shipped as is.
- `k = 60` is the conventional RRF constant from the original paper. Stated, not tuned, unless we measure it.
- InnoDB full-text has a default minimum token length (`innodb_ft_min_token_size`, 3) and a stopword list,
  so short or common query words silently match nothing. Must be checked and documented.

This query is the strongest single artifact in the project for the depth criterion, and also the most
likely to take longer than expected. File 11 schedules it accordingly.

## 4. The under-return defect, reproduced

`sql/retrieval/under_return.sql` — not a feature, a documented failure, committed as a demonstration.

```sql
-- Filter on a column that is NOT on the vector-indexed table.
-- Asks for 10; 20 rows match the predicate; returns fewer. Silently.
SET @q = VEC_FromText(?);

SELECT COUNT(*) AS rows_returned FROM (
    SELECT c.id
    FROM chunks c
    JOIN articles a ON a.id = c.article_id
    WHERE a.title LIKE 'Emperor%'        -- unindexed predicate, other table
    ORDER BY VEC_DISTANCE_COSINE(c.embedding, @q)
    LIMIT 10
) t;
```

Alongside it, the same query with `FORCE INDEX (ix_category)` on the denormalised `chunks.category`,
returning the full 10 every time and identically to exhaustive search. Side by side, with `EXPLAIN` for both,
the behaviour is self-explanatory and the schema decision in file 05 justifies itself.

**Moving the filter onto the indexed column is not by itself the fix** — this is the correction of 2026-10-22
and the script demonstrates it in scenario D. An indexed `chunks.category` predicate at ~11% selectivity
still returns 0 of 10 when it selects rows *away* from the query, because above the ~7% crossover the
optimizer post-filters through the vector index regardless of the btree being available. Two things are
needed together: the column denormalised onto `chunks` (file 05) **and** `FORCE INDEX` naming it (section 3
above). Either alone is insufficient.

And `ef_search` is not a third option: at 2000, larger than the whole table, the shortfall is unchanged.
See file 09 finding 7c for the measurements.

## 5. The `ef_search` dial

`mhnsw_ef_search` (default **20**, verified) is how many candidates the graph walk keeps in flight. It is a
session variable, so it can be set per connection without restarting anything:

```sql
SET mhnsw_ef_search = 100;
```

Higher means more of the graph visited: better recall, more time. The curve relating the two, on our corpus
with our model, is the project's headline result (file 07).

Two practical notes:

- Because it is per-session, a reader can experiment interactively. The README should invite exactly that —
  it turns the central finding from a claim into something a reader confirms in thirty seconds.
- `ef_search` must be set explicitly in every measurement script. Inheriting the default silently would make
  results depend on server configuration rather than on our stated parameters.

## 6. The reader-facing query interface (requirement A7)

`python/answer.py`, a command-line tool:

```
$ python -m python.answer "why can't penguins fly?"
$ python -m python.answer "what is a black hole?" --category physics
$ python -m python.answer "..." --ef-search 200 --show-sql --no-llm
```

Design rules, each tied to a requirement:

- `--show-sql` prints the exact statement executed. The project's substance is the SQL, so the tool must
  expose it rather than hide it. (A6, usability)
- `--no-llm` returns the retrieved chunks without calling any model, so the whole tool works with no API
  key. (A7)
- `--ef-search` lets a reader reproduce the central finding themselves. (A5)
- Every answer prints its sources as clickable URLs. (B4, honesty)

A reader who can run three commands and see the retrieval change is a reader who has understood the
feature, which is what the usability criterion is actually asking for.
