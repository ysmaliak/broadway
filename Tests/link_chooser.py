#!/usr/bin/env python3
"""The Open Link In chooser: its rows, its keys, its place, how it comes and
goes, and that it gives the page back.

Build first (`./build.sh`), then `python3 Tests/link_chooser.py`. The app runs
hidden in a world of its own that is removed afterwards. Local pages only.
Pictures of it alone come from `Tests/float_review_shots.py --only=link-chooser`.
`python3 Tests/link_chooser.py --pictures OUT` has the app draw its own window
with the chooser up, and again with the field up, into OUT. The app draws them
itself over an empty page, so glass shows without what is behind it. OUT
must be a folder the app may write to, such as one under /private/tmp.
"""
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import visual_diff as vd  # noqa: E402

sv.use("link-chooser")
WORDS = " ".join(["words"] * 500)
GROUNDS = {"white": "background:#fff;color:#000", "black": "background:#000;color:#fff"}
t = sv.T()


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        page = urlparse(self.path).path.strip("/")
        if page == "taps":
            body = ("<title>taps</title><button id=b style='font-size:30px;margin:40px' onclick='window.taps=(window.taps||0)+1'>tap</button>"
                    "<input id=in style='font-size:30px'><script>window.taps=0</script>")
        elif page in ("blank-light", "blank-dark"):
            body = f"<title>Page</title><body style='background:{'#fff' if page == 'blank-light' else '#000'}'>"
        elif page in GROUNDS:
            body = f"<title>{page.title()}</title><body style='margin:12px;font:20px system-ui;{GROUNDS[page]}'><p>{WORDS}</p>"
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


def until(check, within=4.0):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.1)
    return check()


def route(**extra):
    return sv.cmd({"do": "route", "args": [], **extra})


def ui(**fields):
    return sv.cmd({"do": "ui", **fields})


def ask(name="chosen", **extra):
    ui(linkChooser=f"{sv.BASE}/{name}", **extra)
    until(lambda: route()["chooser"] and route()["chooserWindow"], 20)
    time.sleep(0.3)
    return route()


def seen(said):
    return (said["chooserLit"], said["chooserAlways"], said["chooserFaint"], len(said["chooser"]))


def press(code, chars=""):
    before = seen(route())
    sv.cmd({"do": "press", "code": code, "chars": chars})
    until(lambda: seen(route()) != before, 1.2)
    return route()


def motion():
    ui(linkChooserWatch=8.0)
    ui(linkChooser=f"{sv.BASE}/moving")
    until(lambda: route()["chooser"] and route()["chooserWindow"], 6)
    time.sleep(0.9)
    ui(linkChooserDrop="fade")
    time.sleep(0.8)
    rows = route()["chooserMotion"]
    first = next((i for i, row in enumerate(rows) if row[1] < 0.999), 0)
    rows = rows[first:]
    last = max((i for i, row in enumerate(rows) if row[1] >= 0.999), default=len(rows) - 1)
    coming, going = rows[:last + 1], rows[last:]
    whole = next((row[0] - coming[0][0] for row in coming if row[1] >= 0.999 and abs(row[2] - 1) <= 0.002), None) if coming else None
    print("  note  ms, opacity, scale while arriving: " + " ".join(f"{int(r[0] - rows[0][0])}:{r[1]:g}:{r[2]:g}" for r in coming[:40:3]))
    print("  note  ms, opacity, scale while leaving: " + " ".join(f"{int(r[0] - going[0][0])}:{r[1]:g}:{r[2]:g}" for r in going[::3]))
    return {"all": rows, "coming": coming, "going": going, "whole": whole}


def gone():
    return bool(until(lambda: not route()["chooser"], 10))


def panels():
    return [w for w in sv.cmd({"do": "probe"})["windows"] if w["kind"] == "KitPopupPanel"]


def space(**request):
    return sv.cmd({"do": "space", **request})


def paths():
    return [urlparse(x["url"]).path.strip("/") for x in sv.sp("state")["tabs"]]


def front():
    state = sv.sp("state")
    return next((urlparse(x["url"]).path.strip("/") for x in state["tabs"] if x["id"] == state["activeID"]), "")


SIZES = (("normal", 1200, 800), ("narrow", 640, 800), ("short", 1200, 420))


def field_frame(**where):
    if where:
        sv.cmd({"do": "field", "text": "a", **where})
        until(lambda: route(**where)["chooserFrames"].get("field"), 5)
        time.sleep(0.6)
        return route(**where)["chooserFrames"]
    sv.cmd({"do": "press", "code": 37, "chars": "l", "mods": ["cmd"]})
    until(lambda: route(**where)["chooserFrames"].get("field"), 5)
    time.sleep(0.6)
    frames = route(**where)["chooserFrames"]
    sv.cmd({"do": "press", "code": 53, "chars": "\u001b"})
    until(lambda: not route(**where)["chooserFrames"].get("field"), 3)
    time.sleep(0.3)
    return frames


def frames_match(rows, pick, **where):
    for name, width, height in SIZES:
        sv.cmd({"do": "resize", "width": width, "height": height, "steps": 1, **where})
        time.sleep(0.5)
        pick()
        time.sleep(0.3)
        field = field_frame(**where).get("field")
        ask(f"frame-{rows}-{name}", **where)
        said = route(**where)
        frames = said["chooserFrames"]
        chooser = frames.get("chooser")
        t.ok(f"{rows} rows in a {name} window: the chooser's frame is the field's",
             len(said["chooser"]) == rows and bool(field) and bool(chooser)
             and all(abs(a - b) <= 1 for a, b in zip(field, chooser)), [said["chooser"], frames["content"], field, chooser])
        if name == "narrow":
            t.ok(f"{rows} rows: the narrow window takes width off the field", bool(field) and field[2] < 640, [frames["content"], field])
        if name == "short":
            t.ok(f"{rows} rows: the short window takes height off the field", bool(field) and field[3] < 462, [frames["content"], field])
        ui(linkChooserDrop=True)
        gone()
    sv.cmd({"do": "resize", "width": 1200, "height": 800, "steps": 1, **where})
    time.sleep(0.5)


def checks():
    sv.setup(sidebar=True)
    sv.launch()
    try:
        ui(spaces=True)
        space(action="new", name="Work")
        space(action="go", index=1)
        time.sleep(0.5)
        page = sv.page("taps")
        sv.sp("select", id=page)
        time.sleep(0.4)

        said = ask("first")
        rows = said["chooser"]
        t.ok("the rows are the two spaces, New Window and Peek, and nothing else",
             len(rows) == 4 and rows[1:] == ["Work", "New Window", "Peek"], rows)
        t.ok("the space in front is lit to begin with", said["chooserLit"] == 0, said["chooserLit"])
        t.ok("one panel is up", len(panels()) == 1, panels())
        frames = said["chooserFrames"]
        wide, tall = frames["content"]
        box = frames["chooser"]
        t.ok("it stands a sixth of the way down the window, in the middle",
             abs(box[1] - round(tall * 0.177)) <= 1 and abs(box[0] + box[2] / 2 - wide / 2) <= 1, frames)
        lit = [press(125)["chooserLit"] for _ in range(4)]
        t.ok("Down walks the rows and stops at the last", lit == [1, 2, 3, 3], lit)
        t.ok("Up walks back", press(126)["chooserLit"] == 2)
        ui(linkChooserPoint=0)
        time.sleep(0.15)
        said = route()
        t.ok("pointing at a row lights it faintly", said["chooserLit"] == 0 and said["chooserFaint"], said)
        said = press(125)
        t.ok("a key lights its row in full again", said["chooserLit"] == 1 and not said["chooserFaint"], said)
        flips = [press(49, " ")["chooserAlways"] for _ in range(3)]
        t.ok("Space flips Always", flips == [True, False, True], flips)
        press(0, "2")
        t.ok("a digit picks its row and the chooser goes", gone())
        time.sleep(0.8)
        said = route()
        t.ok("the link opened in Work", front() == "first", front())
        t.ok("Always made a rule for the site to Work", any("Work" in str(r.get("to")) for r in said["routes"]), said["routes"])

        space(action="go", index=1)
        time.sleep(0.6)
        sv.sp("select", id=page)
        time.sleep(0.3)
        rules = len(route()["routes"])
        ask("second")
        press(125)
        press(36, "\r")
        t.ok("Return picks the lit row", gone())
        time.sleep(0.8)
        t.ok("Return on Work opened the link in Work", front() == "second", front())

        space(action="go", index=1)
        time.sleep(0.6)
        sv.sp("select", id=page)
        time.sleep(0.3)
        ask("here")
        press(53, "\u001b")
        t.ok("Escape closes the chooser", gone())
        time.sleep(0.8)
        t.ok("Escape opened the link where you are", front() == "here" and "taps" in paths(), paths())
        t.ok("Escape made no rule", len(route()["routes"]) == rules, route()["routes"])
        t.ok("no panel is left", bool(until(lambda: not panels(), 2)), panels())

        sv.sp("select", id=page)
        time.sleep(0.4)
        sv.cmd({"do": "tap", "id": page, "selector": "#b"})
        time.sleep(0.4)
        t.ok("after it is gone the page still takes a click", sv.ev(page, "window.taps") == 1, sv.ev(page, "window.taps"))
        sv.cmd({"do": "tap", "id": page, "selector": "#in"})
        time.sleep(0.3)
        sv.cmd({"do": "press", "code": 18, "chars": "1"})
        sv.cmd({"do": "press", "code": 49, "chars": " "})
        sv.cmd({"do": "press", "code": 0, "chars": "a"})
        typed = until(lambda: sv.ev(page, "document.querySelector('#in').value") == "1 a" and "1 a", 3) or sv.ev(page, "document.querySelector('#in').value")
        t.ok("after it is gone its own keys reach the page", typed == "1 a", typed)

        ask("outside")
        sv.sp("mouse", points=[[wide - 60, tall - 60], [wide - 60, tall - 60]])
        t.ok("a click outside closes the chooser", gone())
        time.sleep(0.8)
        t.ok("and opens the link where you are", "outside" in paths(), paths())
        sv.sp("select", id=page)
        time.sleep(0.3)

        sv.cmd({"do": "press", "code": 37, "chars": "l", "mods": ["cmd"]})
        time.sleep(0.8)
        field = route()["chooserFrames"].get("field")
        sv.cmd({"do": "press", "code": 53, "chars": "\u001b"})
        time.sleep(0.5)
        t.ok("the field's frame is the chooser's", bool(field)
             and all(abs(field[i] - box[i]) <= 1 for i in range(4)), [field, box])
        sv.sp("select", id=page)
        time.sleep(0.3)

        sv.cmd({"do": "press", "code": 37, "chars": "l", "mods": ["cmd"]})
        time.sleep(0.8)
        t.ok("the field is up", bool(until(lambda: sv.cmd({"do": "probe"})["field"], 5)))
        ask("over-field")
        t.ok("a link that arrives while the field is up puts the field away", bool(until(lambda: not sv.cmd({"do": "probe"})["field"], 5)))
        ui(linkChooserDrop=True)
        gone()
        sv.sp("select", id=page)
        time.sleep(0.3)

        moved = motion()
        coming, going = moved["coming"], moved["going"]
        t.ok("it arrives from nearly its own size and faded, and is whole within half a second",
             bool(coming) and coming[0][1] < 0.6 and 0.97 <= coming[0][2] < 1 and moved["whole"] is not None and moved["whole"] <= 500, coming[:12])
        t.ok("it leaves within a quarter of a second", bool(going) and going[-1][0] - going[0][0] <= 260 and going[-1][1] < 0.4, going)
        sv.sp("select", id=page)
        time.sleep(0.3)

        ask("one")
        ask("two")
        time.sleep(0.5)
        t.ok("a second link takes the chooser over: one panel", len(panels()) == 1, panels())
        ui(linkChooserDrop=True)
        t.ok("dropped", gone() and bool(until(lambda: not panels(), 2)))
        sv.sp("select", id=page)
        time.sleep(0.3)

        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true"], check=True)
        time.sleep(0.3)
        moved = motion()
        sizes = {row[2] for row in moved["all"]}
        t.ok("with Reduce Motion it only fades, and never changes size", bool(moved["all"]) and sizes == {1.0}, sorted(sizes))
        t.ok("with Reduce Motion it is whole within a fifth of a second", moved["whole"] is not None and moved["whole"] <= 200, moved["coming"][:10])
        t.ok("with Reduce Motion it still goes", bool(until(lambda: not panels(), 2)), panels())
        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "false"], check=True)

        for index in range(3, 13):
            space(action="new", name=f"S{index:02d}")
            if index in (7, 10):
                space(action="go", index=1)
                time.sleep(0.8)
                frames_match(index + 2, lambda: sv.sp("select", id=page))
        space(action="go", index=1)
        time.sleep(0.8)
        sv.sp("select", id=page)
        time.sleep(0.3)
        said = ask("many")
        rows = said["chooser"]
        t.ok("twelve spaces: a row for each, then New Window and Peek", len(rows) == 14 and rows[-2:] == ["New Window", "Peek"], rows)
        seen, hidden = {said["chooserLit"]}, []
        for code in [125] * 15 + [126] * 15:
            said = press(code)
            seen.add(said["chooserLit"])
            if not said["chooserLitShown"]:
                hidden.append(said["chooserLit"])
        t.ok("twelve spaces: the arrows reach every row", seen == set(range(14)), sorted(seen))
        t.ok("twelve spaces: the lit row is always in view", not hidden, hidden)
        t.ok("twelve spaces: a digit past nine picks nothing", press(0, "0")["chooser"] == rows)
        press(0, "9")
        t.ok("twelve spaces: 9 picks the ninth row", gone())
        time.sleep(0.8)
        t.ok("twelve spaces: the link opened in the ninth space", front() == "many", front())

        space(action="go", index=1)
        time.sleep(0.6)
        ui(spaces=False)
        time.sleep(0.5)
        sv.sp("select", id=page)
        time.sleep(0.3)
        said = ask("few")
        t.ok("with no spaces the rows are New Window and Peek", said["chooser"] == ["New Window", "Peek"], said["chooser"])
        t.ok("with no spaces the first row is lit", said["chooserLit"] == 0)
        ui(linkChooserDrop=True)
        gone()
        frames_match(2, lambda: sv.sp("select", id=page))
        ui(spaces=True)
        time.sleep(0.4)

        shy = sv.cmd({"do": "open", "url": f"{sv.BASE}/white", "private": True})["id"]
        time.sleep(1.0)
        number = next(w["n"] for w in sv.cmd({"do": "windows", "action": "list"})["windows"] if w["private"])
        sv.cmd({"do": "select", "id": shy, "window": number})
        time.sleep(0.4)
        said = ask("shy", window=number)
        t.ok("a private window offers New Window alone", said["chooser"] == ["New Window"], said["chooser"])
        ui(linkChooserDrop=True)
        gone()
        frames_match(1, lambda: sv.cmd({"do": "select", "id": shy, "window": number}), window=number)
    finally:
        sv.finish()


def pictures(out):
    out.mkdir(parents=True, exist_ok=True)
    sv.setup(sidebar=True)
    sv.launch()
    try:
        ui(spaces=True)
        space(action="rename", name="Home", icon="house")
        space(action="look", colour="peach")
        space(action="new", name="Work")
        space(action="rename", name="Work", icon="briefcase")
        space(action="look", colour="sky")
        space(action="go", index=1)
        time.sleep(0.6)
        sv.cmd({"do": "resize", "width": 1100, "height": 720, "steps": 1})
        pages = {look: sv.page(f"blank-{look}") for look in ("light", "dark")}
        sheet = vd.tool("sheet", "ContactSheet.swift")
        for look, page in pages.items():
            ui(look=look)
            time.sleep(0.8)
            sv.sp("select", id=page)
            time.sleep(1.0)
            chooser = out / f"window-chooser-{look}.png"
            field = out / f"window-field-{look}.png"
            beside = out / f"field-beside-chooser-{look}.png"
            ask("team/issue/RDR-214")
            time.sleep(0.4)
            ui(linkChooserPicture=str(chooser))
            ui(linkChooserDrop=True)
            gone()
            sv.cmd({"do": "press", "code": 37, "chars": "l", "mods": ["cmd"]})
            time.sleep(0.9)
            ui(linkChooserPicture=str(field))
            sv.cmd({"do": "press", "code": 53, "chars": "\u001b"})
            time.sleep(0.6)
            t.ok(f"drew the window with the chooser, {look}", chooser.exists())
            t.ok(f"drew the window with the field, {look}", field.exists())
            subprocess.run([str(sheet), str(beside), "2", "2200", "1440", f"the field={field}", f"the chooser={chooser}"], capture_output=True)
            t.ok(f"put the field beside the chooser, {look}", beside.exists())
    finally:
        sv.finish()


def main():
    try:
        if "--pictures" in sys.argv:
            pictures(Path(sys.argv[sys.argv.index("--pictures") + 1]).resolve())
        else:
            checks()
    finally:
        t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/link_chooser.py requires macOS and a built Broadway.app")
    sys.exit(main())
