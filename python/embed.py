"""Turn text into vectors with the configured model. Thin by design.

Spec: docs/main_dish_spec/04_chunking_embedding.md.

The model runs locally, so `python -m python.ingest` needs no API key and no
account -- a reader can reproduce the corpus from the README alone, which is
requirement E6.

THE ASYMMETRY MATTERS. BGE models are trained with an instruction prefix on
the QUERY side only; passages are embedded bare. Prefixing both, or neither,
degrades retrieval quietly -- no error, just worse neighbours. That is why
there are two functions here instead of one with a flag, and why
`corpus_meta.query_prefix` records which prefix a corpus was built with.

NOT NORMALISED. `VEC_DISTANCE_COSINE` is scale-invariant, verified on a live
server (09_verified_findings.md, section 8), so unit-length vectors would
change nothing about the ranking. Skipping it keeps what is stored identical
to what the model emits.
"""

import os
import sys

from python import config

_model = None


def device():
    """'cuda' when a GPU is usable, else 'cpu'. Override with EMBED_DEVICE.

    Embedding is the ingest's bottleneck by a wide margin -- measured at ~11
    chunks/second on an 8-thread CPU, which makes the full corpus a multi-hour
    job and a GPU a few minutes. Nothing about the RESULT depends on the
    device: the same model and weights produce the same vectors either way,
    give or take floating-point ordering well below the precision stored.
    """
    forced = os.environ.get("EMBED_DEVICE")
    if forced:
        return forced
    try:
        import torch
        if torch.cuda.is_available():
            return "cuda"
        print("no CUDA device visible; embedding on CPU. A full ingest takes "
              "hours this way -- see docs/limitations.md section 5.",
              file=sys.stderr)
    except ImportError:
        pass
    return "cpu"


def model():
    """The embedding model, loaded once. First call downloads it (~130 MB)."""
    global _model
    if _model is None:
        from sentence_transformers import SentenceTransformer
        dev = device()
        print(f"loading {config.EMBED_MODEL} on {dev} ...", file=sys.stderr,
              flush=True)
        _model = SentenceTransformer(config.EMBED_MODEL, device=dev)
        dims = _model.get_sentence_embedding_dimension()
        if dims != config.EMBED_DIMS:
            raise RuntimeError(
                f"{config.EMBED_MODEL} emits {dims} dimensions, but config "
                f"and the VECTOR({config.EMBED_DIMS}) columns expect "
                f"{config.EMBED_DIMS}. Change both or neither.")
    return _model


def encode_passages(texts, batch_size=32, progress=True):
    """Embed chunk text. No prefix -- see the note above."""
    return model().encode(list(texts), batch_size=batch_size,
                          show_progress_bar=progress)


def encode_queries(texts, batch_size=32, progress=False):
    """Embed questions. The instruction prefix goes on, exactly once."""
    prefixed = [config.QUERY_PREFIX + t for t in texts]
    return model().encode(prefixed, batch_size=batch_size,
                          show_progress_bar=progress)


def to_vec_text(vector):
    """One vector as the '[a,b,c]' literal that VEC_FromText() parses."""
    return "[" + ",".join(f"{float(x):.6g}" for x in vector) + "]"
