"""Fetch Wikipedia category listings and article text, caching to raw/.

Spec: docs/main_dish_spec/03_corpus.md. Every response is cached on disk, so a
re-run makes no requests for anything already fetched, and an interrupted run
resumes where it stopped.

Articles are fetched by revision id, never as "the current version": the
category listing records each article's current revid, and the text is then
rendered from exactly that revision with action=parse&oldid=. The TextExtracts
API (prop=extracts) is deliberately NOT used: it ignores the revision asked for
and returns the current text, while still reporting the old revid.
"""

import json
import time
import urllib.error
import urllib.parse
import urllib.request

from python import config
from python.htmltotext import html_to_text

RETRYABLE = {429, 500, 502, 503, 504}
ATTEMPTS = 4
GONE = {"nosuchrevid", "missingtitle", "permissiondenied"}  # deleted/hidden

_last_request = 0.0


class ApiError(RuntimeError):
    def __init__(self, error):
        super().__init__(f"Wikipedia API error: {error}")
        self.code = error.get("code")


def _get(params):
    """One API call, throttled to config.REQUEST_INTERVAL_S, with retries."""
    global _last_request
    query = urllib.parse.urlencode(
        {"action": "query", "format": "json", "formatversion": 2, **params})
    request = urllib.request.Request(f"{config.WIKI_API}?{query}",
                                     headers={"User-Agent": config.USER_AGENT})
    for attempt in range(ATTEMPTS):
        wait = config.REQUEST_INTERVAL_S - (time.monotonic() - _last_request)
        if wait > 0:
            time.sleep(wait)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                data = json.load(response)
            break
        except urllib.error.URLError as e:
            # HTTPError carries a status; a plain URLError is a network fault.
            if getattr(e, "code", 503) not in RETRYABLE or attempt == ATTEMPTS - 1:
                raise
            time.sleep(5 * 2 ** attempt)
        finally:
            _last_request = time.monotonic()
    if "error" in data:
        raise ApiError(data["error"])
    return data


def _cached(path, produce):
    """Return the JSON at `path`, calling produce() and saving it if absent."""
    if path.exists():
        return json.loads(path.read_text(encoding="utf-8"))
    value = produce()
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")  # write-then-rename: no half-written cache
    tmp.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
    tmp.replace(path)
    return value


def category_members(category):
    """Articles (namespace 0) directly in `Category:<category>`, as
    [{'pageid', 'title', 'length', 'revid'}]: length in wikitext bytes, revid
    the current revision, which pins what fetch_article later renders.
    Subcategories are not followed."""
    def produce():
        members, cont = {}, {}
        while True:
            data = _get({"generator": "categorymembers",
                         "gcmtitle": f"Category:{category}",
                         "gcmnamespace": 0, "gcmtype": "page",
                         "gcmlimit": "max", "prop": "info|revisions",
                         "rvprop": "ids", **cont})
            # A page's info and revisions can arrive in different batches.
            for p in data.get("query", {}).get("pages", []):
                m = members.setdefault(p["pageid"], {"pageid": p["pageid"],
                                                     "title": p["title"]})
                if "length" in p:
                    m["length"] = p["length"]
                if p.get("revisions"):
                    m["revid"] = p["revisions"][0]["revid"]
            if "continue" not in data:
                incomplete = [m["title"] for m in members.values()
                              if "length" not in m or "revid" not in m]
                if incomplete:
                    raise RuntimeError(f"{category}: no length/revid for {incomplete}")
                return sorted(members.values(), key=lambda m: m["pageid"])
            cont = data["continue"]

    slug = urllib.parse.quote(category, safe="")
    return _cached(config.RAW_DIR / "category_members" / f"{slug}.json", produce)


def select_articles(categories=config.CATEGORIES):
    """The articles to fetch, as {key: [member, ...]} (03_corpus.md).

    Overlap: an article belongs to the first category in `categories` that
    contains it, so it is fetched and stored once. Cap: of what is left, keep
    the ARTICLES_PER_CATEGORY longest, ties broken by lower pageid."""
    claimed, selection = set(), {}
    for key, category in categories:
        members = [m for m in category_members(category)
                   if not m["title"].startswith(config.NON_ARTICLE_PREFIXES)]
        eligible = [m for m in members if m["pageid"] not in claimed]
        claimed.update(m["pageid"] for m in members)
        eligible.sort(key=lambda m: (-m["length"], m["pageid"]))
        selection[key] = eligible[:config.ARTICLES_PER_CATEGORY]
    return selection


def fetch_article(pageid, revid):
    """Plain text of revision `revid` of an article, as
    {'pageid', 'revid', 'title', 'url', 'text'}, or None if that revision is
    gone (deleted or hidden).

    The rendered HTML is what gets cached, so a converter change needs no
    re-fetch. The same revid always gives the same article text; templates
    inside it render as they are today (03_corpus.md)."""
    def produce():
        try:
            data = _get({"action": "parse", "oldid": revid, "prop": "text",
                         "disableeditsection": 1, "disablelimitreport": 1})
        except ApiError as e:
            if e.code in GONE:
                return None
            raise
        page = data["parse"]
        if (page["pageid"], page["revid"]) != (pageid, revid):
            raise RuntimeError(f"asked for {pageid}@{revid}, got "
                               f"{page['pageid']}@{page['revid']}")
        return {"pageid": pageid, "revid": revid, "title": page["title"],
                "html": page["text"]}

    page = _cached(config.RAW_DIR / "revisions" / f"{revid}.json", produce)
    if page is None:
        return None
    path = urllib.parse.quote(page["title"].replace(" ", "_"))
    return {"pageid": pageid, "revid": revid, "title": page["title"],
            "url": config.WIKI_API.replace("/w/api.php", "/wiki/") + path,
            "text": html_to_text(page["html"])}
