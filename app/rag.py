"""Retrieval: chunking, embeddings and an in-memory vector index."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from typing import Protocol

import numpy as np

EMBED_MODEL = os.getenv("EMBED_MODEL", "BAAI/bge-small-en-v1.5")
EMBED_CACHE_DIR = os.getenv("EMBED_CACHE_DIR")  # baked into the image at build time


@dataclass(frozen=True)
class Chunk:
    doc_name: str
    part: int
    text: str

    @property
    def title(self) -> str:
        return f"{self.doc_name} (part {self.part})"


def chunk_text(text: str, max_chars: int = 1200, overlap: int = 200) -> list[str]:
    """Split text into ~max_chars chunks on paragraph boundaries, with overlap.

    Paragraphs longer than max_chars are hard-split so no chunk exceeds the limit.
    """
    text = re.sub(r"\r\n?", "\n", text).strip()
    if not text:
        return []

    paragraphs: list[str] = []
    for para in re.split(r"\n\s*\n", text):
        para = para.strip()
        while len(para) > max_chars:
            paragraphs.append(para[:max_chars])
            para = para[max_chars - overlap :]
        if para:
            paragraphs.append(para)

    chunks: list[str] = []
    current = ""
    for para in paragraphs:
        candidate = f"{current}\n\n{para}" if current else para
        if len(candidate) <= max_chars:
            current = candidate
            continue
        chunks.append(current)
        # Carry the tail of the previous chunk forward so answers spanning a
        # boundary are still retrievable.
        tail = current[-overlap:].split(" ", 1)[-1] if overlap else ""
        current = f"{tail}\n\n{para}" if tail and len(tail) + len(para) + 2 <= max_chars else para
    if current:
        chunks.append(current)
    return chunks


class Embedder(Protocol):
    def embed_passages(self, texts: list[str]) -> np.ndarray: ...
    def embed_query(self, text: str) -> np.ndarray: ...


class FastEmbedder:
    """Local ONNX embeddings via fastembed - no extra API key or GPU required."""

    def __init__(self, model_name: str = EMBED_MODEL, cache_dir: str | None = EMBED_CACHE_DIR):
        from fastembed import TextEmbedding

        self._model = TextEmbedding(model_name=model_name, cache_dir=cache_dir)

    @staticmethod
    def _normalise(vectors: np.ndarray) -> np.ndarray:
        norms = np.linalg.norm(vectors, axis=-1, keepdims=True)
        return vectors / np.clip(norms, 1e-12, None)

    def embed_passages(self, texts: list[str]) -> np.ndarray:
        return self._normalise(np.array(list(self._model.passage_embed(texts)), dtype=np.float32))

    def embed_query(self, text: str) -> np.ndarray:
        return self._normalise(np.array(next(iter(self._model.query_embed(text))), dtype=np.float32))


class VectorIndex:
    """Cosine-similarity search over normalised embeddings held in a numpy matrix."""

    def __init__(self, embedder: Embedder):
        self._embedder = embedder
        self.chunks: list[Chunk] = []
        self._matrix: np.ndarray | None = None

    def copy(self) -> VectorIndex:
        clone = VectorIndex(self._embedder)
        clone.chunks = list(self.chunks)
        clone._matrix = None if self._matrix is None else self._matrix.copy()
        return clone

    @property
    def doc_names(self) -> list[str]:
        return list(dict.fromkeys(c.doc_name for c in self.chunks))

    def add_document(self, name: str, text: str) -> int:
        pieces = chunk_text(text)
        if not pieces:
            return 0
        vectors = self._embedder.embed_passages(pieces)
        self.chunks.extend(Chunk(name, i + 1, t) for i, t in enumerate(pieces))
        self._matrix = vectors if self._matrix is None else np.vstack([self._matrix, vectors])
        return len(pieces)

    def search(self, query: str, k: int = 6, min_score: float = 0.3) -> list[tuple[Chunk, float]]:
        if self._matrix is None:
            return []
        scores = self._matrix @ self._embedder.embed_query(query)
        top = np.argsort(-scores)[:k]
        return [(self.chunks[i], float(scores[i])) for i in top if scores[i] >= min_score]
