#!/usr/bin/env python3
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("small-commands")

PAGES = {
    "/lamp": "<!doctype html><title>lamp</title>"
             + "".join(f"<p>Filler line {i} about nothing much.</p>" for i in range(300))
             + "<p id=lamp>The amber lantern glows.</p><p id=next>Second paragraph follows here.</p>"
             + "".join(f"<p>Filler line {i} about nothing much.</p>" for i in range(300))
             + "<p id=again>Once more the amber lantern glows.</p>"
             + "".join(f"<p>Filler line {i} about nothing much.</p>" for i in range(300)),
    "/harbour": "<!doctype html><title>harbour</title><p id=first>The quiet harbour sleeps.</p>"
                "<p>Boats rest.</p><p id=second>Again the quiet harbour wakes.</p>",
}


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path, f"<!doctype html><title>{self.path.strip('/')}</title><p>{self.path}").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a): pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
HERE = f"http://127.0.0.1:{server.server_port}"


def small(action, **f): return sv.cmd({"do": "small", "action": action, **f})
def row(menu, item, choose=False): return small("row", menu=menu, item=item, choose=choose)
def windows(action=None, **f):
    req = {"do": "windows", **f}
    if action: req["action"] = action
    return sv.cmd(req)["windows"]
def opened(name, window):
    return sv.cmd({"do": "split", "action": "open", "url": f"{sv.BASE}/{name}", "window": window})["resultID"]
def mine(path, window=1):
    return sv.cmd({"do": "split", "action": "open", "url": f"{HERE}{path}", "window": window})["resultID"]
def run_js(tab, js): return sv.cmd({"do": "eval", "id": tab, "js": js})
def pages(w): return [u.rsplit("/", 1)[-1] for u in w["tabs"] if u.startswith(sv.BASE)]


def merge(t):
    windows("new")
    windows("new")
    for name in ["one", "two"]: opened(name, 1)
    for name in ["three", "four"]: opened(name, 2)
    opened("five", 3)
    time.sleep(0.8)
    windows("front", n=1)
    before = row("Window", "Merge All Windows")
    t.ok("Merge All Windows is there and can be chosen", before["enabled"], before)
    row("Window", "Merge All Windows", choose=True)
    time.sleep(1.2)
    left = windows()
    t.ok("one window is left", len(left) == 1, left)
    t.ok("its tabs are its own, then the others' in the order the windows were opened",
         pages(left[0]) == ["one", "two", "three", "four", "five"], pages(left[0]))
    after = row("Window", "Merge All Windows")
    t.ok("with one window there is nothing to merge", not after["enabled"], after)


def merge_into_newer(t):
    windows("new")
    opened("six", 2)
    time.sleep(0.8)
    windows("front", n=2)
    row("Window", "Merge All Windows", choose=True)
    time.sleep(1.2)
    left = windows()
    t.ok("merged into a newer window, the first window's tabs come along", len(left) == 1
         and sorted(pages(left[0])) == ["five", "four", "one", "six", "three", "two"], left)
    sv.quit()
    time.sleep(0.5)
    sv.launch()
    back = windows()
    t.ok("…and all of them come back after a restart", len(back) == 1
         and sorted(pages(back[0])) == ["five", "four", "one", "six", "three", "two"], back)


def places(t):
    for menu, before, title in [("Window", "Zoom", "Keep Window on Top"), ("Window", "Bring All to Front", "Merge All Windows"),
                                ("Edit", "Find Previous", "Use Selection for Find"), ("Edit", "Copy Clean Link", "Copy Link to Highlight"),
                                ("Tabs", "Stop Sound in Tab", "Mute Other Tabs"), ("Broadway", "Warn Before Quitting", "Open at Login")]:
        titles = row(menu, title)["titles"]
        at = titles.index(title) if title in titles else -1
        t.ok(f"{title} comes right after {before}", at > 0 and titles[at - 1] == before, titles)


def find(t):
    windows("front", n=1)
    tab = mine("/harbour")
    time.sleep(1.5)
    run_js(tab, "var r = document.createRange(); var t = document.getElementById('first').firstChild;"
                " r.setStart(t, 4); r.setEnd(t, 18); getSelection().removeAllRanges(); getSelection().addRange(r); 1")
    shown = row("Edit", "Use Selection for Find")
    t.ok("Use Selection for Find can be chosen on a web page", shown["enabled"], shown)
    row("Edit", "Use Selection for Find", choose=True)
    time.sleep(0.8)
    state = small("find")
    t.ok("the selection is what Find looks for", state["needle"] == "quiet harbour", state)
    t.ok("…on the test's own find board", state["board"] == "quiet harbour", state)
    t.ok("the Find bar stays shut", not state["finding"], state)
    again = row("Edit", "Find Next", choose=True)
    time.sleep(1.0)
    state = small("find")
    t.ok("Find Next can be chosen with the bar shut", again["enabled"], again)
    t.ok("Find Next finds both", state["status"].endswith("of 2"), state)


def sound(t):
    windows("front", n=1)
    front = mine("/front")
    loud = mine("/loud", window=1)
    quiet = mine("/quiet", window=1)
    sv.cmd({"do": "select", "id": front})
    time.sleep(0.6)
    state = small("sound", noisy=[front, loud])
    t.ok("with another tab playing, the tab's menu offers Mute Other Tabs", "Mute Other Tabs" in state["menu"], state["menu"])
    row("Tabs", "Mute Other Tabs", choose=True)
    time.sleep(0.4)
    tabs = {x["id"]: x for x in small("sound")["tabs"]}
    t.ok("the other tab playing is muted", tabs[loud[:8]]["muted"], tabs)
    t.ok("the tab in front plays on", not tabs[front[:8]]["muted"], tabs)
    t.ok("a silent tab is left alone", not tabs[quiet[:8]]["muted"], tabs)
    after = row("Tabs", "Mute Other Tabs")
    t.ok("with nothing else playing the row is greyed", not after["enabled"], after)


def on_top(t):
    windows("front", n=1)
    level = small("ontop")["level"]
    shown = row("Window", "Keep Window on Top")
    t.ok("Keep Window on Top can be chosen", shown["enabled"] and not shown["on"], shown)
    row("Window", "Keep Window on Top", choose=True)
    state = small("ontop")
    t.ok("Keep Window on Top is recorded", state["asked"][-1:] == [True] and state["on"], state)
    t.ok("…and the hidden window's level is unchanged", state["level"] == level, (level, state))
    t.ok("the row shows a checkmark", row("Window", "Keep Window on Top")["on"])
    row("Window", "Keep Window on Top", choose=True)
    t.ok("choosing it again turns it off", not small("ontop")["on"])


def login(t):
    windows("front", n=1)
    t.ok("Open at Login starts off", not row("Broadway", "Open at Login")["on"])
    row("Broadway", "Open at Login", choose=True)
    t.ok("choosing it turns the stand-in on", small("login")["on"])
    t.ok("…and the row shows a checkmark", row("Broadway", "Open at Login")["on"])
    small("login", refuses=True)
    row("Broadway", "Open at Login", choose=True)
    state = small("login", refuses=False)
    t.ok("a refusal leaves it as it was", state["on"], state)
    t.ok("…and says so", state["said"] == "Couldn't change Open at Login. You can do it in System Settings › General › Login Items.", state)
    row("Broadway", "Open at Login", choose=True)
    t.ok("choosing it again turns it off", not small("login")["on"])


def highlight(t):
    windows("front", n=1)
    tab = mine("/lamp")
    time.sleep(1.5)
    run_js(tab, "var r = document.createRange(); var t = document.getElementById('lamp').firstChild;"
                " r.setStart(t, 4); r.setEnd(t, 17); getSelection().removeAllRanges(); getSelection().addRange(r); 1")
    shown = row("Edit", "Copy Link to Highlight")
    t.ok("Copy Link to Highlight can be chosen on a web page", shown["enabled"], shown)
    link, scrolled, near = landed(tab)
    t.ok("the copied link names the words", link == f"{HERE}/lamp#:~:text=amber%20lantern", link)
    t.ok("a new tab opened at it is scrolled to the words", near("lamp"), scrolled)
    pick(tab, "lamp", 8, "next", 17)
    link, scrolled, near = landed(tab)
    t.ok("words across two paragraphs, cut mid-word, are named by their whole ends",
         link == f"{HERE}/lamp#:~:text=amber%20lantern%20glows.,Second%20paragraph", link)
    t.ok("…and the link lands on them", near("lamp"), scrolled)
    pick(tab, "again", 14, "again", 27)
    link, scrolled, near = landed(tab)
    t.ok("words that came earlier too carry the words before them",
         link == f"{HERE}/lamp#:~:text=Once%20more%20the-,amber%20lantern", link)
    t.ok("…and the link lands on the second", near("again"), scrolled)


def pick(tab, start, at, end, to):
    sv.cmd({"do": "select", "id": tab})
    run_js(tab, f"var r = document.createRange(); r.setStart(document.getElementById('{start}').firstChild, {at});"
                f" r.setEnd(document.getElementById('{end}').firstChild, {to});"
                " getSelection().removeAllRanges(); getSelection().addRange(r); 1")


def landed(tab):
    row("Edit", "Copy Link to Highlight", choose=True)
    time.sleep(0.8)
    link = small("board")["links"]
    opened_at = sv.cmd({"do": "split", "action": "open", "url": link, "window": 1})["resultID"]
    time.sleep(2.5)
    found = run_js(opened_at, "[window.scrollY, window.innerHeight, document.getElementById('lamp').offsetTop,"
                              " document.getElementById('again').offsetTop]")["value"]
    y, height, lamp, again = found
    spots = {"lamp": lamp, "again": again}
    return link, found, lambda where: y > 1000 and y <= spots[where] <= y + height


def handoff(t):
    away = "https://handoff-garden.example/roses"
    windows("front", n=1)
    tab = small("handoff", away=away)["active"]
    time.sleep(0.6)
    t.ok("the page in front is offered", small("handoff")["offered"] == away, small("handoff"))
    mine("/front")
    time.sleep(0.8)
    t.ok("a local address is not", small("handoff")["offered"] == "", small("handoff"))
    sv.cmd({"do": "select", "id": tab})
    time.sleep(0.6)
    t.ok("it follows the tab in front", small("handoff")["offered"] == away, small("handoff"))
    made = windows("private")
    n = len(made)
    windows("front", n=n)
    sv.cmd({"do": "small", "action": "handoff", "away": away, "window": n})
    time.sleep(0.8)
    state = small("handoff")
    t.ok("nothing from a private window", made[-1]["private"] and state["offered"] == "", (made[-1]["private"], state))
    windows("front", n=1)
    time.sleep(0.6)
    t.ok("it follows the window in front", small("handoff")["offered"] == away, small("handoff"))
    sv.cmd({"do": "go", "id": tab, "url": away + "/tulips", "window": 1})
    time.sleep(1.2)
    t.ok("it follows the address in the tab", small("handoff")["offered"] == away + "/tulips", small("handoff"))
    sv.cmd({"do": "windows", "action": "close", "n": n})
    windows("front", n=1)
    time.sleep(0.6)
    sv.cmd({"do": "windows", "action": "close", "n": 1})
    time.sleep(1.2)
    state = sv.cmd({"do": "small", "action": "handoff"})
    t.ok("nothing once the last window is closed", state.get("offered") == "", state)


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        merge(t)
        merge_into_newer(t)
        places(t)
        find(t)
        sound(t)
        on_top(t)
        login(t)
        highlight(t)
        handoff(t)
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
