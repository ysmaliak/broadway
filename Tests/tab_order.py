#!/usr/bin/env python3
"""Which tab comes next when one opens or closes, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/tab_order.py` from a
worktree. The app starts hidden in a world of its own (see split_view.use),
is driven through ./bench's socket with trusted clicks (`tap`), and is quit.
Local pages only. The rules it follows are the table in docs/tabs.md.
"""
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tab-order")

STYLE = 'style="display:block;font-size:30px;line-height:60px;padding:0 20px"'


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path
        if page.startswith("/links"):
            links = "".join(f'<a id="l{n}" href="/opened-{n}" {STYLE}>link {n}</a>' for n in range(1, 4))
            blank = f'<a id="front" target="_blank" href="/front" {STYLE}>front</a>'
            script = f'<a id="win" href="/win" {STYLE}>window</a>'
            body = f'''<title>links</title>{links}{blank}{script}<script>
            document.getElementById('win').addEventListener('click', e => {{ e.preventDefault(); window.open('/win', '_blank') }});
            </script>'''
        else:
            body = f"<title>{page}</title>opened {page}"
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


def state():
    return sv.sp("state")


def path(st, id):
    return next((urlparse(x["url"]).path for x in st["tabs"] if x["id"] == id), None)


def on(st=None):
    st = st or state()
    return path(st, st["activeID"])


def ids(st=None):
    return [x["id"] for x in (st or state())["tabs"]]


def find(st, p):
    return next(x["id"] for x in st["tabs"] if urlparse(x["url"]).path == p)


def tap(tab, anchor, mods=("cmd",), wait=1.2):
    sv.cmd({"do": "tap", "id": tab, "selector": f"#{anchor}", "mods": list(mods)})
    time.sleep(wait)


def close(id, wait=0.5):
    st = sv.sp("closeTab", id=id)
    time.sleep(wait)
    return st


def clear():
    st = state()
    keep = sv.page("start")
    for id in ids(st):
        if id not in st.get("pins", []) and id != keep and id in ids():
            sv.sp("close", id=id)
    return keep


def row(*names):
    return [sv.page(n) for n in names]


def button_then_close(t):
    clear()
    a, b, c = row("a", "b", "c")
    sv.sp("select", id=b); time.sleep(0.3)
    before = set(ids())
    sv.sp("newTab"); time.sleep(0.4)
    st = state()
    fresh = st["activeID"]
    t.ok("the New Tab button's tab is new, selected and last in the row",
         fresh not in before and ids(st)[-1] == fresh, (fresh, ids(st)))
    close(fresh)
    t.ok("closed straight away, the tab you were on is back", on() == "/b", on())

    sv.sp("newTab"); time.sleep(0.4)
    fresh = state()["activeID"]
    sv.cmd({"do": "go", "id": fresh, "url": f"{sv.BASE}/typed"}); time.sleep(0.8)
    sv.sp("select", id=a); time.sleep(0.3)
    sv.sp("select", id=fresh); time.sleep(0.3)
    close(fresh)
    t.ok("after looking at another tab first, closing goes to its neighbour", on() == "/c", on())


def three_links(t):
    clear()
    sv.page("x")
    s = sv.page("links")
    sv.page("y")
    sv.sp("select", id=s); time.sleep(0.4)
    tap(s, "l1"); tap(s, "l2"); tap(s, "l3")
    st = state()
    o1, o2, o3 = (find(st, f"/opened-{n}") for n in (1, 2, 3))
    t.ok("three links behind sit after their page in click order",
         ids(st)[ids(st).index(s) + 1:ids(st).index(s) + 4] == [o1, o2, o3] and st["activeID"] == s, ids(st))
    sv.sp("select", id=o1); time.sleep(0.4)
    close(o1)
    t.ok("closing the first link goes to the next link from the same page", on() == "/opened-2", on())
    close(o2)
    t.ok("closing the second goes to the third", on() == "/opened-3", on())
    close(o3)
    t.ok("closing the last of them goes back to the page they came from", on() == "/links", on())


def front_link(t):
    clear()
    sv.page("x")
    s = sv.page("links")
    sv.page("y")
    sv.sp("select", id=s); time.sleep(0.4)
    tap(s, "front", mods=())
    st = state()
    f = st["activeID"]
    t.ok("a link that opens a tab in front sits right after its page, selected",
         path(st, f) == "/front" and ids(st)[ids(st).index(s) + 1] == f, (path(st, f), ids(st)))
    close(f)
    t.ok("closing it goes back to the page it came from", on() == "/links", on())


def page_closes_itself(t):
    clear()
    s = sv.page("links")
    y = sv.page("y")
    sv.sp("select", id=s); time.sleep(0.4)
    tap(s, "win", mods=(), wait=1.5)
    st = state()
    w = st["activeID"]
    t.ok("a window the page opens is a tab in front", path(st, w) == "/win", on(st))
    sv.sp("select", id=y); time.sleep(0.4)
    sv.cmd({"do": "eval", "id": w, "js": "window.close(); 1"}); time.sleep(1)
    st = state()
    t.ok("a tab behind closed by its page leaves the tab on screen alone",
         st["activeID"] == y and w not in ids(st), (on(st), ids(st)))


def close_last(t):
    clear()
    a, b, c = row("a", "b", "c")
    sv.sp("select", id=c); time.sleep(0.3)
    sv.sp("select", id=a); time.sleep(0.3)
    sv.sp("select", id=c); time.sleep(0.3)
    close(c)
    t.ok("closing the last tab in the list goes to the one above it", on() == "/b", on())
    sv.sp("select", id=a); time.sleep(0.3)
    close(b)
    t.ok("closing a tab that isn't selected changes nothing on screen", on() == "/a", on())


def in_folder(t):
    clear()
    sv.page("above")
    f = sv.page("links")
    sv.sp("group", id=f)
    below = sv.page("below")
    sv.sp("group", id=below, group="none")
    sv.sp("select", id=f); time.sleep(0.4)
    tap(f, "l1"); tap(f, "l2")
    st = state()
    o1, o2 = find(st, "/opened-1"), find(st, "/opened-2")
    folder = dict(zip(ids(st), st["groupIDs"]))
    t.ok("links from a tab in a folder join the folder after it",
         folder[o1] == folder[f] == folder[o2] and ids(st).index(o2) == ids(st).index(f) + 2, (st["groupIDs"], ids(st)))
    t.ok("the tab after the folder is out of it", folder[below] != folder[f], st["groupIDs"])
    sv.sp("select", id=below); time.sleep(0.3)
    sv.sp("select", id=o2); time.sleep(0.3)
    close(o2)
    t.ok("closing the last tab in a folder goes to the one above it in the folder", on() == "/opened-1", on())
    sv.sp("select", id=f); time.sleep(0.3)
    close(f)
    t.ok("closing the first tab in a folder goes to the next one in it", on() == "/opened-1", on())


def in_split(t):
    clear()
    p = sv.page("left")
    q = sv.page("right")
    sv.page("other")
    sv.sp("pair", id=q, **{"with": p, "side": "right"})
    sv.sp("select", id=p); time.sleep(0.4)
    close(p)
    t.ok("closing one side of Split View leaves the other side", on() == "/right", on())


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, **{"tabs.groups": True, "splitView": True})
        sv.launch()
        for case in (button_then_close, three_links, front_link, page_closes_itself, close_last, in_folder, in_split):
            try:
                case(t)
            except Exception as error:
                t.ok(f"{case.__name__} ran", False, repr(error))
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/tab_order.py requires macOS and a built Broadway.app")
    sys.exit(main())
