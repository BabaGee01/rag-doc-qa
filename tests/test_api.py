from fastapi.testclient import TestClient

from app.main import create_app

from .conftest import FakeClaude, HashEmbedder

SAMPLE = "northwind-oncall-handbook.md"
QUESTION = {"question": "How fast must a SEV1 be acknowledged?"}


def test_healthz(client):
    assert client.get("/healthz").json()["status"] == "ok"


def test_head_requests_for_uptime_monitors(client):
    assert client.head("/").status_code == 200
    assert client.head("/healthz").status_code == 200


def test_index_page_served(client):
    res = client.get("/")
    assert res.status_code == 200
    assert "RAG Doc Q&amp;A" in res.text


def test_sample_docs_loaded(client, session):
    assert client.get("/api/documents", headers=session).json()["documents"] == [SAMPLE]


def test_session_header_required(client):
    assert client.get("/api/documents").status_code == 400
    assert client.get("/api/documents", headers={"X-Session-Id": "not-a-uuid"}).status_code == 400


def test_ask_returns_cited_answer(client, session, fake_claude):
    res = client.post("/api/ask", json=QUESTION, headers=session)
    assert res.status_code == 200
    data = res.json()
    assert data["segments"][0]["citations"] == [1]  # duplicate citation de-duplicated
    assert data["segments"][1]["citations"] == []
    assert data["sources"][0]["title"].startswith(SAMPLE)
    assert data["retrieved"]

    call = fake_claude.calls[0]
    assert call["model"] == "claude-opus-5"
    assert call["fallbacks"] == "default"
    docs = [b for b in call["messages"][0]["content"] if b["type"] == "document"]
    assert docs and all(d["citations"] == {"enabled": True} for d in docs)


def test_refusal_is_handled(session):
    app = create_app(embedder=HashEmbedder(), claude=FakeClaude(stop_reason="refusal"))
    res = TestClient(app).post("/api/ask", json=QUESTION, headers=session)
    assert res.json()["sources"] == []
    assert "can't help" in res.json()["segments"][0]["text"]


def test_upload_is_isolated_per_session(client, session):
    res = client.post(
        "/api/documents",
        files={"file": ("notes.txt", b"The staging database password rotates every 30 days.", "text/plain")},
        headers=session,
    )
    assert res.status_code == 200
    assert res.json()["documents"] == [SAMPLE, "notes.txt"]

    other = {"X-Session-Id": "3f1c9a52-7d0e-4b8e-9d55-1f2a3b4c5d6e"}
    assert client.get("/api/documents", headers=other).json()["documents"] == [SAMPLE]


def test_upload_rejects_bad_type_and_duplicates(client, session):
    bad = client.post("/api/documents", files={"file": ("x.exe", b"MZ", "application/octet-stream")}, headers=session)
    assert bad.status_code == 415
    dup = client.post("/api/documents", files={"file": (SAMPLE, b"hello there", "text/markdown")}, headers=session)
    assert dup.status_code == 409


def test_rate_limit(client, session, monkeypatch):
    import app.main as main

    monkeypatch.setattr(main, "RATE_LIMIT_PER_MINUTE", 2)
    limited = TestClient(create_app(embedder=HashEmbedder(), claude=FakeClaude()))
    codes = [limited.post("/api/ask", json=QUESTION, headers=session).status_code for _ in range(3)]
    assert codes == [200, 200, 429]


def test_question_validation(client, session):
    assert client.post("/api/ask", json={"question": "x" * 1001}, headers=session).status_code == 422


def test_security_headers(client):
    headers = client.get("/").headers
    assert "script-src 'self';" in headers["content-security-policy"]
    assert headers["x-frame-options"] == "DENY"
    assert client.get("/docs").status_code == 404  # API explorer disabled in production


def test_client_ip_prefers_trusted_header(monkeypatch):
    from starlette.requests import Request

    import app.main as main

    def request(headers):
        return Request({"type": "http", "headers": [(k.encode(), v.encode()) for k, v in headers.items()]})

    spoofed = {"x-forwarded-for": "6.6.6.6, 203.0.113.9", "cloudfront-viewer-address": "2001:db8::1:51234"}
    assert main.client_ip(request(spoofed)) == "203.0.113.9"
    monkeypatch.setattr(main, "TRUSTED_CLIENT_IP_HEADER", "cloudfront-viewer-address")
    assert main.client_ip(request(spoofed)) == "2001:db8::1"
