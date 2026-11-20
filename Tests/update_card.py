#!/usr/bin/env python3
import os
import shutil
import struct
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("update-card")
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/update-card")
PICTURES = os.environ.get("UPDATE_PICTURES") == "1"
t = sv.T()
WINDOW = [0]
CLOSE_OUT = 6


def wav(seconds=150, rate=8000):
    count = seconds * rate
    frames = bytearray(count * 2)
    for i in range(count):
        struct.pack_into("<h", frames, i * 2, 1 if (i // 9) % 2 else -1)
    head = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    return head + b"data" + struct.pack("<I", len(frames)) + bytes(frames)


TONE = wav()
MUSIC = """<!doctype html><title>Music page</title><p>music</p><audio id=t src=/tone.wav loop></audio><script>
navigator.mediaSession.metadata = new MediaMetadata({ title: 'Night Drive', artist: 'A Band' });
</script>"""


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/music":
            return self.send(MUSIC.encode(), "text/html")
        if path == "/tone.wav":
            return self.send(TONE, "audio/wav")
        name = path.strip("/") or "page"
        return self.send(f"<!doctype html><title>{name}</title><p>{name}</p>".encode(), "text/html")

    def send(self, body, kind):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *a):
        pass


def updates(**request):
    return sv.cmd({"do": "updates", **request})


def side(**request):
    return updates(**request)["sidebar"]


def until(check, within=8):
    end = time.time() + within
    while time.time() < end:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.2)
    try:
        return bool(check())
    except Exception:
        return False


def stage(dark, size=(1100, 640)):
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": list(size)})["window"]
    time.sleep(0.8)


def shoot(name):
    if not PICTURES:
        return None
    path = OUT / f"{name}.png"
    subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
    return path if path.exists() else None


def pictures(name):
    if not PICTURES:
        return
    for dark in (False, True):
        stage(dark)
        shoot(f"{name}-{'dark' if dark else 'light'}")
    stage(False)


def film(name, act, frames=20):
    if not PICTURES:
        act()
        return
    folder = OUT / f"{name}-frames"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    thread = threading.Thread(target=act)
    thread.start()
    for index in range(frames):
        subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(folder / f"{index:03d}.png")], capture_output=True)
    thread.join()
    if shutil.which("ffmpeg"):
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "8", "-i", str(folder / "%03d.png"),
                        "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p", str(OUT / f"{name}.mp4")])


def opened(url):
    tab = sv.cmd({"do": "open", "url": url})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 10})
    return tab


def at_foot(state, label):
    view, foot, column = state["view"], state["foot"], state["column"]
    t.ok(f"{label}: the card is shown", state["shown"], state)
    if not state["shown"] or not foot or not column:
        return
    t.ok(f"{label}: its bottom is the foot's top", abs(view[1] + view[3] - foot[1]) < 0.5, (view, foot))
    t.ok(f"{label}: it spans the column", abs(view[0] - column[0]) < 0.5 and abs(view[2] - column[2]) < 0.5, (view, column))
    card = state["card"]
    t.ok(f"{label}: the title is whole", card["titleCut"] is False, card)
    if state["mini"]:
        mini = state["mini"]
        t.ok(f"{label}: under the mini player", abs(mini[1] + mini[3] - (view[1] + CLOSE_OUT)) < 0.5, (mini, view))


STATES = [
    ("available", {"phase": "available"}, "Update Available", "button", "Install"),
    ("checking", {"phase": "checking"}, "Checking for Updates", "spinner", None),
    ("downloading", {"phase": "downloading", "progress": 0.42}, "Downloading", "percent", "42%"),
    ("downloading-unknown", {"phase": "downloading"}, "Downloading", "spinner", None),
    ("installing", {"phase": "installing"}, "Installing", "spinner", None),
    ("failed", {"phase": "failed", "trouble": "The update is improperly signed and could not be validated"}, "Couldn't Update", "button",
     "Try Again"),
]


def every_state():
    for place in ("left", "right"):
        sv.cmd({"do": "ui", "side": place})
        for width in (200, 440):
            sv.cmd({"do": "ui", "sideWidth": width})
            time.sleep(0.5)
            for name, request, title, trailing, shown in STATES:
                updates(stage="0.7", build="950", **request)
                time.sleep(0.5)
                state = side()
                card = state["card"] or {}
                label = f"{name}, {place}, {width}"
                t.ok(f"{label}: the card is shown", state["shown"], state)
                t.ok(f"{label}: the title is {title}", card.get("title") == title, card)
                t.ok(f"{label}: the right side is a {trailing}", card.get("trailing") == trailing, card)
                if trailing == "button":
                    t.ok(f"{label}: the button says {shown}", card.get("buttonTitle") == shown, card)
                if trailing == "percent":
                    t.ok(f"{label}: the percent is whole", card.get("percent") == shown and card.get("percentCut") is False, card)
                t.ok(f"{label}: the title is cut only when it does not fit",
                     card.get("titleCut") == (card.get("titleNeeds", 0) > card.get("textRoom", 0) + 0.5), card)
                if width == 440:
                    t.ok(f"{label}: at the widest the title is whole", card.get("titleCut") is False, card)
                if name == "downloading":
                    box, line = card.get("card") or [0, 0, 0, 0], card.get("lineBox") or [0, 0, 0, 0]
                    t.ok(f"{label}: the progress line is 42% of the card", abs(line[2] - round(box[2] * 0.42)) <= 1, (line, box))
                if name == "failed":
                    t.ok(f"{label}: the reason is the tooltip", card.get("tip", "").startswith("The update is improperly signed"), card)
                if width == 200 or name in ("available", "downloading"):
                    pictures(f"state-{name}-{place}-{width}")
    sv.cmd({"do": "ui", "side": "left"})
    sv.cmd({"do": "ui", "sideWidth": 258})
    updates(unstage=True)
    time.sleep(0.4)


def restore_facts():
    windows = sv.cmd({"do": "windows"})["windows"]
    split = sv.sp("state")
    return {
        "windows": sorted((w["space"], w["spaces"], sorted(u for u in w["tabs"] if u and "/alpha" not in u and "/beta" not in u))
                          for w in windows if not w["private"]),
        "splits": [(s["axis"], len(s["tabs"])) for s in split["splits"]],
        "folded": sorted(g["collapsed"] for g in split["groups"]),
    }


def main():
    if PICTURES:
        OUT.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    sv.BASE = base
    sv.setup(splitView=True)
    sv.launch()
    try:
        stage(False)
        a = opened(f"{base}/alpha")
        opened(f"{base}/beta")
        said = updates()
        t.ok("a test build has no feed and nothing staged", said["runs"] is False and said["staged"] == "", said)
        t.ok("no card while nothing waits", not said["sidebar"]["shown"], said["sidebar"])
        t.ok("no Install Update in the menu", "Install Update" not in said["sidebar"]["menu"], said["sidebar"]["menu"])

        film("arrival", lambda: (updates(stage="0.1", build="900"), time.sleep(1.2)))
        said = updates()
        t.ok("staged: the card shows", said["card"] and until(lambda: side()["shown"]), said)
        menu = side()["menu"]
        t.ok("staged: Install Update is right after About", menu[:2] == ["About Broadway", "Install Update"], menu)
        t.ok("staged: the version line says Broadway 0.1 is available", said["line"].endswith(" · Broadway 0.1 is available"), said["line"])
        state = side()
        t.ok("names: group, button, hide",
             state["card"]["label"] == "Update available, version 0.1" and state["card"]["button"] == "Install Update"
             and state["card"]["hide"] == "Hide" and state["card"]["tip"] == "Version 0.1", state["card"])
        t.ok("words: Update Available and Install", state["card"]["title"] == "Update Available" and state["card"]["buttonTitle"] == "Install",
             state["card"])
        at_foot(state, "left")
        pictures("left")

        sv.cmd({"do": "ui", "side": "right"})
        time.sleep(0.6)
        state = side()
        at_foot(state, "right")
        t.ok("right: the column is on the right", state["column"][0] > 300, state["column"])
        pictures("right")
        sv.cmd({"do": "ui", "side": "left"})

        sv.cmd({"do": "ui", "sideWidth": 200})
        time.sleep(0.6)
        state = side()
        at_foot(state, "narrowest")
        pictures("narrowest")
        sv.cmd({"do": "ui", "sideWidth": 258})

        every_state()
        updates(stage="0.1", build="900")
        time.sleep(0.4)

        music = opened(f"{base}/music")
        sv.cmd({"do": "select", "id": music})
        time.sleep(0.5)
        sv.ev(music, "var a = document.getElementById('t'); a.volume = 0.01; a.play(), 1")
        time.sleep(0.5)
        sv.cmd({"do": "select", "id": a})
        t.ok("the mini player shows", until(lambda: side()["mini"] is not None, within=12), side())
        state = side()
        at_foot(state, "with the mini player")
        pictures("with-mini")

        sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "stacked"})
        time.sleep(0.8)
        state = side()
        at_foot(state, "stacked spaces")
        pictures("stacked")
        sv.cmd({"do": "settings", "set": "spaces.stacked", "value": "side"})
        sv.ev(music, "document.getElementById('t').pause(), 1")
        sv.cmd({"do": "close", "id": music})
        time.sleep(0.6)

        sv.cmd({"do": "ui", "folded": True})
        time.sleep(0.6)
        t.ok("folded: no card", not side()["shown"], side())
        sv.cmd({"do": "ui", "folded": False})
        time.sleep(0.6)

        updates(hide=True)
        t.ok("the x hides the card", until(lambda: not side()["shown"]), side())
        t.ok("hidden, the menu still has Install Update", "Install Update" in side()["menu"], side()["menu"])
        updates(stage="0.1", build="900")
        t.ok("the same build stays hidden", not side()["shown"], side())
        updates(stage="0.1", build="901")
        t.ok("a newer build brings it back", until(lambda: side()["shown"]), side())

        sv.cmd({"do": "windows", "action": "private"})
        time.sleep(0.8)
        windows = sv.cmd({"do": "windows"})["windows"]
        t.ok("a private window is open", any(w["private"] for w in windows), windows)
        sv.cmd({"do": "ui", "confirm": False})
        before = updates()["restartsAsked"]
        said = updates(install=True)
        time.sleep(1.5)
        said = updates()
        t.ok("with a private window it asks first, and Not Now keeps Broadway running",
             said["restartsAsked"] == before and "Restart to update?" in said["asked"], said)
        private = next(w["n"] for w in sv.cmd({"do": "windows"})["windows"] if w["private"])
        sv.cmd({"do": "windows", "action": "close", "n": private})
        time.sleep(0.8)
        sv.cmd({"do": "ui", "confirm": "ask"})

        sv.cmd({"do": "ui", "groups": True, "spaces": True})
        sv.cmd({"do": "space", "action": "new", "name": "Two"})
        sv.cmd({"do": "space", "action": "go", "index": 2})
        time.sleep(1.5)
        t.ok("space Two is picked", sv.cmd({"do": "windows"})["windows"][0]["space"] == "Two", sv.cmd({"do": "windows"})["windows"])
        c, d, e = (sv.page(name) for name in ("gamma", "delta", "epsilon"))
        sv.sp("pair", id=d, **{"with": c}, side="right")
        sv.sp("group", id=e)
        group = sv.sp("state")["groups"][0]["id"]
        sv.sp("collapse", group=group)
        sv.cmd({"do": "windows", "action": "new"})
        time.sleep(1)
        sv.cmd({"do": "windows", "action": "front", "n": 1})
        before = restore_facts()
        t.ok("before: two windows, space Two picked, a pair and a folded folder",
             len(before["windows"]) == 2 and any(w[0] == "Two" for w in before["windows"]) and before["splits"] and True in before["folded"],
             before)

        updates(stage="0.1", build="902", quits=True)
        pid = updates()["pid"]
        try:
            updates(install=True)
        except Exception:
            pass
        t.ok("Install ends Broadway through its quit path", until(lambda: str(pid) not in sv.running(), within=15))
        sv.launch()
        stage(False)
        sv.cmd({"do": "windows", "action": "front", "n": 1})
        after = restore_facts()
        t.ok("after the restart: the same windows, spaces, picked space and tabs", after["windows"] == before["windows"],
             (before["windows"], after["windows"]))
        t.ok("after the restart: the pair is back", after["splits"] == before["splits"], (before["splits"], after["splits"]))
        t.ok("after the restart: the folder is still folded", after["folded"] == before["folded"], (before["folded"], after["folded"]))
        t.ok("after the restart: nothing is staged and there is no card", updates()["staged"] == "" and not side()["shown"], side())
    finally:
        sv.finish()
        server.shutdown()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
