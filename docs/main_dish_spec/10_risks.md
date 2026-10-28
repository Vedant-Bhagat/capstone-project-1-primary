# 10 — Risks

Ordered by expected damage. Each carries the signal that tells us it is happening and the response.

## R1 — Scope creep into the Python half

**The most likely way this project goes wrong.** Three visible components, only one of which is graded on
MariaDB depth. Building a nice chunker, a nice CLI, a nice evaluation framework is satisfying, and none of
it moves the criterion that can fail us outright (A9).

- *Signal*: a week passes in which no file under `sql/` changed.
- *Response*: the `sql/` directory is the project. Weekly check — if it did not grow, the week was
  misspent. The scope-exclusion list in file 08 is there to be enforced, not admired.

## R2 — Recall never reaches 98%

Kaj's bar is specific and we cannot be sure in advance that it is reachable on our corpus with our model.

- *Signal*: the file-07 sweep plateaus below 0.98 even at `ef_search = 1000`.
- *Response*, in order: raise `mhnsw_default_m` and rebuild; raise `mhnsw_max_cache_size` in case the
  ceiling is I/O; check for duplicate or near-duplicate chunks, which make top-k ordering unstable and
  depress apparent recall for reasons that have nothing to do with the index. If recall still plateaus,
  **report the plateau as the finding**, with the diagnosis. A measured, explained failure to reach 98%
  is a legitimate result for a feature a year old, and is explicitly covered by Kaj's B6. Quietly reporting
  recall@50 instead of recall@10 to clear the bar is not.

## R3 — The corpus is too small for the index to matter

If brute force over ~13,000 chunks is already fast, HNSW has nothing to prove and the central comparison is
hollow. Kaj warned about exactly this when he set the 1,000-article floor.

- *Signal*: the brute-force row in the file-07 table is within noise of the indexed rows.
- *Response*: grow the corpus — another 1,000 articles is one more ingest run, and the pipeline is built for
  it. Alternatively, report the crossover: *at what corpus size does the index start to pay?* That is a
  better finding than the one we set out to produce, so this risk has an upside.

## R4 — The under-return defect does not reproduce on real embeddings

As of 2026-10-28 the defect reproduces at 384 dimensions on synthetic vectors, varying per index build, and
`mhnsw_ef_search` does not mitigate it (finding 7c). What remains unverified is **real embeddings**: the
fixture's clusters are near-orthogonal, and real BGE vectors may not separate sharply enough to starve the
graph walk. The schema in file 05, a planned CI test (T7), and a possible bug report all rest on it.

- *Signal*: the real corpus returns the full `k` with a filter pointing away from the query, across many
  index builds.
- *Response*: this is **good news**, not a setback, and it costs nothing we have already spent. Rewrite the
  finding as "reproducible at 384 dimensions on near-orthogonal synthetic clusters, absent on real
  embeddings", which is itself a publishable result — it would locate the boundary rather than lose the
  finding. Nothing in the design changes: the denormalisation and `FORCE INDEX` are harmless either way, and
  `FORCE INDEX` is independently justified by the plan flip at 11% selectivity (7b), which *is* confirmed at
  384 dimensions.
- *What would be a genuine setback* is the reverse — discovering it on real embeddings **after** publishing
  recall numbers measured without `FORCE INDEX`, because every one of those numbers would be wrong rather
  than merely incomplete. That is why T7 exists and why file 07 must not treat `ef_search` as the remedy.

## R5 — Vector search is a year old

The least mature feature on the list, by our own assessment in the shortlist. We have already hit one
probable defect in a two-hour probe, which is itself evidence for this risk.

- *Signal*: more surprises of the file-09 kind.
- *Response*: Kaj told us directly that hitting an undocumented limitation is not a problem provided we
  document it. So each surprise is logged in `docs/limitations.md` as it is found, with a reproduction. The
  risk is real but it is pre-converted into a deliverable, which is most of why this area was chosen.
- *Secondary*: system-versioned tables remains the fallback in the shortlist. Realistically the switch is
  only viable before any substantial implementation exists, so the decision point is the end of milestone 2
  (file 11) and not later.

## R6 — Three contributors, one tightly-coupled pipeline

The starter split cleanly into one file each. This does not: the schema, the retrieval queries and the
evaluation harness all depend on each other, and on the ingest existing first. Two people blocked on a
third is the default outcome.

- *Signal*: a contributor's branch has no commits for a week, or two people edit the same file.
- *Response*: the schema and a **small committed fixture corpus** land first and early, so the retrieval and
  evaluation work can proceed against real rows without waiting for the full ingest. Beyond that, the
  distribution is deliberately left to file 12 and a team conversation rather than decided here.

## R7 — Reproducibility rot

Wikipedia changes, models get updated, dependencies drift. Our published numbers become unverifiable and
the usability criterion suffers.

- *Signal*: an ingest re-run produces a different corpus size.
- *Response*: the three mitigations already specified — committed revision-id manifest (file 03), pinned
  model and parameters recorded in `corpus_meta` (file 05), exact dependency pins (file 02). Plus the CI
  run, which is a continuous reproducibility test: if a fresh machine stops being able to build the project,
  CI says so the same day.

## R8 — Time

Vector search, hybrid full-text fusion, an evaluation harness, a RAG pipeline and a README that explains all
of it, alongside the rest of the semester.

- *Signal*: milestone 3 in file 11 slipping.
- *Response*: cut in this order — reranking experiments, the chunk-size sweep, the model comparison, the
  RRF full-text query, LLM-as-judge answer scoring. **Never cut**: the recall sweep, the brute-force
  baseline, the hybrid filter query, or the README explanation. Those four are requirements A3–A5 and B3,
  and without any one of them the project does not satisfy its area.

## R9 — The LLM evaluator, not a human, reads the repository

MariaDB scores with a published prompt. It rewards an explicit, well-structured README and will not infer
what we meant. The starter taught us this expensively: 21/40 before we addressed the criteria directly,
34/40 after, on substantially the same underlying work.

- *Signal*: none until it is too late.
- *Response*: run the evaluation prompt against the repository at every milestone, not once at the end.
  It is free and it takes minutes. Specifically: the area declaration on line 1, the stated parameters with
  reasoning, the measured numbers in tables, and the "what the database-native approach gave us" section
  (A8) all exist because the prompt asks for them, and each should be in place before the milestone that
  depends on it.

## R10 — Overclaiming the bug

The temptation to write up file 09 as "we found a bug in MariaDB" before it is verified at scale, on other
versions, and on another platform. If MariaDB look at it and it does not reproduce, we lose more credibility
than the finding was ever worth.

- *Signal*: the words "MariaDB has a bug" appearing anywhere without the caveats attached.
- *Response*: the checklist at the end of file 09 is a gate, not a suggestion. Until every box is ticked the
  finding is described as "observed on MariaDB 12.3.3 on Windows with synthetic data", in those words. Robert
  also asked explicitly that Jira be searched for duplicates before filing, and that is part of the gate.
