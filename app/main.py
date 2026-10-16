"""FastAPI entry point: upload documents, ask questions, get cited answers."""

from __future__ import annotations

import io
import logging
import os
import threading
import time
import uuid
from collections import OrderedDict, defaultdict, deque
from datetime import date
from pathlib import Path

import anthropic
from fastapi import FastAPI, Header, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field
from pypdf import PdfReader

from .qa import MODEL, answer_question
from .rag import Embedder, FastEmbedder, VectorIndex

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
log = logging.getLogger("rag-doc-qa")

BASE_DIR = Path(__file__).resolve().parent
SAMPLE_DOCS_DIR = Path(os.getenv("SAMPLE_DOCS_DIR", BASE_DIR.parent / "sample_docs"))

MAX_UPLOAD_BYTES = int(os.getenv("MAX_UPLOAD_MB", "5")) * 1024 * 1024
MAX_DOCS_PER_SESSION = int(os.getenv("MAX_DOCS_PER_SESSION", "5"))
MAX_SESSIONS = int(os.getenv("MAX_SESSIONS", "200"))
SESSION_TTL_SECONDS = int(os.getenv("SESSION_TTL_SECONDS", "3600"))
RATE_LIMIT_PER_MINUTE = int(os.getenv("RATE_LIMIT_PER_MINUTE", "8"))
DAILY_QUESTION_CAP = int(os.getenv("DAILY_QUESTION_CAP", "300"))
ALLOWED_SUFFIXES = {".pdf", ".txt", ".md"}
# Set to "cloudfront-viewer-address" when the app is only reachable through CloudFront
# (enforced by the load balancer's security group), so per-visitor rate limiting sees the real IP.
TRUSTED_CLIENT_IP_HEADER = os.getenv("TRUSTED_CLIENT_IP_HEADER", "").lower()

SECURITY_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
        "connect-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"
    ),
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "strict-origin-when-cross-origin",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
}


def extract_text(filename: str, data: bytes) -> str:
    if filename.lower().endswith(".pdf"):
        reader = PdfReader(io.BytesIO(data))
        return "\n\n".join(page.extract_text() or "" for page in reader.pages)
    return data.decode("utf-8", errors="replace")


class SessionStore:
    """Each visitor gets a private copy of the sample index; uploads never leak between visitors."""

    def __init__(self, base: VectorIndex):
        self._base = base
        self._sessions: OrderedDict[str, tuple[float, VectorIndex]] = OrderedDict()
        self._lock = threading.Lock()

    def get(self, session_id: str) -> VectorIndex:
        now = time.monotonic()
        with self._lock:
            for sid, (seen, _) in list(self._sessions.items()):
                if now - seen > SESSION_TTL_SECONDS:
                    del self._sessions[sid]
            if session_id in self._sessions:
                index = self._sessions.pop(session_id)[1]
            else:
                index = self._base.copy()
            self._sessions[session_id] = (now, index)
            while len(self._sessions) > MAX_SESSIONS:
                self._sessions.popitem(last=False)
            return index


class RateLimiter:
    """Sliding-window per-client limit plus a global daily cap to bound API spend."""

    def __init__(self, per_minute: int, daily_cap: int):
        self.per_minute = per_minute
        self.daily_cap = daily_cap
        self._hits: dict[str, deque[float]] = defaultdict(deque)
        self._day = date.today()
        self._day_count = 0
        self._lock = threading.Lock()

    def check(self, client_id: str) -> None:
        now = time.monotonic()
        with self._lock:
            if date.today() != self._day:
                self._day, self._day_count = date.today(), 0
            if self._day_count >= self.daily_cap:
                raise HTTPException(429, "The demo has reached its daily question limit. Please try again tomorrow.")
            hits = self._hits[client_id]
            while hits and now - hits[0] > 60:
                hits.popleft()
            if len(hits) >= self.per_minute:
                raise HTTPException(429, "Too many questions - please wait a minute and try again.")
            hits.append(now)
            self._day_count += 1


def client_ip(request: Request) -> str:
    if TRUSTED_CLIENT_IP_HEADER:
        viewer = request.headers.get(TRUSTED_CLIENT_IP_HEADER)
        if viewer:
            # CloudFront-Viewer-Address is "ip:port" (IPv6 addresses contain colons too).
            return viewer.rsplit(":", 1)[0]
    # Behind a load balancer the real client is the right-most X-Forwarded-For entry;
    # anything to its left is client-supplied and can be spoofed.
    forwarded = request.headers.get("x-forwarded-for")
    if forwarded:
        return forwarded.split(",")[-1].strip()
    return request.client.host if request.client else "unknown"


class AskRequest(BaseModel):
    question: str = Field(min_length=2, max_length=1000)


def create_app(embedder: Embedder | None = None, claude: anthropic.Anthropic | None = None) -> FastAPI:
    app = FastAPI(title="RAG Doc Q&A", version="1.0.0", docs_url=None, redoc_url=None, openapi_url=None)

    @app.middleware("http")
    async def security_headers(request: Request, call_next):
        response = await call_next(request)
        response.headers.update(SECURITY_HEADERS)
        return response

    embedder = embedder or FastEmbedder()

    base = VectorIndex(embedder)
    for path in sorted(SAMPLE_DOCS_DIR.glob("*")):
        if path.suffix.lower() in ALLOWED_SUFFIXES:
            n = base.add_document(path.name, extract_text(path.name, path.read_bytes()))
            log.info("loaded sample doc %s (%d chunks)", path.name, n)

    sessions = SessionStore(base)
    limiter = RateLimiter(RATE_LIMIT_PER_MINUTE, DAILY_QUESTION_CAP)
    state = {"claude": claude}

    def get_claude() -> anthropic.Anthropic:
        if state["claude"] is None:
            if not os.getenv("ANTHROPIC_API_KEY"):
                raise HTTPException(503, "Server is missing ANTHROPIC_API_KEY.")
            state["claude"] = anthropic.Anthropic()
        return state["claude"]

    def session_index(session_id: str | None) -> VectorIndex:
        try:
            return sessions.get(str(uuid.UUID(session_id or "")))
        except ValueError:
            raise HTTPException(400, "Missing or invalid X-Session-Id header.") from None

    @app.api_route("/healthz", methods=["GET", "HEAD"])
    def healthz() -> dict:
        return {"status": "ok", "model": MODEL}

    @app.get("/api/documents")
    def list_documents(x_session_id: str | None = Header(default=None)) -> dict:
        return {"documents": session_index(x_session_id).doc_names}

    @app.post("/api/documents")
    async def upload_document(file: UploadFile, x_session_id: str | None = Header(default=None)) -> dict:
        index = session_index(x_session_id)
        name = Path(file.filename or "document.txt").name
        if Path(name).suffix.lower() not in ALLOWED_SUFFIXES:
            raise HTTPException(415, "Only .pdf, .txt and .md files are supported.")
        if len(index.doc_names) >= MAX_DOCS_PER_SESSION + len(base.doc_names):
            raise HTTPException(409, f"You can upload up to {MAX_DOCS_PER_SESSION} documents per session.")
        if name in index.doc_names:
            raise HTTPException(409, f"'{name}' is already loaded.")

        data = await file.read(MAX_UPLOAD_BYTES + 1)
        if len(data) > MAX_UPLOAD_BYTES:
            raise HTTPException(413, f"Files must be under {MAX_UPLOAD_BYTES // (1024 * 1024)} MB.")
        try:
            text = extract_text(name, data)
        except Exception:
            raise HTTPException(422, "Couldn't read that file. Is it a valid PDF?") from None

        chunks = index.add_document(name, text)
        if chunks == 0:
            raise HTTPException(422, "No text found in that file (scanned PDFs aren't supported).")
        log.info("session upload %s (%d chunks)", name, chunks)
        return {"document": name, "chunks": chunks, "documents": index.doc_names}

    @app.post("/api/ask")
    def ask(body: AskRequest, request: Request, x_session_id: str | None = Header(default=None)) -> dict:
        index = session_index(x_session_id)
        limiter.check(client_ip(request))
        started = time.perf_counter()
        hits = index.search(body.question)
        try:
            result = answer_question(get_claude(), body.question, [chunk for chunk, _ in hits])
        except anthropic.RateLimitError:
            raise HTTPException(429, "The AI service is busy - please retry in a moment.") from None
        except anthropic.APIStatusError as e:
            log.error("Claude API error %s: %s", e.status_code, e.message)
            raise HTTPException(502, "The AI service returned an error.") from None
        except anthropic.APIConnectionError:
            raise HTTPException(502, "Couldn't reach the AI service.") from None
        result["retrieved"] = [{"title": c.title, "score": round(s, 3)} for c, s in hits]
        result["latency_ms"] = round((time.perf_counter() - started) * 1000)
        log.info("answered in %dms with %d chunks", result["latency_ms"], len(hits))
        return result

    app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")

    @app.api_route("/", methods=["GET", "HEAD"], include_in_schema=False)
    def index_page() -> FileResponse:
        return FileResponse(BASE_DIR / "static" / "index.html")

    return app
