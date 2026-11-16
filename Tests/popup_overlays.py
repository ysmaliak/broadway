#!/usr/bin/env python3
"""Windows a site opens behind your back, refused, and the legit ones kept.

Build first (`./build.sh`), then `python3 Tests/popup_overlays.py`. The app
starts hidden in a world of its own, is driven through ./bench's socket and
quit. Local pages only: http://localhost:PORT is the site, and every window
it asks for goes to http://127.0.0.1:PORT, another site. Clicks are `tap`'s
trusted ones at the middle of what the user aims at; the page's own script
does every opening. State is read from the DOM and the tab's sign.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-overlay")
PORT = sv.srv.server_port
SITE = f"http://localhost:{PORT}"
OTHER = f"http://127.0.0.1:{PORT}"

PLAYER = """
<style>
  body { margin: 0; font: 18px system-ui; }
  #player { position: relative; width: 640px; height: 360px; margin: 40px; background: #111; }
  #play { position: absolute; left: 270px; top: 130px; width: 100px; height: 100px; border-radius: 50%;
          background: #e33; color: white; font-size: 40px; text-align: center; line-height: 100px; cursor: pointer; }
</style>
<div id="player"><div id="play" class="play-button">&#9654;</div></div>
<script>
  document.getElementById('play').addEventListener('click', () => {
    document.body.dataset.played = String(Number(document.body.dataset.played || 0) + 1);
  });
</script>
"""

PAGES = {
    "/overlay": PLAYER + """<script>
      setTimeout(() => {
        const cover = document.createElement('div');
        cover.id = 'cover';
        cover.style.cssText = 'position:fixed;inset:0;z-index:99;opacity:0.01;background:white;cursor:pointer';
        cover.addEventListener('click', () => window.open('OTHER/opened-overlay'));
        document.body.appendChild(cover);
      }, 200);
    </script>""",
    "/clear": """
      <style>body { margin: 0; } #v { display: block; width: 640px; height: 360px; margin: 40px; background: #222; }</style>
      <video id="v" width="640" height="360"></video>
      <div id="glass" style="position:absolute;left:40px;top:40px;width:640px;height:360px;z-index:5"></div>
      <script>document.getElementById('glass').onclick = () => window.open('OTHER/opened-clear');</script>""",
    "/anchor": PLAYER + """
      <a id="cover" href="OTHER/opened-anchor" target="_blank"
         style="position:absolute;left:40px;top:40px;width:640px;height:360px;z-index:9;opacity:0"></a>""",
    "/docdown": """
      <p id="text" style="font-size:22px;margin:60px">An article you are reading, with nothing to click.</p>
      <script>document.addEventListener('mousedown', () => window.open('OTHER/opened-docdown'));</script>""",
    "/linkdoc": """
      <p style="margin:60px"><a id="story" href="/story" style="font-size:22px">Read the story</a></p>
      <script>document.addEventListener('mousedown', () => window.open('OTHER/opened-astray'));</script>""",
    "/tabunder": """
      <p style="margin:60px"><a id="go" href="OTHER/opened-real" style="font-size:22px">Download</a></p>
      <script>
        document.getElementById('go').addEventListener('click', e => {
          e.preventDefault();
          window.open(e.currentTarget.href);
          location.href = 'OTHER/ad-tabunder';
        });
      </script>""",
    "/blanklink": """
      <p style="margin:60px"><a id="out" href="OTHER/opened-legit" target="_blank" style="font-size:22px">A real link</a></p>""",
    "/button": """
      <button id="b" style="font-size:22px;margin:60px" onclick="window.open('OTHER/opened-button')">Open</button>""",
    "/oauth": """
      <button id="b" style="font-size:22px;margin:60px"
        onclick="window.open('OTHER/opened-oauth', 'signin', 'width=480,height=600')">Sign in with Other</button>""",
    "/stretched": """
      <div style="position:relative;width:420px;margin:60px;padding:16px;border:1px solid #ccc">
        <h2 id="title">A story card</h2><p>Its summary.</p>
        <a href="OTHER/opened-card" target="_blank" style="position:absolute;inset:0" aria-label="Open"></a>
      </div>""",
}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        body = PAGES.get(page, f"plain {page}").replace("OTHER", OTHER)
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H
anchor = None


def tabs():
    return sv.cmd({"do": "tabs"})["tabs"]


def opened(name):
    return [t for t in tabs() if urlparse(t["url"]).path == f"/opened-{name}"]


def state(tab):
    return sv.cmd({"do": "popups", "id": tab})


def address(tab):
    return next((t["url"] for t in tabs() if t["id"] == tab), "")


def visit(path):
    req = {"do": "split", "action": "open", "url": f"{SITE}{path}"}
    if anchor:
        req["from"] = anchor
    tab = sv.cmd(req)["resultID"]
    time.sleep(1.5)
    return tab


def tap(tab, selector, **extra):
    sv.cmd({"do": "select", "id": tab})
    reply = sv.cmd({"do": "tap", "id": tab, "selector": selector, **extra})
    time.sleep(1.5)
    return reply


def played(tab):
    return int(sv.ev(tab, "document.body.dataset.played || 0") or 0)


def main():
    global anchor
    t = sv.T()
    try:
        sv.setup(); sv.launch()

        page = anchor = visit("/blanklink")
        tap(page, "#out")
        t.ok("a visible target=_blank link opens its tab", len(opened("legit")) == 1, tabs())
        t.ok("and nothing is refused", state(page)["sign"] is False, state(page))

        page = visit("/blanklink")
        before = len(opened("legit"))
        tap(page, "#out", mods=["cmd"])
        t.ok("a ⌘-click on it opens a tab", len(opened("legit")) == before + 1)

        page = visit("/button")
        tap(page, "#b")
        t.ok("window.open from a visible button opens", len(opened("button")) == 1)
        t.ok("with no sign", state(page)["sign"] is False, state(page))

        page = visit("/oauth")
        tap(page, "#b")
        t.ok("a sized sign-in window from a button opens", len(opened("oauth")) == 1)

        page = visit("/stretched")
        tap(page, "#title")
        t.ok("a card's stretched link opens", len(opened("card")) == 1, state(page))

        page = visit("/tabunder")
        tap(page, "#go")
        time.sleep(0.5)
        st = state(page)
        t.ok("the tab-under's opener stays", urlparse(address(page)).path == "/tabunder", address(page))
        t.ok("its new tab is closed", not opened("real"), [x["url"] for x in tabs()])
        t.ok("and offered in the sign", st["blocked"] == [f"{OTHER}/opened-real"] and st["reasons"] == ["tab-under"], st)
        active = next((x for x in tabs() if x["active"]), {})
        t.ok("the opener is in front", active.get("id") == page, active)

        page = visit("/overlay")
        tap(page, "#play")
        st = state(page)
        t.ok("a nearly transparent overlay's window is refused", not opened("overlay"))
        t.ok("and offered in the sign", st["blocked"] == [f"{OTHER}/opened-overlay"], st)
        t.ok("as unseen", st["reasons"] == ["unseen"], st)
        t.ok("the click goes on to the play button", played(page) == 1, played(page))
        tap(page, "#play")
        t.ok("the overlay no longer takes the next click", played(page) == 2 and not opened("overlay"), played(page))

        page = visit("/clear")
        tap(page, "#v")
        st = state(page)
        t.ok("a clear layer over a video opens nothing", not opened("clear"))
        t.ok("and is refused as unseen", st["reasons"] == ["unseen"], st)

        page = visit("/anchor")
        tap(page, "#play")
        st = state(page)
        t.ok("an invisible target=_blank anchor over the player opens nothing", not opened("anchor"))
        t.ok("refused as unseen", st["reasons"] == ["unseen"], st)
        t.ok("and the play button gets the click", played(page) == 1, played(page))

        page = visit("/docdown")
        tap(page, "#text")
        st = state(page)
        t.ok("a document mousedown opener on plain text opens nothing", not opened("docdown"))
        t.ok("refused as inert", st["reasons"] == ["inert"], st)

        page = visit("/linkdoc")
        tap(page, "#story")
        time.sleep(0.5)
        t.ok("a document opener beside a real link opens nothing", not opened("astray"))
        t.ok("the link still goes where it points", urlparse(address(page)).path == "/story", address(page))

        page = visit("/button")
        st = state(page)
        t.ok("after these refusals the site is wary", st["wary"] is True, st)
        count = len(opened("button"))
        tap(page, "#b")
        st = state(page)
        t.ok("so even a button's window to another site waits in the sign",
             len(opened("button")) == count and st["reasons"] == ["wary"], st)
        sv.cmd({"do": "popups", "id": page, "action": "allow"})
        sv.cmd({"do": "popups", "action": "remove", "site": "localhost"})
        t.ok("allowing the site forgives it", state(page)["wary"] is False)
        tap(page, "#b")
        t.ok("and the button opens again", len(opened("button")) == count + 1)
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
