# 08 — The RAG pipeline

Requirement B4: Kaj was explicit that the pipeline should end in an actual generated answer, because
*"the easiest way to evaluate is for you to run that through an LLM so that you do get the answer to the
prompt."* He also confirmed the embedding model and the answering model need not be the same, and that the
answering model can be any provider or a local one.

This is the smallest part of the project by effort and the part most likely to eat time it does not deserve.
The retrieval is what is graded on MariaDB depth. The generation step exists to close the loop and to make
the demo legible to a human reader.

## Why retrieval-augmented generation at all

Worth one paragraph in the README because it is the thing a non-technical reader most wants explained:

> A language model knows what it was trained on, and it will answer confidently about things it does not
> know. The fix is not to make the model bigger — it is to look the answer up first and hand it over. We
> retrieve ten passages from Wikipedia, give them to the model, and tell it to answer using only those and
> to cite which one each claim came from. If the answer is wrong, you can see exactly which passage misled
> it. That checkability is the entire point.

## The prompt

```
You are answering a question using only the numbered passages below.

Rules:
- Use only information in the passages. Do not add anything you know independently.
- Cite the passage number in square brackets after each claim, like this [3].
- If the passages do not contain the answer, say exactly: "The retrieved passages do
  not answer this question." Do not guess.
- Be concise. Three sentences unless the question needs more.

Passages:
[1] (Emperor penguin — Description) Emperor penguins are ...
[2] (Flightless bird — Evolution) ...
...

Question: why can't penguins fly?
```

Three design choices, each with a reason:

- **"Do not add anything you know independently"** turns the pipeline into a test of retrieval. If the model
  can answer from its own training, a broken retriever still looks fine, and we learn nothing about MariaDB.
- **The explicit refusal string** gives us a measurable abstention rate. A system that refuses when
  retrieval failed is working correctly; one that confabulates is not, and without an exact string to match
  we cannot count which happened.
- **Passages labelled with article and section** so citations resolve to something a reader can click.

## Model choice

| | Decision |
|---|---|
| Default | Claude via the Anthropic API — `claude-haiku-5-5` is ample for extractive answering and the cheapest of the current family |
| Configurable | `ANSWER_MODEL` in `.env`; any provider, or a local model through Ollama |
| Required? | **No.** `--no-llm` returns the passages and nothing calls out |

The last row is a hard requirement, not a convenience. Per file 02 and requirement A7, the entire retrieval
and measurement half of the project must run with no API key, so that anyone — including MariaDB's
evaluator — can clone, ingest, and reproduce every number in the README without an account. Generation is
the one optional step.

## Evaluating the answers

Weaker evidence than the recall measurement, and the write-up must say so rather than present a judged score
with the same confidence as a measured one.

Three levels, in increasing cost:

**1. Abstention correctness (cheap, objective).** Ask 10 questions the corpus genuinely cannot answer —
"what is the capital of Mongolia?" against a corpus of birds and physics. Correct behaviour is the exact
refusal string. This catches the worst failure mode with no human judgement at all, and it is the test worth
having if we only have time for one.

**2. Citation faithfulness (cheap, objective).** For every citation `[n]` in an answer, assert that passage
`n` was actually retrieved, and that the sentence's claim appears in it. The first half is a trivial
automated check and catches a real failure — models cite passages that were never shown. The second half
needs judgement, so it falls to level 3.

**3. Answer correctness (expensive, subjective).** 30 QA pairs from `eval_qa_pairs`, each scored
`correct / partially correct / incorrect / refused`. Two options:

- *Human scoring* — 30 items, two contributors scoring independently, disagreements discussed. Slow, and the
  most defensible.
- *LLM-as-judge* — a second model compares answer to expected answer. Fast, and **must be validated**: have
  a human score 10 of the 30 and report the agreement rate. An unvalidated LLM judge is a number with no
  known relationship to the truth, and publishing one would undercut the credibility the recall measurement
  earns us.

**Recommendation: LLM-as-judge for all 30, with 10 human-scored for agreement, reported as such.** It keeps
the cost proportionate to how much this part is worth while staying honest about what the number is.

## The retrieval-quality metric that actually matters

Separate from answer correctness, and more useful: **does the right chunk appear in the top k at all?**

For each of the 30 QA pairs we know the source chunk, so:

```
hit@k  =  fraction of questions whose known source chunk appears in the retrieved top k
```

Reported for k = 1, 5, 10. This is end-to-end retrieval quality — it folds in the embedding model, the
chunking and the index together — and it is the number that tells us whether a disappointing answer is the
retriever's fault or the generator's.

**It must not be confused with recall@k from file 07.** They answer different questions:

| | recall@k (file 07) | hit@k (here) |
|---|---|---|
| Ground truth | brute-force nearest neighbours | human-labelled source chunk |
| Holds fixed | the embedding model | nothing |
| Tells you about | **the HNSW index** | the whole pipeline |
| Needs labelling | no | yes |

A project reporting only hit@k has measured its embedding model and called it a database result. A project
reporting only recall@k has measured the index but cannot say whether the system is useful. We report both,
labelled, and explain the difference — which is itself a thing worth marks, because it is the distinction
most RAG write-ups get wrong.

## Scope discipline

Explicitly **not** in scope, listed so the temptation is pre-refused:

- Conversation history or multi-turn chat
- A web UI — the CLI is the interface (A7 asks for something a reader can try, not something pretty)
- Query rewriting, HyDE, or other retrieval tricks
- Reranking with a cross-encoder — genuinely improves RAG, and genuinely nothing to do with MariaDB
- Streaming output

Every item on that list would make the demo nicer and the grade no better. If there is spare time, it goes
into the file-07 experiments, which feed the criterion that can fail us.
