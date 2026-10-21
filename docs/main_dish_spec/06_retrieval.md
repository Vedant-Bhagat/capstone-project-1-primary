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
FROM chunks c
JOIN articles a ON a.id = c.article_id
WHERE c.category = 'physics'          -- absolute: indexed, on the same table
  AND c.word_count >= 100            -- absolute: no stubs
ORDER BY distance
LIMIT 10;
```

**Why this is genuinely hybrid and not a `WHERE` bolted on.** The predicate is not a post-filter applied by
our application after a vector service returned results. It is in the same statement, and MariaDB's
optimizer *chooses* how to combine the two access paths — in this case using `ix_category` to narrow the
candidate set and then computing distances exactly over it. The combination is the database's decision,
based on its own statistics. That is a capability that only exists when one system owns both the vectors and
the relational data.

The demonstration should show this with `EXPLAIN` side by side: unfiltered uses `key: embedding`, filtered
uses `key: ix_category`. Same query shape, two different strategies, chosen automatically. That contrast is
the clearest evidence of depth we can put in front of an evaluator.

And the filtered form is **exact**, because brute force over 12% of the corpus is cheap. So the honest
summary is counter-intuitive and worth stating: *adding a selective filter makes the query both faster and
more accurate, because it stops being approximate.*

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

Alongside it, the corrected form filtering on the indexed `chunks.category`, returning the full 10 every
time. Side by side, with `EXPLAIN` for both, the behaviour is self-explanatory and the schema decision in
file 05 justifies itself.

See file 09 for the measured numbers, including the non-monotonic behaviour across `ef_search`.

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
