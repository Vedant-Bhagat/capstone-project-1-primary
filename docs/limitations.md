# Limitations

What this project does not establish, and where its numbers stop being load-bearing. Requirements B6 and
C1–C3. Measured results are in [`findings.md`](findings.md); verified server behaviour is in
[`main_dish_spec/09_verified_findings.md`](main_dish_spec/09_verified_findings.md).

This file exists because the most common way a project like this misleads is not a wrong number — it is a
correct number quoted outside the conditions that produced it.

## 1. MariaDB's vector index does not serve selective filtered queries

The central limitation we found, and the one that shaped the schema.

A vector query with a relational filter has two plans available, and neither is satisfactory above roughly
7% selectivity:

| Plan | Result |
|---|---|
| Post-filter through the vector index (what the optimizer picks) | Approximate, and **can return fewer rows than requested — sometimes zero** |
| Pre-filter on a b-tree, then exact distances (`FORCE INDEX`) | Exact, but the vector index contributes nothing |

So a filtered semantic search is either unreliable or is not actually using the vector index. For a ~11%
slice the exact scan is cheap and clearly the right trade, which is what every committed query does — but it
means the feature's headline capability, "semantic search with ordinary SQL filters", currently costs you the
index on exactly the queries where you most wanted it.

**What governs the shortfall is the filter's direction relative to the query**, not the dimensionality and
not the selectivity. A filter selecting rows the graph walk would visit anyway returns the full `k`; one
selecting distant rows can return nothing, because post-filtering explores the query's neighbourhood and
discards everything failing the predicate rather than widening its search.

**Distance ranks the risk; it does not draw a line, and we overstated this once.** On the real corpus the
table happened to come out monotonic in distance, which made the rule look sharper than it is. The minimal
reproduction shows it is not: two categories at 0.0326 and 0.0332 — a 2% difference, identical selectivity of
12.5% — behave oppositely, one returning nothing and the other all ten. Selectivity is ruled out; distance
is a good predictor and not a threshold.

**It varies per index build — on real data.** Five rebuilds of the same index on the same data returned 10,
0, 2, 3, 0 rows. We initially called it deterministic on the strength of four consecutive failures and were
wrong; a fifth build came back full. This is why `tests.sql` T7 retries across rebuilds instead of asserting
one. The minimal reproduction is the opposite — identical across five runs and five rebuilds — so the
variation is a property of the real corpus, not of the defect, and the two cases are not interchangeable as
test fixtures.

**Whether `mhnsw_ef_search` mitigates it depends on the geometry, and we got this wrong once.** On the
synthetic fixture's near-orthogonal clusters, no value up to the table size recovered the missing rows. On
**real embeddings it does** — every category was whole by `ef_search = 200`. The fixture was the harsher
case, and the earlier claim that tuning cannot fix this was true only there. The minimal reproduction sides
with the fixture: no value up to 2000, the size of the whole table, recovers a single row. **The practical
consequence is the bad one — an operator cannot tell in advance which case they are in**, so raising
`ef_search` is not a fix you can rely on.

Raising `mhnsw_default_m` from MariaDB's default of 6 to 16 also mostly removes it on the real corpus, which
is consistent with a reachability problem. It is not a fix either, and the minimal case shows why it is worse
than "partial": sweeping `M` over 6, 16, 32 and 64, **one category that worked at `M = 6` breaks at
`M = 16`**, and another is short at every value from 6 to 64. Raising `M` reshuffles which queries fail more
than it stops them failing. The index hint stays.

### What we have NOT established about it

- **Why it is not perfectly repeatable.** Repeating an identical query five times against one index build,
  most categories are stable but two of nine flipped. Raising `mhnsw_max_cache_size` from 16 MB to 128 MB —
  above the 27.3 MB index — changed *which* categories failed without removing the instability, so the cache
  is not the explanation we assumed. It is reported because a user hitting it would see a query that works on
  Monday and returns nothing on Tuesday, which is worse than one that always fails.

  **There is now a named candidate cause, and it is not ours.**
  [MDEV-37559](https://jira.mariadb.org/browse/MDEV-37559) has Sergei Golubchik stating that MHNSW tracks
  visited graph nodes with a Bloom filter keyed on **vector addresses in memory**, so "depending on where a
  next malloc() places the vector data, hash values may happen to be particularly unlucky" and the search
  skips a node it never visited. That would explain both the run-to-run variation and the thing that most
  puzzled us — that changing the cache size changed *which* categories failed, since a different cache means
  different allocations. We flag two limits on this. His own comment begins "Presuming this theory is
  correct", and the ticket is **Stalled**, not fixed. And we cannot verify it from SQL: it needs a debug
  build. **So the cause is no longer unexplained, but it is still unconfirmed, and it is someone else's
  hypothesis rather than our finding.**
- **Genuinely random vectors**, to rule out a patterned-data artifact. Our vectors come from seeded `RAND()`.
- **Where the ~7% crossover actually sits at 384 dimensions.** The plan flip reproduces there, but the
  threshold itself was swept at 3 dimensions and is likely cost-model dependent.
- **Whether it is already reported — it is, and we had this backwards.** Searched 2026-10-28. The symptom
  is on record three times and unfixed: MDEV-34774 (our exact case, **marked Fixed in 11.7.1**, still present
  for us on 11.8 through the current release), MDEV-37709 (closed **Incomplete** for lack of a small test
  case) and MDEV-41342 (confirmed, a different trigger). Two recall reports, MDEV-35071 and MDEV-36317, were
  closed **Won't Fix** as artifacts of uniform-random vectors. `docs/bug_report_draft.md` has the full table.
  What this project adds is therefore not the discovery but **the minimal reproduction**
  (`sql/retrieval/minimal_repro.sql`) and the measurement on real embeddings.

## 2. Nothing here measures the embedding model, and nothing here should be read as doing so

recall@k compares the HNSW index against exhaustive search **with the embedding model held fixed**. It is a
question about MariaDB. If retrieval returns an irrelevant passage that brute force would also have returned,
recall is 1.0 and the system is still unhelpful — that is the model's fault, not the database's, and this
project does not try to separate good embeddings from bad ones.

A project reporting only hit@k has measured its embedding model and called it a database result. We report
both and label which is which.

## 3. The synthetic fixture produces no quality numbers

`sql/fixture.sql` exists so components could be built in parallel, and so CI runs in seconds without loading
Wikipedia. Its vectors are generated, not embedded. **Any recall, latency or hit@k figure from it describes
the harness, not the system**, and `findings.md` marks those numbers as such. CI green means the invariants
hold, not that retrieval is good.

One figure from it is worth keeping for a different reason: at the default `ef_search`, one of nine fixture
queries scored recall@10 of **0.0000** — ten rows returned, none of them correct. On synthetic vectors that
is not a result, but it is the failure *shape* worth watching for on real ones, and a mean recall of 0.87
hides it completely. Per-query reporting is not optional.

## 4. Corpus scale and composition

- **One language, one source, one register.** 1,295 English Wikipedia articles across nine categories. Nothing
  here generalises to multilingual corpora, to short text such as product titles or chat logs, or to domains
  where Wikipedia's encyclopaedic register is unrepresentative.
- **The categories are deliberately close.** `ethics` and `political_philosophy` overlap on purpose, to give
  the retriever a real chance to confuse them. That makes recall harder than a well-separated corpus would,
  so our numbers are not comparable to benchmarks on distinct topics.
- **The corpus came out 43% larger than planned: 18,651 chunks against `03_corpus.md`'s "~13,000
  (unverified)", at 14.5 chunks per article.** Worth recording how we got that wrong twice over. The estimate
  came from Kaj's ~10-chunks-per-article figure. Mid-ingest we extrapolated from the first 20 articles, which
  gave 47 chunks each and a projection of ~61,000 — but the cap rule takes the *longest* 150 articles per
  category, so the first articles processed are the biggest on Wikipedia and the worst possible sample. The
  real average is 14.5. **Both the original estimate and our correction to it were wrong, in opposite
  directions, and only the completed ingest settled it.** The index is 27.3 MB, which still exceeds the
  16 MB default `mhnsw_max_cache_size`.

- **Category sizes are uneven, from 5.0% to 18.8% of chunks**, because articles differ in length far more
  than counts suggest: `space_telescopes` has 137 articles but 932 chunks, `composers` has 149 and 3,503.
  Any per-category comparison is across unequal samples of six questions each, which is too few to rank
  categories by.
- **Templates are not pinned.** A revision id fixes the wikitext, but templates such as unit conversions
  render with today's template code, so a reproduction can differ in formatting. `corpus_manifest.csv` records
  a SHA-256 per article so a reproduction can *report* how closely it matched instead of assuming.

## 5. Measurement environment

- **One machine for the headline numbers**, stated in `findings.md`. Latency figures are wall-clock on a
  laptop with other processes running; the variance columns are there because the mean alone would be
  dishonest, and one `ef_search = 1000` sample came in at 22 ms against a 1 ms mean.
- **Default server configuration.** In particular `mhnsw_max_cache_size` is the 16 MB default while the real
  index is far larger than that, so published latencies include disk I/O the setting was meant to avoid.
  `05_schema.md` flags raising it; the sweep reports the value rather than changing it, because it is global.
- **Windows for the manual runs, Linux only in CI.** CI covers 11.8, 12.3 and the current release on
  `ubuntu-latest`, which is what lets us say the under-return is not platform-specific. Every *timing* number,
  though, comes from one Windows laptop.
- **Embedding hardware changes the ingest time by more than an order of magnitude, and nothing else.**
  Measured on the same machine, same model, same 300-word chunks:

  | Device | chunks/second | full corpus |
  |---|---|---|
  | CPU, 8 threads (`torch==2.2.1`) | 11 | ~90 min of embedding |
  | RTX 3050 Laptop, 4 GB (`torch==2.2.1+cu121`) | **357** | **~3 min**, 0.89 GB VRAM |

  Throughput is flat above batch 32 on CPU and above batch 128 on the GPU, so neither number is a tuning
  artefact. With a GPU the 1 request/second Wikipedia rate limit becomes the bottleneck, which is where it
  belongs. **No measured result in this project depends on the device** — the same weights produce the same
  vectors, to well below the precision stored — but a reader reproducing the corpus on a CPU should expect
  hours, and `requirements.txt` says so.

## 6. Scope we deliberately did not enter

Listed so that their absence reads as a decision rather than an oversight: no multi-vector or late-interaction
retrieval, no reranking model, no query rewriting or HyDE, no fine-tuning, no quantisation, no sharding or
replication, no multi-tenant isolation, and no comparison against Pinecone, Qdrant or FAISS. The last is the
most tempting and the least honest: a fair cross-system benchmark needs equal tuning effort on both sides, and
we could not have given it.

## 7. The answering half is the least measured part

`python/answer.py` runs with `--no-llm` and needs no API key, which is a hard requirement — every number in
this repository is reproducible without an account. The consequence is that generation quality is the one
thing we check least. Citation resolution is asserted automatically; answer correctness is **not** graded at
scale, and the refusal rate is reported rather than optimised.

What exists and what does not, precisely:

- **Graded, and free to reproduce:** retrieval hit@k over 30 QA pairs with known source chunks — hit@10
  1.000, hit@1 0.767 (`python -m python.grade_answers --no-llm`).
- **Not graded:** the abstention rate over the 10 unanswerable questions, and answer correctness over the 30
  answerable ones. `grade_answers.py` implements both; neither has been run over the full set, because doing
  so needs an API key and no key is stored in this repository.
- **The hit@10 of 1.000 is an upper bound, not a difficulty estimate.** Each question was written from the
  chunk it is scored against, so its phrasing sits closer to that chunk than a real question would. Questions
  written by someone who had not seen the passages would be a harder and more informative set, and that is
  the obvious next improvement to this file rather than more API calls.
- **Any LLM-as-judge score is unvalidated.** File 08 requires a human agreement rate before such a number is
  published. There is none, so `grade_answers.py` prints the warning itself and leaves a `human` column for a
  hand-scored sample. A judge figure in the README without that agreement rate would be a number with no
  known relationship to the truth.
