"""Unit tests for htmltotext.py. Run: python -m unittest python.test_htmltotext

Fixture: rendered HTML of Wikipedia's "Emperor penguin", revision 1188837017
(2023-12-08), https://en.wikipedia.org/w/index.php?oldid=1188837017, fetched
with action=parse&prop=text&disableeditsection=1. Wikipedia text is licensed
CC BY-SA 4.0.
"""

import re
import unittest
from pathlib import Path

from python.chunk import HEADING, chunk_article
from python.htmltotext import html_to_text

FIXTURE = Path(__file__).parent / "fixtures" / "emperor_penguin_1188837017.html"


class FixtureTests(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.html = FIXTURE.read_text(encoding="utf-8")
        cls.text = html_to_text(cls.html)

    def assertRemoved(self, s):
        self.assertIn(s, self.html)      # proves the test is not vacuous
        self.assertNotIn(s, self.text)

    def test_starts_with_lead_prose(self):
        self.assertTrue(self.text.startswith(
            "The emperor penguin (Aptenodytes forsteri) is the tallest and heaviest"))

    def test_headings_in_chunk_format(self):
        headings = [l for l in self.text.splitlines() if l.startswith("=")]
        self.assertEqual(headings[:6], [
            "== Taxonomy ==", "== Description ==", "=== Vocalisation ===",
            "=== Adaptations to cold ===",
            "=== Adaptations to pressure and low oxygen ===",
            "== Distribution and habitat ==",
        ])
        self.assertEqual(len(headings), 18)  # 8 h2 + 10 h3 in the HTML
        for h in headings:
            self.assertRegex(h, HEADING)

    def test_chunker_sees_the_sections(self):
        sections = {c.section for c in chunk_article("Emperor penguin", self.text)}
        self.assertTrue({"", "Taxonomy", "Vocalisation", "Courtship and breeding"} <= sections)
        self.assertFalse(sections & {"References", "External links", "Notes"})

    def test_unit_conversions_survive(self):
        # {{convert}} in the wikitext; pre-rendered in the HTML.
        self.assertIn("reaching 100 cm (39 in) in length", self.text)
        self.assertIn("weighing from 22 to 45 kg (49 to 99 lb)", self.text)
        self.assertNotIn("\xa0", self.text)  # non-breaking spaces normalised

    def test_citation_markers_removed(self):
        self.assertIn('class="reference"', self.html)
        self.assertIsNone(re.search(r"\[\d+\]|\[[a-z]\]", self.text))
        self.assertRemoved("image reference needed")    # [citation needed]-style

    def test_infobox_removed(self):
        self.assertRemoved("Scientific classification")
        self.assertRemoved("Binomial name")

    def test_navboxes_removed(self):
        self.assertRemoved("Taxon identifiers")
        self.assertRemoved("Authority control databases")

    def test_images_and_captions_removed(self):
        self.assertRemoved("Adults with chicks")
        self.assertRemoved("Wikimedia Commons logo")

    def test_notice_removed(self):
        self.assertRemoved("This article is about the bird")

    def test_no_markup_left(self):
        self.assertIsNone(re.search(r"<[a-zA-Z/][^>]*>", self.text))
        self.assertIsNone(re.search(r"&(#\d+|#x[0-9a-f]+|[a-z]+);", self.text))
        self.assertNotIn(".mw-parser-output", self.text)  # inline CSS


class SnippetTests(unittest.TestCase):

    def test_edit_links_removed(self):
        html = ('<div class="mw-heading mw-heading2"><h2>Taxonomy</h2>'
                '<span class="mw-editsection">[<a href="#">edit</a>]</span></div>')
        self.assertEqual(html_to_text(html), "== Taxonomy ==")

    def test_exponents_kept_but_references_dropped(self):
        html = '<p>An area of 5 km<sup>2</sup>.<sup class="reference">[3]</sup></p>'
        self.assertEqual(html_to_text(html), "An area of 5 km2.")

    def test_citation_needed_removed(self):
        html = ('<p>It may live 50 years.<sup class="noprint Inline-Template Template-Fact">'
                '[<i><a href="#">citation needed</a></i>]</sup></p>')
        self.assertEqual(html_to_text(html), "It may live 50 years.")

    def test_hidden_elements_removed(self):
        html = '<p>Seen<span style="display: none">HIDDEN</span> here.</p>'
        self.assertEqual(html_to_text(html), "Seen here.")

    def test_maths_kept_as_latex(self):
        html = ('<p>Energy is <span class="mwe-math-element"><img alt="{\\displaystyle E=mc^{2}}" '
                'class="mwe-math-fallback-image-inline"></span>.</p>')
        self.assertEqual(html_to_text(html), "Energy is {\\displaystyle E=mc^{2}}.")

    def test_void_tags_inside_dropped_element(self):
        html = ('<p>Before.</p><div class="thumb"><img src="x"><br>caption '
                '<div>nested</div></div><p>After.</p>')
        self.assertEqual(html_to_text(html), "Before.\nAfter.")

    def test_lists_and_line_breaks(self):
        html = "<ul><li>One</li><li>Two<br>half</li></ul><p>A &amp; B</p>"
        self.assertEqual(html_to_text(html), "One\nTwo\nhalf\nA & B")


if __name__ == "__main__":
    unittest.main()
