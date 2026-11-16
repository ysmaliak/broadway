"""A new tab's label settles once: the best title known from the first frame,
then the page's own, never a run of interim values (2026-11-05).

Build first (`./build.sh`), then `python3 Tests/tab_title.py`. Hidden, in a
world of its own. `--write before` or `--write after` also writes what each
case's label went through to `.context/before.md` or `.context/after.md`.
`--real` adds a few real sites (no accounts), when the network allows.
"""
import json
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-title")

SPA = """<!doctype html><title>App</title><body>booting<script>
const steps = [[40, 'Loading…'], [120, 'Loading… 40%'], [220, 'Mail'], [300, 'Inbox (3) – Mail']];
for (const [at, name] of steps) setTimeout(() => { document.title = name }, at);
</script>"""

LATE_SPA = """<!doctype html><body>booting<script>
window.addEventListener('load', () => {
  setTimeout(() => { document.title = 'Loading…' }, 60);
  setTimeout(() => { document.title = 'Board – Tracker' }, 260);
});
</script>"""

LINKS = """<!doctype html><title>Links</title><body style="margin:0">
<p style="margin:0;padding:40px"><a id="blank" target="_blank" href="/slow/blanky">Blank link words</a></p>
<p style="margin:0;padding:40px"><a id="cmd" href="/slow/cmdy" title="Cmd link title">Cmd link words</a></p>
<p style="margin:0;padding:40px"><a id="noisy" target="_blank" href="/spa">Spa link</a></p>
</body>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        path = self.path.split("?")[0]
        if path.startswith("/wait"):
            time.sleep(1.2)
            body, kind = b"GIF89a\x01\x00\x01\x00\x00\x00\x00;", "image/gif"
        elif path.startswith("/slow/"):
            name = path[len("/slow/"):]
            body = f"<!doctype html><title>Slow {name}</title><p>{name}<img src='/wait?{name}'>".encode()
            kind = "text/html"
        elif path.startswith("/r/"):
            self.send_response(302)
            self.send_header("Location", f"http://localhost:{port}/slow/{path[3:]}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        elif path == "/none":
            body, kind = b"<!doctype html><p>no title here<img src='/wait?none'>", "text/html"
        elif path == "/spa":
            body, kind = SPA.encode(), "text/html"
        elif path == "/late":
            body, kind = LATE_SPA.encode(), "text/html"
        elif path == "/feed.xml":
            item = f"<item><title>Live item one</title><link>http://127.0.0.1:{port}/slow/live1</link><guid>live1</guid></item>"
            body = f"<?xml version='1.0'?><rss version='2.0'><channel><title>Feed</title><link>http://127.0.0.1:{port}/</link>{item}</channel></rss>".encode()
            kind = "application/rss+xml"
        elif path == "/links":
            body, kind = LINKS.encode(), "text/html"
        else:
            name = path.strip("/")
            body, kind = f"<!doctype html><title>Page {name}</title><p>{name}".encode(), "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind + ("; charset=utf-8" if kind.startswith("text/") else ""))
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"
HOST = "127.0.0.1"
LOCAL = "localhost"

results = []


def titles():
    return sv.cmd({"do": "titles"})["tabs"]


def tab(id):
    return next((x for x in titles() if x["id"] == id), None)


def ids():
    return {x["id"] for x in titles()}


def active():
    return next(x for x in titles() if x["active"])


def idle(id, rest=1.2, within=12):
    until = time.time() + within
    quiet = None
    last = None
    while time.time() < until:
        x = tab(id)
        if x is None:
            return None
        key = (x["loading"], len(x["trace"]))
        if not x["loading"] and key == last:
            quiet = quiet or time.time()
            if time.time() - quiet >= rest:
                return x
        else:
            quiet = None
        last = key
        time.sleep(0.1)
    return tab(id)


def labels(trace, after_blank=False):
    seq = [label for _, label in trace]
    if after_blank:
        while seq and seq[0] == "New Tab":
            seq = seq[1:]
    return seq


def record(t, name, x, first, final, after_blank=False, note=""):
    trace = x["trace"] if x else []
    seq = labels(trace, after_blank)
    results.append({"case": name, "trace": trace, "note": note})
    print(f"  {name}: {' → '.join(repr(s) for s in seq)}")
    want = 1 if first is not None and first == final else 2
    t.ok(f"{name}: changes at most once", len(seq) <= want, seq)
    if first is not None:
        t.ok(f"{name}: starts with {first!r}", bool(seq) and seq[0] == first, seq)
    if final is not None:
        t.ok(f"{name}: ends with {final!r}", bool(seq) and seq[-1] == final, seq)


def new_tab():
    before = ids()
    sv.sp("newTab")
    time.sleep(0.6)
    made = ids() - before
    return made.pop() if made else active()["id"]


def typed(text):
    id = new_tab()
    sv.cmd({"do": "field", "text": text, "go": True})
    return id


def opened_since(before, within=4):
    until = time.time() + within
    while time.time() < until:
        made = ids() - before
        if made:
            return made.pop()
        time.sleep(0.1)
    return None


def case_typed(t):
    id = typed(f"{BASE}/slow/typed")
    record(t, "⌘T, typed address", idle(id), f"{HOST}/slow/typed", "Slow typed", after_blank=True)


def case_search(t, real):
    if not real:
        return
    id = typed("rivers in spring")
    x = idle(id, within=15)
    record(t, "⌘T, search", x, None, None, after_blank=True, note="real engine")


def case_history(t):
    sv.cmd({"do": "titles", "history": f"{BASE}/slow/hist", "named": "Slow hist"})
    id = typed(f"{BASE}/slow/hist")
    record(t, "history pick (typed, known)", idle(id), "Slow hist", "Slow hist", after_blank=True)


def case_command(t):
    sv.cmd({"do": "titles", "history": f"{BASE}/slow/picked", "named": "Slow picked"})
    id = new_tab()
    sv.cmd({"do": "field", "text": f"{HOST}:{srv.server_port}/slow/pic", "type": True, "go": True})
    x = idle(id)
    record(t, "command bar pick", x, "Slow picked", "Slow picked", after_blank=True, note=x["url"] if x else "")


def case_bookmark(t):
    sv.cmd({"do": "titles", "mark": f"{BASE}/slow/marked", "named": "My marked page"})
    before = ids()
    sv.cmd({"do": "bookmark", "url": f"{BASE}/slow/marked", "new": True})
    id = opened_since(before) or active()["id"]
    record(t, "bookmark", idle(id), "My marked page", "Slow marked", after_blank=True)


def case_redirect(t):
    id = typed(f"{BASE}/r/moved")
    record(t, "redirect (302 to another host)", idle(id), f"{HOST}/r/moved", "Slow moved", after_blank=True)


def case_none(t):
    id = typed(f"{BASE}/none")
    record(t, "page with no title", idle(id), f"{HOST}/none", f"{HOST}/none", after_blank=True)


def case_spa(t):
    id = typed(f"{BASE}/spa")
    record(t, "single-page app, titles while booting", idle(id), f"{HOST}/spa", "Inbox (3) – Mail", after_blank=True)


def case_late_spa(t):
    id = typed(f"{BASE}/late")
    record(t, "single-page app, titles after load", idle(id), f"{HOST}/late", "Board – Tracker", after_blank=True)


def case_links(t):
    links = sv.sp("open", url=f"{BASE}/links")["resultID"]
    sv.cmd({"do": "select", "id": links})
    time.sleep(0.8)
    before = ids()
    sv.cmd({"do": "tap", "id": links, "selector": "#blank"})
    id = opened_since(before)
    record(t, "target=_blank link", idle(id) if id else None, "Blank link words", "Slow blanky")
    sv.cmd({"do": "select", "id": links})
    time.sleep(0.8)
    before = ids()
    sv.cmd({"do": "tap", "id": links, "selector": "#cmd", "mods": ["cmd"]})
    id = opened_since(before)
    if id:
        time.sleep(0.5)
        sv.cmd({"do": "select", "id": id})
    record(t, "⌘-click link (behind, then opened)", idle(id) if id else None, "Cmd link title", "Slow cmdy")


def case_idle_change(t):
    id = typed(f"{BASE}/p/chat")
    idle(id)
    sv.cmd({"do": "eval", "id": id, "js": "1"})
    time.sleep(0.5)
    delays, webkit, settling = [], [], []
    for n in range(1, 6):
        name = f"({n}) Page p/chat"
        start = time.time()
        sv.cmd({"do": "eval", "id": id, "js": f"document.title = {json.dumps(name)}"})
        sent = time.time()
        raw = None
        while time.time() - start < 2:
            x = tab(id)
            if x and raw is None and x["raw"] == name:
                raw = round((time.time() - sent) * 1000)
            if x and x["label"] == name:
                delays.append(round((time.time() - sent) * 1000))
                webkit.append(raw)
                settling.append(x["settling"])
                break
            time.sleep(0.005)
        time.sleep(0.3)
    print(f"  idle retitles: label {delays} ms, WebKit's own title {webkit} ms after the eval answered; settling {settling}")
    results.append({"case": "a deliberate retitle after load", "trace": tab(id)["trace"], "note": f"five retitles: label shown {delays} ms, WebKit's title {webkit} ms after the eval answered"})
    lag = [d - (w if w is not None else d) for d, w in zip(delays, webkit)]
    t.ok("a retitle after load shows as soon as WebKit has it", len(delays) == 5 and max(lag) < 50 and not any(settling), (delays, webkit, settling))


def case_restore(t):
    keep = [f"{BASE}/slow/kept", f"{BASE}/none"]
    made = []
    for url in keep:
        made.append(sv.sp("open", url=url)["resultID"])
        time.sleep(0.4)
    for id in made:
        idle(id)
    sv.sp("save")
    time.sleep(0.5)
    sv.quit()
    time.sleep(1)
    sv.launch()
    time.sleep(1)
    restored = {x["url"]: x for x in titles()}
    kept = restored.get(keep[0])
    if kept:
        sv.cmd({"do": "select", "id": kept["id"]})
        record(t, "restored session tab, then opened", idle(kept["id"]), "Slow kept", "Slow kept")
    else:
        t.ok("the session came back", False, list(restored))


def case_live(t):
    sv.cmd({"do": "live", "args": ["on"]})
    sv.cmd({"do": "live", "args": ["add", "Feed", f"{BASE}/feed.xml"]})
    sv.cmd({"do": "live", "args": ["update", "Feed"]})
    row = None
    until = time.time() + 40
    while time.time() < until and row is None:
        for folder in sv.cmd({"do": "live", "args": []}).get("folders", []):
            for x in folder.get("tabs", []):
                row = row or x
        time.sleep(0.3)
    if row is None:
        t.ok("live folder row came", False, sv.cmd({"do": "live", "args": []}))
        return
    sv.cmd({"do": "select", "id": row["id"]})
    record(t, "live-folder row, then opened", idle(row["id"]), "Live item one", "Slow live1")


def case_real(t, real):
    if not real:
        return
    for url, name in [("http://github.com", "real redirect (http://github.com)"),
                      ("https://en.wikipedia.org/wiki/River", "real heavy page (Wikipedia)")]:
        id = typed(url)
        record(t, name, idle(id, rest=2, within=25), None, None, after_blank=True, note="real site")


def write(kind):
    out = [f"# Tab label sequences, {kind}", "",
           "Every value the sidebar row's label took, with milliseconds since the tab was made "
           "(`python3 Tests/tab_title.py --write " + kind + "`).", ""]
    for r in results:
        out.append(f"## {r['case']}")
        if r["note"]:
            out.append(f"_{r['note']}_")
        out.append("")
        for at, label in r["trace"]:
            out.append(f"- {int(at):>5} ms  {label}")
        out.append("")
    Path(sv.ROOT, ".context", f"{kind}.md").write_text("\n".join(out))


def main():
    real = "--real" in sys.argv
    kind = sys.argv[sys.argv.index("--write") + 1] if "--write" in sys.argv else None
    t = sv.T()
    try:
        sv.setup(sidebar=True)
        sv.launch()
        only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
        for case in (case_typed, case_history, case_command, case_bookmark, case_redirect,
                     case_none, case_spa, case_late_spa, case_links, case_idle_change, case_live):
            if only and only not in case.__name__:
                continue
            try:
                case(t)
            except Exception as e:
                t.ok(case.__name__, False, repr(e))
        if not only:
            case_search(t, real)
            case_real(t, real)
            case_restore(t)
    finally:
        t.done()
        if kind:
            write(kind)
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
