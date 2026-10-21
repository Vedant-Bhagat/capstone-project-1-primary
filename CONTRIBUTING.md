# Contributing workflow

We use a small, standard branch/PR workflow so the git history itself shows who did what — this is part of
how the course is graded.

Same conventions as our starter repository, so nothing has to be relearned between the two.

## Branches

- Never commit directly to `main`.
- One branch per piece of work, named `<yourname>/<short-description>`, e.g. `vedant/vector-schema`,
  `janhavi/ingest-pipeline`, `pranesh/recall-harness`.

## Commits

- Small, focused commits with a clear message: what changed and why, e.g.
  `Add recall sweep across ef_search with per-query timings`.
- Commit as yourself — your commits are the evidence of your own contribution, and the supervisor assesses
  the process half of the mark on git history.

## Pull requests

1. Push your branch: `git push -u origin <branch-name>`.
2. Open a PR on GitHub into `main`.
3. **Another contributor reviews it before it is merged.** With three of us, use a rotation rather than
   always asking the same person — review of each other's code is explicitly part of the course
   requirements, and it was the weakest part of our starter project.
4. Merge via GitHub, then delete the branch.

## Issues

Use GitHub Issues for anything worth tracking across a session: a bug found, a task to pick up later, a
question for the MariaDB reviewers.

## Self-assessment and AI-use log

- Every contributor fills their own section in the current week's file under `self_assessment/` before the
  weekly meeting. A self-assessment that contradicts the git history counts against us.
- Every AI-assisted change gets a line in `AI_USE_LOG.md`, added in the same commit as the change — not
  retroactively at the end of the week. The course guide is explicit that a trace which is out of date is
  worse than none.

## Specifics for this repository

- **The specification is the plan.** Before starting a piece of work, read the relevant file in
  `docs/main_dish_spec/`. If the implementation has to deviate from it, update the spec in the same PR and
  say why — a spec that silently drifts from the code is worse than no spec.
- **Keep the Python thin and the SQL deep.** Only the MariaDB side earns marks on the depth criterion, and
  that criterion can fail the project outright. If a week passes with no change under `sql/`, the week was
  misspent. The reasoning is in `02_architecture.md`.
- **Numbers need method.** Any measurement committed here carries repetitions, variance and the hardware it
  was taken on. A single timing is not a measurement.
- **Unflattering results get published.** The starter's headline finding was that its custom aggregate ran
  2.4x slower than writing the formula out, and saying so is the most credible thing in that README. Same
  standard here.
- **Do not overclaim the probe findings.** `09_verified_findings.md` ends with a verification checklist.
  Until those boxes are ticked, the filtered-search behaviour is described as observed on MariaDB 12.3.3 on
  Windows with synthetic data, in those words.
