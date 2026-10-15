from app.rag import VectorIndex, chunk_text

from .conftest import HashEmbedder


def test_chunk_text_respects_max_size_and_keeps_all_content():
    text = "\n\n".join(f"Paragraph {i} " + "word " * 60 for i in range(20))
    chunks = chunk_text(text, max_chars=500, overlap=100)
    assert len(chunks) > 1
    assert all(len(c) <= 500 for c in chunks)
    for i in range(20):
        assert any(f"Paragraph {i} " in c for c in chunks)


def test_chunk_text_hard_splits_oversized_paragraph():
    chunks = chunk_text("x" * 3000, max_chars=1000, overlap=100)
    assert all(len(c) <= 1000 for c in chunks)
    assert len(chunks) >= 3


def test_chunk_text_empty():
    assert chunk_text("   \n\n  ") == []


def test_search_ranks_relevant_chunk_first():
    index = VectorIndex(HashEmbedder())
    index.add_document("pets.md", "Cats sleep most of the day and love warm windowsills.")
    index.add_document("cloud.md", "Terraform provisions AWS infrastructure such as ECS clusters.")
    hits = index.search("how does terraform provision ECS on AWS", min_score=0.0)
    assert hits[0][0].doc_name == "cloud.md"


def test_copy_is_independent():
    base = VectorIndex(HashEmbedder())
    base.add_document("a.md", "alpha beta gamma")
    clone = base.copy()
    clone.add_document("b.md", "delta epsilon")
    assert base.doc_names == ["a.md"]
    assert clone.doc_names == ["a.md", "b.md"]
