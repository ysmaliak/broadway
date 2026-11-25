#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("BROADWAY_APP") or ROOT / "build/Broadway.app")
BROADWAY = str(APP / "Contents/Helpers/broadway")
BENCH = str(ROOT / "bench")
sv.use(f"window-{os.getpid()}")
WORLD = sv.W
FOLDER = Path(sv.SUPPORT)
SUITE = sv.SUITE

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail, flush=True)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        data = b"<!doctype html><title>Shop</title><h1>Shop</h1><button>Buy</button>"
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def broadway(*words, timeout=60, agent=None):
    env = dict(os.environ)
    if agent:
        env["BROADWAY_AGENT"] = agent
    return subprocess.run([BROADWAY, "--world", WORLD, *[str(w) for w in words]], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, timeout=timeout, env=env)


def envelope(*words, agent=None):
    try:
        result = broadway(*words, "--json", agent=agent)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": {"code": "probe_timeout"}}
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"ok": False, "error": {"code": "unparsed", "message": result.stdout + result.stderr}}


def data(said):
    return said.get("data") or {}


def code(said):
    return (said.get("error") or {}).get("code")


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.1)
    return None


def windows(action=None, n=None):
    request = {"do": "windows"}
    if action:
        request["action"] = action
    if n:
        request["n"] = n
    return sv.cmd(request).get("windows", [])


def holding(tab):
    return [w for w in windows() if any(tab and tab in (t or "") for t in w.get("tabs", []))]


def tab_ids(said):
    return [row.get("id") for row in data(said).get("tabs", [])]


def start():
    for key in ("bench", "agents.on", "spaces"):
        subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"], check=True)
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
    return wait_for(lambda: broadway("status").returncode == 0, 40)


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def stop():
    subprocess.run([BENCH, "--world", WORLD, "quit"], capture_output=True)
    for _ in range(60):
        if not held():
            break
        time.sleep(0.25)
    for pid in held():
        os.kill(int(pid), signal.SIGKILL)
    time.sleep(1)


def private_in_front(base):
    wait_for(lambda: windows(), 15)
    person = broadway("tabs", "new", base + "mine", "--front")
    check("the person has a tab in the ordinary window", person.returncode == 0, person.stdout + person.stderr)
    after = windows("private")
    secret = next((w["n"] for w in after if w["private"]), None)
    check("a private window is open", secret is not None, after)
    windows("front", secret)
    check("the private window is in front", any(w["private"] and w["front"] for w in windows()), windows())

    opened = envelope("open", base + "shop")
    tab = data(opened).get("id")
    check("open answers with an id", opened.get("ok") and tab, opened)
    listed = envelope("tabs")
    check("tabs lists the tab open just made", tab in tab_ids(listed), (tab, listed))
    shot = envelope("snapshot", "--tab", tab)
    check("snapshot --tab ID reads it", shot.get("ok"), shot)
    current = envelope("snapshot")
    check("snapshot with no tab reads the current tab", current.get("ok"), current)
    used = envelope("tab", tab)
    check("tab ID makes it current", used.get("ok"), used)
    places = holding("/shop")
    check("the tab is in an ordinary window", places and not any(w["private"] for w in places), windows())
    check("the private window has no agent tab", not any(w["private"] and any("/shop" in t for t in w["tabs"]) for w in windows()), windows())
    check("the private window is still in front", any(w["private"] and w["front"] for w in windows()), windows())

    spaces = envelope("spaces")
    rows = data(spaces).get("spaces", [])
    check("spaces lists the ordinary window's spaces", spaces.get("ok") and data(spaces).get("on") is True and rows, spaces)
    here = next((row for row in rows if row.get("current")), {})
    check("spaces counts the person's tab", here.get("tabs", 0) >= 1, rows)
    named = envelope("open", base + "shop?space", "--space", here.get("name", "Personal"))
    check("open --space NAME works with a private window in front", named.get("ok"), named)
    windows("close", secret)
    return tab


def only_private(base):
    ordinary = [w for w in windows() if not w["private"]]
    windows("private")
    secret = next(w["n"] for w in windows() if w["private"])
    windows("front", secret)
    for w in reversed(ordinary):
        windows("close", w["n"])
    before = windows()
    kept = [w["n"] for w in before if not w["private"] and w.get("shut")]
    check("the ordinary window is closed and kept", len(kept) == 1, before)
    for words in (("status",), ("agents", "list"), ("tabs",), ("spaces",), ("tabs", "--all")):
        said = envelope(*words, agent=f"{WORLD}-alone")
        now = windows()
        check(f"{' '.join(words)} opens no window", said.get("ok") and len(now) == len(before)
              and [w["n"] for w in now if not w["private"] and w.get("shut")] == kept, (said, now))
    person = broadway("tabs", "new", base + "shop?made", agent=f"{WORLD}-alone")
    places = holding("/shop?made")
    check("tabs new with only a private window open makes the tab in an ordinary window",
          person.returncode == 0 and places and not any(w["private"] for w in places) and [w["n"] for w in places] == kept
          and not places[0].get("shut"), (person.stdout + person.stderr, windows()))
    opened = envelope("open", base + "shop?alone", agent=f"{WORLD}-alone")
    tab = data(opened).get("id")
    check("with only a private window open, open still answers with an id", opened.get("ok") and tab, opened)
    listed = envelope("tabs", agent=f"{WORLD}-alone")
    check("and tabs lists it", tab in tab_ids(listed), listed)
    places = holding("/shop?alone")
    check("the tab is in an ordinary window", places and not any(w["private"] for w in places), windows())
    check("that window is the kept one, open again, and no other was made",
          [w["n"] for w in places] == kept and not places[0].get("shut") and len(windows()) == len(before), windows())
    check("the private window is still in front", any(w["private"] and w["front"] for w in windows()), windows())
    windows("close", next(w["n"] for w in windows() if w["private"]))


def two_ordinary(base):
    for _ in range(3):
        if len([w for w in windows() if not w["private"] and not w.get("shut")]) >= 2:
            break
        windows("new")
    both = [w for w in windows() if not w["private"] and not w.get("shut")]
    check("two ordinary windows", len(both) >= 2, windows())
    older, newer = both[0]["n"], both[-1]["n"]
    windows("front", newer)
    opened = envelope("open", base + "shop?newer", agent=f"{WORLD}-two")
    places = holding("/shop?newer")
    check("with two ordinary windows the tab goes to the newer one when it is in front", opened.get("ok") and [w["n"] for w in places] == [newer], (opened, windows()))
    person = broadway("tabs", "new", base + "shop?person", agent=f"{WORLD}-two")
    places = holding("/shop?person")
    check("tabs new goes to the window in front too", person.returncode == 0 and [w["n"] for w in places] == [newer], (person.stdout + person.stderr, windows()))
    windows("front", older)
    opened = envelope("open", base + "shop?older", agent=f"{WORLD}-two")
    places = holding("/shop?older")
    check("and to the older one when that is in front", opened.get("ok") and [w["n"] for w in places] == [older], (opened, windows()))


def no_window(base):
    for w in reversed(windows()):
        windows("close", w["n"])
    opened = envelope("open", base + "shop?none", agent=f"{WORLD}-none")
    tab = data(opened).get("id")
    check("with no window open, open answers with an id", opened.get("ok") and tab, opened)
    check("and tabs lists it", tab in tab_ids(envelope("tabs", agent=f"{WORLD}-none")))
    places = holding("/shop?none")
    check("the tab is in an ordinary window", places and not any(w["private"] for w in places), windows())


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    os.environ["BROADWAY_AGENT"] = WORLD
    os.environ["BROADWAY_AGENT_NAME"] = "Window Probe"
    for name in ("BROADWAY_TAB", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"):
        os.environ.pop(name, None)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sv.wipe()
    try:
        check("the app is up", start())
        for step in (private_in_front, only_private, two_ordinary, no_window):
            try:
                step(base)
            except Exception as problem:
                check(f"{step.__name__} ran", False, repr(problem))
    finally:
        stop()
        sv.wipe()
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
