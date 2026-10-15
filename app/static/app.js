const $ = (id) => document.getElementById(id);
let sessionId;
try { sessionId = localStorage.getItem("ragSession"); } catch {}
if (!sessionId) {
  sessionId = crypto.randomUUID();
  try { localStorage.setItem("ragSession", sessionId); } catch {}
}
const headers = { "X-Session-Id": sessionId };
let answerCount = 0;

function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function renderDocs(names) {
  const ul = $("docs");
  ul.replaceChildren(...names.map((n) => el("li", "", n)));
}

async function api(path, opts = {}) {
  const res = await fetch(path, { ...opts, headers: { ...headers, ...(opts.headers || {}) } });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(body.detail || `Request failed (${res.status})`);
  return body;
}

async function loadDocs() {
  try { renderDocs((await api("/api/documents")).documents); }
  catch (e) { $("docs").replaceChildren(el("li", "err", e.message)); }
}

function scrollDown() { const m = $("messages"); m.scrollTop = m.scrollHeight; }

function renderAnswer(data) {
  const n = ++answerCount;
  const wrap = el("div", "msg bot");
  const answer = el("div", "answer");
  for (const seg of data.segments) {
    answer.append(document.createTextNode(seg.text));
    for (const id of seg.citations) {
      const sup = el("sup", "c", `[${id}]`);
      sup.title = "Jump to source";
      sup.onclick = () => {
        const src = document.getElementById(`src-${n}-${id}`);
        src.scrollIntoView({ behavior: "smooth", block: "center" });
        src.classList.add("flash");
        setTimeout(() => src.classList.remove("flash"), 900);
      };
      answer.append(sup);
    }
  }
  wrap.append(answer);
  if (data.sources.length) {
    const box = el("div", "sources");
    for (const s of data.sources) {
      const d = el("div", "src");
      d.id = `src-${n}-${s.id}`;
      d.append(el("b", "", `[${s.id}] `), el("span", "", `"${s.quote}"`), el("div", "t", s.title));
      box.append(d);
    }
    wrap.append(box);
  }
  const bits = [`${data.retrieved.length} chunks retrieved`, `${(data.latency_ms / 1000).toFixed(1)}s`];
  if (data.model) bits.unshift(data.model);
  wrap.append(el("div", "meta", bits.join(" · ")));
  return wrap;
}

async function ask(question) {
  $("suggest")?.remove();
  $("messages").append(el("div", "msg user", question));
  const pending = el("div", "msg bot typing");
  pending.innerHTML = "<span></span><span></span><span></span>";
  $("messages").append(pending);
  scrollDown();
  $("send").disabled = true;
  try {
    const data = await api("/api/ask", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ question }),
    });
    pending.replaceWith(renderAnswer(data));
  } catch (e) {
    pending.replaceWith(el("div", "msg bot err", e.message));
  } finally {
    $("send").disabled = false;
    scrollDown();
  }
}

$("form").addEventListener("submit", (e) => {
  e.preventDefault();
  const q = $("q").value.trim();
  if (q.length < 2) return;
  $("q").value = "";
  ask(q);
});
$("q").addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); $("form").requestSubmit(); }
});
$("suggest").addEventListener("click", (e) => {
  if (e.target.tagName === "BUTTON") ask(e.target.textContent);
});

async function upload(file) {
  const label = $("dropText");
  const original = label.innerHTML;
  label.textContent = `Indexing ${file.name}...`;
  const form = new FormData();
  form.append("file", file);
  try {
    const data = await api("/api/documents", { method: "POST", body: form });
    renderDocs(data.documents);
    label.textContent = `Added ${data.document} (${data.chunks} chunks)`;
  } catch (e) {
    label.innerHTML = "";
    label.append(el("span", "err", e.message));
  }
  setTimeout(() => { label.innerHTML = original; }, 3500);
}

$("file").addEventListener("change", (e) => { if (e.target.files[0]) upload(e.target.files[0]); e.target.value = ""; });
const drop = $("drop");
drop.addEventListener("dragover", (e) => { e.preventDefault(); drop.classList.add("over"); });
drop.addEventListener("dragleave", () => drop.classList.remove("over"));
drop.addEventListener("drop", (e) => {
  e.preventDefault(); drop.classList.remove("over");
  if (e.dataTransfer.files[0]) upload(e.dataTransfer.files[0]);
});

loadDocs();
