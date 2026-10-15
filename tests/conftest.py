import hashlib
import re
from types import SimpleNamespace

import numpy as np
import pytest
from fastapi.testclient import TestClient

from app.main import create_app


class HashEmbedder:
    """Deterministic bag-of-words embedder so tests don't download a model."""

    dim = 256

    def _vec(self, text: str) -> np.ndarray:
        v = np.zeros(self.dim, dtype=np.float32)
        for word in re.findall(r"[a-z0-9]+", text.lower()):
            v[int(hashlib.md5(word.encode()).hexdigest(), 16) % self.dim] += 1
        n = np.linalg.norm(v)
        return v / n if n else v

    def embed_passages(self, texts):
        return np.stack([self._vec(t) for t in texts])

    def embed_query(self, text):
        return self._vec(text)


class FakeClaude:
    """Mimics client.beta.messages.create and records the request."""

    def __init__(self, stop_reason="end_turn"):
        self.calls = []
        self.stop_reason = stop_reason
        self.beta = SimpleNamespace(messages=SimpleNamespace(create=self._create))

    def _create(self, **kwargs):
        self.calls.append(kwargs)
        docs = [b for b in kwargs["messages"][0]["content"] if b["type"] == "document"]
        cite = SimpleNamespace(
            document_index=0,
            start_char_index=0,
            end_char_index=20,
            document_title=docs[0]["title"],
            cited_text=docs[0]["source"]["data"][:20],
        )
        return SimpleNamespace(
            stop_reason=self.stop_reason,
            model=kwargs["model"],
            content=[
                SimpleNamespace(type="thinking", thinking=""),
                SimpleNamespace(type="text", text="Acknowledge within 5 minutes.", citations=[cite, cite]),
                SimpleNamespace(type="text", text=" That's it.", citations=None),
            ],
        )


@pytest.fixture
def fake_claude():
    return FakeClaude()


@pytest.fixture
def client(fake_claude):
    return TestClient(create_app(embedder=HashEmbedder(), claude=fake_claude))


@pytest.fixture
def session():
    return {"X-Session-Id": "8a6e0804-2bd0-4672-b79a-d97a1f9f8a01"}
