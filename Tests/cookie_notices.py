#!/usr/bin/env python3
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("cookie-notices")
t = sv.T()
REAL = sys.argv[sys.argv.index("--real") + 1] if "--real" in sys.argv else None
OUT = Path(__file__).resolve().parents[1] / ".context" / "cookie-notices"
LIST = """[Adblock Plus 2.0]
! Title: Cookie fixture
###onetrust-consent-sdk
##.cookie-notice-fixture
"""
PAGE = """<!doctype html><title>notice</title>
<style>.tall { height: 4000px }</style>
<div class="tall">article</div>
<div id="onetrust-consent-sdk"><div id="onetrust-banner-sdk">We use cookies</div></div>
<div class="cookie-notice-fixture" id="plain">Cookies?</div>
"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/list.txt":
            body, kind = LIST.encode(), "text/plain"
        elif path.startswith("/lists/") and REAL:
            body, kind = (Path(REAL) / path.removeprefix("/lists/")).read_bytes(), "text/plain"
        else:
            body, kind = PAGE.encode(), "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{srv.server_port}"


def shield(action, *values): return sv.cmd({"do": "shield", "action": action, "values": list(values)})


def value(id, js):
    answer = sv.cmd({"do": "eval", "id": id, "js": js}).get("value")
    return json.loads(answer) if isinstance(answer, str) else answer


def fetch(*addresses):
    try:
        return shield("fetch", *addresses)
    except RuntimeError as error:
        if "no answer" not in str(error):
            raise
    for _ in range(120):
        time.sleep(1)
        state = shield("state")
        if not state["busy"]:
            return state
    raise RuntimeError("the lists never finished compiling")


def go(id, url, seconds=10):
    sv.cmd({"do": "go", "id": id, "url": url})
    sv.cmd({"do": "wait", "id": id, "seconds": seconds})
    time.sleep(0.6)


FIXTURE = """JSON.stringify({
  banner: getComputedStyle(document.getElementById('onetrust-consent-sdk')).display,
  plain: getComputedStyle(document.getElementById('plain')).display})"""

LOOK = r"""(() => {
  const seen = e => { const r = e.getBoundingClientRect(), s = getComputedStyle(e);
    return r.width > 40 && r.height > 20 && s.display !== 'none' && s.visibility !== 'hidden' && +s.opacity > 0.05; };
  const known = ['#onetrust-consent-sdk', '#onetrust-banner-sdk', '#CybotCookiebotDialog', '#didomi-host', '.didomi-popup-container',
    '.fc-consent-root', '#usercentrics-root', '#usercentrics-cmp-ui', '[id^="sp_message_container"]', '#qc-cmp2-container', '#truste-consent-track',
    '#cmpbox', '#cmpwrapper', '#iubenda-cs-banner', '#cookie-law-info-bar', '#cookie-notice', '#cookie-banner', '#consent-banner',
    'iframe[src*="consent"]', 'iframe[src*="privacy-mgmt"]', '[aria-modal="true"]', '[role="dialog"]'];
  const found = known.filter(s => [...document.querySelectorAll(s)].some(seen));
  const words = [...document.querySelectorAll('div, section, aside, dialog, form')].filter(e => {
    if (!seen(e)) return false; const s = getComputedStyle(e); if (s.position !== 'fixed' && s.position !== 'sticky') return false;
    return /cookie|consent|privacy|gdpr|zgod|souhlas|einwillig/i.test((e.innerText || '').slice(0, 400)); }).slice(0, 3)
    .map(e => (e.tagName + '#' + e.id + '.' + String(e.className)).slice(0, 80) + ' ' + (e.innerText || '').slice(0, 60).replace(/s+/g, ' '));
  const look = e => { const s = getComputedStyle(e); return {overflow: s.overflowY, position: s.position,
    cls: String(e.className || '').slice(0, 160), style: (e.getAttribute('style') || '').slice(0, 160)}; };
  const cover = [...document.querySelectorAll('body *')].filter(e => { const s = getComputedStyle(e);
    if (s.position !== 'fixed') return false; const r = e.getBoundingClientRect();
    return r.width >= innerWidth * 0.9 && r.height >= innerHeight * 0.9 && seen(e); }).slice(0, 3)
    .map(e => (e.tagName + '#' + e.id + '.' + String(e.className)).slice(0, 80));
  const mid = document.elementFromPoint(innerWidth / 2, innerHeight / 2);
  const html = look(document.documentElement), body = document.body ? look(document.body) : {};
  const locked = ['hidden', 'clip'].includes(html.overflow) || ['hidden', 'clip'].includes(body.overflow) || body.position === 'fixed';
  return JSON.stringify({url: location.href, title: document.title.slice(0, 60), found, words, html, body, locked,
    tall: document.documentElement.scrollHeight, high: innerHeight, cover,
    mid: mid ? (mid.tagName + '#' + mid.id + '.' + String(mid.className)).slice(0, 80) : null,
    text: (document.body ? document.body.innerText.length : 0)});
})()"""

SITES = [
    "https://edition.cnn.com/",
    "https://apnews.com/",
    "https://www.theverge.com/",
    "https://www.dr.dk/",
    "https://politiken.dk/",
    "https://www.theguardian.com/europe",
    "https://www.spiegel.de/",
    "https://www.lemonde.fr/",
    "https://www.google.com/",
    "https://www.youtube.com/",
    "https://stackoverflow.com/questions",
    "https://www.ikea.com/pl/en/",
    "https://www.bbc.com/news",
    "https://www.reddit.com/",
]
if "--sites" in sys.argv:
    SITES = sys.argv[sys.argv.index("--sites") + 1].split(",")
SIX = ["easylist", "easyprivacy", "ublock", "ublock-privacy", "ublock-badware", "lowe"]


def survey(label):
    found = {}
    for start in range(0, len(SITES), 5):
        batch = SITES[start:start + 5]
        ids = [sv.cmd({"do": "open", "url": url})["id"] for url in batch]
        for id in ids:
            sv.cmd({"do": "wait", "id": id, "seconds": 25})
        time.sleep(8)
        for url, id in zip(batch, ids):
            try:
                found[url] = value(id, LOOK)
                value(id, "window.scrollTo(0, 0) || document.activeElement && document.activeElement.blur && document.activeElement.blur() || 0")
                sv.cmd({"do": "key", "id": id, "text": "   "})
                time.sleep(1.5)
                found[url]["spaced"] = value(id, "scrollY")
            except Exception as error:
                found[url] = {"error": str(error)}
            name = url.split("//")[1].split("/")[0]
            try:
                sv.cmd({"do": "shot", "id": id, "path": str(OUT / f"{label}-{name}.png")})
            except Exception as error:
                found[url]["shot"] = str(error)
            print(label, url, json.dumps(found[url])[:600], flush=True)
            sv.cmd({"do": "close", "id": id})
    return found


try:
    sv.setup(splitView=True)
    sv.launch()

    fetched = shield("fetch", f"{BASE}/list.txt")
    t.ok("a cookie list is fetched and compiled with the others", fetched["downloaded"] >= 1, fetched)
    id = sv.cmd({"do": "open", "url": f"{BASE}/page"})["id"]
    sv.cmd({"do": "wait", "id": id, "seconds": 10})
    time.sleep(0.6)
    state = value(id, FIXTURE)
    t.ok("a cookie notice is hidden", state["banner"] == "none" and state["plain"] == "none", state)

    shield("pause", "127.0.0.1")
    go(id, f"{BASE}/page?paused")
    state = value(id, FIXTURE)
    t.ok("off for this site shows the notice again", state["banner"] != "none" and state["plain"] != "none", state)
    shield("pause", "127.0.0.1", "off")
    go(id, f"{BASE}/page?back")
    state = value(id, FIXTURE)
    t.ok("back on, the notice is hidden again", state["banner"] == "none", state)
    sv.cmd({"do": "close", "id": id})

    if REAL:
        OUT.mkdir(parents=True, exist_ok=True)
        started = time.monotonic()
        lists = fetch(*[f"{BASE}/lists/{name}.txt" for name in SIX])
        print("six lists", lists["rules"], lists["downloaded"], f"{time.monotonic() - started:.1f} s", flush=True)
        six = survey("six")
        started = time.monotonic()
        lists = fetch(*[f"{BASE}/lists/{name}.txt" for name in SIX + ["cookies"]])
        print("seven lists", lists["rules"], lists["downloaded"], f"{time.monotonic() - started:.1f} s", flush=True)
        seven = survey("seven")
        (OUT / os.environ.get("SURVEY", "survey.json")).write_text(json.dumps({"six": six, "seven": seven}, indent=1))
finally:
    t.done(); sv.finish()
sys.exit(1 if t.failed else 0)
