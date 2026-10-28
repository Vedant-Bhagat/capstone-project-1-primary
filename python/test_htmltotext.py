"""Unit tests for htmltotext.py. Run: python -m unittest python.test_htmltotext

Fixtures: rendered HTML (action=parse&prop=text&disableeditsection=1) of two
Wikipedia revisions. Wikipedia text is licensed CC BY-SA 4.0.
- "Emperor penguin", revision 1188837017 (2023-12-08),
  https://en.wikipedia.org/w/index.php?oldid=1188837017
- "Active and passive transformation", revision 1363379558 (2026-07-09),
  https://en.wikipedia.org/w/index.php?oldid=1363379558
"""

import re
import unittest
from html import unescape
from pathlib import Path

from python.chunk import HEADING, chunk_article
from python.htmltotext import html_to_text

FIXTURE = Path(__file__).parent / "fixtures" / "emperor_penguin_1188837017.html"
MATHS_FIXTURE = (Path(__file__).parent / "fixtures"
                 / "active_passive_transformation_1363379558.html")


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


class MathsFixtureTests(unittest.TestCase):
    """Each formula is rendered twice: a hidden MathML copy, and an image whose
    alt text is the LaTeX source. Only the LaTeX should reach the output."""

    @classmethod
    def setUpClass(cls):
        cls.html = MATHS_FIXTURE.read_text(encoding="utf-8")
        cls.text = html_to_text(cls.html)
        cls.alts = [unescape(a) for a in re.findall(
            r'class="mwe-math-fallback-image[^"]*"[^>]*alt="([^"]*)"', cls.html)]

    def test_every_formula_kept_as_latex(self):
        self.assertEqual(len(self.alts), 69)   # 64 inline + 5 display
        for alt in self.alts:
            self.assertIn(alt, self.text)

    def test_inline_formula_in_sentence(self):
        self.assertIn(
            "As an example, let the vector "
            "{\\displaystyle \\mathbf {v} =(v_{1},v_{2})\\in \\mathbb {R} ^{2}}, "
            "be a vector in the plane.", self.text)

    def test_display_formula_stays_in_its_sentence(self):
        # A block equation inside <p>; its &amp; column separators decoded.
        self.assertIn(
            "given by the rotation matrix: {\\displaystyle R={\\begin{pmatrix}"
            "\\cos \\theta &-\\sin \\theta \\\\\\sin \\theta &\\cos \\theta "
            "\\end{pmatrix}},} which can be viewed", self.text)

    def test_hidden_mathml_not_leaked(self):
        self.assertIn("<semantics>", self.html)
        self.assertNotIn("v = ( v 1 , v 2 )", self.text)   # MathML token text
        self.assertEqual(len(self.text.split()), 1179)      # 2,019 if leaked


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
