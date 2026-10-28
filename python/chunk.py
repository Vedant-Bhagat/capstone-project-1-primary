"""Split one Wikipedia article into chunks. Pure: no I/O, no network.

Input is the plain text from the API's `prop=extracts&explaintext=1`, where
section headings appear on their own line as `== Heading ==`.

Rules (spec 04_chunking_embedding.md):
- pack whole sentences up to the target size, never splitting one;
- never span a section heading;
- start each chunk with the trailing sentences of the previous one, up to the
  overlap size;
- drop chunks below the minimum size.

One exception to "never split a sentence": a single "sentence" longer than the
target (in practice a list or table flattened with no full stops) is cut at
word boundaries, because the alternative is the embedding model silently
truncating it.
"""

import re
from dataclasses import dataclass

from python import config

HEADING = re.compile(r"^(={2,6})\s*(.*?)\s*\1\s*$")
# A sentence ends at . ! or ? followed by whitespace and something that can
# start a sentence. Abbreviations ("U.S. Army") cause extra splits; harmless,
# since it only moves where a chunk may break.
SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=[\"'(\[]?[A-Z0-9])")


@dataclass(frozen=True)
class Chunk:
    section: str      # nearest heading; '' for the lead section
    ordinal: int      # 1-based position within the article
    body: str         # stored and cited
    word_count: int
    embed_text: str   # what gets embedded; body plus title/heading context


def _sections(text):
    """Yield (heading, paragraphs) for each section, skipping SKIP_SECTIONS."""
    heading, paras = "", []
    skip_level = None
    for line in text.splitlines():
        m = HEADING.match(line.strip())
        if m:
            level = len(m.group(1))
            if skip_level is not None and level > skip_level:
                continue  # subsection of a skipped section
            if skip_level is None:
                yield heading, paras
            skip_level = None
            heading, paras = m.group(2), []
            if heading.lower() in config.SKIP_SECTIONS:
                skip_level = level
        elif skip_level is None and line.strip():
            paras.append(line.strip())
    if skip_level is None:
        yield heading, paras


def _units(paras, target):
    """Sentences as (text, words, starts_paragraph); oversize ones cut up."""
    for para in paras:
        first = True
        for sentence in SENTENCE_END.split(para):
            words = sentence.split()
            for i in range(0, len(words), target):
                piece = words[i:i + target]
                yield " ".join(piece), len(piece), first
                first = False


def _join(units):
    out = ""
    for text, _, para_start in units:
        out += ("\n\n" if para_start else " ") + text if out else text
    return out


def _pack(units, target, overlap):
    """Group sentence units into lists of at most `target` words."""
    groups, current, words = [], [], 0
    for unit in units:
        if current and words + unit[1] > target:
            groups.append(current)
            carry, carried = [], 0
            for prev in reversed(current):
                if carried + prev[1] > overlap:
                    break
                carry.insert(0, prev)
                carried += prev[1]
            # Drop the overlap if it would push the next chunk over target.
            # This also guarantees no chunk is made of overlap alone.
            if carried + unit[1] > target:
                carry, carried = [], 0
            current, words = carry, carried
        current.append(unit)
        words += unit[1]
    if current:
        groups.append(current)
    return groups


def chunk_article(title, text,
                  target=config.CHUNK_TARGET_WORDS,
                  overlap=config.CHUNK_OVERLAP_WORDS,
                  min_words=config.CHUNK_MIN_WORDS,
                  prepend_title=config.PREPEND_TITLE):
    """Return the article's chunks in reading order."""
    chunks = []
    for heading, paras in _sections(text):
        for group in _pack(_units(paras, target), target, overlap):
            word_count = sum(u[1] for u in group)
            if word_count < min_words:
                continue
            body = _join(group)
            if not prepend_title:
                embed_text = body
            elif heading:
                embed_text = f"{title} — {heading}\n\n{body}"
            else:
                embed_text = f"{title}\n\n{body}"
            chunks.append(Chunk(heading, len(chunks) + 1, body, word_count,
                                embed_text))
    return chunks
