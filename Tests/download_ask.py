#!/usr/bin/env python3
"""Ask Each Time, checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/download_ask.py`. The app
starts hidden in a world of its own, a small server in this script serves a
page and its files, and the setting is turned on through the bench. The
question each download puts is read from the bench and answered there: a
folder inside the world, then a cancel. Last, one question shows the real
save sheet: the window's sheet is a save panel, a second window still takes
a bench command while it is up, the bench cancels it, and one picture of
the probe's own window (and of the sheet's own window) is taken by its id.
Then Save is pressed in a real sheet, and a second download's real sheet,
held behind it, comes up after it and is cancelled.
Pictures go to .context/download-ask/. Where this process may not record the
screen, DOWNLOAD_ASK_HOLD names a folder: the sheet stays up while the
process id and window numbers are written there as hold.txt, and pictures
another process takes of those windows, named as above, are taken in.
"""
import os
import shutil
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("download-ask")

ROOT = Path(__file__).resolve().parents[1]
HOME = f"http://127.0.0.1:{sv.srv.server_port}"
LINK = 'style="display:block;font-size:40px;line-height:80px;padding:0 20px"'
OUT = ROOT / ".context" / "download-ask"
TMP = Path(os.environ.get("TMPDIR", "/tmp")) / f"download-ask-{os.getpid()}"
SHOT = TMP / "shot"


def body(name):
    return f"ask file {name}\n".encode() * 64


class H(BaseHTTPRequestHandler):
    def reply(self, data, kind="text/html", headers=()):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        if url.path == "/page":
            name = q.get("name", "ask.bin")
            html = f'<!doctype html><meta charset=utf-8><title>ask</title><a id="go" href="/file?name={name}" {LINK}>Download</a>'
            return self.reply(html.encode())
        if url.path == "/file":
            name = q.get("name", "ask.bin")
            return self.reply(body(name), "application/octet-stream",
                              [("Content-Disposition", f'attachment; filename="{name}"')])
        return self.reply(b"<!doctype html><title>plain</title><p>plain</p>")

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def ask(action="state", *values, **at):
    return sv.cmd({"do": "saveask", "action": action, "values": list(values), **at})


def trace():
    return sv.cmd({"do": "downloadtrace"})


def question(seconds=10, real=False):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        up = [q for q in ask()["questions"] if q["up"] and (not real or q["sheet"])]
        if up:
            return up[0]
        time.sleep(0.2)
    return None


def start(name, **at):
    tab = sv.cmd({"do": "split", "action": "open", "url": f"{HOME}/page?name={name}", **at})["resultID"]
    time.sleep(1.2)
    sv.cmd({"do": "tap", "id": tab, "selector": "#go", **at})
    return tab


def landed(path, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if path.exists() and any(k["path"] == str(path) for k in trace()["kept"]):
            return True
        time.sleep(0.2)
    return False


def tool():
    TMP.mkdir(parents=True, exist_ok=True)
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    return subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(TMP),
                          capture_output=True, text=True).returncode == 0


def shoot(pid, number, name):
    path = OUT / f"{name}.png"
    if path.exists():
        path.unlink()
    said = ""
    for _ in range(4):
        got = subprocess.run([str(SHOT), str(pid), str(number), str(path)], cwd=str(TMP), capture_output=True, text=True)
        said = (got.stdout + got.stderr).strip()
        if path.exists():
            return path, said
        time.sleep(0.8)
    return None, said


def case_answered(t, picked):
    downloads = Path(trace()["folder"])
    start("ask-answered.bin")
    q = question()
    t.ok("a link download puts a question", q is not None, ask())
    if not q:
        return
    t.ok("the question carries the file's name", q["name"] == "ask-answered.bin", q["name"])
    t.ok("the question starts in the downloads folder", Path(q["folder"]).resolve() == downloads.resolve(), q["folder"])
    t.ok("no real sheet in a test world", not q["sheet"] and not q["real"], q)
    target = picked / "answered.bin"
    ask("answer", str(target))
    t.ok("the file lands where the bench answered and is kept", landed(target), trace()["kept"])
    t.ok("the file has the bytes the server sent", target.exists() and target.read_bytes() == body("ask-answered.bin"))
    t.ok("nothing went to the downloads folder", not (downloads / "ask-answered.bin").exists())
    folders = ask()["folders"]
    t.ok("the folder is kept for the next question", str(picked) in folders.values(), folders)


def case_cancelled(t, picked):
    downloads = Path(trace()["folder"])
    kept = len(trace()["kept"])
    start("ask-cancelled.bin")
    q = question()
    t.ok("a second download puts a question", q is not None)
    if not q:
        return
    t.ok("the next question starts in the folder picked last", Path(q["folder"]).resolve() == picked.resolve(), q["folder"])
    ask("cancel")
    time.sleep(1.5)
    got = trace()
    t.ok("cancel leaves nothing in the list", not got["entries"] and len(got["kept"]) == kept, got["entries"])
    t.ok("cancel leaves no file", not (downloads / "ask-cancelled.bin").exists() and not (picked / "ask-cancelled.bin").exists())
    t.ok("cancel reads as no failure", "didn't finish" not in got["announcement"], got["announcement"])
    t.ok("no question is left", not ask()["questions"])


def case_real(t, pid, shots):
    sv.cmd({"do": "windows", "action": "new"})
    time.sleep(1)
    number = sv.cmd({"do": "idle", "action": "unhide", "window": 1})["number"]
    time.sleep(0.8)
    ask("real", window=1)
    start("ask-real.bin", window=1)
    q = question(seconds=12, real=True)
    t.ok("the real step shows a sheet", q is not None, ask())
    if not q:
        return
    t.ok("the window's attached sheet is the save panel", q["attachedIsPanel"], q["attached"])
    t.ok("the sheet shows the whole name with its ending", q["shownName"] == "ask-real.bin", q["shownName"])
    t.ok("the sheet is on the window the download came from", q["window"] == number, (q["window"], number))
    other = sv.cmd({"do": "split", "action": "open", "url": f"{HOME}/plain", "window": 2})
    time.sleep(1)
    tabs = sv.cmd({"do": "windows"})["windows"]
    t.ok("a second window takes a bench command while the sheet is up",
         bool(other.get("resultID")) and any(f"{HOME}/plain" in u for u in tabs[1]["tabs"]), tabs[1]["tabs"] if len(tabs) > 1 else tabs)
    time.sleep(0.6)
    wanted = [("window-with-sheet", number), ("sheet", q["attachedNumber"])]
    if SHOT.exists():
        for name, which in wanted:
            path, said = shoot(pid, which, name)
            if path:
                shots.append(path)
            else:
                print(f"  no picture {name}: {said}")
    hold = os.environ.get("DOWNLOAD_ASK_HOLD")
    if hold and not shots:
        handoff = Path(hold)
        handoff.mkdir(parents=True, exist_ok=True)
        (handoff / "hold.txt").write_text(" ".join(str(x) for x in [pid] + [n for _, n in wanted]))
        print(f"  holding the sheet for pictures from {handoff}", flush=True)
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline and not all((handoff / f"{name}.png").exists() for name, _ in wanted):
            time.sleep(0.5)
        for name, _ in wanted:
            if (handoff / f"{name}.png").exists():
                shutil.copy(handoff / f"{name}.png", OUT / f"{name}.png")
                shots.append(OUT / f"{name}.png")
    ask("cancel", q["id"])
    time.sleep(1)
    state = ask()
    t.ok("the bench cancels the real sheet", not state["questions"], state)
    t.ok("no file after cancelling the sheet", not (Path(trace()["folder"]) / "ask-real.bin").exists())


def case_saved(t, picked):
    ask("real", "2", window=1)
    start("ask-saved.bin", window=1)
    q = question(seconds=12, real=True)
    t.ok("a real sheet comes up for the next download", q is not None, ask())
    if not q:
        return
    start("ask-second.bin", window=1)
    time.sleep(1)
    waiting = [x for x in ask()["questions"] if not x["up"]]
    t.ok("a second download waits behind the sheet that is up",
         len(waiting) == 1 and waiting[0]["name"] == "ask-second.bin" and not waiting[0]["sheet"], ask()["questions"])
    t.ok("the sheet starts in the folder picked last", Path(q["folder"]).resolve() == picked.resolve(), q["folder"])
    time.sleep(1)
    ask("save", q["id"])
    t.ok("Save in the real sheet lands the file there and keeps it", landed(picked / "ask-saved.bin"), trace()["kept"])
    second = question(seconds=12, real=True)
    t.ok("the waiting download's sheet comes up once the first is answered",
         second is not None and second["name"] == "ask-second.bin" and second["attachedIsPanel"], ask())
    if second:
        ask("cancel", second["id"])
        time.sleep(1)
    t.ok("cancelling the second sheet leaves no question and no file",
         not ask()["questions"] and not (picked / "ask-second.bin").exists(), ask())
    sv.cmd({"do": "idle", "action": "hide"})


def main():
    t = sv.T()
    shots = []
    OUT.mkdir(parents=True, exist_ok=True)
    have_tool = tool()
    try:
        sv.setup()
        sv.launch()
        pid = next(iter(sv.holding() & sv.running()))
        picked = Path(sv.SUPPORT) / "Picked"
        picked.mkdir(parents=True, exist_ok=True)
        sv.cmd({"do": "settings", "set": "downloads.ask", "value": True})
        t.ok("the setting is on", ask()["asks"] is True)
        case_answered(t, picked)
        case_cancelled(t, picked)
        t.ok("the picture tool builds", have_tool)
        case_real(t, pid, shots)
        case_saved(t, picked)
    finally:
        t.done()
        for path in shots:
            print("picture", path)
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
