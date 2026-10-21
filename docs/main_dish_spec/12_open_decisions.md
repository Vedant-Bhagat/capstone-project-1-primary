# 12 — Open decisions

What this spec deliberately does not settle. Each item says who decides, what the options are, and what the
recommendation is, so that a decision is a short conversation rather than a fresh analysis.

## D1 — Work distribution *(team, before M1)*

Explicitly deferred at Vedant's request. The pipeline does not split into three independent files the way
the starter did, so the split has to be along dependency lines instead.

The natural carve, with the caveat that **component B is the graded core** and the other two support it:

| Component | Contains | Depends on |
|---|---|---|
| **A — Ingest** | `fetch.py`, `chunk.py`, `embed.py`, `ingest.py`, the manifest | the schema only |
| **B — Schema and retrieval** | `schema.sql`, all four retrieval queries, the `EXPLAIN` analysis | nothing; must land first |
| **C — Evaluation** | ground truth, the sweep, tests, CI, `findings.md` | the fixture corpus |

Three sequencing facts that constrain any split:

1. **B must land first.** A and C both need tables to exist.
2. **A fixture corpus of ~100 chunks must be committed early**, or C is blocked behind A for as long as the
   ingest takes to build. This is why it is a named M1 deliverable.
3. **The README is not a fourth component.** Whoever owns a piece writes its section as they go. The starter
   ended with one person folding everyone's results into the README by hand, and it created the only merge
   conflicts the team had.

Also to settle: who reviews whose pull requests. D5 asks for reviews between contributors and it was the
team's weakest area in the starter. A fixed rotation decided now is easier than negotiating each time.

## D2 — Separate repository, confirmed? *(Vedant, before M0)*

File 01 concludes yes, because the evaluation prompt takes one declared area per README and the existing
repository is committed to area 2.

**Worth one question to the supervisor**, since he is the facilitator for submission mechanics and may have
his own expectation about how many repositories a team submits. The technical argument is one-sided; the
course-administration side is his to confirm. Cheap to ask, expensive to get wrong after M3.

## D3 — Embedding model *(whoever owns component A, at M1)*

File 04 recommends `BAAI/bge-small-en-v1.5` at 384 dimensions, local. The reasoning is in that file, and the
decision is effectively forced by requirement A7 — an ingest that stops to ask for an API key does not run
from the README.

What remains open is only the quality claim, which comes from published benchmarks rather than our data.
The file-07 experiment settles it on our corpus. If MiniLM matches BGE here, we say so and keep whichever is
simpler.

## D4 — Corpus categories *(decided 2026-10-21, team)*

**Decided: nine categories, up to 150 articles each, ~1,295 articles in total** (file 03 has the table and
the live counts). Four of the original eight were too thin to sample from and were replaced by topically
similar categories rather than by crawling subcategories. Each category is capped at 150 articles, longest
first, and an article in several categories belongs to the first in config order.

The constraints the choice had to meet, which still apply to any later swap:

- enough categories that retrieval has a genuine chance to be wrong
- each category selective enough to make the hybrid filter interesting (~10–15% of the corpus)
- a spread of difficulty, so per-category recall says something

At ~12% each, every category sits above the ~7% under-return crossover, so filtered queries rely on the
index hint (file 03).

## D5 — Answering model *(team, at M4)*

File 08 recommends Claude `claude-haiku-5-5`, configurable, optional. Needs a key, so: does anyone already
have one, or do we use a local model through Ollama for the default path?

Not urgent — M4 is late, and nothing before it depends on the answer.

## D6 — Whether to file the bug *(team, at M6)*

Gated on the file-09 checklist. The decision is not "is it a bug" but "have we verified it enough to put our
names on it", and R10 is the reason that distinction matters.

If it verifies: file it, and the Jira link goes in the README and every self-assessment. If it does not:
`docs/limitations.md` records what we saw and why it did not generalise, which is still a result.

## D7 — Whether to switch to the fallback *(team, end of M2)*

System-versioned tables remains the shortlist fallback. Realistically this is only switchable before
substantial implementation exists, so the decision point is the end of M2 and not later.

Switch only if vector search proves genuinely unworkable — not merely surprising. Surprises are the
deliverable here; Kaj said so explicitly. The bar for switching is something that blocks the area's own
criteria, such as being unable to build a working index at our corpus size at all.

## D8 — Revision pinning and the corpus manifest *(decided 2026-10-21, team)*

**Decided: every article is fetched by revision id, and the corpus is reproduced from a committed
manifest** (file 03, "Fetching" and "The manifest"). Articles are rendered with `action=parse&oldid=` and
converted by our own `htmltotext.py`, because the TextExtracts API silently ignores the requested revision.
`corpus_manifest.csv` records each article's category, pageid, revid, title, fetch time and a SHA-256 of its
text. `--manifest` re-fetches exactly those revisions and reports how many hashes match. Accepted
limitation: templates render with today's template code, so a reproduction can rarely differ in formatting.

## Stretch goals, if time somehow allows

In descending order of value, and all of them below the file-07 experiments in priority:

1. **Coarse-to-fine retrieval** — an `article_embeddings` table with its own vector index, to narrow to
   candidate articles before searching chunks. Directly exercises the one-index-per-table limitation (C1)
   and turns it from a constraint we worked around into a design we deliberately used. Best of the four.
2. **Corpus scaling curve** — recall and latency at 1k, 5k, 12k, 50k chunks. Answers "when does the index
   start to pay?", which is the R3 upside and a genuinely useful result for anyone evaluating the feature.
3. **`m` parameter sweep** — graph density against recall. Cheap, needs a rebuild per value.
4. **A pgvector comparison** — the most tempting and the least advisable. Needs two systems tuned fairly to
   be honest, and an unfair benchmark is worse than none. Only with a lot of spare time and an explicit
   statement of method.

## Questions worth putting to MariaDB

The Foundation's own channels are Zulip and Stack Overflow under the MariaDB tag, not GitHub — Kaj was
specific about that. Three questions are worth asking once we have M2's evidence:

1. Is the filtered-search shortfall in file 09 known behaviour, an accepted consequence of post-filtering,
   or a defect? Asking before filing a Jira issue is both politer and faster than the reverse.
2. Is there a planned mechanism for pre-filtered vector search — the equivalent of a filtered HNSW search —
   or is indexing the filter column and accepting an exhaustive scan the intended pattern?
3. Is `mhnsw_default_distance` defaulting to `euclidean` deliberate, given that cosine is the usual choice
   for text embeddings?

All three are better asked with our measurements in hand than before, which is why they sit at M2 rather
than now.
