"""Fetch Wikipedia category listings and article text, caching to raw/.

Spec: docs/main_dish_spec/03_corpus.md. Every response is cached on disk, so a
re-run makes no requests for anything already fetched, and an interrupted run
resumes where it stopped.

The API returns only ONE whole-article extract per request (it lowers
`exlimit` to 1 unless `exintro` is set), so articles are fetched one at a time.
"""

import json
import time
import urllib.error
import urllib.parse
import urllib.request

from python import config

RETRYABLE = {429, 500, 502, 503, 504}
ATTEMPTS = 4

_last_request = 0.0


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
        raise RuntimeError(f"Wikipedia API error: {data['error']}")
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
    [{'pageid', 'title'}]. Subcategories are not followed."""
    def produce():
        members, cont = [], {}
        while True:
            data = _get({"list": "categorymembers",
                         "cmtitle": f"Category:{category}",
                         "cmnamespace": 0, "cmtype": "page", "cmlimit": "max",
                         **cont})
            members += [{"pageid": m["pageid"], "title": m["title"]}
                        for m in data["query"]["categorymembers"]]
            if "continue" not in data:
                return members
            cont = data["continue"]

    slug = urllib.parse.quote(category, safe="")
    return _cached(config.RAW_DIR / "categories" / f"{slug}.json", produce)


def fetch_article(pageid):
    """Current plain text of one article with the revision it came from, as
    {'pageid', 'revid', 'title', 'url', 'text'}, or None if it is missing.

    Text and revid come from the same request, so they always match."""
    def produce():
        data = _get({"pageids": pageid,
                     "prop": "extracts|revisions|info",
                     "explaintext": 1, "rvprop": "ids", "inprop": "url"})
        page = data["query"]["pages"][0]
        if page.get("missing") or "extract" not in page:
            return None
        return {"pageid": page["pageid"],
                "revid": page["revisions"][0]["revid"],
                "title": page["title"],
                "url": page["fullurl"],
                "text": page["extract"]}

    return _cached(config.RAW_DIR / "articles" / f"{pageid}.json", produce)
