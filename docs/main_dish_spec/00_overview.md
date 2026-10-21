# 00 — Overview

## The problem this feature solves

Ordinary SQL search is literal. `WHERE body LIKE '%flightless bird%'` finds rows containing that phrase and
nothing else. Ask it about flightless birds and it will not return the article on penguins, because the
article says "penguins are unable to fly" and shares no words with the question.

Semantic search fixes that. You convert text into a list of numbers — an **embedding** — using a model
trained so that text with similar meaning gets similar numbers. "Flightless bird" and "unable to fly" land
near each other in that number space even though they share no words. Searching then becomes a geometry
problem: find the stored vectors closest to the query vector.

Until recently, doing this meant running a **second database** next to your real one — Pinecone, Qdrant,
Weaviate, Milvus, or FAISS inside a Python process. That is two systems to deploy, two to back up, two to
keep in sync, and a permanent split where your facts live in one place and your meanings live in another.

MariaDB 11.8 LTS removed the need for the second system. A `VECTOR` column holds the embedding, a
`VECTOR INDEX` makes the search fast, and `VEC_DISTANCE_COSINE()` measures closeness. It is one database,
one query language, one backup.

## What we are building

A question-answering system over Wikipedia where every retrieval step is a single SQL statement.

```
                        ┌─────────────────── ingest (run once) ───────────────────┐
                        │                                                         │
  Wikipedia  ──────▶  fetch  ──▶  chunk  ──▶  embed  ──▶  INSERT into MariaDB
  (>= 1000 articles)            (~10 per      (model      (VECTOR column +
                                 article)      -> 384      VECTOR INDEX)
                                               numbers)
                        │                                                         │
                        └─────────────────────────────────────────────────────────┘

                        ┌──────────────────── query (per question) ───────────────┐
                        │                                                         │
  "why can't          embed the            SELECT ... ORDER BY              top k
   penguins fly?"  ──▶ question       ──▶  VEC_DISTANCE_COSINE(...)   ──▶  chunks
                       (same model)        LIMIT k                          │
                                           + ordinary WHERE predicates      │
                        │                                                   ▼
                        │                                          prompt an LLM
                        │                                                   │
                        └───────────────────────────────────────────────────┼─────┘
                                                                            ▼
                                                            cited answer in prose
```

Six stages. Stage four is the one being graded, and files 05–07 of this spec are about it.

## The "explain it to a parent" version

Kaj Arnö told us directly what good documentation looks like for this area:

> *"The place where you explain things is the readme… if this is something that you can show to your
> sibling or your parent that is not into AI and they understood roughly what it's about, then you got it."*

So here is that version, and it belongs near the top of the final README:

> Imagine every paragraph of Wikipedia being given a position on an enormous map — not a map of the
> world, but a map of meaning, where paragraphs about similar things sit near each other. Paragraphs
> about penguins sit near paragraphs about ostriches, because both are about birds that do not fly, even
> though neither mentions the other.
>
> When you ask a question, we work out where your question sits on that map, and hand back the paragraphs
> standing nearest to it. Then we give those paragraphs to an AI and ask it to write the answer using only
> them, so it can show you where each part of the answer came from.
>
> The interesting bit is that the whole map lives inside the database, next to the ordinary data. That is
> new. It means you can ask "find me paragraphs that *mean* roughly this, but only from physics articles
> edited since 2024" in a single question — because the thing that understands meaning and the thing that
> knows the edit dates are, for the first time, the same thing.

## What is actually hard about it

Not the plumbing. Fetching Wikipedia, chunking text and calling an embedding model are solved problems with
libraries. If that were the project it would not be worth a semester.

The hard part is that **the index is approximate**. HNSW — Hierarchical Navigable Small World — is fast
precisely because it does not compare your query against all 10,000 rows. It navigates a graph, visiting a
few hundred candidates and returning the best it found. Usually that is the true answer. Sometimes it is
not, and nothing tells you when.

So the real deliverable is a measurement: *how often does the fast answer differ from the correct one, and
what does closing that gap cost?* There is a server variable, `mhnsw_ef_search`, that controls how many
candidates the search visits. Turn it up and accuracy rises and speed falls. The project's central artifact
is the curve that relates the two, on our data, with our embedding model.

Kaj set the bar at **98% recall**, and said 95% is *"still frequently not considered acceptable"*. That is a
specific, falsifiable target, which is most of why we chose this area over the others.

## How this relates to the starter

The starter (area 2, custom aggregate functions, in the repository root of this project) made one
intellectual move: take a MariaDB feature, build the honest comparison, report what the feature costs. The
headline result was unflattering — our custom aggregate ran 2.4× slower than writing the formula out — and
we published it as the finding rather than hiding it.

The main dish is the same move at a larger scale. Same discipline: build the baseline first, measure
against it, report the curve rather than the flattering point on it. The starter was the rehearsal.

## Scope boundary

To be explicit about what this project is **not**:

- Not a chatbot with conversation history, user accounts or a polished UI.
- Not a comparison of embedding models. We pick one, justify it, and move on.
- Not a benchmark of MariaDB against pgvector or Pinecone. Tempting, but it needs three systems tuned
  fairly to be honest, and a badly-run comparison is worse than none. Noted in file 12 as a stretch goal.
- Not a general-purpose RAG library.

The one sentence that defines scope: **everything we build exists to make a claim about MariaDB's vector
search measurable.** Anything that does not serve that gets cut.
