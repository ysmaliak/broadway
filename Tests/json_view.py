#!/usr/bin/env python3
"""JSON documents open as a foldable tree, checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/json_view.py`. A local
server serves JSON under several types (nested, large, too large, invalid,
strings that look like HTML), and HTML pages that fetch JSON, embed it in
a script tag, or frame it, which must stay exactly as they were. The app
starts hidden in a world of its own (see split_view.use) and is driven
through ./bench's socket; copies stay inside the app on a test run. Window-
only pictures of the pages go to .context/ when that folder exists.
"""
import json
import os
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("json-view")

NESTED = {
    "name": "Broadway",
    "version": 3,
    "price": 12.5,
    "big": 12345678901234567890123,
    "ok": True,
    "off": False,
    "nothing": None,
    "home": "https://example.com/path?q=1",
    "items": [{"id": i, "tags": ["a", "b"], "meta": {"seen": i % 2 == 0}} for i in range(6)],
    "content-type": "application/json",
    "empty": {},
    "none": [],
}
NESTED_TEXT = json.dumps(NESTED, indent=None)
HOSTILE = {
    "<script>window.__ran=1</script>": "<img src=x onerror=\"window.__ran=2\">",
    "plain": "</pre><b>bold</b>",
}
HOSTILE_TEXT = json.dumps(HOSTILE)
ESCAPED = {
    'say "hi"': 'quoted "value"',
    "path\\key": "C:\\temp\\notes",
    "line\nkey": "line\nnext\ttab\bback\fform\rreturn\x00",
    "unicode": "Привет 😀",
    "link": "https://example.com/a\\b",
    "nested": [{"s": 'a"b\nc'}],
}
TOP_STRING = 'quote" slash\\ newline\n tab\t control\x00 Привет 😀'
LARGE = [{"id": i, "name": f"row {i}", "tags": ["x", "y", "z"], "score": i * 0.5, "on": i % 3 == 0} for i in range(30000)]
LARGE_TEXT = json.dumps(LARGE)
HUGE_TEXT = json.dumps([{"id": i, "pad": "z" * 200} for i in range(45000)])
INVALID_TEXT = '{\n  "a": 1,\n  "b": tru\n}'

PAGES = {
    "/nested": ("application/json", NESTED_TEXT),
    "/api": ("application/vnd.api+json; charset=utf-8", NESTED_TEXT),
    "/hostile": ("application/json", HOSTILE_TEXT),
    "/escaped": ("application/json", json.dumps(ESCAPED)),
    "/string": ("application/json", json.dumps(TOP_STRING)),
    "/large": ("application/json", LARGE_TEXT),
    "/huge": ("application/json", HUGE_TEXT),
    "/invalid": ("application/json", INVALID_TEXT),
    "/file.json": ("text/plain", NESTED_TEXT),
    "/notes.json": ("text/plain", "not json at all"),
    "/notes.txt": ("text/plain", NESTED_TEXT),
}
HTML = """<!doctype html><meta charset=utf-8><title>host</title>
<script type="application/json" id="data">{"inline": true}</script>
<pre id="shown">{"in": "html"}</pre>
<iframe id="frame" src="/nested"></iframe>
<script>
fetch('/nested').then(r => r.text()).then(t => { window.__fetched = t; });
var x = new XMLHttpRequest(); x.open('GET', '/api'); x.onload = () => { window.__xhr = x.responseText; }; x.send();
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        kind, text = PAGES.get(path, ("text/html; charset=utf-8", HTML))
        data = text.encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H
SHOTS = sv.ROOT / ".context"


def open_tab(path, wait=1.2):
    tab = sv.cmd({"do": "open", "url": f"{sv.BASE}{path}"})["id"]
    until = time.time() + 20
    while time.time() < until:
        if sv.ev(tab, "document.readyState") == "complete":
            break
        time.sleep(0.1)
    time.sleep(wait)
    return tab


def search(tab, js):
    return sv.cmd({"do": "eval", "id": tab, "js": js, "world": "search"}).get("value")


def mode(tab):
    return sv.ev(tab, "document.documentElement.getAttribute('data-broadway-json')")


def json_state(action="state"):
    return sv.cmd({"do": "json", "action": action})


def shot(tab, name):
    if not SHOTS.is_dir():
        return
    sv.cmd({"do": "select", "id": tab})
    time.sleep(0.6)
    sv.cmd({"do": "shot", "id": tab, "path": str(SHOTS / name), "width": 900})


def row_point(tab, path):
    js = f"""(() => {{ var id = window.__broadwayJSON.find({json.dumps(path)}); if (id < 0) return null;
      var line = document.querySelector('.aj-row[data-id="' + id + '"] > .aj-line');
      line.scrollIntoView({{block: 'center'}}); var r = line.getBoundingClientRect();
      return [r.left + 60, r.top + r.height / 2]; }})()"""
    return search(tab, js)


def menu_pick(tab, path, title):
    json_state("forget")
    point = row_point(tab, path)
    if not point:
        return None
    sv.cmd({"do": "linkmenu", "id": tab, "x": point[0], "y": point[1], "pick": title})
    until = time.time() + 5
    while time.time() < until:
        copied = json_state()["copied"]
        if copied:
            return copied
        time.sleep(0.1)
    return ""


def case_tree(t):
    tab = open_tab("/nested")
    t.ok("application/json opens as a tree", mode(tab) == "tree", mode(tab))
    shot(tab, "json-view-tree-light.png")
    t.ok("the raw <pre> is kept, hidden", sv.ev(tab, "getComputedStyle(document.querySelector('body > pre')).display") == "none")
    kinds = sv.ev(tab, "['aj-s','aj-n','aj-b','aj-z'].map(c => { var e = document.querySelector('.aj-tree .' + c); return e ? getComputedStyle(e).color : '' }).join('|')") or ""
    colours = kinds.split("|")
    t.ok("strings, numbers, booleans and null each have a colour", len(colours) == 4 and all(colours) and len(set(colours)) == 4, kinds)
    big = sv.ev(tab, "Array.from(document.querySelectorAll('.aj-n')).map(e => e.textContent).join(',')") or ""
    t.ok("a number past 2^53 is shown as sent", "12345678901234567890123" in big, big)
    order = sv.ev(tab, "Array.from(document.querySelectorAll('.aj-tree > .aj-row > .aj-kids > .aj-row > .aj-line > .aj-k')).map(e => e.textContent).join(',')")
    t.ok("keys keep the document's order", order == ",".join(NESTED.keys()), order)
    link = sv.ev(tab, "(document.querySelector('.aj-s a') || {}).href || ''")
    t.ok("a web address in a string is a link", link == NESTED["home"], link)
    items = search(tab, "window.__broadwayJSON.find('$.items')")
    search(tab, f"window.__broadwayJSON.open({items}, false)")
    count = sv.ev(tab, f"getComputedStyle(document.querySelector('.aj-row[data-id=\"{items}\"] > .aj-line > .aj-sum'), '::after').content")
    shut = sv.ev(tab, f"getComputedStyle(document.querySelector('.aj-row[data-id=\"{items}\"] > .aj-line > .aj-sum'), '::before').content")
    t.ok("a collapsed array shows […] and its count", count == '"6 items"' and shut == '"[…]"', (shut, count))
    sv.cmd({"do": "select", "id": tab})
    sv.cmd({"do": "tap", "id": tab, "selector": f".aj-row[data-id=\"{items}\"] > .aj-line > .aj-k"})
    time.sleep(0.3)
    t.ok("clicking a collapsed row opens it", search(tab, f"window.__broadwayJSON.open({items}, true)") is True and sv.ev(tab, f"document.querySelector('.aj-row[data-id=\"{items}\"]').classList.contains('aj-open')"))
    sv.cmd({"do": "tap", "id": tab, "selector": f".aj-row[data-id=\"{items}\"] > .aj-line > .aj-tog"})
    time.sleep(0.3)
    t.ok("clicking it again folds it", sv.ev(tab, f"document.querySelector('.aj-row[data-id=\"{items}\"] > .aj-kids').hidden") is True)
    search(tab, f"window.__broadwayJSON.open({items}, true)")
    copied = menu_pick(tab, "$.items[3].id", "Copy Path")
    t.ok("Copy Path in a row's menu gives $.items[3].id", copied == "$.items[3].id", copied)
    copied = menu_pick(tab, '$["content-type"]', "Copy Path")
    t.ok("a key that isn't a name is quoted in brackets", copied == '$["content-type"]', copied)
    copied = menu_pick(tab, "$.items[2]", "Copy Value")
    t.ok("Copy Value of an object is its JSON", copied and json.loads(copied) == NESTED["items"][2], copied)
    copied = menu_pick(tab, "$.home", "Copy Value")
    t.ok("Copy Value of a string is the string itself", copied == NESTED["home"], copied)
    copied = menu_pick(tab, "$.big", "Copy Value")
    t.ok("Copy Value of a long number keeps every digit", copied == "12345678901234567890123", copied)
    found = sv.cmd({"do": "find", "text": "application/json"})
    t.ok("⌘F finds a value in the tree", found.get("status", "").startswith("1 of 1"), found)
    found = sv.cmd({"do": "find", "text": "Collapse All"})
    t.ok("⌘F doesn't find the toolbar's words", "1 of" not in found.get("status", ""), found)
    sv.cmd({"do": "find", "close": True})
    text = sv.cmd({"do": "text", "id": tab})["text"]
    t.ok("the page's text shows the tree", "content-type" in text and "Expand All" not in text, text[:200])
    return tab


def case_modes(t, tab):
    sv.cmd({"do": "select", "id": tab})
    sv.cmd({"do": "tap", "id": tab, "selector": ".aj-seg button[aria-label=Pretty]"})
    time.sleep(0.4)
    t.ok("Pretty shows indented text", mode(tab) == "pretty" and json.loads(sv.ev(tab, "document.querySelector('.aj-pretty').textContent")) == NESTED)
    pretty = sv.ev(tab, "document.querySelector('.aj-pretty').textContent")
    t.ok("Pretty indents by two and keeps the long number", '\n  "name": "Broadway"' in pretty and "12345678901234567890123" in pretty)
    shot(tab, "json-view-pretty-light.png")
    t.ok("the mode is kept as pages.json", json_state()["mode"] == "pretty")
    kept = subprocess.run(["defaults", "read", sv.SUITE, "pages.json"], capture_output=True, text=True).stdout.strip()
    t.ok("…in the app's settings", kept == "pretty", kept)
    other = open_tab("/api")
    t.ok("the next JSON page opens in the kept mode", mode(other) == "pretty", mode(other))
    sv.cmd({"do": "select", "id": other})
    sv.cmd({"do": "tap", "id": other, "selector": ".aj-seg button[aria-label=Raw]"})
    time.sleep(0.4)
    t.ok("Raw shows the document exactly as sent", mode(other) == "raw" and sv.ev(other, "document.querySelector('body > pre').textContent") == NESTED_TEXT)
    t.ok("Raw hides the tree", sv.ev(other, "document.querySelector('.aj-tree').hidden && document.querySelector('.aj-pretty').hidden") is True)
    shot(other, "json-view-raw-light.png")
    sv.cmd({"do": "tap", "id": other, "selector": ".aj-seg button[aria-label=Tree]"})
    time.sleep(0.4)
    t.ok("back to Tree, and kept", mode(other) == "tree" and json_state()["mode"] == "tree")
    sv.cmd({"do": "close", "id": other})


def case_pretty_escaping(t):
    for path, expected in [("/escaped", ESCAPED), ("/string", TOP_STRING)]:
        tab = open_tab(path)
        sv.cmd({"do": "select", "id": tab})
        search(tab, "window.__broadwayJSON.show('pretty')")
        pretty = sv.ev(tab, "document.querySelector('.aj-pretty').textContent")
        try:
            actual = json.loads(pretty)
        except (TypeError, ValueError):
            actual = None
        t.ok(f"Pretty round-trips escaped strings and keys at {path}", mode(tab) == "pretty" and actual == expected, pretty)
        sv.cmd({"do": "close", "id": tab})


def case_hostile(t):
    tab = open_tab("/hostile")
    ran = sv.ev(tab, "String(window.__ran)")
    t.ok("a string's <script> and onerror run nothing", ran == "undefined" and search(tab, "String(window.__ran)") == "undefined", ran)
    t.ok("no element came from the data", sv.ev(tab, "document.querySelectorAll('.aj-tree img, .aj-tree script, .aj-tree b').length") == 0)
    text = sv.cmd({"do": "text", "id": tab})["text"]
    t.ok("the strings are shown as written", '<img src=x onerror="window.__ran=2">' in text and "<script>window.__ran=1</script>" in text and "</pre><b>bold</b>" in text, text)
    sv.cmd({"do": "close", "id": tab})


def case_invalid(t):
    tab = open_tab("/invalid")
    t.ok("invalid JSON stays as sent", mode(tab) == "raw" and sv.ev(tab, "document.querySelector('body > pre').textContent") == INVALID_TEXT)
    note = sv.ev(tab, "document.querySelector('.aj-note').textContent")
    t.ok("…with where it breaks", note and "line 3, column 8" in note, note)
    t.ok("…and Tree is not offered", sv.ev(tab, "document.querySelector('.aj-seg button[aria-label=Tree]').disabled") is True)
    shot(tab, "json-view-invalid-light.png")
    sv.cmd({"do": "close", "id": tab})


def case_names(t):
    tab = open_tab("/file.json")
    t.ok("a .json address sent as text/plain that parses is a tree", mode(tab) == "tree", mode(tab))
    sv.cmd({"do": "close", "id": tab})
    tab = open_tab("/notes.json")
    t.ok("a .json address that doesn't parse is left alone", mode(tab) is None and sv.ev(tab, "document.querySelectorAll('.aj-bar').length") == 0)
    sv.cmd({"do": "close", "id": tab})
    tab = open_tab("/notes.txt")
    t.ok("plain text JSON at another name is left alone", mode(tab) is None)
    sv.cmd({"do": "close", "id": tab})


def case_file(t):
    folder = Path(sv.SUPPORT) / "files"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "local.json").write_text(NESTED_TEXT)
    tab = sv.cmd({"do": "open", "url": (folder / "local.json").as_uri()})["id"]
    time.sleep(2)
    t.ok("a .json file on this Mac opens as a tree", mode(tab) == "tree", (mode(tab), sv.ev(tab, "document.contentType")))
    sv.cmd({"do": "close", "id": tab})


def case_untouched(t):
    tab = open_tab("/page.html", wait=2)
    t.ok("an HTML page is not taken over", mode(tab) is None and sv.ev(tab, "document.querySelectorAll('.aj-bar, .aj-tree').length") == 0)
    t.ok("JSON in a script tag is untouched", sv.ev(tab, "document.getElementById('data').textContent") == '{"inline": true}')
    t.ok("JSON in a <pre> of the page is untouched", sv.ev(tab, "document.getElementById('shown').outerHTML") == '<pre id="shown">{"in": "html"}</pre>')
    t.ok("the page's fetch gets the bytes as sent", sv.ev(tab, "window.__fetched") == NESTED_TEXT)
    t.ok("the page's XHR gets the bytes as sent", sv.ev(tab, "window.__xhr") == NESTED_TEXT)
    framed = sv.ev(tab, "(() => { var d = document.getElementById('frame').contentDocument; return d ? [d.documentElement.getAttribute('data-broadway-json'), d.querySelectorAll('.aj-bar').length, d.body.textContent] : null })()")
    t.ok("a JSON document in a frame stays raw", framed == [None, 0, NESTED_TEXT], framed)
    sv.cmd({"do": "close", "id": tab})


def case_large(t):
    start = time.time()
    tab = sv.cmd({"do": "open", "url": f"{sv.BASE}/large"})["id"]
    shown = None
    while time.time() - start < 20:
        if mode(tab) == "tree":
            shown = time.time() - start
            break
        time.sleep(0.05)
    t.ok(f"{len(LARGE_TEXT) / 1e6:.1f} MB opens as a tree", shown is not None, shown)
    print(f"        tree up {shown:.2f}s after the tab opened" if shown else "        never shown")
    rows = sv.ev(tab, "document.querySelectorAll('.aj-row').length")
    t.ok("only a slice is laid out", rows and rows <= 2000, rows)
    more = sv.ev(tab, "document.querySelectorAll('.aj-more').length")
    t.ok("a long array offers more", more and more >= 1, more)
    sv.cmd({"do": "select", "id": tab})
    sv.cmd({"do": "tap", "id": tab, "selector": ".aj-more .aj-btn"})
    time.sleep(0.5)
    after = sv.ev(tab, "document.querySelectorAll('.aj-tree > .aj-row > .aj-kids > .aj-row').length")
    t.ok("Show 500 More adds the next 500", after == 1000, after)
    path = search(tab, "window.__broadwayJSON.path(window.__broadwayJSON.find('$[999]'))")
    t.ok("rows past the first slice have their paths", path == "$[999]", path)
    shot(tab, "json-view-large-light.png")
    sv.cmd({"do": "close", "id": tab})
    start = time.time()
    tab = sv.cmd({"do": "open", "url": f"{sv.BASE}/huge"})["id"]
    while time.time() - start < 20 and mode(tab) is None:
        time.sleep(0.05)
    print(f"        huge document's bar up {time.time() - start:.2f}s after the tab opened")
    t.ok(f"{len(HUGE_TEXT) / 1e6:.1f} MB is shown as sent", mode(tab) == "raw", mode(tab))
    note = sv.ev(tab, "document.querySelector('.aj-note').textContent") or ""
    t.ok("…saying why, with Show Tree Anyway", "shown as sent" in note and sv.ev(tab, "!!document.querySelector('.aj-note .aj-btn')"), note)
    shot(tab, "json-view-huge-light.png")
    sv.cmd({"do": "select", "id": tab})
    sv.cmd({"do": "tap", "id": tab, "selector": ".aj-note .aj-btn"})
    until = time.time() + 20
    while time.time() < until and mode(tab) != "tree":
        time.sleep(0.1)
    t.ok("Show Tree Anyway lays it out", mode(tab) == "tree")
    t.ok("…without changing the kept mode", json_state()["mode"] == "tree")
    sv.cmd({"do": "close", "id": tab})


def case_agent(t):
    tab = open_tab("/nested")
    sv.cmd({"do": "select", "id": tab})
    sv.cmd({"do": "agent", "action": "copy"})
    copied, until = "", time.time() + 5
    while not copied and time.time() < until:
        time.sleep(0.2)
        copied = sv.cmd({"do": "agent"}).get("copied", "")
    t.ok("Copy for Agent gives the JSON as sent", NESTED_TEXT in copied, copied[:300])
    sv.cmd({"do": "close", "id": tab})


def case_dark(t):
    sv.quit()
    subprocess.run(["defaults", "write", sv.SUITE, "look", "dark"])
    subprocess.run(["defaults", "write", sv.SUITE, "pages.dusk", "-bool", "true"])
    sv.launch()
    tab = open_tab("/nested", wait=2.5)
    sv.cmd({"do": "select", "id": tab})
    time.sleep(1.5)
    ground = sv.ev(tab, "getComputedStyle(document.body).backgroundColor")
    t.ok("in the dark, the viewer is dark", ground == "rgb(30, 30, 30)", ground)
    state = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == tab), {})
    filtered = sv.ev(tab, "getComputedStyle(document.documentElement).filter")
    t.ok("Dark pages leaves it alone", not state.get("dusked") and filtered in ("none", ""), (state.get("dusked"), filtered))
    shot(tab, "json-view-tree-dark.png")
    sv.cmd({"do": "select", "id": tab})
    sv.cmd({"do": "tap", "id": tab, "selector": ".aj-seg button[aria-label=Pretty]"})
    time.sleep(0.4)
    shot(tab, "json-view-pretty-dark.png")
    sv.cmd({"do": "tap", "id": tab, "selector": ".aj-seg button[aria-label=Tree]"})
    tab = open_tab("/invalid")
    shot(tab, "json-view-invalid-dark.png")


def main():
    t = sv.T()
    try:
        sv.setup()
        subprocess.run(["defaults", "write", sv.SUITE, "look", "light"])
        sv.launch()
        tab = case_tree(t)
        case_modes(t, tab)
        case_pretty_escaping(t)
        case_hostile(t)
        case_invalid(t)
        case_names(t)
        case_file(t)
        case_untouched(t)
        case_large(t)
        case_agent(t)
        case_dark(t)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
