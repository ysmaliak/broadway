#!/usr/bin/env python3
"""Pull to refresh, in a hidden probe: what reloads a page and what leaves it alone.

Build first (`./build.sh`), then `python3 Tests/pull_refresh.py`. Same harness
as the split suite: a probe started hidden, in a world of its own, driven
through the bench, nothing made or shown, everything removed afterwards.

The bench's `wheel` is a trackpad's two-finger scroll over a point of the
page, with its phases, a hold before the fingers lift, a glide after, or none
of that for a plain mouse wheel. `refresh` reads what the page's view made of
the last gesture: whether the disc showed, how far it was pulled, whether it
armed, how it ended and why not. The server counts every time a page is
asked for, so a reload is a count going up and nothing else.

Each case says the user-visible thing: the page reloaded or it did not, and
the disc showed or it did not.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("pull-refresh")

TALL = "<div style='height:4000px'>tall</div>"
PAGES = {
    "long": TALL,
    "short": "<p>short</p>",
    "inner": "<div id=box style='position:absolute;left:0;top:0;width:400px;height:300px;overflow:auto'><div style='height:3000px'>inner</div></div>" + TALL,
    "chat": "<div id=box style='position:absolute;left:0;top:0;width:400px;height:300px;overflow:auto;display:flex;flex-direction:column-reverse'><div style='height:3000px;flex:none'>chat</div></div>" + TALL,
    "boxed": "<div id=box style='position:absolute;left:0;top:0;width:400px;height:300px;overflow:auto;overscroll-behavior:contain'><div style='height:3000px'>boxed</div></div>" + TALL,
    "prevent": "<script>addEventListener('wheel', function (e) { e.preventDefault() }, { passive: false })</script>" + TALL,
    "contain": "<style>html{overscroll-behavior-y:contain}</style>" + TALL,
    "nobounce": "<style>body{overscroll-behavior:none}</style>" + TALL,
    "form": "<form action=/long><input id=name name=name style='position:absolute;left:20px;top:20px;width:200px'><textarea id=note style='position:absolute;left:20px;top:60px;width:200px;height:60px'></textarea></form>" + TALL,
    "search": "<form action=/long onsubmit='return false'><input id=q type=search style='position:absolute;left:20px;top:20px;width:200px'></form>" + TALL,
    "leaving": "<script>addEventListener('beforeunload', function (e) { e.preventDefault(); e.returnValue = 'stay' })</script><button id=b style='position:absolute;left:20px;top:20px'>press</button>" + TALL,
    "posting": "<form id=f method=post action=/slow><input name=a value=1></form>" + TALL,
    "framed": "<iframe id=f src=/long style='position:absolute;left:0;top:0;width:400px;height:300px;border:0'></iframe>" + TALL,
    "framing": "<iframe id=f src=/form style='position:absolute;left:0;top:0;width:400px;height:300px;border:0'></iframe>" + TALL,
    "video": "<video id=v style='position:absolute;left:0;top:0;width:400px;height:300px'></video>" + TALL,
    "player": "<video muted playsinline style='display:block;width:640px;height:360px;margin:0 auto'></video><canvas width=320 height=180 style='display:none'></canvas><script>var c=document.querySelector('canvas'),g=c.getContext('2d'),n=0;setInterval(function(){g.fillStyle='hsl('+(n++*7%360)+',70%,50%)';g.fillRect(0,0,c.width,c.height)},40);var v=document.querySelector('video');v.srcObject=c.captureStream(25);v.play()</script>" + TALL,
    "body": "<style>html{height:100%;overflow:hidden}body{height:100%;margin:0;overflow:auto}</style>" + TALL,
}
hits = {}
posts = {}
PDF = (b"%PDF-1.1\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
       b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 3000]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n")


class H(BaseHTTPRequestHandler):
    def answer(self, body, kind="text/html"):
        self.send_response(200); self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)

    def do_GET(self):
        name = self.path.strip("/").split("?")[0]
        hits[name] = hits.get(name, 0) + 1
        if name == "paper.pdf": return self.answer(PDF, "application/pdf")
        if name == "slow": time.sleep(4)
        self.answer(f"<!doctype html><meta charset=utf-8><title>{name}</title><body style='margin:0'>{PAGES.get(name, TALL)}".encode())

    def do_POST(self):
        name = self.path.strip("/")
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        posts[name] = posts.get(name, 0) + 1
        time.sleep(4)
        self.answer(f"<!doctype html><title>posted</title>{TALL}".encode())

    def log_message(self, *a): pass


srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
BASE = f"http://localhost:{srv.server_port}"

t = sv.T()


def ev(id, js): return sv.cmd({"do": "eval", "id": id, "js": js}).get("value")
def state(id, **f): return sv.cmd({"do": "refresh", "id": id, **f})
def settings(**f): return sv.cmd({"do": "settings", **f})


def go(id, name):
    sv.cmd({"do": "go", "id": id, "url": f"{BASE}/{name}"}); sv.cmd({"do": "wait", "id": id, "seconds": 5}); time.sleep(0.4)


def wheel(id, dy, ms=400, steps=24, settle=1.0, **f):
    """Two fingers DY points toward the top of the page (down the trackpad,
    as a Mac comes) over MS, lifted, and what the page's view made of it."""
    state(id, clear=True)
    sv.cmd({"do": "wheel", "id": id, "dx": 0, "dy": dy, "steps": steps, "ms": ms, "exact": True, **f}); time.sleep(settle)
    return state(id)


def pulled(name, id, what, reloads, shown, **f):
    """One pull on a page, said the way a person would: it reloaded or not,
    and the disc showed or not. The disc counts travel from the page's
    answer on, so the pull is long enough to arm with a late answer."""
    before = hits.get(name, 0)
    r = wheel(id, 320, **{"ms": 600, "steps": 36, **f})
    after = hits.get(name, 0)
    t.ok(f"{what}: {'reloads' if reloads else 'no reload'}", (after > before) == reloads, (before, after, r["end"], r["why"]))
    t.ok(f"{what}: {'the disc shows' if shown else 'no disc'}", r["shown"] == shown, (r["shown"], r["peak"], r["why"]))
    return r


def case_pull():
    """the pull itself: past the point, short of it, back again, a flick"""
    tab = sv.page("a"); sv.cmd({"do": "select", "id": tab}); go(tab, "long")
    r = pulled("long", tab, "a pull past the point", True, True)
    t.ok("it armed on the way", r["armed"] and r["peak"] >= 110, r["peak"])
    t.ok("the disc is gone once the page is back", state(tab)["discs"] == 0 and state(tab)["phase"] == "idle", state(tab))
    t.ok("the reload is the tab's own, once", r["reloads"] == 1, r["reloads"])

    before = hits["long"]
    r = wheel(tab, 80)
    t.ok("a pull short of the point: no reload", hits["long"] == before and r["end"] == "back", r)
    t.ok("a pull short of the point: the disc shows, and goes", r["shown"] and not r["armed"] and state(tab)["discs"] == 0, r)

    r = wheel(tab, 320, ms=600, steps=36, legs=[[0, -250]])
    t.ok("past the point and back before letting go: no reload", hits["long"] == before and r["armed"] and r["end"] == "back", r)

    r = wheel(tab, 200, legs=[[0, -260]])
    t.ok("pulled, then pushed back past the start: no reload, and the page scrolls on", hits["long"] == before and r["why"] == "back" and ev(tab, "scrollY") > 0, (r, ev(tab, "scrollY")))
    ev(tab, "scrollTo(0, 0)"); time.sleep(0.2)

    r = wheel(tab, 300, ms=90, steps=8)
    t.ok("a quick flick at the top, however far: no reload", hits["long"] == before and r["why"] == "flick", r)

    r = wheel(tab, 220, cancel=True)
    t.ok("a gesture the Mac calls off: no reload", hits["long"] == before and r["why"] == "cancelled", r)

    r = wheel(tab, 220, plain=True)
    t.ok("a plain scroll wheel never pulls", hits["long"] == before and not r["shown"], r)

    state(tab, clear=True)
    sv.cmd({"do": "wheel", "id": tab, "dx": 300, "dy": 40, "steps": 24, "ms": 400, "exact": True}); time.sleep(1)
    r = state(tab)
    t.ok("a sideways swipe is not a pull", hits["long"] == before and not r["shown"] and r["why"] == "sideways", r)
    return tab


def case_momentum(tab):
    """a glide to the top, and coming to the top in one gesture"""
    go(tab, "long"); before = hits["long"]
    ev(tab, "scrollTo(0, 200)"); time.sleep(0.3)
    r = wheel(tab, 150, ms=80, steps=6, glide=60, settle=1.5)
    t.ok("a flick that coasts to the top: no reload, no disc", hits["long"] == before and not r["shown"] and ev(tab, "scrollY") == 0, (r, ev(tab, "scrollY")))

    ev(tab, "scrollTo(0, 100)"); time.sleep(0.3)
    r = wheel(tab, 500, ms=700, steps=40)
    t.ok("scrolled to the top and pulled on in one gesture: no reload, no disc", hits["long"] == before and not r["shown"] and r["why"] == "scrolled", r)

    r = wheel(tab, -100, legs=[[0, 400]], ms=400)
    t.ok("down and back up past the top in one gesture: no reload", hits["long"] == before and not r["shown"], r)
    ev(tab, "scrollTo(0, 0)"); time.sleep(0.2)

    state(tab, continues=True)
    ev(tab, "scrollTo(0, 100)"); time.sleep(0.3)
    r = wheel(tab, 500, ms=700, steps=40)
    t.ok("with the other rule (one gesture counts) the same pull reloads", hits["long"] == before + 1 and r["end"] == "reload", r)
    state(tab, continues=False)


def case_refusals(tab):
    """when it must not act"""
    go(tab, "long"); ev(tab, "scrollTo(0, 300)"); time.sleep(0.3)
    r = pulled("long", tab, "a page not at its top", False, False)
    t.ok("it says the page is scrolled", r["why"] == "scrolled", r["why"])

    go(tab, "inner")
    ev(tab, "document.getElementById('box').scrollTop = 500"); time.sleep(0.2)
    pulled("inner", tab, "over a box that scrolls and is not at its top", False, False, x=200, y=150)
    t.ok("the box scrolled instead", ev(tab, "document.getElementById('box').scrollTop") < 500)
    ev(tab, "document.getElementById('box').scrollTop = 0"); time.sleep(0.2)
    pulled("inner", tab, "over a box that scrolls and is at its top", True, True, x=200, y=150)
    ev(tab, "document.getElementById('box').scrollTop = 500"); time.sleep(0.2)
    pulled("inner", tab, "beside a scrolled box, on the page", True, True, x=600, y=400)

    go(tab, "chat")
    pulled("chat", tab, "over a chat pane at its newest (it scrolls up)", False, False, x=200, y=150)
    go(tab, "boxed")
    pulled("boxed", tab, "over a box that keeps its overscroll", False, False, x=200, y=150)
    go(tab, "framed"); time.sleep(0.5)
    pulled("framed", tab, "over a frame at its top, on a page at its top", True, True, x=200, y=150)
    go(tab, "framed"); time.sleep(0.5)
    ev(tab, "document.getElementById('f').contentWindow.scrollTo(0, 400)"); time.sleep(0.3)
    pulled("framed", tab, "over a frame that is scrolled", False, False, x=200, y=150)
    go(tab, "body")
    ev(tab, "document.body.scrollTop = 300"); time.sleep(0.2)
    pulled("body", tab, "a page whose body is the scroller, scrolled", False, False)

    go(tab, "prevent")
    r = pulled("prevent", tab, "a page that handles the wheel itself", False, False)
    t.ok("it says the page took the wheel", r["why"] == "prevented", r["why"])
    go(tab, "contain")
    r = pulled("contain", tab, "overscroll-behavior: contain on the page", False, False)
    t.ok("it says the page keeps its overscroll", r["why"] == "contained", r["why"])
    go(tab, "nobounce")
    pulled("nobounce", tab, "overscroll-behavior: none on the body", False, False)

    go(tab, "long")
    sv.cmd({"do": "magnify", "id": tab, "scale": 2}); time.sleep(0.3)
    r = pulled("long", tab, "a page pinched in", False, False)
    t.ok("it says the page is pinched in", r["why"] == "pinched", r["why"])
    sv.cmd({"do": "magnify", "id": tab, "scale": 1}); time.sleep(0.3)

    go(tab, "paper.pdf"); time.sleep(1)
    r = pulled("paper.pdf", tab, "a PDF", False, False)
    print("        (a PDF says:", r["why"] + ")")

    go(tab, "short")
    pulled("short", tab, "a page too short to scroll", True, True)


def case_typing(tab):
    """text typed and not sent"""
    go(tab, "form")
    ev(tab, "document.getElementById('name').focus()")
    sv.cmd({"do": "key", "id": tab, "text": "Sam"}); time.sleep(0.3)
    t.ok("the key reached the field", ev(tab, "document.getElementById('name').value") == "Sam", ev(tab, "document.getElementById('name').value"))
    r = pulled("form", tab, "a half-filled form, the caret in it", False, False)
    t.ok("it says there is typed text", r["why"] == "typing", r["why"])
    ev(tab, "document.activeElement.blur()")
    pulled("form", tab, "a half-filled form, the caret gone", False, False)
    t.ok("the text is still there", ev(tab, "document.getElementById('name').value") == "Sam")
    ev(tab, "document.getElementById('name').value = ''")
    pulled("form", tab, "the form emptied again", True, True)

    go(tab, "form")
    ev(tab, "document.getElementById('name').value = 'filled by the page'")
    pulled("form", tab, "a field the page filled itself", True, True)

    go(tab, "search")
    ev(tab, "document.getElementById('q').focus()")
    sv.cmd({"do": "key", "id": tab, "text": "cats"}); time.sleep(0.2)
    pulled("search", tab, "a search typed and not entered", False, False)
    sv.cmd({"do": "key", "id": tab, "text": "\r"}); time.sleep(0.3)
    pulled("search", tab, "a search entered, its words still in the box", True, True)

    inner = "document.getElementById('f').contentWindow.document.getElementById('name')"
    go(tab, "framing"); time.sleep(0.5)
    ev(tab, inner + ".focus()")
    sv.cmd({"do": "key", "id": tab, "text": "Sam"}); time.sleep(0.3)
    t.ok("the key reached the field in the frame", ev(tab, inner + ".value") == "Sam", ev(tab, inner + ".value"))
    r = pulled("framing", tab, "text typed in a frame, the pointer on the page beside it", False, False, x=600, y=400)
    t.ok("it says there is typed text", r["why"] == "typing", r["why"])
    pulled("framing", tab, "text typed in a frame, the pointer over the frame", False, False, x=200, y=150)
    ev(tab, inner + ".value = ''")
    pulled("framing", tab, "the frame's field emptied again", True, True, x=600, y=400)


def case_leaving(tab):
    """a page with a leave-page handler, a post in flight, a load in flight"""
    go(tab, "leaving")
    sv.cmd({"do": "click", "id": tab, "selector": "#b"}); time.sleep(0.2)
    r = pulled("leaving", tab, "a page with a leave-page handler (Broadway asks nothing on ⌘R either)", True, True)
    t.ok("no question was put, and the disc went", not [q for q in sv.qs() if q["tab"] == tab] and state(tab)["discs"] == 0, sv.qs())

    go(tab, "posting")
    ev(tab, "document.getElementById('f').submit()"); time.sleep(0.6)
    r = pulled("posting", tab, "a form post in flight", False, False)
    t.ok("it says the page is on its way out", r["why"] == "leaving", r["why"])
    for _ in range(40):
        if "posted" in (ev(tab, "document.title") or ""): break
        time.sleep(0.25)
    t.ok("the post arrived, once", posts.get("slow") == 1 and "posted" in (ev(tab, "document.title") or ""), (posts, ev(tab, "document.title")))

    go(tab, "long")
    sv.cmd({"do": "go", "id": tab, "url": f"{BASE}/slow"}); time.sleep(0.6)
    r = pulled("long", tab, "a link followed and not yet answered", False, False)
    time.sleep(4.5)
    t.ok("the page it was going to arrived", hits.get("slow") == 1, hits.get("slow"))


def case_setting(tab):
    """the switch, in Settings, Find a setting and the settings list"""
    go(tab, "long")
    found = settings(find="pull")
    row = next((i for i in found["found"] if i["id"] == "pages.pull"), None)
    t.ok("Find a setting finds it by pull, refresh and reload",
         row is not None and all("pages.pull" in [i["id"] for i in settings(find=w)["found"]] for w in ("refresh", "reload")), found["found"])
    t.ok("it is on Websites, with Page zoom", row is not None and row["page"] == "websites" and row["group"] == "pages", row)
    listed = {i["id"]: i for i in settings()["items"]}.get("pages.pull")
    t.ok("the settings list has it, as a row of its own", listed is not None and listed["page"] == "websites" and not listed["findOnly"], listed)
    t.ok("on unless turned off", found["values"].get("pages.pull") is True and state(tab)["on"], found["values"].get("pages.pull"))
    settings(set="pages.pull", value=False); time.sleep(0.2)
    r = pulled("long", tab, "switched off", False, False)
    t.ok("it says it is off", r["why"] == "off", r["why"])
    settings(set="pages.pull", value=True); time.sleep(0.2)
    pulled("long", tab, "switched on again", True, True)


def case_places(tab):
    """each pane of a pair, a peek, a private window"""
    go(tab, "long")
    other = sv.page("long"); time.sleep(0.5)
    sv.sp("pair", id=other, **{"with": tab}, side="right"); time.sleep(0.8)
    sv.sp("focus", id=other); time.sleep(0.2)
    before = hits["long"]
    r = wheel(tab, 320, ms=600, steps=36)
    t.ok("the pane that isn't focused reloads by itself", hits["long"] == before + 1 and r["reloads"] >= 1 and r["end"] == "reload", (hits["long"], before, r))
    t.ok("the other pane's view made nothing of it", state(other)["end"] == "" and not state(other)["shown"], state(other))
    held = {}
    hand = threading.Thread(target=lambda: held.update(sv.cmd({"do": "wheel", "id": other, "dx": 0, "dy": 150, "steps": 20, "ms": 300, "hold": 900, "exact": True})))
    hand.start(); time.sleep(0.8)
    mid = state(other); f = sv.frames(sv.sp("state")); hand.join(); time.sleep(0.8)
    t.ok("held, the disc sits over the middle of its own pane, under its top edge",
         mid.get("disc") and abs(mid["x"] - f[other]["width"] / 2) < 1 and abs(mid["width"] - f[other]["width"]) < 1 and 0 < mid["top"] < 60, (mid.get("x"), mid.get("top"), f[other]))
    sv.sp("close", id=other); time.sleep(0.5)

    sv.cmd({"do": "select", "id": tab}); time.sleep(0.3)
    sv.cmd({"do": "peek", "url": f"{BASE}/peeked"}); time.sleep(1.5)
    before = hits.get("peeked", 0)
    state(tab, peek=True, clear=True)
    sv.cmd({"do": "wheel", "peek": True, "dx": 0, "dy": 220, "steps": 24, "ms": 400, "exact": True}); time.sleep(1)
    r = state(tab, peek=True)
    t.ok("a peek reloads its own page", hits.get("peeked", 0) == before + 1 and r["end"] == "reload" and r["shown"], (hits.get("peeked"), before, r["end"], r["why"]))
    sv.cmd({"do": "peek", "url": "close"}); time.sleep(0.5)

    quiet = sv.cmd({"do": "open", "private": True, "url": f"{BASE}/quiet"})["id"]
    sv.cmd({"do": "wait", "id": quiet, "seconds": 5}); time.sleep(0.8)
    pulled("quiet", quiet, "a private window", True, True)
    sv.cmd({"do": "windows", "action": "close", "n": 2}); time.sleep(0.5)


def case_float(tab):
    """a page out in the floating window"""
    import tempfile
    go(tab, "player"); time.sleep(1)
    try:
        sv.cmd({"do": "film", "action": "float", "path": tempfile.mkdtemp() + "/float", "seconds": 1})
    except RuntimeError as error:
        print("  skip  the floating window (it would not float here:", str(error)[-80:] + ")")
        return
    time.sleep(0.5)
    r = pulled("player", tab, "the page out in the floating window", False, False)
    t.ok("it says the page is floating", r["why"] == "floating", r["why"])
    sv.cmd({"do": "film", "action": "land", "path": tempfile.mkdtemp() + "/land", "seconds": 1}); time.sleep(0.8)
    pulled("player", tab, "the same page, landed in its tab again", True, True)


def case_layouts():
    """the sidebar folded and cards off: its own launch"""
    sv.quit(); time.sleep(0.5)
    sv.setup(sidebar=False, **{"layout.cards": False}); sv.launch()
    tab = sv.page("bare"); sv.cmd({"do": "select", "id": tab}); go(tab, "long")
    pulled("long", tab, "with the sidebar folded and cards off", True, True)


CASES = [case_pull, case_momentum, case_refusals, case_typing, case_leaving, case_setting, case_places, case_float]

if __name__ == "__main__":
    only = sys.argv[1:]
    try:
        sv.setup(splitView=True); sv.launch()
        tab = case_pull() if not only or "pull" in only else None
        if tab is None:
            tab = sv.page("a"); sv.cmd({"do": "select", "id": tab})
        for case in CASES[1:]:
            if only and case.__name__.split("_", 1)[1] not in only: continue
            print(case.__name__ + ":", case.__doc__)
            case(tab)
        if not only or "layouts" in only:
            print("case_layouts:", case_layouts.__doc__)
            case_layouts()
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)
