"""Ask the corpus a question: retrieve in SQL, then optionally generate.

Spec: docs/main_dish_spec/08_rag_pipeline.md.

    python -m python.answer "why can't penguins fly?" --no-llm
    python -m python.answer "why can't penguins fly?"            # needs a key
    python -m python.answer "..." --category birds --k 5
    python -m python.answer --check-citations                     # self-test

`--no-llm` is a hard requirement, not a convenience (file 02, requirement
A7): retrieval and every measurement must run with no API key, so anyone can
clone, ingest and reproduce the numbers without an account. Generation is the
only optional step, and without `ANTHROPIC_API_KEY` this prints the passages
and says so rather than failing.

THE RETRIEVAL IS ONE SQL STATEMENT and it is the point of the project, so it
lives here in full rather than behind a query builder. Two shapes:

  plain      ORDER BY VEC_DISTANCE_COSINE(...) LIMIT k   -- uses the HNSW index
  filtered   the same, plus FORCE INDEX (ix_category)

The hint on the filtered shape is load-bearing, not tidy-minded. Above ~7%
selectivity the optimizer post-filters through the vector index and can return
fewer rows than asked for -- sometimes none -- with no error
(09_verified_findings.md, findings 7, 7b and 7c). Every category in this
corpus is above that threshold, so the hint is what makes a filtered answer
trustworthy. Removing it would not break a test that counts rows; it would
quietly degrade answers.
"""

import argparse
import os
import re
import sys

from python import config, embed
from python.ingest import connect

PROMPT = """You are answering a question using only the numbered passages below.

Rules:
- Use only information in the passages. Do not add anything you know independently.
- Cite the passage number in square brackets after each claim, like this [3].
- If the passages do not contain the answer, say exactly: "{refusal}" Do not guess.
- Be concise. Three sentences unless the question needs more.

Passages:
{passages}

Question: {question}"""

REFUSAL = "The retrieved passages do not answer this question."

# Cheap for extractive answering, and the answering model need not match the
# embedding model (08_rag_pipeline.md). Override with ANSWER_MODEL.
DEFAULT_ANSWER_MODEL = "claude-haiku-5-5"


def check_corpus(cur):
    """Refuse to embed a question with a model the corpus was not built with.

    Without this the failure is silent: mismatched vectors still have 384
    dimensions, still insert, and still come back ranked -- just meaninglessly.
    corpus_meta exists so the query path can catch it (05_schema.md)."""
    cur.execute("""SELECT embed_model, embed_dims, query_prefix
                   FROM corpus_meta""")
    row = cur.fetchone()
    if row is None:
        raise SystemExit("corpus_meta is empty -- run python -m python.ingest")
    model, dims, prefix = row
    if model != config.EMBED_MODEL or dims != config.EMBED_DIMS:
        raise SystemExit(
            f"corpus was built with {model} at {dims} dimensions, but config "
            f"says {config.EMBED_MODEL} at {config.EMBED_DIMS}. Re-ingest, or "
            f"put config back.")
    if prefix != config.QUERY_PREFIX:
        raise SystemExit(
            f"corpus recorded query prefix {prefix!r}, config has "
            f"{config.QUERY_PREFIX!r}. BGE is asymmetric: the wrong prefix "
            f"degrades retrieval with no error.")
    if model.startswith("SYNTHETIC"):
        print("NOTE: this is the synthetic fixture, not a real corpus. "
              "Answers will be nonsense.", file=sys.stderr)


def retrieve(question, k=10, category=None, ef_search=None):
    """The k nearest chunks to `question`. Returns a list of dicts."""
    vector = embed.to_vec_text(embed.encode_queries([question])[0])
    conn = connect()
    try:
        with conn.cursor() as cur:
            check_corpus(cur)
            if ef_search:
                cur.execute("SET SESSION mhnsw_ef_search = %s", (ef_search,))
            if category:
                cur.execute(
                    """SELECT c.id, a.title, c.section, c.body, a.url,
                              VEC_DISTANCE_COSINE(c.embedding,
                                                  VEC_FromText(%s)) AS dist
                       FROM chunks c FORCE INDEX (ix_category)
                       JOIN articles a ON a.id = c.article_id
                       WHERE c.category = %s
                       ORDER BY VEC_DISTANCE_COSINE(c.embedding,
                                                    VEC_FromText(%s))
                       LIMIT %s""", (vector, category, vector, k))
            else:
                cur.execute(
                    """SELECT c.id, a.title, c.section, c.body, a.url,
                              VEC_DISTANCE_COSINE(c.embedding,
                                                  VEC_FromText(%s)) AS dist
                       FROM chunks c
                       JOIN articles a ON a.id = c.article_id
                       ORDER BY VEC_DISTANCE_COSINE(c.embedding,
                                                    VEC_FromText(%s))
                       LIMIT %s""", (vector, vector, k))
            cols = [d[0] for d in cur.description]
            return [dict(zip(cols, row)) for row in cur.fetchall()]
    finally:
        conn.close()


def format_passages(passages, width=600):
    return "\n".join(
        f"[{i}] ({p['title']} — {p['section'] or 'Lead'}) "
        f"{p['body'][:width]}"
        for i, p in enumerate(passages, 1))


def generate(question, passages):
    """Ask the answering model. Returns None if no key is configured."""
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return None
    try:
        import anthropic
    except ImportError:
        print("pip install anthropic, or use --no-llm", file=sys.stderr)
        return None
    client = anthropic.Anthropic(api_key=key)
    message = client.messages.create(
        model=os.environ.get("ANSWER_MODEL", DEFAULT_ANSWER_MODEL),
        max_tokens=600,
        messages=[{"role": "user", "content": PROMPT.format(
            refusal=REFUSAL, passages=format_passages(passages),
            question=question)}])
    return "".join(b.text for b in message.content if b.type == "text")


def citation_check(answer, n_passages):
    """Every [n] in the answer must point at a passage that was shown.

    Objective, needs no judgement, and catches a real failure: models cite
    passages that were never in the prompt (08_rag_pipeline.md). Returns the
    out-of-range citations."""
    cited = {int(m) for m in re.findall(r"\[(\d+)\]", answer)}
    return sorted(c for c in cited if not 1 <= c <= n_passages)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("question", nargs="?", help="the question to answer")
    ap.add_argument("--k", type=int, default=10, help="passages to retrieve")
    ap.add_argument("--category", help="restrict to one category")
    ap.add_argument("--ef-search", type=int,
                    help="mhnsw_ef_search for this query")
    ap.add_argument("--no-llm", action="store_true",
                    help="retrieve only; never calls out")
    ap.add_argument("--check-citations", action="store_true",
                    help="self-test: every citation must resolve")
    args = ap.parse_args(argv)

    if not args.question:
        ap.error("a question is required")

    passages = retrieve(args.question, args.k, args.category, args.ef_search)
    if not passages:
        print("no passages retrieved.")
        if args.category:
            print("A filtered query returning nothing is the behaviour in "
                  "finding 7 -- check that FORCE INDEX is still on the query.")
        return 1
    # A filtered query that comes back short is the documented defect, so say
    # so rather than quietly answering from fewer passages than requested.
    if len(passages) < args.k:
        print(f"NOTE: asked for {args.k} passages, got {len(passages)}.",
              file=sys.stderr)

    print(f"Retrieved {len(passages)} passages:\n")
    for i, p in enumerate(passages, 1):
        print(f"[{i}] {p['title']} — {p['section'] or 'Lead'}  "
              f"(cosine {p['dist']:.4f})")
        print(f"    {p['body'][:200].strip()}...")
        print(f"    {p['url']}")
    print()

    if args.no_llm:
        return 0

    answer = generate(args.question, passages)
    if answer is None:
        print("No ANTHROPIC_API_KEY set, so no answer was generated. The "
              "passages above are the retrieval result, which is the part "
              "this project measures. Set the key, or pass --no-llm to make "
              "that explicit.")
        return 0

    print("Answer:\n")
    print(answer)
    bad = citation_check(answer, len(passages))
    if bad:
        print(f"\nCITATION FAILURE: cited {bad}, but only 1-{len(passages)} "
              f"were shown.", file=sys.stderr)
        return 1
    if answer.strip().startswith(REFUSAL):
        print("\n(The model refused. That is correct behaviour when retrieval "
              "failed, and it is counted as an abstention, not an error.)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
