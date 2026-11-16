#!/usr/bin/env python3
"""An automatic folder left with one tab dissolves (Browser.dissolveLoneFolder).

Build first (`./build.sh`), then `python3 Tests/ai_folder_of_one.py [LABEL]`.

Shown, with the fake engine (aigroups fake): two Lisbon pages are grouped into
an AI folder between two loose tabs and the column is pictured at 2x; then one
Lisbon tab is closed, the folder goes, the other stays in its place as a plain
tab with the selection unchanged, and the column is pictured again. The grouper
is asked to regroup and must not put the tab back into a folder of one.
Out: .context/after/ai-folder-of-one/LABEL/{before,after}.png.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
sys.argv = sys.argv[:1]
import split_view as sv  # noqa: E402

OUT = ROOT / ".context" / "after" / "ai-folder-of-one" / LABEL
WIDTH, HEIGHT, COLUMN = 1000, 520, 270
TITLES = {"inbox": "Inbox", "flights": "Lisbon flights", "hotels": "Lisbon hotels", "swift": "Swift docs"}


class Pages(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def do_GET(self):
        name = self.path.strip("/").split("/")[0]
        body = (f"<!doctype html><meta charset=utf-8><title>{TITLES.get(name, name)}</title>"
                f"<body style='background:#33373d'>").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"
sv.use("ai-folder-of-one-" + uuid.uuid4().hex[:6])
t = sv.T()
SHOT = Path(os.environ.get("AI_FOLDER_SHOT", "/tmp/ai-folder-of-one-tools/shot"))


def cmd(**r): return sv.cmd(r)
def state(): return sv.sp("state")
def ai(*args): return sv.cmd({"do": "aigroups", "args": list(args)})
def ai_groups(): return [g for g in ai("state")["groups"] if g["ai"]]


def wait_for(test, within=10):
    until = time.time() + within
    while time.time() < until:
        value = test()
        if value:
            return value
        time.sleep(0.2)
    return test()


def tool():
    if SHOT.exists():
        return
    SHOT.parent.mkdir(parents=True, exist_ok=True)
    source = SHOT.parent / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(SHOT.parent), check=True)


def picture(name, scratch):
    number = cmd(do="idle", action="unhide")["number"]
    time.sleep(0.8)
    pid = next(iter(sv.holding() & sv.running()))
    drawn = scratch / f"{name}-whole.png"
    said = ""
    for _ in range(4):
        got = subprocess.run([str(SHOT), str(pid), str(number), str(drawn)], cwd=str(scratch), capture_output=True, text=True)
        said = f"{pid} {number}: {got.stdout.strip()} {got.stderr.strip()[-400:]}"
        if drawn.exists():
            break
        time.sleep(0.8)
    if not drawn.exists():
        t.ok(f"pictured {name}", False, said)
        return
    width = int(subprocess.run(["sips", "-g", "pixelWidth", str(drawn)], capture_output=True, text=True).stdout.split()[-1])
    k = max(1, round(width / WIDTH))
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(drawn), "-vf",
                    f"crop={COLUMN * k}:{HEIGHT * k}:0:0", str(OUT / f"{name}.png")], check=True)
    t.ok(f"pictured {name} at {k}x", (OUT / f"{name}.png").exists() and k == 2, k)


def order():
    return [x["id"] for x in state()["tabs"] if x.get("url")]


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    scratch = Path(tempfile.mkdtemp(prefix="ai-folder-of-one-"))
    tool()
    sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "ai": True, "ai.groups": True, "tabs.cards": True,
                                           "layout.cards": True, "start.fresh": False, "split": False,
                                           "tabs.newAtBottom": True})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    try:
        cmd(do="resize", width=WIDTH, height=HEIGHT, steps=1)
        ai("fake", "0.4", "1.0")
        ids = {}
        for name in ["inbox", "flights", "hotels", "swift"]:
            ids[name] = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
            cmd(do="wait", id=ids[name], seconds=10)
        for x in state()["tabs"]:
            if not x.get("url"):
                sv.sp("close", id=x["id"])
        ai("regroup")
        folder = wait_for(lambda: next((g for g in ai_groups() if len(g["tabs"]) == 2 and g["how"]), None), 12)
        t.ok("the two Lisbon tabs share an AI folder", folder is not None
             and sorted(folder["tabs"]) == sorted([ids["flights"], ids["hotels"]]), ai("state"))
        sv.sp("select", id=ids["flights"])
        time.sleep(1.2)
        picture("before", scratch)
        row = order()

        sv.sp("close", id=ids["hotels"])
        time.sleep(1.2)
        picture("after", scratch)
        now = state()
        t.ok("the folder is gone", not ai_groups(), ai("state"))
        t.ok("the last tab is a plain tab", all(ids["flights"] not in g["tabs"] for g in ai("state")["groups"]), ai("state"))
        t.ok("it stays where the folder was", order() == [x for x in row if x != ids["hotels"]], (row, order()))
        t.ok("the selection did not change", now.get("activeID") == ids["flights"], now.get("activeID"))

        ai("regroup")
        time.sleep(2.0)
        t.ok("the grouper puts it in no folder of one", all(len(g["tabs"]) >= 2 for g in ai_groups())
             and all(ids["flights"] not in g["tabs"] for g in ai_groups()), ai("state"))
    finally:
        t.done()
        sv.finish()
        shutil.rmtree(scratch, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
