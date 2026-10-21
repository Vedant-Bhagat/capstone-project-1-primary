"""Every tunable parameter of the ingest, and nowhere else.

Spec: docs/main_dish_spec/04_chunking_embedding.md. Hard-coding any of these
elsewhere makes the file-07 experiments impossible to run.
"""

from pathlib import Path

# Fetching. Wikipedia's etiquette: a descriptive User-Agent with a contact
# URL, and requests made one at a time at a polite rate.
WIKI_API           = "https://en.wikipedia.org/w/api.php"
USER_AGENT         = ("MariaDB-capstone-ingest/0.1 "
                      "(https://github.com/Vedant-Bhagat/capstone-project-1-primary)")
REQUEST_INTERVAL_S = 1.0
RAW_DIR            = Path(__file__).resolve().parent.parent / "raw"   # gitignored

# Corpus categories, (key, Wikipedia category). ORDER IS LOAD-BEARING: an
# article in several categories belongs to the first one listed here
# (03_corpus.md, overlap rule).
CATEGORIES = [
    ("birds",                "Birds described in 1758"),
    ("physics",              "Concepts in physics"),
    ("composers",            "Composers for piano"),
    ("prog_lang",            "Programming languages"),
    ("space_telescopes",     "Space telescopes"),
    ("diseases",             "Infectious diseases"),
    ("political_philosophy", "Concepts in political philosophy"),
    ("ethics",               "Concepts in ethics"),
    ("architecture",         "Architectural styles"),
]
ARTICLES_PER_CATEGORY = 150   # longest first when a category has more
# Pages in a category that are indexes of other articles, not prose.
NON_ARTICLE_PREFIXES = ("List of", "Lists of", "Outline of", "Index of",
                        "Glossary of", "Timeline of")

# Chunking
CHUNK_TARGET_WORDS  = 300
CHUNK_OVERLAP_WORDS = 50
CHUNK_MIN_WORDS     = 40
PREPEND_TITLE       = True

# Wikipedia sections that are link lists or citations, not prose. Matched
# case-insensitively; their subsections are dropped with them.
SKIP_SECTIONS = frozenset({
    "see also", "references", "notes", "footnotes", "citations",
    "sources", "bibliography", "further reading", "external links",
})

# Embedding. The prefix goes on the QUERY side only; passages are embedded
# bare. Wording checked against the model card on 2026-10-21.
EMBED_MODEL  = "BAAI/bge-small-en-v1.5"
EMBED_DIMS   = 384
QUERY_PREFIX = "Represent this sentence for searching relevant passages: "
