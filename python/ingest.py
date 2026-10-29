"""Build the corpus: fetch, chunk, embed, load, index. One command.

Spec: docs/main_dish_spec/03_corpus.md and 02_architecture.md.

    python -m python.ingest                    # fresh corpus, writes the manifest
    python -m python.ingest --limit 20         # a small slice, for a smoke test
    python -m python.ingest --manifest corpus_manifest.csv   # reproduce one

Run sql/schema.sql first. This writes `articles`, `chunks`, `corpus_meta` and
`eval_queries`, then adds the vector index.

RESUMABLE in two independent ways, because a full run is ~22 minutes of
fetching plus a few minutes of embedding and should never have to start over:

  * fetched HTML is cached under raw/ by revision id (fetch.py), so a second
    run re-fetches nothing;
  * articles already present in the database are skipped, so an interrupted
    load continues where it stopped.

THE VECTOR INDEX IS ADDED LAST. Inserting into an already-indexed table
rebuilds the HNSW graph per row. sql/fixture.sql does the same, for the same
reason.

REPRODUCIBILITY. A fresh run pins every article to the revision id it actually
fetched and writes corpus_manifest.csv with a SHA-256 of the extracted text.
`--manifest` re-fetches exactly those revisions and reports how many hashes
match, rather than assuming they do: a revision renders with today's template
code, so formatting can drift even though the wikitext cannot (03_corpus.md).
"""

import argparse
import csv
import hashlib
import os
import sys
from pathlib import Path

import pymysql

from python import chunk, config, embed, fetch

MANIFEST = Path(__file__).resolve().parent.parent / "corpus_manifest.csv"
EVAL_QUERIES = Path(__file__).resolve().parent.parent / "eval_queries.csv"
MANIFEST_FIELDS = ["category", "pageid", "revid", "title", "words", "chunks",
                   "text_sha256"]

# Chunks to accumulate before one embedding call. See flush_batch().
EMBED_BATCH = 512


def connect():
    """Connect to wikirag. Overridable by environment, for CI and for
    Janhavi's server, which runs on 3307 because MySQL holds 3306."""
    return pymysql.connect(
        host=os.environ.get("WIKIRAG_HOST", "127.0.0.1"),
        port=int(os.environ.get("WIKIRAG_PORT", "3306")),
        user=os.environ.get("WIKIRAG_USER", "root"),
        password=os.environ.get("WIKIRAG_PASSWORD", ""),
        database=os.environ.get("WIKIRAG_DB", "wikirag"),
        charset="utf8mb4", autocommit=False)


def text_sha256(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def write_corpus_meta(cur):
    cur.execute("DELETE FROM corpus_meta")
    cur.execute(
        """INSERT INTO corpus_meta (embed_model, embed_dims, query_prefix,
                                    chunk_words, chunk_overlap, prepend_title,
                                    distance_metric)
           VALUES (%s, %s, %s, %s, %s, %s, 'cosine')""",
        (config.EMBED_MODEL, config.EMBED_DIMS, config.QUERY_PREFIX,
         config.CHUNK_TARGET_WORDS, config.CHUNK_OVERLAP_WORDS,
         config.PREPEND_TITLE))


def already_loaded(cur):
    cur.execute("SELECT pageid FROM articles")
    return {row[0] for row in cur.fetchall()}


def plan(limit, manifest_path):
    """What to fetch: either chosen live, or pinned by a manifest."""
    if manifest_path:
        with open(manifest_path, newline="", encoding="utf-8") as f:
            rows = list(csv.DictReader(f))
        wanted = [(r["category"], int(r["pageid"]), int(r["revid"]),
                   r["text_sha256"]) for r in rows]
        print(f"reproducing {len(wanted)} articles from {manifest_path}")
    else:
        selection = fetch.select_articles()
        wanted = [(key, m["pageid"], m["revid"], None)
                  for key, members in selection.items() for m in members]
        for key, members in selection.items():
            print(f"  {key:22s} {len(members):4d} articles")
        print(f"selected {len(wanted)} articles across "
              f"{len(selection)} categories")
    return wanted[:limit] if limit else wanted


def load_article(cur, category, page, chunks, digest, vecs):
    """Insert one article and its chunks. Embeddings are already computed."""
    cur.execute(
        """INSERT INTO articles (pageid, revid, title, url, category,
                                 word_count, text_sha256)
           VALUES (%s, %s, %s, %s, %s, %s, %s)""",
        (page["pageid"], page["revid"], page["title"], page["url"], category,
         sum(c.word_count for c in chunks), digest))
    article_id = cur.lastrowid
    cur.executemany(
        """INSERT INTO chunks (article_id, section, ordinal, body, word_count,
                               category, embedding)
           VALUES (%s, %s, %s, %s, %s, %s, VEC_FromText(%s))""",
        [(article_id, c.section, c.ordinal, c.body, c.word_count, category,
          vec) for c, vec in zip(chunks, vecs)])


def flush_batch(conn, batch):
    """Embed every chunk of several articles in ONE call, then insert them.

    Embedding is the bottleneck: measured on an 8-thread CPU, a call per
    article managed 4.4 chunks/sec against ~11 in bulk, because the per-call
    overhead dominates when an article has a few dozen chunks. Grouping is
    worth roughly 2.5x on a corpus this size. Articles are grouped, never
    split, so a commit is always a whole article and the resume logic in
    `already_loaded` stays correct."""
    if not batch:
        return
    texts = [c.embed_text for _, _, chunks, _ in batch for c in chunks]
    # 256 keeps a 4 GB GPU busy without risking VRAM; harmless on CPU,
    # where throughput is flat above 32 anyway (measured).
    vectors = embed.encode_passages(texts, batch_size=256, progress=False)
    at = 0
    with conn.cursor() as cur:
        for category, page, chunks, digest in batch:
            vecs = [embed.to_vec_text(v)
                    for v in vectors[at:at + len(chunks)]]
            at += len(chunks)
            load_article(cur, category, page, chunks, digest, vecs)
    conn.commit()


def has_vector_index(cur):
    cur.execute("""SELECT COUNT(*) FROM information_schema.STATISTICS
                   WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'chunks'
                     AND INDEX_NAME = 'embedding'""")
    return bool(cur.fetchone()[0])


def drop_vector_index(cur):
    """Drop the index before loading, so rows are inserted into an unindexed
    table. An earlier partial run (say `--limit 20`) leaves an index behind,
    and without this the rest of the corpus is inserted the slow way -- HNSW
    rebuilt per row -- silently, since the result is still correct."""
    if has_vector_index(cur):
        print("dropping the existing vector index; it is rebuilt after the "
              "load", flush=True)
        cur.execute("ALTER TABLE chunks DROP INDEX embedding")


def add_vector_index(cur):
    if has_vector_index(cur):
        return
    print("building the vector index ...", flush=True)
    # m = 16, not MariaDB's default 6. Measured on this corpus: m=6 caps
    # recall@10 at 0.94 and cannot reach 0.98 at any ef_search, while m=16
    # reaches 0.99 at the default ef_search for ~0.1 ms more per query
    # (docs/findings.md). It is a global, so it is set, used, and reported.
    cur.execute("SET GLOBAL mhnsw_default_m = %s", (config.HNSW_M,))
    cur.execute("ALTER TABLE chunks ADD VECTOR INDEX (embedding) "
                "DISTANCE=cosine")


def write_manifest():
    """The manifest, from the database -- so a resumed or continued ingest
    still writes a complete one. Sorted, so two runs of the same corpus give
    byte-identical files and a diff means something."""
    conn = connect()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """SELECT a.category, a.pageid, a.revid, a.title,
                          a.word_count, COUNT(c.id), a.text_sha256
                   FROM articles a LEFT JOIN chunks c ON c.article_id = a.id
                   GROUP BY a.id
                   ORDER BY a.category, a.pageid""")
            rows = cur.fetchall()
    finally:
        conn.close()
    with open(MANIFEST, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(MANIFEST_FIELDS)
        w.writerows(rows)
    return len(rows)


def load_eval_queries(cur):
    """Embed the evaluation questions, WITH the query prefix."""
    if not EVAL_QUERIES.exists():
        print(f"no {EVAL_QUERIES.name}; skipping evaluation queries")
        return 0
    with open(EVAL_QUERIES, newline="", encoding="utf-8") as f:
        rows = [r for r in csv.DictReader(f) if r.get("query_text")]
    cur.execute("DELETE FROM eval_ground_truth")
    cur.execute("DELETE FROM recall_runs")
    cur.execute("DELETE FROM eval_queries")
    vectors = embed.encode_queries([r["query_text"] for r in rows])
    # The id comes FROM THE CSV and is not left to AUTO_INCREMENT. Every
    # committed query selects its probe by id (`WHERE id = 1`), and
    # `DELETE FROM` does not reset AUTO_INCREMENT -- so loading the fixture and
    # then ingesting used to leave these rows numbered 55-108. `WHERE id = 1`
    # then matched nothing, @q became NULL, every VEC_DISTANCE_COSINE returned
    # NULL, and ORDER BY on a column of NULLs returned the first ten rows of
    # the table in storage order. Which are all birds, so the output looked
    # entirely plausible. Making the CSV authoritative is what stops that.
    cur.executemany(
        "INSERT INTO eval_queries (id, query_text, embedding) "
        "VALUES (%s, %s, VEC_FromText(%s))",
        [(int(r["id"]), r["query_text"], embed.to_vec_text(v))
         for r, v in zip(rows, vectors)])
    return len(rows)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--limit", type=int, default=0,
                    help="ingest only the first N articles (smoke test)")
    ap.add_argument("--manifest", metavar="CSV",
                    help="reproduce the corpus pinned by this manifest")
    args = ap.parse_args(argv)

    wanted = plan(args.limit, args.manifest)
    conn = connect()
    gone, matched, mismatched = [], 0, []
    try:
        with conn.cursor() as cur:
            write_corpus_meta(cur)
            drop_vector_index(cur)
            seen = already_loaded(cur)
            if seen:
                print(f"{len(seen)} articles already loaded; skipping those")
            conn.commit()

            batch, pending = [], 0
            for i, (category, pageid, revid, want_hash) in enumerate(wanted, 1):
                if pageid not in seen:
                    page = fetch.fetch_article(pageid, revid)
                    if page is None:
                        gone.append((category, pageid, revid))
                    else:
                        digest = text_sha256(page["text"])
                        if want_hash is not None:
                            if digest == want_hash:
                                matched += 1
                            else:
                                mismatched.append(page["title"])
                        chunks = chunk.chunk_article(page["title"],
                                                     page["text"])
                        if chunks:
                            batch.append((category, page, chunks, digest))
                            pending += len(chunks)
                        else:
                            gone.append((category, pageid, revid))
                if pending >= EMBED_BATCH or i == len(wanted):
                    flush_batch(conn, batch)
                    batch, pending = [], 0
                    cur.execute("SELECT COUNT(*) FROM chunks")
                    print(f"  {i}/{len(wanted)} articles, "
                          f"{cur.fetchone()[0]} chunks", flush=True)

            with conn.cursor() as cur:
                n_queries = load_eval_queries(cur)
                conn.commit()
                add_vector_index(cur)
                conn.commit()
                cur.execute("SELECT COUNT(*) FROM articles")
                n_articles = cur.fetchone()[0]
                cur.execute("SELECT COUNT(*) FROM chunks")
                n_chunks = cur.fetchone()[0]
    finally:
        conn.close()

    if not args.manifest and not args.limit:
        n = write_manifest()
        print(f"wrote {MANIFEST.name} ({n} articles)")
    elif not args.manifest:
        print(f"--limit given, so {MANIFEST.name} was NOT rewritten: a "
              f"partial corpus must not overwrite a complete manifest")

    print(f"\n{n_articles} articles, {n_chunks} chunks, "
          f"{n_queries} evaluation queries")
    if gone:
        print(f"{len(gone)} article(s) produced nothing and were skipped")
    if args.manifest:
        print(f"manifest check: {matched} of {matched + len(mismatched)} "
              f"article texts matched their recorded hash")
        for title in mismatched[:10]:
            print(f"  differs: {title}")
        if mismatched:
            print("A difference is expected where an article uses templates: "
                  "the revision is pinned, the template code is not "
                  "(03_corpus.md).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
