#!/usr/bin/env python3
import datetime
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Broadway.app"
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"codexdesk-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
FIXTURES = ROOT / "Tests/Fixtures/codex"
FRAMES = Path(os.environ.get("AGENT_MODE_FRAMES", ROOT / ".context/frames"))
WORKING = "01a1c0de-0000-7000-8000-00000000000a"
DONE = "01a1c0de-0000-7000-8000-00000000000b"
LATER = "01a1c0de-0000-7000-8000-00000000000e"

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail)
    if not ok:
        failures.append(name)


def bench(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(str(FOLDER / "bench.sock"))
        s.sendall((json.dumps(request) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
    return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")


def agent(action, **more):
    return bench(dict({"do": "agents", "action": action}, **more))


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.2)
    return None


def area():
    return agent("state").get("area", [])


def card(named):
    return next((row for row in area() if row["name"] == named), None)


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def film(name):
    FRAMES.mkdir(parents=True, exist_ok=True)
    answer = bench({"do": "film", "action": "none", "path": str(FRAMES / name), "frames": 1, "region": "full"})
    files = [frame.get("file") for frame in answer.get("frames", []) if frame.get("file")]
    check(f"frame {name}", bool(files), answer)


def lay_out(home):
    day = home / "sessions" / datetime.date.today().strftime("%Y/%m/%d")
    day.mkdir(parents=True)
    for name in ["desktop-working.jsonl", "desktop-done.jsonl", "cli.jsonl", "subagent.jsonl"]:
        shutil.copy(FIXTURES / name, day / f"rollout-2026-11-04T08-00-00-{name}")
        os.utime(day / f"rollout-2026-11-04T08-00-00-{name}")
    shutil.copy(FIXTURES / "session_index.jsonl", home / "session_index.jsonl")
    return day


def append(path, row):
    with open(path, "a") as handle:
        handle.write(json.dumps(row) + "\n")


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    home = Path(tempfile.mkdtemp(prefix="codex-home-"))
    day = lay_out(home)
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", "--env", f"BROADWAY_CODEX_HOME={home}",
                        "--env", "BROADWAY_CODEX_RUNNING=1", str(APP)], check=True)
        check("the app is up", wait_for(lambda: subprocess.run([BROADWAY, "--world", WORLD, "status"], capture_output=True).returncode == 0, 30) is not None)
        bench({"do": "window"})

        busy = wait_for(lambda: card("Codex · Fix the build"), 10)
        check("a working desktop thread has a card named for its title", busy is not None, area())
        check("it says what Codex is doing", busy and busy["status"] == "Running swift test --filter" and busy["mood"] == "reading", busy)
        finished = card("Codex · project-b")
        check("a finished turn shows its answer and the tick", finished and finished["status"] == "Fixed the failing test. All green." and finished["mood"] == "done", finished)
        check("the cards wear Codex's colour", busy and finished and busy["accent"] == 1 and finished["accent"] == 1, area())
        check("CLI and subagent threads get no card", len(area()) == 2, area())
        time.sleep(1.5)
        film("codex-01-cards")

        working = day / "rollout-2026-11-04T08-00-00-desktop-working.jsonl"
        append(working, {"type": "event_msg", "payload": {"type": "task_complete", "turn_id": "t1", "last_agent_message": "Build fixed.", "started_at": 1793700000}})
        moved = wait_for(lambda: (lambda c: c if c and c["status"] == "Build fixed." else None)(card("Codex · Fix the build")), 10)
        check("a write to the rollout reaches the card through file events", moved is not None and moved["mood"] == "done", card("Codex · Fix the build"))

        later = day / "rollout-2026-11-04T09-00-00-later.jsonl"
        text = (FIXTURES / "desktop-working.jsonl").read_text().replace(WORKING, LATER).replace("/tmp/project-a", "/tmp/project-e")
        later.write_text(text)
        fresh = wait_for(lambda: card("Codex · project-e"), 10)
        check("a new desktop thread shows up by itself", fresh is not None, area())

        opened = agent("codexopen", link=busy["id"][:8]) if busy else {}
        check("a click opens the thread in Codex", opened.get("opened") == f"codex://threads/{WORKING}", opened)

        agent("codex", running=False)
        ended = area()
        check("quitting Codex ends its cards, which stay a moment", len(ended) == 3 and all(row["mood"] == "done" for row in ended), ended)
        rows = agent("state")["links"]
        check("ended cards report done", all(row["state"] == "done" for row in rows if row.get("codex")), rows)
        swept = agent("linksweep", after=60)
        check("they linger past a minute", len(swept["area"]) == 3, swept["area"])
        swept = agent("linksweep", after=130)
        check("and are gone after two", swept["area"] == [], swept["area"])

        append(later, {"type": "event_msg", "payload": {"type": "task_started", "turn_id": "t9", "started_at": int(time.time())}})
        time.sleep(2.5)
        check("nothing is read while Codex is closed", area() == [], area())
    finally:
        subprocess.run([BROADWAY, "--world", WORLD, "quit", "--force"], capture_output=True)
        for _ in range(40):
            if not held():
                break
            time.sleep(0.25)
        for pid in held():
            os.kill(int(pid), signal.SIGKILL)
        shutil.rmtree(FOLDER, ignore_errors=True)
        shutil.rmtree(home, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
