# 04 — Chunking and the embedding model

Requirement A6 asks for "chunk size, embedding model and index parameters stated, with the reasoning." This
file is that reasoning. The numbers here are the starting configuration; file 07 defines the experiment that
confirms or revises them, and whichever we end up with, the README states the final values and why.

## Chunking

### Why chunk at all

An embedding is a fixed-size summary of its input. Embed an entire 3,500-word article into 384 numbers and
you get the article's average meaning — useful for "which article is about this topic", useless for "which
paragraph answers this question". The whole point of retrieval is to hand the answering model a short,
specific passage, so the unit we embed has to be roughly the size of the answer.

The trade-off runs in both directions:

- **Too large** — the embedding averages several topics together and the specific fact gets diluted. The
  chunk may still be retrieved, but the model has to find the answer inside a wall of text.
- **Too small** — the chunk loses the context that makes it interpretable. A sentence reading "He died there
  three years later" is unretrievable and unusable on its own.

### Decision

| Parameter | Value | Reasoning |
|---|---|---|
| Target chunk size | **300 words** | Comfortably inside the 512-token input limit of the candidate models (roughly 380 tokens of English), so nothing is silently truncated. Also about the length of a self-contained Wikipedia paragraph group. |
| Overlap | **50 words** (~17%) | A fact sitting on a chunk boundary would otherwise be split across two chunks and appear fully in neither. Overlap is the standard fix; 10-20% is the usual range and 17% sits inside it. |
| Boundary rule | **Never split mid-sentence** | Pack whole sentences until adding the next would exceed 300 words. A chunk truncated mid-clause embeds badly and reads worse when cited. |
| Section awareness | **Never span a section heading** | Wikipedia section headings are a free, human-authored signal that the topic has changed. Crossing one merges two topics into one embedding for no benefit. |
| Minimum chunk | **40 words** | Below that, discard. Wikipedia has many short stubs and navigation fragments which add noise and dilute recall. |
| Skipped sections | **See also, References, Notes, Footnotes, Citations, Sources, Bibliography, Further reading, External links** (and their subsections) | Added at implementation. These are link lists and citations, not prose; a long "See also" list clears the 40-word minimum and would otherwise be embedded as a chunk of bare article titles. |
| Run-on sentences | **Cut at word boundaries if one exceeds 300 words** | Added at implementation. The one exception to "never split mid-sentence": a flattened list or table with no full stops would otherwise exceed the model's 512-token limit and be silently truncated, which is worse. |
| Stored with each chunk | section heading, ordinal position, word count | The heading goes into the embedded text (see below); position and count are for analysis. |

### The one non-obvious choice: prepending context to the embedded text

We embed `"{article title} — {section heading}\n\n{chunk body}"` rather than the bare body, while storing
the bare body for display and citation.

The reason: a chunk from the Emperor Penguin article's "Breeding" section may never contain the words
"penguin" or "Antarctica". Embedded alone it is nearly unretrievable for the question "how do penguins
raise their young?". Prepending the title and heading restores exactly the context a human reader gets for
free from the page around them.

This is cheap, well-established, and measurable — and because it is measurable, it becomes an experiment
rather than an assumption. File 07 defines an A/B over it. If prepending does not help on our corpus, we
drop it and report that, which is a more interesting result than the version where it works.

**`chunk.py` must be a pure function with no I/O**, so this A/B costs a unit test rather than a re-fetch,
and so chunking is testable at all.

## The embedding model

### What the choice actually constrains

The model's output dimension becomes part of the schema: `VECTOR(384)` is not alterable without rebuilding
the table and re-embedding the entire corpus. The model also has to be identical at ingest and at query
time — embedding a question with a different model than the corpus produces vectors in an unrelated space,
and the search returns confident nonsense. There is no error for this. The model name therefore belongs
**in the database**, in a `corpus_meta` table, checked by the query path at startup.

### Local or hosted

| | Local (`sentence-transformers`) | Hosted API (OpenAI, Voyage, Cohere) |
|---|---|---|
| Quality | Good | Somewhat better |
| Cost | Free | Cents for our corpus, but needs a card |
| Reproducibility | A pinned version produces identical vectors forever | Models are updated without notice; vectors silently change |
| Works in CI | Yes | Needs a secret, and burns quota on every push |
| Teammates | Each installs once | Each needs their own key |
| Offline | Yes | No |
| Evaluator can run it | **Yes** | No — blocked at step one |

**Decision: local.** The deciding argument is the last row. Robert indicated the evaluation may later
actually run submitted solutions, and requirement A7 asks for an ingest that runs from the README. An
ingest that stops to ask for an API key fails that for every reader without one. Reproducibility is the
second argument and nearly as strong: our published recall numbers are only meaningful if someone else can
obtain the same vectors.

### Which local model

| Model | Dims | Size | Notes |
|---|---|---|---|
| `all-MiniLM-L6-v2` | 384 | ~90 MB | The default everyone reaches for. Fast, weakest of the three on retrieval. |
| **`BAAI/bge-small-en-v1.5`** | **384** | **~130 MB** | Trained specifically for retrieval, and markedly stronger than MiniLM on retrieval benchmarks at the same dimension. Expects a short instruction prefix on queries. |
| `all-mpnet-base-v2` | 768 | ~420 MB | Stronger than MiniLM, but doubles vector storage and index size. |

**Decision: `BAAI/bge-small-en-v1.5`, 384 dimensions.** It is purpose-built for retrieval, 384 dimensions
keeps the index roughly half the size of a 768-dimension alternative, and it runs on CPU in reasonable time
so CI and a laptop both cope.

Two caveats recorded honestly:

1. **The relative quality claim is from published benchmarks, not our measurement.** It should be checked
   on our own corpus, and file 07 defines that check. If MiniLM matches it on our data, we say so.
2. **BGE models expect an instruction prefix on the query side only** — the documented form is
   `"Represent this sentence for searching relevant passages: {query}"` — with passages embedded bare.
   Getting this asymmetry wrong degrades retrieval quietly. The exact prefix must be read from the model
   card at implementation time and stored in `corpus_meta` alongside the model name, because it is as much
   part of reproducing our vectors as the model itself.

### Normalisation: not needed, and verified

A common extra step is normalising vectors to unit length before storing them. **With cosine distance this
is unnecessary**, because cosine distance ignores magnitude by construction. Verified on the server:

```sql
SELECT VEC_DISTANCE_COSINE(VEC_FromText('[1,2,3]'), VEC_FromText('[2,4,6]'));
-- 0
```

Same direction, magnitudes differing by a factor of two, distance exactly zero.

Worth stating in the README for two reasons. It removes a step readers of other tutorials will expect and
wonder about. And it is a real consequence of the index/distance-function pairing: had we chosen a Euclidean
index, normalisation would have been **mandatory**, because Euclidean distance between unnormalised
embeddings is dominated by vector length rather than meaning. One line of DDL decides whether a whole
pipeline step is required — a good, concrete illustration of why limitation C3 matters.

## Batching and cost

12,000 chunks on CPU at batch size 32 should run in single-digit minutes; a GPU makes it seconds. Fast
enough that re-embedding the whole corpus to test a chunking change is a coffee break, not a blocker, which
is what makes the file-07 experiments affordable.

`embed.py` must show a progress indicator and be resumable — writing vectors to disk as it goes — so an
interrupted run does not start over. Readers judge an ingest that appears to hang.

## Configuration

Every number in this file lives in `python/config.py` and nowhere else:

```python
CHUNK_TARGET_WORDS   = 300
CHUNK_OVERLAP_WORDS  = 50
CHUNK_MIN_WORDS      = 40
PREPEND_TITLE        = True
SKIP_SECTIONS        = {"see also", "references", ...}
EMBED_MODEL          = "BAAI/bge-small-en-v1.5"
EMBED_DIMS           = 384
QUERY_PREFIX         = "Represent this sentence for searching relevant passages: "
```

Hard-coding any of these elsewhere makes the file-07 experiments impossible to run, so this is a review
check, not a style preference.
