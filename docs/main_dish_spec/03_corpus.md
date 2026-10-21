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

Fetch up to 150 articles from each of nine Wikipedia categories, in this order:

| Category key | Wikipedia category | Articles (live, 2026-10-21) | Fetched | Why it is in the set |
|---|---|---|---|---|
| `birds` | Birds described in 1758 | 463 | 150 | Dense, factual, and includes the flightless birds (penguins, ostrich) whose example makes semantic search obvious to a non-technical reader |
| `physics` | Concepts in physics | 113 | 113 | Abstract language; hard for literal search, easy for semantic |
| `composers` | Composers for piano | 458 | 150 | Biographical, lots of dates and places — good for hybrid date filters |
| `prog_lang` | Programming languages | 175 | 150 | Technical vocabulary that overlaps heavily between articles; a stress test for retrieval precision |
| `space_telescopes` | Space telescopes | 138 | 138 | Narrative and chronological |
| `diseases` | Infectious diseases | 144 | 144 | Terminology-heavy; where an embedding model's domain coverage shows |
| `political_philosophy` | Concepts in political philosophy | 248 | 150 | Abstract and contested vocabulary; with `ethics`, the fuzziest part of the set |
| `ethics` | Concepts in ethics | 178 | 150 | Close neighbour of `political_philosophy`, so the retriever has a real chance to confuse the two |
| `architecture` | Architectural styles | 197 | 150 | Visual and descriptive language |

"Articles" counts pages directly in the category (subcategories are not followed), excluding
List/Lists/Outline/Index/Glossary/Timeline pages, as returned by `list=categorymembers` on the date shown.
They will drift as Wikipedia changes; the manifest records what was actually used.

Nine categories capped at 150 is ~1,295 articles, clearing B1 with margin for articles that fail to fetch or
produce no chunk above the minimum size.

**Why these categories and not the original eight.** The first draft named Birds, Classical composers,
Human spaceflight and Philosophical concepts. Measured live, they hold 28, 22, 85 and 5 articles directly,
too few to sample from. Each was replaced by a topically similar category rather than by crawling
subcategories, which would have pulled in loosely related pages. Philosophy became two categories, since no
single one was both large enough and coherent. Space Shuttle missions (137 articles) was rejected for
spaceflight because its near-identical "STS-xx" articles make a poor semantic-search test.

### Fetch cap: 150 per category, longest first

When a category has more than 150 eligible articles, take the **150 with the largest source size** (`length`
from `prop=info`, in bytes of wikitext), breaking ties by lower `pageid`. Longest-first favours substantial
articles over stubs, which produce one short chunk or none. Source size is measured at fetch time, so a
fresh fetch may pick a slightly different 150; the manifest pins the selection that was actually used.

### Overlap rule: first category in config order wins

An article can sit in more than one chosen category (e.g. `political_philosophy` and `ethics` share 16
articles), but the schema gives each article exactly one `category`. So it is assigned to the **first**
category in config order that contains it, and is never stored twice or counted twice.

- **The order** is the order of the category list in `python/config.py`, which matches the table above.
- **The assignment** happens in `fetch.py`: categories are processed in that order, an article already
  assigned to an earlier category is skipped, and the 150-article cap is applied *after* skipping. A later
  category therefore still gets its full 150 if it has enough articles left.
- **"Assigned" means membership, not selection.** An article is claimed by every earlier category that
  *contains* it, checked before that category's cap is applied. An article cut from an earlier category by
  the cap is therefore excluded from every later category too; it is not offered to the next one.

**Why nine and not one.** A single-topic corpus makes retrieval look better than it is: if everything is
about birds, any bird-related chunk is a plausible hit and precision is unmeasurable. Multiple distinct
categories create genuine opportunities for the retriever to be wrong, which is the only way the recall
number means anything. It also gives the category filter real selectivity — each category is about 9–12% of
the corpus, which is the range where the hybrid query is interesting and, as file 09 shows, where the
under-return defect bites.

**Why these are deliberately uneven in difficulty.** `political_philosophy`, `ethics` and `physics` should
retrieve worse than `birds` and `composers`. If they do, we have a per-category recall table, which is a more
honest and more interesting result than one global number. If they do not, that is also worth reporting.

### Category size is a correctness constraint, not a presentation choice

Nine categories capped at 150 means each is ~11.6% of the corpus (150 of ~1,295; `physics`, at 113
articles, is ~8.7%). **Every one of them is above the threshold where MariaDB's optimizer stops
pre-filtering a vector query and starts silently under-returning** — the crossover is around 7%, and
finding 7b in file 09 has the measurement.

Two responses were considered:

1. **Force the index in every filtered query** (file 06). This is the real fix and it works regardless of
   category size. **It is the one we rely on.**
2. **More, smaller categories.** Sixteen categories at ~6% each would sit below the crossover, so the safe
   plan would also be the one the optimizer picks unaided. **Not taken:** the team chose the nine
   categories above, at up to 150 articles each.

The consequence is that the index hint is the only protection. A reader who copies a filtered query
without it can silently get too few rows on this corpus, so every filtered query we publish carries it.

The crossover was measured on the 3-dimensional synthetic harness and is likely cost-model dependent, so it
must be re-measured on the real corpus before the category sizing is considered settled. That check is on
the verification checklist at the end of file 09.

## Fetching

Wikipedia's action API. Public, no key, rate-limited politely at one request per second with a descriptive
`User-Agent` as Wikipedia's etiquette requires (both set in `python/config.py`). Every article is fetched
**by revision id**, never as "the current version":

1. **List each category with sizes and current revids** — `fetch.category_members`, one request per 500
   members: `generator=categorymembers&prop=info|revisions&rvprop=ids`. This returns each article's
   `pageid`, `title`, `length` (wikitext bytes, for the cap) and the revid current at listing time, so
   pinning a revision costs no extra requests.
2. **Render that exact revision** — `fetch.fetch_article(pageid, revid)`, one article per request:
   `action=parse&oldid=<revid>&prop=text`. The pageid and revid in the response must match those asked for,
   or the fetch fails. A revision that has since been deleted or hidden returns `None`; the article is
   skipped and reported. At one request per second, ~1,300 articles is a ~22-minute first fetch.
3. **Convert the HTML to plain text** — `python/htmltotext.py`, standard library only. It drops citation
   markers, edit links, tables, images, navigation boxes, infoboxes, notices and the reference list, keeps
   maths as its LaTeX source, and writes headings as `== Heading ==` lines for `chunk.py`. Checked on the
   same revision of Emperor penguin, its output matches the old TextExtracts output sentence for sentence
   and produces identical chunks.
4. **Cache by revid** — the rendered HTML, not the converted text, goes to `raw/revisions/<revid>.json`
   (gitignored), so a converter change costs no re-fetch. A revision's content never changes, so this cache
   never goes stale.

**Why not the TextExtracts API.** The first implementation used `prop=extracts&explaintext=1`. Checked
against the live API, it serves only the current text: asked for an old revision via `revids=`, it returns
today's article *while still reporting the old revid*, and it has no `oldid` parameter at all. Revision
pinning was impossible with it, and the reproduction path would have been silently wrong, so it was dropped.

### Reproducibility — the part that is easy to get wrong

Wikipedia changes. An ingest run in October and a re-run in January will not produce the same corpus, which
would make every number in our README unreproducible and quietly invalidate the whole measurement.

Three mitigations, in order of strength:

1. **Fetch and record by revision id.** Every article's revid is stored in `articles.revid` and in the
   manifest. The corpus is then exactly identifiable after the fact, and every article can be re-rendered at
   the precise revision we used.
2. **Commit the manifest, not the text.** `corpus_manifest.csv` (below) is about 200 KB, well inside what a
   repository should hold, and makes the corpus reproducible without committing it. This is the same move as
   the starter's OpenFlights step, one degree stronger.
3. **Cache raw responses to `raw/`**, gitignored. Re-running ingest does not re-fetch, so iteration on
   chunking or embedding costs no network time and no load on Wikipedia's servers.

**Known, accepted limitation: templates render as they are today.** Pinning by revid fixes the article's
own wikitext exactly. But the HTML is rendered at fetch time, and templates called from that wikitext run
with *today's* template code, not the code current when the revision was saved. The common case is
`{{convert}}` producing "100 cm (39 in)"; date and number formatting templates are others. So reproducing an
old corpus gets the same prose, but in rare cases a differently formatted number or phrase, if a template
itself has changed since. The only exact alternative is converting raw wikitext ourselves, which means
reimplementing templates: one revision of Emperor penguin alone makes 180 template calls, 51 of them
`{{convert}}` inside sentences. We judged that not worth it. The manifest's content hash makes any such drift
**visible** instead of silent.

### The manifest

`corpus_manifest.csv` at the repository root, committed. It lists exactly the articles stored in the
`articles` table: the resolved list after the cap, the overlap rule, and any skipped revisions.

| Column | Example | Meaning |
|---|---|---|
| `category` | `birds` | Category key from `config.CATEGORIES` |
| `pageid` | `223204` | Wikipedia page id |
| `revid` | `1377089235` | The exact revision rendered |
| `title` | `Emperor penguin` | Title at fetch time. It is part of the embedded text (`04_chunking_embedding.md`), so reproduction uses this, not the page's current title |
| `fetched_at` | `2026-10-21T14:05:09Z` | UTC time the revision's HTML was first fetched, stored in its `raw/revisions/` cache record |
| `text_sha256` | `9f86d0…` (64 hex) | SHA-256 of the converted plain text, UTF-8 encoded: the exact input to `chunk.py` |

Format: UTF-8, a header row, Python `csv` default quoting (titles can contain commas and quotes), rows
ordered by config category order and then `pageid`, so two manifests of the same corpus diff cleanly. The
file is written atomically (temp file, then rename).

**Why a content hash.** The revid pins the source; the hash verifies the result. It costs one SHA-256 per
article, and it is the only way a reproduction can say whether it actually matched instead of assuming it.
It hashes the plain text rather than the HTML because the text is what reaches chunking and embedding; a
markup-only difference that changes no text should not count as a mismatch. The hash also depends on
`htmltotext.py`, so a converter change shifts hashes even for identical HTML. That is correct, since the
chunks would change too. Because the manifest is committed with the code that produced it, git history
shows which converter version a hash belongs to.

**Mode 1: fresh corpus** (`python -m python.ingest`, no manifest given):

1. `select_articles()`, which lists each category in config order and applies the cap and the overlap rule.
2. `fetch_article(pageid, revid)` for each selected article; skip and report any that return `None`.
3. Chunk, embed and store.
4. Only after the database writes succeed, write `corpus_manifest.csv`, replacing any existing one, with one
   row per stored article. A fresh manifest is committed when results from that corpus are published,
   together with them.

**Mode 2: reproduction** (`python -m python.ingest --manifest corpus_manifest.csv`):

1. Read the manifest. **Skip `category_members` and `select_articles` entirely.** The manifest already is
   the resolved article list, and re-running the selection today would pick different articles.
2. For each row, `fetch_article(pageid, revid)`, taking `category` and `title` from the row, not from the
   API.
3. Compare the SHA-256 of the converted text with `text_sha256`. A mismatch is a warning, not an error,
   since the template limitation above makes it occasionally expected. The article is still ingested. A
   revision that is gone is a warning too, and that article is skipped.
4. Never write the manifest. End with a summary line: `N of M articles identical, K differ, J unavailable`,
   listing the titles in the last two groups. All identical means the text going into chunking was
   reproduced exactly. Chunking is deterministic from there; embedding is too for a pinned model, up to
   floating-point differences across hardware or library versions, so recall numbers can still move very
   slightly.

The README then offers both modes, and says plainly which is which:

- `python -m python.ingest` builds a fresh corpus from the current Wikipedia. Our numbers will not
  reproduce exactly, and that is expected.
- `python -m python.ingest --manifest corpus_manifest.csv` renders the exact revisions we used. Our numbers
  should reproduce, and the summary line says how closely.

Offering only the first would make the results unverifiable. Offering only the second would make the
project a museum piece. Both, clearly labelled, is the honest answer.

## Expected scale

| Quantity | Estimate | Basis |
|---|---|---|
| Articles | ~1,295 | 9 categories, capped at 150 (table above) |
| Mean article length | ~3,500 words | Typical for non-stub Wikipedia articles; to be measured, not assumed |
| Chunks | ~13,000 (unverified) | Kaj's ~10 per article estimate. **Not measured:** the one real article chunked so far (Emperor penguin) gave 26. Replace with the measured count after the first full ingest |
| Chunk text on disk | ~23 MB | 13,000 x 300 words x ~6 bytes |
| Vectors at 384 dims | **~20 MB** | 13,000 x 384 x 4 bytes |
| Vectors at 768 dims | ~40 MB | Same, doubled |

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
