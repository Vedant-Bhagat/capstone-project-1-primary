# 11 — Deliverables and milestones

## The repository

A **new, second public repository**, because the evaluation prompt requires one declared area per README
(file 01, A2) and the existing one is committed to area 2.

**Created 2026-10-21.** This specification now lives in it.

| | |
|---|---|
| Repository | **https://github.com/Vedant-Bhagat/capstone-project-1-primary** |
| Starter repository | https://github.com/Vedant-Bhagat/capstone-project-1 (area 2) |
| Owner | `Vedant-Bhagat`; Janhavi and Pranesh to be added as collaborators |
| Default branch | `main` — the evaluation prompt returns `NOT ASSESSABLE` if the code is not on `main` |
| First line of README | the exact area-4 declaration from file 01 — in place |
| Local working copy | `todo/capstone-project-1-primary/`, a sibling of `todo/capstone-project-1/` so both projects share one working folder |

**Cross-link both repositories.** Each README gets a line naming the other and saying which course
deliverable it is — starter or main dish. Costs two lines and stops either repository looking like an
orphaned fragment to a reader who arrives at one and not the other. Done in both as of 2026-10-21.

### Already in place

- `README.md` with the area declaration, the non-technical explanation (B5), the version floor, and the
  verified findings from file 09 surfaced rather than buried
- `CONTRIBUTING.md`, carrying the starter's conventions forward plus four rules specific to this project
- `.gitignore`, including the fetched corpus and model weights, which must not be committed (E6)
- `AI_USE_LOG.md` (D3) and `self_assessment/` (D2), with the starter's log and earlier weeks cross-linked
  rather than duplicated

What remains for M0 is the schema and CI.

## File inventory

Marked by what each one satisfies, so nothing is built that nothing asks for.

| Path | Satisfies |
|---|---|
| `README.md` | A1, A2, A6, A8, B5 — the single most heavily graded file |
| `requirements.txt` | pinned deps, E6-adjacent reproducibility |
| `.env.example` | connection config; makes the no-API-key path obvious |
| `python/config.py` | A6 — every tunable in one place |
| `python/fetch.py` | A3, E6 — corpus fetch, cached, resumable |
| `python/chunk.py` | A6 — pure function, unit-tested |
| `python/embed.py` | A6 |
| `python/ingest.py` | A7 — the one command the README asks a reader to run |
| `python/answer.py` | A7, B4 — the query interface |
| `sql/schema.sql` | A3, C1, C2 — the DDL, idempotent |
| `sql/retrieval/semantic.sql` | A3 |
| `sql/retrieval/hybrid_filter.sql` | **A4, B3** |
| `sql/retrieval/hybrid_fulltext.sql` | A4, B3 |
| `sql/retrieval/under_return.sql` | B6 — the documented defect |
| `sql/evaluation/ground_truth.sql` | **A5** |
| `sql/evaluation/recall_sweep.sql` | **A5**, B2 |
| `sql/evaluation/tests.sql` | E3 |
| `.github/workflows/ci.yml` | E2 |
| `corpus_manifest.csv` | E6 — reproducibility by revision id |
| `eval_queries.csv`, `eval_qa_pairs.csv` | A5 |
| `docs/findings.md` | A5, E5 |
| `docs/limitations.md` | B6, C1–C3 |
| `docs/bug_report_draft.md`, `docs/jira_submissions.md` | the contribution to MariaDB |
| `AI_USE_LOG.md` | D3 |
| `self_assessment/` | D2 |
| `CONTRIBUTING.md` | D4 |

## Milestones

Each is defined by something demonstrable, not by effort spent. No dates — the schedule depends on the
distribution decision in file 12 and on the remaining course calendar.

### M0 — Foundation
*Done when: the repository exists and CI runs green on an empty schema.*

- Repository created, area declaration on line 1, cross-links in place
- `schema.sql` complete and idempotent
- CI workflow installing MariaDB 11.8 / 12.3 / current, creating the schema
- `AI_USE_LOG.md`, `self_assessment/`, `CONTRIBUTING.md` carried over from the starter

Deliberately first and deliberately small. It unblocks everyone else, and it is where the file-09 probe
findings get encoded in DDL while they are fresh.

### M1 — Corpus in the database
*Done when: `python -m python.ingest` on a clean machine produces ~13,000 indexed chunks (an unverified
estimate; replace with the measured count after the first full ingest).*

- `fetch.py`, `chunk.py`, `embed.py`, `ingest.py`
- `corpus_manifest.csv` committed
- `corpus_meta` populated
- Chunking unit tests
- **Measured**: index-build-before-load vs after-load (the file-02 hypothesis)
- **A committed fixture corpus of ~100 chunks** so M2 and M3 are not blocked on a full ingest

### M2 — Retrieval
*Done when: all four queries run and `EXPLAIN` is captured for each.*

- `semantic.sql`, `hybrid_filter.sql`, `hybrid_fulltext.sql`, `under_return.sql`
- The `EXPLAIN` contrast — unfiltered uses the vector index, filtered uses the btree — captured and
  explained. This is the depth evidence.
- `answer.py` working with `--no-llm`
- **Re-verify file 09's finding 7 at 384 dimensions.** This is the gate on the bug report, and it belongs
  here because this is the first point at which real embeddings exist.

### M3 — Measurement
*Done when: the recall/latency table is filled in with real numbers.*

- `ground_truth.sql`, `recall_sweep.sql`
- 50+ evaluation queries committed
- The `ef_search` sweep, with the smallest `ef_search` reaching recall@10 ≥ 0.98 identified
- Per-category recall
- The brute-force comparison — does the index earn its place?
- `tests.sql` with T1–T8, gating CI
- `docs/findings.md`

The project's core. If time runs out, it runs out after this, not during it.

### M4 — Generation
*Done when: `python -m python.answer "..."` returns a cited answer.*

- `answer.py` with the LLM path and the prompt from file 08
- `eval_qa_pairs.csv`
- Abstention correctness and citation-faithfulness checks
- hit@k reported alongside recall@k, with the distinction explained
- Answer scoring, LLM-judge with human validation on a subset

### M5 — Write-up
*Done when: the evaluation prompt scores ≥ 32/40 with no criterion below 7.*

- README: declaration, the non-technical explanation (B5), all stated parameters with reasoning (A6),
  results tables, the "what database-native gave us" section (A8)
- `docs/limitations.md`
- Reproduction check: one contributor follows the README on a machine that has never run the project
- Run the evaluation prompt; act on what it says
- Self-assessments current; every contributor has reviewed someone else's PR (D5)

### M6 — The optional contribution
*Done when: either a Jira issue exists, or a written decision not to file one.*

- Complete the file-09 verification checklist
- Search Jira for duplicates — Robert asked for this explicitly
- Minimal reproduction case
- File the issue, or record why not

Also worth the look: MariaDB's vector documentation is thin, and the Foundation does accept markdown docs
through GitHub. Anything we learn that is absent from the docs — the `euclidean` default, the metric-mismatch
fallback to a table scan, the filtered-search behaviour — is candidate material for a documentation PR. That
is the one path by which this work can land in MariaDB's own repository with our names on it, and unlike the
server-patch route it is actually open to us.

## Acceptance criteria

The list in file 01 section F, unchanged. Nine items, and item 9 — the evaluation prompt score — is the one
that should be checked at every milestone rather than at the end, for the reason given in R9.
