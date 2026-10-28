"""Unit tests for chunk.py. Run: python -m unittest python.test_chunk"""

import unittest

from python.chunk import chunk_article


def sentence(tag, n):
    """A distinct sentence of exactly n words, e.g. 'Aa a1 a2.'"""
    return " ".join([tag.capitalize()] + [f"{tag}{i}" for i in range(1, n)]) + "."


def para(tag, n_sentences, words_each):
    return " ".join(sentence(f"{tag}s{i}", words_each) for i in range(n_sentences))


class ChunkTests(unittest.TestCase):

    def test_empty_text(self):
        self.assertEqual(chunk_article("T", ""), [])

    def test_short_article_is_one_chunk(self):
        text = para("lead", 5, 10)
        [c] = chunk_article("Emperor penguin", text)
        self.assertEqual(c.section, "")
        self.assertEqual(c.ordinal, 1)
        self.assertEqual(c.word_count, 50)
        self.assertEqual(c.body, text)

    def test_embed_text_prepends_title_and_heading(self):
        text = para("lead", 5, 10) + "\n\n== Breeding ==\n" + para("br", 5, 10)
        lead, breeding = chunk_article("Emperor penguin", text)
        self.assertEqual(lead.embed_text, "Emperor penguin\n\n" + lead.body)
        self.assertEqual(breeding.section, "Breeding")
        self.assertEqual(breeding.embed_text,
                         "Emperor penguin — Breeding\n\n" + breeding.body)

    def test_prepend_off_embeds_bare_body(self):
        text = "== Breeding ==\n" + para("br", 5, 10)
        [c] = chunk_article("Emperor penguin", text, prepend_title=False)
        self.assertEqual(c.embed_text, c.body)

    def test_below_minimum_is_dropped(self):
        text = para("lead", 3, 10) + "\n== Big ==\n" + para("big", 5, 10)
        chunks = chunk_article("T", text)
        self.assertEqual([c.section for c in chunks], ["Big"])
        self.assertEqual(chunks[0].ordinal, 1)  # ordinals renumber after drops

    def test_size_and_whole_sentences(self):
        sentences = [sentence(f"s{i}x", 23) for i in range(60)]  # 1,380 words
        chunks = chunk_article("T", " ".join(sentences))
        self.assertGreater(len(chunks), 4)
        for c in chunks:
            self.assertLessEqual(c.word_count, 300)
            self.assertEqual(c.word_count, len(c.body.split()))
            for piece in c.body.split(". "):
                self.assertIn(piece.rstrip(".") + ".", sentences)

    def test_every_sentence_is_kept(self):
        sentences = [sentence(f"s{i}x", 23) for i in range(60)]
        chunks = chunk_article("T", " ".join(sentences))
        covered = " ".join(c.body for c in chunks)
        for s in sentences:
            self.assertIn(s, covered)

    def test_overlap_carries_trailing_sentences(self):
        sentences = [sentence(f"s{i}x", 20) for i in range(40)]
        chunks = chunk_article("T", " ".join(sentences))
        for prev, nxt in zip(chunks, chunks[1:]):
            # 20-word sentences under a 50-word overlap: exactly two carried.
            carried = " ".join(sentences[i] for i in range(40)
                               if sentences[i] in prev.body
                               and sentences[i] in nxt.body)
            self.assertEqual(len(carried.split()), 40)
            self.assertTrue(prev.body.endswith(carried))
            self.assertTrue(nxt.body.startswith(carried))

    def test_overlap_dropped_rather_than_exceeding_target(self):
        text = sentence("a", 200) + " " + sentence("b", 30) + " " + sentence("c", 280)
        first, second = chunk_article("T", text)
        self.assertEqual(first.word_count, 230)
        self.assertEqual(second.body, sentence("c", 280))

    def test_never_spans_a_heading(self):
        text = para("one", 20, 20) + "\n\n== Two ==\n" + para("two", 20, 20)
        for c in chunk_article("T", text):
            self.assertFalse("one" in c.body and "two" in c.body.lower())
            self.assertEqual(c.section, "Two" if "Two" in c.body else "")

    def test_reference_sections_and_subsections_skipped(self):
        text = (para("lead", 5, 10)
                + "\n== See also ==\n" + para("nav", 10, 10)
                + "\n=== Lists ===\n" + para("sub", 10, 10)
                + "\n== Legacy ==\n" + para("leg", 5, 10)
                + "\n== External links ==\n" + para("ext", 10, 10))
        chunks = chunk_article("T", text)
        self.assertEqual([c.section for c in chunks], ["", "Legacy"])

    def test_subsection_heading_is_nearest_heading(self):
        text = "== History ==\n" + para("h", 5, 10) + "\n=== Early life ===\n" + para("e", 5, 10)
        self.assertEqual([c.section for c in chunk_article("T", text)],
                         ["History", "Early life"])

    def test_oversize_sentence_cut_at_words(self):
        run_on = " ".join(f"item{i}" for i in range(700))  # no full stops
        chunks = chunk_article("T", run_on)
        self.assertEqual([c.word_count for c in chunks], [300, 300, 100])

    def test_paragraph_breaks_preserved(self):
        text = para("p", 3, 10) + "\n" + para("q", 3, 10)
        [c] = chunk_article("T", text)
        self.assertEqual(c.body, para("p", 3, 10) + "\n\n" + para("q", 3, 10))

    def test_parameters_override_config(self):
        sentences = " ".join(sentence(f"s{i}x", 10) for i in range(20))
        chunks = chunk_article("T", sentences, target=50, overlap=0, min_words=1)
        self.assertEqual([c.word_count for c in chunks], [50, 50, 50, 50])


if __name__ == "__main__":
    unittest.main()
