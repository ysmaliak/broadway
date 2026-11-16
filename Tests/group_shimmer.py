#!/usr/bin/env python3
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("group-shimmer")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/group-shimmer")
TOOLS = ROOT / ".build" / "popup-shots"
FILM = TOOLS / "popup-film"
WIDTH, HEIGHT = 1100, 700
TITLES = {"flights": "Lisbon flights", "hotels": "Lisbon hotels", "swift": "Swift docs"}
t = sv.T()


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        title = TITLES.get(name, name)
        data = f"<!doctype html><title>{title}</title><body style='background:white'><h1>{title}</h1>".encode()
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


def tools():
    TOOLS.mkdir(parents=True, exist_ok=True)
    source = ROOT / "Tests/popup_film.swift"
    if not FILM.exists() or FILM.stat().st_mtime < source.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(source), "-o", str(FILM)], check=True)


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def ai(*args):
    return sv.cmd({"do": "aigroups", "args": list(args)})


def group():
    return next((g for g in ai("state")["groups"] if g["ai"]), None)


def wait_for(test, within=10):
    until = time.time() + within
    while time.time() < until:
        value = test()
        if value:
            return value
        time.sleep(0.2)
    return test()


def stage(dark):
    staged = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [WIDTH, HEIGHT]})
    time.sleep(0.8)
    return staged["window"], staged["pid"]


def film(window, pid, name, seconds, act):
    folder = OUT / name
    taker = subprocess.Popen([str(FILM), str(pid), str(window), str(folder), str(seconds)],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    line = taker.stdout.readline()
    if not line.startswith("ready"):
        taker.wait()
        t.ok(f"{name}: filmed", False, line + taker.stderr.read())
        return
    act()
    out, err = taker.communicate()
    t.ok(f"{name}: filmed", (folder / "times.txt").exists(), (out + err).strip())


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    tools()
    try:
        sv.setup(**{"tabs.groups": True, "ai": True, "ai.groups": True})
        launch()
        sv.cmd({"do": "window"})
        ai("fake", "0.3", "0.6")
        for name in ("flights", "hotels", "swift"):
            sv.sp("open", url=f"{BASE}/{name}")
            time.sleep(0.4)
        formed = wait_for(lambda: (lambda g: g if g and g["how"] else None)(group()), 10)
        t.ok("two Lisbon pages form a named AI group", formed is not None and len(formed["tabs"]) == 2, ai("state"))
        if not formed:
            return
        t.ok("its name came without the veil left on", not formed["veiled"], formed)

        for dark in (True, False):
            tag = "dark" if dark else "light"
            window, pid = stage(dark)
            sv.cmd({"do": "ui", "side": "left"})
            ai("release", formed["id"], "Lisbon", "✈️")
            time.sleep(0.4)
            seen = {}

            def named():
                time.sleep(0.2)
                ai("hold", formed["id"])
                seen["held"] = group()
                time.sleep(1.6)
                ai("release", formed["id"], "Lisbon Trip", "🧳")
                seen["released"] = group()

            film(window, pid, f"name-arrives-{tag}", 3.0, named)
            t.ok(f"{tag}: held, the heading is veiled", seen.get("held", {}).get("veiled"), seen.get("held"))
            done = seen.get("released", {})
            t.ok(f"{tag}: released, the name and emoji are in", not done.get("veiled") and done.get("name") == "Lisbon Trip"
                 and done.get("emoji") == "🧳", done)

        window, pid = stage(True)
        ai("stop", "1.2")
        seen = {}

        def stopped():
            time.sleep(0.2)
            ai("hold", formed["id"], "free")
            seen["held"] = group()
            time.sleep(1.8)
            seen["after"] = group()

        film(window, pid, "stop-lifts-dark", 2.8, stopped)
        t.ok("free hold: veiled at first", seen.get("held", {}).get("veiled"), seen.get("held"))
        after = seen.get("after", {})
        t.ok("the stop lifts the bar and keeps the name", not after.get("veiled") and after.get("name") == "Lisbon Trip", after)
        ai("stop", "8")
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
