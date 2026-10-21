"""Rendered article HTML (action=parse&prop=text) to plain text. Pure: no I/O.

Output matches what the TextExtracts API produced before we dropped it (it
cannot fetch an old revision): one paragraph or list item per line, headings
as `== Heading ==` lines for chunk.py, and no citations, tables, images,
navigation boxes, infoboxes, notices or reference lists. Standard library only.
"""

import re
from html.parser import HTMLParser

# Elements dropped with everything inside them.
DROP_TAGS = {"table", "figure", "style", "script", "audio", "video", "noscript"}
DROP_CLASSES = {
    "reference",             # citation markers, [1]
    "mw-editsection",        # [edit] links
    "references", "reflist", "mw-references-wrap",   # the reference list
    "navbox", "navbox-styles", "infobox", "sidebar", "metadata", "ambox",
    "hatnote",               # "This article is about..." notices
    "thumb", "gallery", "mw-empty-elt", "shortdescription", "side-box",
    "noprint",               # [citation needed] and similar
    "sortkey", "mw-cite-backlink", "toc", "catlinks",
}
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link",
        "meta", "param", "source", "track", "wbr"}
# Elements that end a line of output.
BLOCKS = {"p", "div", "li", "dd", "dt", "ul", "ol", "dl", "blockquote", "pre",
          "br", "section", "h1", "h2", "h3", "h4", "h5", "h6"}
HEADINGS = {"h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}

SPACES = re.compile(r"[ \t\r\n\f\xa0]+")


class _Extractor(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.lines, self.line = [], []
        self.skip_depth = 0      # >0 while inside a dropped element
        self.heading = None      # level while inside a heading

    def _dropped(self, tag, attrs):
        a = dict(attrs)
        classes = set((a.get("class") or "").split())
        style = (a.get("style") or "").replace(" ", "")
        return (tag in DROP_TAGS or classes & DROP_CLASSES
                or "display:none" in style)

    def _break(self):
        text = SPACES.sub(" ", "".join(self.line)).strip()
        if text:
            self.lines.append(text)
        self.line = []

    def handle_starttag(self, tag, attrs):
        if self.skip_depth:
            if tag not in VOID:
                self.skip_depth += 1
            return
        if self._dropped(tag, attrs):
            if tag not in VOID:
                self.skip_depth = 1
            return
        if tag == "img":
            # Maths renders as an image whose alt text is the LaTeX source.
            a = dict(attrs)
            if "mwe-math-fallback-image" in (a.get("class") or ""):
                self.line.append(a.get("alt") or "")
            return
        if tag in BLOCKS:
            self._break()
        if tag in HEADINGS:
            self.heading = HEADINGS[tag]

    def handle_startendtag(self, tag, attrs):
        # <br/>, <img/>: no end tag follows, so never open a skip here.
        if not self.skip_depth and not self._dropped(tag, attrs):
            self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if self.skip_depth:
            if tag not in VOID:
                self.skip_depth -= 1
            return
        if tag in HEADINGS and self.heading:
            title = SPACES.sub(" ", "".join(self.line)).strip()
            marks = "=" * self.heading
            self.lines += ["", f"{marks} {title} {marks}"]
            self.line, self.heading = [], None
        elif tag in BLOCKS:
            self._break()

    def handle_data(self, data):
        if not self.skip_depth:
            self.line.append(data)


def html_to_text(html):
    """Plain text of one article's rendered HTML."""
    parser = _Extractor()
    parser.feed(html)
    parser.close()
    parser._break()
    return "\n".join(parser.lines).strip()
