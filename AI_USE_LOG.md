# AI-use log

Per the course's AI-use policy: every AI-assisted change is logged here — tool, part touched, and a link to
the prompt/session plus what it produced. Kept up to date as the code changes; a row is added in the same
commit as the change it describes wherever possible.

This log covers the **main dish** (area 4, vector search and RAG). Our starter project has its own log at
https://github.com/Vedant-Bhagat/capstone-project-1/blob/main/AI_USE_LOG.md, covering sessions S1–S6 and
all work up to 2026-10-15.

Sessions referenced below:
- **S7** — Claude Code (Opus 5), Vedant, 2026-10-15: https://claude.ai/code/session_01FcRqx9zst5MMVEWhSRuAaR
- **S8** — Claude Code (Opus 5), Vedant, 2026-10-21: https://claude.ai/code/session_01FcRqx9zst5MMVEWhSRuAaR

| Date | Contributor | Tool | Part touched | Prompt / session | Output |
|---|---|---|---|---|---|
| 2026-10-15 | Vedant | Claude Code (Opus 5) | `docs/main_dish_spec/` — full specification for the main dish: 14 documents covering requirements traced to source, architecture, corpus, chunking and embedding, schema, retrieval and hybrid search, evaluation methodology, the RAG pipeline, risks, deliverables and open decisions. Includes `probe/vector_probe.sql`, a runnable probe of MariaDB 12.3.3's vector support which verified the three documented limitations, corrected the warning about mismatched distance functions, and found undocumented behaviour: filtered vector queries on an unindexed column silently return fewer rows than requested, nondeterministically per index build | S7 — "write a detailed spec in a folder, as elaborate as possible". Findings obtained by running SQL against a local server, not from the model's prior knowledge; the probe script is committed so they can be re-checked. Area number and the one-area-per-README rule were confirmed by fetching the MariaDB project page rather than assumed | Originally committed in the starter repository as [`64fa83e`](https://github.com/Vedant-Bhagat/capstone-project-1/commit/64fa83e); moved here on 2026-10-21 (see the next row) |
| 2026-10-21 | Vedant | Claude Code (Opus 5) | Repository setup: moved `docs/main_dish_spec/` out of the starter repository into this one, wrote `README.md` (area 4 declaration, the non-technical explanation, verified findings, version floor), `CONTRIBUTING.md`, `.gitignore`, `self_assessment/`, and this log; cross-linked both repositories and updated the spec's deliverables file with the real repository name | S8 — "move the maindish spec to this repo and set up the repo the same way for documentation and readme" | commit `ec8dbd8` |
