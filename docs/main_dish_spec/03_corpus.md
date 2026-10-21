# 03 — The corpus

## Requirements this file satisfies

- A3: a **real** Wikipedia corpus
- B1: at least 1,000 articles
- E6: not committed; fetched by a documented, repeatable step
- A4/B3: must carry a **relational attribute worth filtering on**, or hybrid search has nothing to filter

That last point is the one that drives the design. A corpus of 1,000 random Wikipedia articles satisfies the
word "real" but leaves us with nothing to put in a `WHERE` clause except article length, which is not a
question anybody asks. Hybrid search needs an *absolute* attribute the reader would plausibly filter on.
So the corpus is not sampled randomly — it is sampled **by category, deliberately**.

## Design: a category-stratified sample

Fetch roughly 150 articles from each of eight Wikipedia categories:

| Category key | Wikipedia category | Why it is in the set |
|---|---|---|
| `birds` | Birds | Dense, factual, and gives the flightless-bird example that makes semantic search obvious to a non-technical reader |
| `physics` | Concepts in physics | Abstract language; hard for literal search, easy for semantic |
| `composers` | Classical composers | Biographical, lots of dates and places — good for hybrid date filters |
| `prog_lang` | Programming languages | Technical vocabulary that overlaps heavily between articles; a stress test for retrieval precision |
| `spaceflight` | Human spaceflight | Narrative and chronological |
| `diseases` | Infectious diseases | Terminology-heavy; where an embedding model's domain coverage shows |
| `philosophy` | Philosophical concepts | Deliberately the fuzziest category in the set |
| `architecture` | Architectural styles | Visual and descriptive language |

Eight categories at ~150 articles each is ~1,200 articles, clearing B1 with margin for articles that fail to
fetch or turn out to be stubs.

**Why eight and not one.** A single-topic corpus makes retrieval look better than it is: if everything is
about birds, any bird-related chunk is a plausible hit and precision is unmeasurable. Multiple distinct
categories create genuine opportunities for the retriever to be wrong, which is the only way the recall
number means anything. It also gives the category filter real selectivity — each category is about 12% of
the corpus, which is the range where the hybrid query is interesting and, as file 09 shows, where the
under-return defect bites.

**Why these are deliberately uneven in difficulty.** `philosophy` and `physics` should retrieve worse than
`birds` and `composers`. If they do, we have a per-category recall table, which is a more honest and more
interesting result than one global number. If they do not, that is also worth reporting.

## Fetching

Wikipedia's action API, `action=query`. Two calls per category:

1. `list=categorymembers` to enumerate article titles in the category.
2. `prop=extracts&explaintext=1` in batches of 20 titles to pull plain text.

Both are public, need no key, and are rate-limited politely at one request per second with a descriptive
`User-Agent` as Wikipedia's etiquette requires.

### Reproducibility — the part that is easy to get wrong

Wikipedia changes. An ingest run in October and a re-run in January will not produce the same corpus, which
would make every number in our README unreproducible and quietly invalidate the whole measurement.

Three mitigations, in order of strength:

1. **Record the revision ID of every article fetched** (`prop=revisions&rvprop=ids`) into the `articles`
   table. The corpus is then exactly identifiable after the fact, and any article can be re-fetched at the
   precise revision we used via `oldid=`.
2. **Commit the manifest, not the text.** `corpus_manifest.csv` — title, pageid, revid, category — is a few
   hundred kilobytes, well inside what a repository should hold, and makes the corpus reproducible without
   committing the corpus. This is the same move as the starter's OpenFlights step, one degree stronger.
3. **Cache raw responses to `raw/`**, gitignored. Re-running ingest does not re-fetch, so iteration on
   chunking or embedding costs no network time and no load on Wikipedia's servers.

The README then offers two paths, and says plainly which is which:

- `python -m python.ingest` — fetch the current Wikipedia, build a fresh corpus. Our numbers will not
  reproduce exactly, and that is expected.
- `python -m python.ingest --manifest corpus_manifest.csv` — fetch the exact revisions we used. Our numbers
  should reproduce.

Offering only the first would make the results unverifiable. Offering only the second would make the
project a museum piece. Both, clearly labelled, is the honest answer.

## Expected scale

| Quantity | Estimate | Basis |
|---|---|---|
| Articles | ~1,200 | 8 categories x 150 |
| Mean article length | ~3,500 words | Typical for non-stub Wikipedia articles; to be measured, not assumed |
| Chunks | ~12,000 | At ~300 words per chunk. Close to Kaj's ~10 per article estimate |
| Chunk text on disk | ~25 MB | 12,000 x 300 words x ~6 bytes |
| Vectors at 384 dims | **~18 MB** | 12,000 x 384 x 4 bytes |
| Vectors at 768 dims | ~37 MB | Same, doubled |

The vector sizes are load-bearing, not decoration. The server's default
`mhnsw_max_cache_size` is **16,777,216 bytes — 16 MB** (verified, file 09). At 384 dimensions we are
already slightly over it; at 768 we are more than double. So the index cannot be fully cached at default
settings either way, and `mhnsw_max_cache_size` becomes a parameter we must state and tune under A6. See
file 05.

## Two different sets of evaluation queries, and why they are not the same thing

This distinction is routinely muddled in RAG write-ups, and getting it right is cheap credibility.

**Set 1 — recall queries (for file 07).** 50+ natural questions. Their purpose is to compare the indexed
search against the exhaustive search. **No human-labelled correct answer is needed**, because the ground
truth *is* whatever brute force returns. Recall here measures the index against perfect retrieval with the
same embedding model — it is a question about MariaDB, not about the model.

**Set 2 — QA pairs (for file 08).** 30+ questions with a known answer and a known source chunk. These
measure whether the *whole pipeline* answers correctly, which depends on the embedding model, the chunking,
and the answering LLM as much as on the index. This set has to be built by hand or LLM-generated and then
human-checked, and it is much more expensive per item.

Keeping them separate means a bad recall number points at the index and a bad answer number points at the
pipeline. Conflating them produces a single number that explains nothing.

Both sets live in the database (`eval_queries`, `eval_qa_pairs`) and are committed as CSV, because they are
our own work product and small.

## Licensing

Wikipedia text is CC BY-SA 4.0. We are not redistributing it — the corpus is fetched, not committed, which
sidesteps the question. The README should nonetheless attribute Wikipedia and name the licence, and
generated answers cite article URLs. Costs one paragraph; omitting it on an open-source course would be a
poor look.
