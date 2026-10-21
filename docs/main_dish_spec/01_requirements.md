# 01 — Requirements, traced to source

Every requirement below carries its source. Requirements with no source are our own engineering standards
and are marked `[ours]`. Nothing here is invented to look thorough: if it is listed, something or someone
asks for it.

## Sources

| Tag | Source |
|---|---|
| `[area]` | MariaDB's stated criteria for area 4, https://mariadb.org/bachelor_hackathon_2026-09/ |
| `[eval]` | The LLM evaluation prompt published at the bottom of the same page, last updated 2026-09-04 |
| `[kaj]` | Kaj Arnö, MariaDB Foundation Q&A session, 17.09.2026, and the follow-up email answers |
| `[robert]` | Robert Silén, same session |
| `[course]` | `todo_cp_01.pdf`, `todo_cp_02.pdf`, `team_guide.pdf` |
| `[ours]` | Our own standard, carried over from the starter |

## A. Hard requirements — failing any of these costs us the grade outright

| # | Requirement | Source |
|---|---|---|
| A1 | Public GitHub repository, code on the `main` branch, `README.md` at the root. | `[eval]` |
| A2 | **First line of the README declares exactly one area**, in the prescribed form (see below). The evaluation prompt returns `NOT ASSESSABLE` if no area is named. | `[eval]` |
| A3 | A `VECTOR` column with an index over a real Wikipedia corpus, queried with `VEC_DISTANCE_COSINE`. | `[area]` |
| A4 | Semantic search and ordinary SQL predicates **in the same statement**, joined back to relational tables. | `[area]` |
| A5 | Recall and latency reported against **a ground-truth set we built** — "not adjectives". | `[area]` |
| A6 | Chunk size, embedding model and index parameters **stated, with the reasoning**. | `[area]` |
| A7 | An ingest that runs from the README, and a query interface a reader can try. | `[area]` |
| A8 | The README explains what the database-native approach gave us that a separate vector store would not. | `[area]` |
| A9 | MariaDB depth must not score 0-2, which is an automatic `FAIL` regardless of the other three scores. | `[eval]` |

### The declaration line (A2)

The README's first line must read, exactly:

```
A project for area 4, "Vector search and RAG, natively" for the MariaDB student database projects, 2026-09
```

with "MariaDB student database projects, 2026-09" linked to
`https://mariadb.org/bachelor_hackathon_2026-09/`.

**Consequence — this needs its own repository.** The page says "Pick one area and say so on the first line
of your README." Our existing repository already declares area 2 for the starter. One README cannot
truthfully declare two areas, and whichever it declares is the only one scored. So the main dish goes in a
**second public repository**, cross-linked with the first. See file 11 for the naming and the linking.

## B. Quality bar — what Kaj told us "good" means

| # | Requirement | Source |
|---|---|---|
| B1 | **At least 1,000 Wikipedia articles**, yielding several times more chunks (he estimated ~10 per article). | `[kaj]` |
| B2 | **Recall >= 98%** against an exhaustive comparison. He called 95% *"still frequently not considered acceptable"* and half *"absolutely not acceptable."* | `[kaj]` |
| B3 | Hybrid search must **genuinely combine** relational and vector querying — narrowing on something absolute first and something fluffy second — not a `WHERE` bolted onto a vector query. | `[kaj]` |
| B4 | The pipeline must **end in a generated answer**, because *"the easiest way to evaluate is for you to run that through an LLM so that you do get the answer to the prompt."* | `[kaj]` |
| B5 | Explanation quality is what is actually graded: the README must be comprehensible to a non-technical reader. | `[kaj]` |
| B6 | Hitting an undocumented limitation is **not a problem**, provided we document what we hit. | `[kaj]` |

B1 is a floor with a reason behind it, not a round number: below about a thousand articles a full table scan
beats the index, and a demo where the index does not earn its place proves nothing.

## C. The three limitations we must design around

All three were named by Kaj. **All three are now verified against a live server** — see file 09 for the exact
error messages and the one case where reality turned out to differ from the warning.

| # | Limitation | Verified |
|---|---|---|
| C1 | Only one vector index per table, so `WHERE` criteria cannot span several vector indexes on one table. | Yes — `ERROR 1235` |
| C2 | The indexed column must be `NOT NULL`. | Yes — `ERROR 1252` |
| C3 | The distance function must match the index; an index built for Euclidean cannot be queried with cosine. | Yes, **with a correction** — see file 09 |

## D. Course requirements — the process half of the mark

| # | Requirement | Source |
|---|---|---|
| D1 | Git history must show that everyone contributed and that the team ran itself. | `[course]` |
| D2 | Weekly self-assessment per contributor, kept current and consistent with the git history. | `[course]` |
| D3 | AI-use log, traceable per change, with the entry in the same commit as the change where possible. A trace that is out of date is worse than none. | `[course]` |
| D4 | Professional workflow: branches, pull requests, code review between contributors. | `[course]` |
| D5 | Code review of each other's work — explicitly asked for, and the thing we were weakest on during the starter. | `[course]` |

## E. Our own standards, carried over from the starter

| # | Requirement | Why |
|---|---|---|
| E1 | Every script idempotent — re-running drops and recreates what it owns. | The starter's scripts work this way and it removed a whole class of reader confusion. |
| E2 | CI runs the full pipeline on every push, across multiple MariaDB versions. | Caught version differences in the starter; vector search is newer, so the risk is higher. |
| E3 | Tests that fail the build when a result disagrees with its ground truth. | `SIGNAL SQLSTATE '45000'` makes the client exit non-zero; already proven in the starter. |
| E4 | Measured numbers carry repetitions, variance and stated hardware. | A single timing is not a measurement. |
| E5 | Unflattering results get published as findings. | The starter's 2.4x slowdown is the most credible thing in that README. |
| E6 | The corpus is not committed; it is fetched by a documented, repeatable step. | Rewarded by the usability criterion, and proven by the OpenFlights step in the starter. |

## F. Definition of done

The main dish is finished when all of the following are true:

1. A fresh clone, following only the README, loads the corpus and answers a question. Verified by someone
   who did not write the code — ideally on a different OS.
2. `recall@10 >= 0.98` at a documented `mhnsw_ef_search`, measured against our own brute-force ground truth
   over at least 50 held-out queries.
3. The recall/latency curve is published as a table, across at least five `ef_search` values spanning the
   point where recall crosses 98%.
4. At least two genuine hybrid queries are demonstrated and explained, one of them of the
   "absolute-then-fluffy" shape Kaj described.
5. The under-return defect (file 09) is reproduced in a committed test, documented in the README, and
   either reported to MariaDB or recorded as a deliberate decision not to.
6. The RAG pipeline returns a cited answer, and its quality is assessed by something better than our own
   impression.
7. CI is green on every supported MariaDB version.
8. All three contributors have commits, a current self-assessment, and at least one review of someone
   else's pull request.
9. Running the evaluation prompt against the repository scores at least 32/40, with no criterion below 7.

Item 9 is our own target, not MariaDB's. The starter scored 21/40 before we fixed it and 34/40 after. We
should not do worse on the piece that is worth more.
