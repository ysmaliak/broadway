#!/usr/bin/env python3
"""A walk through Broadway as a new person meets it, pictured window-only.

Build first (`./build.sh`), then `python3 Tests/polish_walk.py [OUT]`
(default `.context/walk`). A test copy in a world of its own, its window
put below the desktop, where nothing shows on a screen and a capture still
pictures it. The column gets pins, folders and tabs, and in each of a pale,
a teal, an Arc blue, a navy and a glass space, light and dark, it pictures
the window, the address field, the look picker, the bookmark card, the blocked pop-ups and translation signs and the folded
column. Then, once a theme, the welcome's steps, the empty lists, the
error pages, split view and Settings, and last a private window. ONLY=a,b limits it to the parts named.
"""
import os
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("polish-walk")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/walk")
SHOT = Path(os.environ.get("TMPDIR", "/tmp")) / f"broadway-walk-shot-{os.getpid()}"
SETTINGS = Path(os.environ.get("TMPDIR", "/tmp")) / f"broadway-walk-settings-{os.getpid()}"
WIDTH, HEIGHT = 1180, 760
WINDOW = [0]
PID = [0]
ONLY = set(filter(None, os.environ.get("ONLY", "").split(",")))
LOOKS = [
    ("pale", {"custom": "FFF0A6", "intensity": 0.8, "glass": False, "transparency": 0, "grain": 0}),
    ("teal", {"custom": "0F9D94", "intensity": 0.8, "glass": False, "transparency": 0, "grain": 0}),
    ("blue", {"custom": "3139FB", "intensity": 1, "glass": False, "transparency": 0, "grain": 0}),
    ("navy", {"colours": ["000354", "2404AA"], "intensity": 1, "glass": False, "transparency": 0, "grain": 0}),
    ("glass", {"custom": "7CC4F2", "intensity": 0.8, "glass": True, "transparency": 0.5, "grain": 0}),
]
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.strip("/")
        if path.startswith("popups"):
            body = ("<!doctype html><title>Pop-ups</title><body style='background:white'>"
                    "<script>setTimeout(function(){ window.open('/white', '_blank', 'width=300,height=200') }, 300)</script>")
        elif path.startswith("french"):
            words = " ".join(["Bonjour tout le monde, voici une page en français."] * 40)
            body = f"<!doctype html><html lang=fr><title>Le monde</title><body style='background:white'><p>{words}</p>"
        else:
            title = path.split("/")[-1].replace("-", " ").title() or "Page"
            body = (f"<!doctype html><meta charset=utf-8><title>{title}</title>"
                    f"<body style='font:16px -apple-system;margin:48px;color:#222;background:#fff'>"
                    f"<h1>{title}</h1><p>{' '.join(['A page in the card.'] * 30)}</p>")
        data = body.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def wanted(name):
    return not ONLY or name in ONLY


def until(check, within=6.0):
    deadline = time.monotonic() + within
    while time.monotonic() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.15)
    return check()


def shoot(name, numbers=None):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    numbers = numbers or [WINDOW[0]]
    subprocess.run([str(SHOT), str(PID[0]), ",".join(str(n) for n in numbers), str(path)], capture_output=True, text=True)
    t.ok(f"pictured {name}", path.exists())


def popovers():
    return [w for w in sv.cmd({"do": "probe"})["windows"] if w["kind"] in ("KitPopupPanel", "_NSPopoverWindow") and w["visible"]]


def popover(name, opener, closer=None):
    opener()
    up = until(popovers, 4)
    if not up:
        t.ok(f"{name}: the popover opened", False)
        return
    time.sleep(0.9)
    shoot(name, [WINDOW[0]] + [w["number"] for w in up])
    (closer or shut)()


def shut():
    sv.cmd({"do": "ui", "bookmarksList": False, "editlook": False, "extensions": False, "bookmarkCard": False})
    if popovers():
        sv.cmd({"do": "ui", "windowPointer": [WIDTH / 2, HEIGHT - 40], "pointerPhase": "down"})
        sv.cmd({"do": "ui", "windowPointer": [WIDTH / 2, HEIGHT - 40], "pointerPhase": "up"})
    until(lambda: not popovers(), 3)
    time.sleep(0.4)


def sign_menu(name):
    for _ in range(4):
        try:
            menu = sv.cmd({"do": "ctxmenu", "kind": "sign", "hold": 3})
        except RuntimeError:
            time.sleep(0.5)
            continue
        time.sleep(0.6)
        shoot(name)
        try:
            sv.cmd({"do": "ctxmenu", "action": "close"})
        except RuntimeError:
            pass
        time.sleep(0.6)
        return menu
    return None


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1",
                    "--env", "SEARCH_TRANSLATE_FAKE=1", sv.APP])
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def stage(dark):
    staged = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})
    WINDOW[0], PID[0] = staged["window"], staged["pid"]
    sv.cmd({"do": "ui", "look": "dark" if dark else "light"})
    time.sleep(0.8)


def opened(name):
    id = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
    time.sleep(0.25)
    return id


def furnish():
    pins = [opened(f"fav/{n}") for n in ("mail", "calendar", "notes", "music")]
    pinned = [opened(n) for n in ("team-calendar", "design-review")]
    kept = [opened(n) for n in ("recipes", "trip-to-lisbon")]
    today = [opened(n) for n in ("inbox", "pull-requests", "weekend-plans", "weather",
                                 "a-very-long-article-title-that-runs-past-the-column-edge",
                                 "flights", "groceries", "reading-list", "docs", "music-for-focus")]
    time.sleep(2)
    for id in pins:
        sv.cmd({"do": "pin", "id": id})
    sv.cmd({"do": "group", "id": pinned[0], "new": True, "name": "Work"})
    sv.cmd({"do": "group", "id": pinned[1], "name": "Work"})
    sv.cmd({"do": "group", "name": "Work", "pinned": True})
    sv.cmd({"do": "group", "id": kept[0], "new": True, "name": "Someday"})
    sv.cmd({"do": "group", "id": kept[1], "name": "Someday"})
    sv.sp("select", id=today[2])
    time.sleep(1)
    return today


def round_of(dark, name, look, today):
    tag = f"{'dark' if dark else 'light'}-{name}"
    stage(dark)
    sv.cmd({"do": "space", "action": "look", **look})
    sv.sp("select", id=today[2])
    time.sleep(1.2)
    if wanted("window"):
        shoot(f"{tag}-01-window")
    if wanted("field"):
        try:
            sv.cmd({"do": "field", "text": "we"})
            time.sleep(1.0)
            shoot(f"{tag}-02-field")
        except RuntimeError as error:
            t.ok(f"{tag}: the field opened", False, error)
        sv.sp("escape")
        time.sleep(0.3)
        sv.sp("escape")
        time.sleep(0.6)
    if wanted("look"):
        popover(f"{tag}-03-look", lambda: sv.cmd({"do": "ui", "editlook": True}))
    if wanted("card"):
        popover(f"{tag}-04-bookmark-card", lambda: sv.cmd({"do": "ui", "bookmarkCard": True}))
    if wanted("signs"):
        tab = sv.sp("open", url=f"{BASE.replace('127.0.0.1', 'localhost')}/popups")["resultID"]
        time.sleep(1.5)
        t.ok(f"{tag}: blocked pop-ups sign opened", sign_menu(f"{tag}-06-blocked") is not None)
        sv.sp("close", id=tab)
        tab = sv.sp("open", url=f"{BASE}/french")["resultID"]
        time.sleep(1.2)
        sv.cmd({"do": "translate", "id": tab})
        time.sleep(1.5)
        t.ok(f"{tag}: translate sign opened", sign_menu(f"{tag}-07-translate") is not None)
        sv.sp("close", id=tab)
        sv.sp("select", id=today[2])
    if wanted("newtab"):
        before = {x["id"] for x in sv.sp("state")["tabs"]}
        sv.cmd({"do": "film", "action": "newtab", "frames": 1, "path": str(OUT / ".film")})
        time.sleep(1.5)
        shoot(f"{tag}-08-newtab")
        sv.sp("escape")
        time.sleep(0.3)
        for x in sv.sp("state")["tabs"]:
            if x["id"] not in before:
                sv.sp("close", id=x["id"])
        sv.sp("select", id=today[2])
        time.sleep(0.6)
    if wanted("fold"):
        sv.cmd({"do": "ui", "toggleFold": True})
        time.sleep(1.0)
        shoot(f"{tag}-09-folded")
        sv.cmd({"do": "ui", "toggleFold": True})
        time.sleep(0.8)


def welcome(action, **more):
    try:
        return sv.cmd({"do": "welcome", "action": action, **more})
    except RuntimeError:
        return None


def closed_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def once(dark, today):
    mode = "dark" if dark else "light"
    stage(dark)
    sv.cmd({"do": "space", "action": "look", **LOOKS[2][1]})
    if wanted("welcome"):
        state = welcome("state")
        if state:
            for index, step in enumerate(["space", "side", "links", "agents", "key", "bring"]):
                number = sv.cmd({"do": "surface", "name": "onboarding", "step": index + 1, "look": mode})["number"]
                time.sleep(0.6)
                shoot(f"{mode}-20-welcome-{step}", [number])
                sv.cmd({"do": "surface", "action": "close"})
    if wanted("pages"):
        for n, url in enumerate(["broadway://history", "broadway://bookmarks", "broadway://files",
                                 "http://nothing-here.invalid/", f"http://127.0.0.1:{closed_port()}/"]):
            id = sv.sp("open", url=url)["resultID"]
            time.sleep(3 if url.startswith("http") else 1.5)
            shoot(f"{mode}-3{n}-{url.split('//')[1].split('/')[0].split('.')[0].split(':')[0]}")
            sv.sp("close", id=id)
        sv.sp("select", id=today[2])
    if wanted("split"):
        a = sv.sp("open", url=f"{BASE}/left-page")["resultID"]
        b = sv.sp("open", url=f"{BASE}/right-page")["resultID"]
        time.sleep(1)
        try:
            sv.sp("pair", id=b, **{"with": a}, side="right")
        except RuntimeError as error:
            t.ok("split view opened", False, error)
        time.sleep(1.2)
        shoot(f"{mode}-40-split")
        sv.sp("close", id=a)
        sv.sp("close", id=b)
        sv.sp("select", id=today[2])
    if wanted("settings"):
        def listed():
            out = subprocess.run([str(SETTINGS), str(PID[0]), "list"], capture_output=True, text=True).stdout
            return {line.split("\t")[0] for line in out.splitlines() if line.count("\t") == 2}
        before = listed()
        sv.cmd({"do": "ui", "settings": True})
        time.sleep(1.5)
        number = next(iter(listed() - before), None)
        pages = sv.cmd({"do": "settings"}).get("pages", [])
        for page in pages:
            sv.cmd({"do": "ui", "settingsPage": page})
            time.sleep(0.9)
            if number:
                path = OUT / f"{mode}-50-settings-{page}.png"
                subprocess.run([str(SETTINGS), str(PID[0]), number, str(path)], capture_output=True)
                t.ok(f"pictured settings {page}", path.exists())
        sv.cmd({"do": "ui", "settings": False})


def private_window():
    sv.cmd({"do": "windows", "action": "private"})
    time.sleep(2)
    windows = sv.cmd({"do": "windows"}).get("windows", [])
    index = next((n + 1 for n, w in enumerate(windows) if w.get("private")), 2)
    for name in ("notes", "reading-list", "weather"):
        sv.cmd({"do": "split", "action": "open", "url": f"{BASE}/{name}", "window": index})
        time.sleep(0.6)
    for dark in (False, True):
        mode = "dark" if dark else "light"
        staged = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT], "window": index})
        number = staged["window"]
        sv.cmd({"do": "ui", "look": mode})
        time.sleep(1.2)
        shoot(f"{mode}-60-private", [number])
        try:
            sv.cmd({"do": "field", "text": "we", "window": index})
            time.sleep(1.0)
            shoot(f"{mode}-61-private-field", [number])
        except RuntimeError as error:
            t.ok(f"{mode}: the private field opened", False, error)
        for _ in range(2):
            sv.cmd({"do": "split", "action": "escape", "window": index})
            time.sleep(0.4)
        try:
            sv.cmd({"do": "film", "action": "newtab", "frames": 1, "path": str(OUT / ".film"), "window": index})
            time.sleep(1.5)
            shoot(f"{mode}-62-private-newtab", [number])
        except RuntimeError as error:
            t.ok(f"{mode}: the private New Tab page opened", False, error)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowsShot.swift"), "-o", str(SHOT)], check=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/SettingsShot.swift"), "-o", str(SETTINGS)], check=True)
    try:
        sv.setup(sidebar=True, spaces=True, **{"start.fresh": False, "welcome.show": False, "tabs.newAtBottom": True})
        subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "250"], check=True)
        launch()
        sv.cmd({"do": "window"})
        stage(False)
        today = furnish()
        for dark in (False, True):
            for name, look in LOOKS:
                round_of(dark, name, look, today)
        for dark in (False, True):
            once(dark, today)
        if wanted("private"):
            private_window()
    finally:
        t.done()
        sv.finish()
        SHOT.unlink(missing_ok=True)
        SETTINGS.unlink(missing_ok=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
