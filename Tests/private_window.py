#!/usr/bin/env python3
import os
import secrets
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("private-window")
TOKEN = "zqpriv" + secrets.token_hex(5)
CONTROL = "zqctrl" + secrets.token_hex(5)
CRASH = "zqcrash" + secrets.token_hex(5)
HOME = os.path.expanduser("~")

ICON = bytes.fromhex(
    "89504e470d0a1a0a0000000d4948445200000010000000100806000000"
    "1ff3ff610000002a49444154789c63fccf80001864f8ffff3fc3800130"
    "fc6760181a0018000f84a1810000c0d6070d1b0a0cc90000000049454e44ae426082"
) + b"\0" * 64


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        kind = "text/html"
        if path.endswith(".png"):
            body, kind = ICON, "image/png"
        elif path.startswith("/signin/"):
            word = path.split("/")[2]
            body = (f"<!doctype html><title>{word} signed in</title>"
                    f"<link rel=icon href='/icon-{word}.png'>"
                    f"<script>document.cookie='sid={word}cookie; path=/; max-age=86400';"
                    f"localStorage.setItem('k','{word}local');</script><p>{word}").encode()
        elif path.startswith("/page/"):
            word = path.split("/")[2]
            body = f"<!doctype html><title>{word} page</title><p>{word}".encode()
        else:
            body = b"<!doctype html><title>blank</title>"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=3600")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def windows(action="list", **f): return sv.cmd({"do": "windows", "action": action, **f})["windows"]


def private(ws): return [w for w in ws if w["private"]]


def open_in(n, url):
    tab = sv.cmd({"do": "split", "action": "open", "url": url, "window": n})["resultID"]
    for _ in range(50):
        if any(x["id"] == tab and not x.get("loading") for x in sv.cmd({"do": "tabs", "window": n})["tabs"]):
            break
        time.sleep(0.1)
    time.sleep(0.8)
    return tab


def ev(tab, js): return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")


def places():
    found = [Path(sv.SUPPORT), Path(HOME, "Library/Preferences", f"{sv.SUITE}.plist")]
    for parent, prefix in [("Library/Caches", "com.ysmaliak.broadway"), ("Library/HTTPStorages", "com.ysmaliak.broadway"),
                           ("Library/Saved Application State", "com.ysmaliak.broadway"), ("Library/WebKit", "com.ysmaliak.broadway")]:
        root = Path(HOME, parent)
        if root.exists():
            found += [p for p in root.iterdir() if p.name.startswith(prefix)]
    return [p for p in found if p.exists()]


def holding(word):
    hits = []
    for place in places():
        out = subprocess.run(["grep", "-rlaiF", word, str(place)], capture_output=True, text=True).stdout
        hits += [line for line in out.splitlines() if line]
    settings = subprocess.run(["defaults", "export", sv.SUITE, "-"], capture_output=True).stdout
    if word.lower().encode() in settings.lower():
        hits.append(f"defaults {sv.SUITE}")
    return hits


t = sv.T()
try:
    sv.setup(sidebar=True)
    sv.launch()
    first = windows()
    t.ok("starts with one normal window", len(first) == 1 and not first[0]["private"], first)
    control = open_in(1, f"{BASE}/page/{CONTROL}")

    ws = windows("private")
    t.ok("New Private Window opens a second window", len(ws) == 2 and len(private(ws)) == 1, ws)
    n_private = private(ws)[0]["n"]
    t.ok("its window isn't restorable", private(ws)[0]["restorable"] is False, private(ws)[0])
    t.ok("it shows one plain space", private(ws)[0]["space"] == "Private", private(ws)[0])

    one = open_in(n_private, f"{BASE}/signin/{TOKEN}")
    two = open_in(n_private, f"{BASE}/page/{TOKEN}two")
    pw = private(windows())[0]
    t.ok("every tab of the window is private", pw["shy"] and all(pw["shy"]), pw)
    t.ok("no tab of the window keeps data", pw["persistent"] and not any(pw["persistent"]), pw)
    t.ok("its tabs share one store", len(set(pw["storeKeys"])) == 1, pw["storeKeys"])
    t.ok("the second private tab is signed in", f"{TOKEN}cookie" in (ev(two, "document.cookie") or ""), ev(two, "document.cookie"))
    t.ok("and sees the first one's storage", ev(two, "localStorage.getItem('k')") == f"{TOKEN}local")

    plain = open_in(1, f"{BASE}/page/{CONTROL}plain")
    t.ok("a normal window isn't signed in", TOKEN not in (ev(plain, "document.cookie") or ""), ev(plain, "document.cookie"))

    windows("private")
    other = [w for w in private(windows()) if w["n"] != n_private]
    t.ok("a second private window opens", len(other) == 1, windows())
    three = open_in(other[0]["n"], f"{BASE}/page/{TOKEN}three")
    t.ok("and has a store of its own", TOKEN not in (ev(three, "document.cookie") or ""), ev(three, "document.cookie"))
    t.ok("which isn't the first one's", set(private(windows())[1]["storeKeys"]).isdisjoint(pw["storeKeys"]))

    sv.sp("save")
    for w in sorted(private(windows()), key=lambda w: -w["n"]):
        windows("close", n=w["n"])
    after = windows()
    t.ok("closed, the private windows are gone", not private(after) and len(after) == 1, after)
    t.ok("and aren't kept to reopen", after and windows("reopen") and not private(windows()), windows())
    t.ok("the normal window's tabs never held a private page", all(TOKEN not in u for u in windows()[0]["tabs"]), windows()[0]["tabs"])
    sv.sp("save")
    sv.quit()
    time.sleep(1)

    sv.launch()
    back = windows()
    t.ok("after quitting, no private window comes back", not private(back), back)
    windows("private")
    crashed = private(windows())[0]["n"]
    open_in(crashed, f"{BASE}/signin/{CRASH}")
    sv.sp("save")
    time.sleep(1.5)
    for pid in sv.holding() & sv.running():
        os.kill(int(pid), signal.SIGKILL)
    time.sleep(1.5)
    sv.launch()
    back = windows()
    t.ok("after a crash, no private window comes back", not private(back), back)
    t.ok("and no tab holds its page", all(CRASH not in u for w in back for u in w["tabs"]), back)
    sv.quit()
    time.sleep(1.5)

    t.ok("the probe can see a leak: the control page is on disk", bool(holding(CONTROL)), places())
    for word in [TOKEN, CRASH]:
        hits = holding(word)
        t.ok(f"nothing on disk holds {word}", not hits, hits)
        print(f"  read {len(places())} places for {word}: {len(hits)} files hold it")
finally:
    t.done()
    sv.finish()
    server.shutdown()
sys.exit(1 if t.failed else 0)
