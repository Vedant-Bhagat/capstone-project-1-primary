"""Grade the answering half against `eval_qa_pairs.csv`.

Spec: docs/main_dish_spec/08_rag_pipeline.md, which defines three levels of
answer evaluation and recommends all three. This implements them in the order
that file puts them, which is cheapest-and-most-objective first:

    python -m python.grade_answers --no-llm        # level 0, no API key
    python -m python.grade_answers --abstention    # level 1, 10 calls
    python -m python.grade_answers --answers       # level 3, 30 calls
    python -m python.grade_answers --answers --judge   # + 30 judge calls

**Level 0 is the one that matters most and it needs no API key.** Every QA
pair carries the `source_chunk` its answer was written from, so we can ask
whether retrieval put that chunk in the top k at all. If it did not, no
answering model can get the answer right from these passages, and an answer
that looks correct came from the model's own memory rather than the corpus --
which is the failure RAG exists to prevent and the one a correctness score
cannot distinguish. File 08 calls this "the retrieval-quality metric that
actually matters", and because it is free it runs on all 30 pairs and is
reproducible by anyone who clones the repository.

A deliberate limitation, stated here because it would otherwise be invisible
in the output: `--judge` is an LLM scoring another LLM, and file 08 requires
that such a number be validated against human scores before it is published.
It is NOT validated yet. `--answers` therefore writes every answer to a CSV
so that a human can score a sample and the agreement rate can be measured.
Until that happens the judge's numbers are labelled unvalidated everywhere
they appear, including in the output of this script.
"""

import argparse
import csv
import os
import sys
from pathlib import Path

from python import answer

QA_PATH = Path(__file__).resolve().parent.parent / "eval_qa_pairs.csv"

JUDGE_PROMPT = """You are grading one answer from a retrieval-augmented system.

Question: {question}

Reference answer (written from the source document): {expected}

Answer to grade: {given}

Grade it as exactly one word on the first line:
CORRECT      - states the reference answer's facts, allowing different wording
PARTIAL      - some of the reference facts, nothing contradicting it
INCORRECT    - contradicts the reference, or asserts facts it does not contain
REFUSED      - declines to answer

Then one short sentence of justification on the second line."""

JUDGE_REFUSAL_NOTE = ("judge scores are UNVALIDATED -- no human agreement rate "
                      "has been measured, see docs/main_dish_spec/08_rag_pipeline.md")


def load_pairs():
    with open(QA_PATH, encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    answerable = [r for r in rows if r["source_chunk"].strip()]
    unanswerable = [r for r in rows if not r["source_chunk"].strip()]
    return rows, answerable, unanswerable


def retrieval_hits(pairs, k):
    """Level 0: is the source chunk in the top k? No API key needed."""
    results = []
    for r in pairs:
        want = int(r["source_chunk"])
        passages = answer.retrieve(r["question"], k=k)
        ids = [p["id"] for p in passages]
        rank = ids.index(want) + 1 if want in ids else None
        results.append({"id": r["id"], "question": r["question"],
                        "source_chunk": want, "returned": len(ids),
                        "rank": rank})
    return results


def report_hits(results, k):
    hits = [r for r in results if r["rank"] is not None]
    top1 = [r for r in hits if r["rank"] == 1]
    print(f"\nLevel 0 -- retrieval hit@{k}, no API key, {len(results)} pairs")
    print(f"  hit@{k}:  {len(hits)}/{len(results)} = {len(hits)/len(results):.3f}")
    print(f"  hit@1:  {len(top1)}/{len(results)} = {len(top1)/len(results):.3f}")
    short = [r for r in results if r["returned"] < k]
    if short:
        print(f"  WARNING: {len(short)} queries returned fewer than {k} passages "
              f"-- that is the under-return defect, not a grading result")
    misses = [r for r in results if r["rank"] is None]
    if misses:
        print(f"  missed entirely ({len(misses)}): "
              f"{', '.join('#' + m['id'] for m in misses)}")
        print("  An answer to any of those that looks right did NOT come from "
              "the cited passages.")
    return {"n": len(results), "hit_at_k": len(hits), "hit_at_1": len(top1)}


def grade_abstention(pairs, k):
    """Level 1: the corpus cannot answer these, so the only correct response
    is the refusal string. Objective, needs no judgement."""
    print(f"\nLevel 1 -- abstention on {len(pairs)} unanswerable questions")
    refused = 0
    rows = []
    for r in pairs:
        passages = answer.retrieve(r["question"], k=k)
        got = answer.generate(r["question"], passages)
        if got is None:
            raise SystemExit("no API key set; abstention needs generation")
        ok = got.strip().startswith(answer.REFUSAL)
        refused += ok
        nearest = passages[0]["dist"] if passages else float("nan")
        print(f"  #{r['id']:>2} {'REFUSED' if ok else 'ANSWERED (wrong)':16} "
              f"nearest={nearest:.4f}  {r['question'][:52]}")
        if not ok:
            print(f"       -> {' '.join(got.split())[:160]}")
        rows.append({"id": r["id"], "question": r["question"],
                     "refused": int(ok), "answer": got})
    print(f"  abstention rate: {refused}/{len(pairs)} = "
          f"{refused/len(pairs):.3f}   (1.000 is correct behaviour)")
    return rows


def grade_answers(pairs, k, judge):
    """Level 3: generate an answer for each pair, check citations, optionally
    score against the reference."""
    print(f"\nLevel 3 -- answers for {len(pairs)} answerable questions"
          f"{' with judge' if judge else ''}")
    rows = []
    for r in pairs:
        passages = answer.retrieve(r["question"], k=k)
        got = answer.generate(r["question"], passages)
        if got is None:
            raise SystemExit("no API key set; use --no-llm for level 0")
        bad = answer.citation_check(got, len(passages))
        refused = got.strip().startswith(answer.REFUSAL)
        want = int(r["source_chunk"])
        ids = [p["id"] for p in passages]
        rank = ids.index(want) + 1 if want in ids else None
        verdict = ""
        if judge:
            prompt = JUDGE_PROMPT.format(question=r["question"],
                                         expected=r["expected"], given=got)
            raw = _judge(prompt)
            verdict = raw.strip().splitlines()[0].strip().upper()[:9]
        print(f"  #{r['id']:>2} {'REFUSED' if refused else 'answered':9} "
              f"src_rank={rank if rank else '-':>3} "
              f"cites_ok={'no' if bad else 'yes':3} {verdict:9} "
              f"{r['question'][:44]}")
        rows.append({"id": r["id"], "question": r["question"],
                     "expected": r["expected"], "answer": got,
                     "source_chunk": want, "source_rank": rank or "",
                     "bad_citations": ",".join(map(str, bad)),
                     "refused": int(refused), "judge": verdict,
                     "human": ""})
    return rows


def _judge(prompt):
    """The judge is a different vendor from the answering model where possible,
    so a model is not grading its own output."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if key:
        return answer._anthropic(prompt, key, answer.DEFAULT_ANSWER_MODEL)
    gem = os.environ.get("GEMINI_API_KEY")
    if gem:
        return answer._gemini(prompt, gem, answer.DEFAULT_GEMINI_MODEL)
    raise SystemExit("--judge needs ANTHROPIC_API_KEY or GEMINI_API_KEY")


def write_csv(path, rows):
    if not rows:
        return
    with open(path, "w", encoding="utf-8", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"  wrote {path}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--k", type=int, default=10)
    ap.add_argument("--no-llm", action="store_true",
                    help="level 0 only: retrieval hit@k, no API key")
    ap.add_argument("--abstention", action="store_true",
                    help="level 1: the unanswerable questions must be refused")
    ap.add_argument("--answers", action="store_true",
                    help="level 3: generate an answer per answerable pair")
    ap.add_argument("--judge", action="store_true",
                    help="score level 3 with a model. UNVALIDATED -- see module docstring")
    ap.add_argument("--limit", type=int,
                    help="first N pairs only, to bound API spend")
    ap.add_argument("--out", default="docs/answer_grades.csv")
    args = ap.parse_args(argv)

    _, answerable, unanswerable = load_pairs()
    if args.limit:
        answerable = answerable[:args.limit]
        unanswerable = unanswerable[:args.limit]

    if not (args.abstention or args.answers):
        args.no_llm = True

    if args.no_llm:
        report_hits(retrieval_hits(answerable, args.k), args.k)
        print("\nLevels 1 and 3 need an API key. Pass --abstention or --answers.")
        return 0

    if args.abstention:
        write_csv("docs/abstention_grades.csv",
                  grade_abstention(unanswerable, args.k))
    if args.answers:
        rows = grade_answers(answerable, args.k, args.judge)
        write_csv(args.out, rows)
        if args.judge:
            tally = {}
            for r in rows:
                tally[r["judge"]] = tally.get(r["judge"], 0) + 1
            print(f"  judge tally: {tally}")
            print(f"  NOTE: {JUDGE_REFUSAL_NOTE}")
            print("  The CSV has an empty `human` column. Score at least 10 rows "
                  "by hand and report the agreement rate before quoting these.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
