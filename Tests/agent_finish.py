#!/usr/bin/env python3
"""An agent whose turn ended reads finished, on a test copy's own window.

Build first (`./build.sh`), then `python3 Tests/agent_finish.py`. A test copy in a
world of its own, driven by the real `broadway` as three invented agents:

1. A Claude Code session acts, its Stop hook arrives on stdin and the card reads
   finished with the last thing it did. A new command makes the same card work again.
   With a question up, the hook leaves it asking. SessionEnd ends it and its tabs stay.
2. A Codex session with no hook reads Thinking at first, and Idle after the quiet
   time, which the bench's shortened clock skips to. A question up keeps it out of idle.
3. A session whose agent process exits ends at the next sweep.
4. The hook never starts Broadway, prints nothing and exits 0.
5. setup and remove against an invented home add only broadway's hooks, twice gives
   the same bytes, and remove gives the original bytes back.

Pictures are of the probe window by its id only. Out: .context/agent-finish.
"""
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("BROADWAY_APP", ROOT / "build/Broadway.app"))
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"agentfinish-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
OUT = ROOT / ".context/agent-finish"

CLAUDE = "0a1b2c3d-0000-4000-8000-00000000c1a0"
CODEX = "0a1b2c3d-0000-4000-8000-00000000c0de"
HELPER = "0a1b2c3d-0000-4000-8000-0000000000e1"

failures = []
passed = [0]


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:600], flush=True)
    if ok:
        passed[0] += 1
    else:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = (f"<!doctype html><title>{name}</title><body style='font:16px system-ui'><h1>{name}</h1>"
                f"<button>Next</button><div style='height:3000px'></div>").encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def clean_env(more):
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith("BROADWAY_") and k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID")}
    environment.update(more)
    return environment


def claude_env():
    return clean_env({"CLAUDE_CODE_SESSION_ID": CLAUDE, "BROADWAY_AGENT_NAME": "Claude Code"})


def codex_env():
    return clean_env({"CODEX_THREAD_ID": CODEX, "BROADWAY_AGENT_NAME": "Codex"})


def run(*words, env, world=WORLD, stdin=None, timeout=60):
    return subprocess.run([BROADWAY, "--world", world, *words], capture_output=True, text=True, env=env,
                          input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL, timeout=timeout)


def data(*words, env):
    result = run(*words, "--json", env=env)
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"ok": False, "raw": result.stdout + result.stderr}


def hook(agent, event, session, world=WORLD, **more):
    payload = dict({"session_id": session, "transcript_path": "/tmp/invented.jsonl", "cwd": "/tmp", "hook_event_name": event}, **more)
    started = time.time()
    result = run("agents", "idle", "--hook", agent, env=clean_env({}), world=world, stdin=json.dumps(payload), timeout=20)
    return result, time.time() - started


def bench(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(60)
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


def state():
    return agent("state")


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.2)
    return None


def card(link_id):
    return next((row for row in state().get("area", []) if row["id"] == link_id), None)


def link_row(link_id):
    return next((row for row in state().get("links", []) if link_id.lower().startswith(row["id"])), None)


def find_card(name):
    return next((row for row in state().get("area", []) if row["name"] == name), None)


shots = []


FRAMES = Path(tempfile.mkdtemp(prefix="agent-finish-frames-"))


def film(name):
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        answer = bench({"do": "film", "action": "none", "path": str(FRAMES / name), "frames": 1, "region": "full"})
    except OSError as error:
        answer = {"error": str(error)}
    files = []
    for frame in answer.get("frames", []):
        if frame.get("file") and Path(frame["file"]).exists():
            shutil.copy(frame["file"], OUT / Path(frame["file"]).name)
            files.append(Path(frame["file"]).name)
    shots.append({"name": name, "files": files, "answer": {k: v for k, v in answer.items() if k != "frames"}})
    window = next((w for w in agent("windows").get("windows", []) if w.get("visible") or w.get("onScreen")), None)
    shots[-1]["window"] = window


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def claude_session(base):
    opened = data("open", base + "shop", env=claude_env())
    check("Claude Code opens a tab of its own", opened.get("ok"), opened)
    found = wait_for(lambda: find_card("Claude Code"), 10)
    check("its card shows", found is not None, state().get("area"))
    link = found["id"]
    read = data("read", env=claude_env())
    check("it reads the page", read.get("ok"), read)
    thinking = wait_for(lambda: (lambda c: c if c and c["status"] == "Thinking" else None)(card(link)), 8)
    check("between steps the card says Thinking, not Waiting", thinking is not None, card(link))
    film("01-thinking")

    result, took = hook("claude", "Stop", CLAUDE, stop_hook_active=False, last_assistant_message="Invented reply",
                        background_tasks=[], session_crons=[])
    check("the Stop hook exits 0 and prints nothing", result.returncode == 0 and result.stdout == "" and result.stderr == "", result)
    finished = wait_for(lambda: (lambda c: c if c and c["status"].startswith("Finished") else None)(card(link)), 5)
    check("the turn's end reads finished with the last thing it did",
          finished is not None and finished["status"].startswith("Finished after ") and "127.0.0.1" in finished["status"], card(link))
    check("with the done face", finished and finished["mood"] == "done" and finished["face"] == "done" and not finished["attention"], finished)
    check("the session is still live", link_row(link) and link_row(link)["state"] == "finished", link_row(link))
    row = state()["row"]
    check("the folded header names it finished", row["line"].startswith("Claude Code · Finished") and not row["attention"], row)
    check("its tabs stay as they are", finished and finished["tabs"] == found["tabs"], finished)
    film("02-finished")

    again = data("scroll", env=claude_env())
    check("a new command goes through", again.get("ok"), again)
    working = card(link)
    check("the same card works again", working and not working["status"].startswith("Finished") and working["id"] == link
          and link_row(link)["state"] == "connected", working)
    check("still one Claude Code session", len([r for r in state()["area"] if r["name"] == "Claude Code"]) == 1, state()["area"])
    return link, found["tabs"]


def question_keeps_asking(link, env, session, agent_name):
    agent("mode", mode="ask")
    asking = subprocess.Popen([BROADWAY, "--world", WORLD, "scroll", "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, stdin=subprocess.DEVNULL, env=env)
    waiting = wait_for(lambda: (lambda c: c if c and c["attention"] else None)(card(link)), 15)
    check(f"{agent_name} asks the person", waiting is not None, card(link))
    if session:
        hook("claude", "Stop", session, background_tasks=[], session_crons=[])
        time.sleep(0.4)
        after = card(link)
        check("a Stop hook with a question up leaves it asking", after and after["attention"] and after["status"].startswith("Needs you"), after)
        film("03-needs-you")
    else:
        swept = agent("linksweep", after=130)
        after = next((row for row in swept["area"] if row["id"] == link), None)
        check("the quiet time with a question up leaves it asking", after and after["attention"] and after["status"].startswith("Needs you"), after)
    row = state()["row"]
    check("the header says it needs you", row["attention"] and row["title"].endswith("needs you"), row)
    agent("answer", **{"with": "yes"})
    out, err = asking.communicate(timeout=30)
    check("the yes lets the scroll through", asking.returncode == 0, out + err)
    agent("mode", mode="auto")


def codex_session(base):
    opened = data("open", base + "notes", env=codex_env())
    check("Codex opens a tab", opened.get("ok"), opened)
    found = wait_for(lambda: find_card("Codex"), 10)
    check("its card shows", found is not None, state().get("area"))
    link = found["id"]
    time.sleep(3.5)
    early = next((row for row in agent("linksweep", after=60)["area"] if row["id"] == link), None)
    check("a minute later it still says Thinking", early and early["status"] == "Thinking", early)
    late = next((row for row in agent("linksweep", after=130)["area"] if row["id"] == link), None)
    check("past the quiet time it reads idle with the last thing it did",
          late and late["status"].startswith("Idle after ") and "127.0.0.1" in late["status"], late)
    check("with the ended face and no attention", late and late["face"] == "ended" and not late["attention"], late)
    check("listed as idle", link_row(link) and link_row(link)["state"] == "idle", link_row(link))
    return link


def helper_session(base, scratch):
    fake = scratch / "claude"
    built = subprocess.run(["cc", "-O", "-o", str(fake), str(ROOT / "Tests/agent_host.c")], capture_output=True, text=True)
    check("the stand-in agent compiles", built.returncode == 0, built.stderr)
    env = clean_env({"CLAUDE_CODE_SESSION_ID": HELPER, "BROADWAY_AGENT_NAME": "Helper"})
    process = subprocess.Popen([str(fake), "/bin/sh", "-c", f"{BROADWAY} --world {WORLD} open {base}helper --json", "sleep 120"],
                               stdout=subprocess.PIPE, text=True, env=env, start_new_session=True)
    process.stdout.readline()
    found = wait_for(lambda: find_card("Helper"), 10)
    check("an agent process named claude starts a session", found is not None, state().get("area"))
    link = found["id"] if found else ""
    swept = agent("linksweep", after=0)
    alive = next((row for row in swept["links"] if link.lower().startswith(row["id"])), None)
    check("while it runs the session stays", alive and alive["state"] != "done", alive)
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    swept = agent("linksweep", after=0)
    ended = next((row for row in swept["links"] if link.lower().startswith(row["id"])), None)
    check("its process exiting ends the session at the next sweep", ended and ended["state"] == "done", ended)
    gone = next((row for row in swept["area"] if row["id"] == link), None)
    check("with the ended face, and its tab stays", gone and gone["face"] == "ended" and len(gone["tabs"]) == 1, gone)


def no_wake():
    nowhere = f"agentfinish-none-{secrets.token_hex(3)}"
    result, took = hook("claude", "Stop", CLAUDE, world=nowhere)
    check("with no Broadway the hook exits 0 at once and prints nothing",
          result.returncode == 0 and result.stdout == "" and result.stderr == "" and took < 3, (result, took))
    time.sleep(1.5)
    socket_path = Path.home() / f"Library/Application Support/Broadway ({nowhere})/broadway.sock"
    check("and starts no Broadway", not socket_path.exists())
    shutil.rmtree(socket_path.parent, ignore_errors=True)
    junk = run("agents", "idle", "--hook", "claude", env=clean_env({}), stdin="not json")
    check("a hook with no event does nothing", junk.returncode == 0 and junk.stdout == "", junk)
    stranger = hook("claude", "Stop", "0a1b2c3d-0000-4000-8000-0000000000ff")[0]
    check("a hook from a session that never used Broadway does nothing", stranger.returncode == 0 and stranger.stdout == ""
          and not any(row["name"] == "Claude Code 2" for row in state()["area"]), stranger)


FOREIGN = """{
    "model": "opus",
    "hooks": {
        "Stop": [
            {
                "hooks": [{"type": "command", "command": "say done"}]
            }
        ]
    }
}"""


def setup_files(scratch):
    home = scratch / "home"
    (home / ".claude").mkdir(parents=True)
    (home / ".codex").mkdir(parents=True)
    settings = home / ".claude/settings.json"
    settings.write_text(FOREIGN)
    env = clean_env({"BROADWAY_HOME": str(home)})
    first = subprocess.run([BROADWAY, "setup", "claude", "codex", "--json"], capture_output=True, text=True, env=env)
    check("setup claude codex runs", first.returncode == 0, first.stdout + first.stderr)
    added = settings.read_text()
    codex = (home / ".codex/hooks.json").read_text()
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "claude-settings.json").write_text(added)
    (OUT / "codex-hooks.json").write_text(codex)
    parsed = json.loads(added)
    stops = parsed["hooks"]["Stop"]
    check("the person's own Stop hook is kept, first", stops[0]["hooks"][0]["command"] == "say done" and len(stops) == 2, stops)
    check("broadway's Stop and SessionEnd hooks are there",
          "agents idle --hook claude" in json.dumps(stops[1]) and "agents idle --hook claude" in json.dumps(parsed["hooks"]["SessionEnd"]), parsed)
    check("codex gets its own hooks file", "agents idle --hook codex" in codex and json.loads(codex)["hooks"].keys() == {"Stop", "SessionEnd"}, codex)
    subprocess.run([BROADWAY, "setup", "claude", "codex", "--json"], capture_output=True, text=True, env=env)
    check("twice gives the same file", settings.read_text() == added and (home / ".codex/hooks.json").read_text() == codex)
    removed = subprocess.run([BROADWAY, "remove", "claude", "codex", "--json"], capture_output=True, text=True, env=env)
    check("remove runs", removed.returncode == 0, removed.stdout + removed.stderr)
    check("remove gives the original bytes back", settings.read_text() == FOREIGN, settings.read_text())
    check("and takes away the codex file it made", not (home / ".codex/hooks.json").exists())


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    scratch = Path(tempfile.mkdtemp(prefix="agent-finish-"))
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}/"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    try:
        setup_files(scratch)
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        check("the app is up", wait_for(lambda: subprocess.run([BROADWAY, "--world", WORLD, "status"], capture_output=True).returncode == 0, 30) is not None)
        bench({"do": "window"})

        link, tabs = claude_session(base)
        question_keeps_asking(link, claude_env(), CLAUDE, "Claude Code")
        data("read", env=claude_env())
        hook("claude", "Stop", CLAUDE, background_tasks=[{"id": "b1", "type": "shell"}])
        time.sleep(0.4)
        check("a Stop with background work still running is not finished", not card(link)["status"].startswith("Finished"), card(link))
        hook("claude", "Stop", CLAUDE, background_tasks=[], session_crons=[])
        check("the next Stop reads finished again", wait_for(lambda: card(link)["status"].startswith("Finished"), 5), card(link))

        codex = codex_session(base)
        question_keeps_asking(codex, codex_env(), None, "Codex")
        time.sleep(3.5)
        agent("linksweep", after=130)
        row = state()["row"]
        check("the header counts a finished agent as done and a quiet one as idle",
              "done" in row["line"] and "idle" in row["line"] and "working" not in row["line"] and not row["attention"], row)
        film("04-header")
        check("the quiet card reads idle", card(codex)["status"].startswith("Idle"), card(codex))
        film("05-idle")
        if state()["folded"]:
            agent("fold")
        time.sleep(0.8)
        open_area = state()
        lines = {row["name"]: row["status"] for row in open_area["area"]}
        check("unfolded, each card says its own state",
              lines.get("Claude Code", "").startswith("Finished") and lines.get("Codex", "").startswith("Idle") and not open_area["folded"], lines)
        film("05-unfolded")
        agent("fold")
        listed = data("agents", "list", env=codex_env())
        check("a command from the quiet agent wakes it", card(codex)["status"] == "Thinking" and listed.get("ok"), card(codex))

        helper_session(base, scratch)
        no_wake()

        result, _ = hook("claude", "SessionEnd", CLAUDE, reason="prompt_input_exit")
        ended = wait_for(lambda: (lambda r: r if r and r["state"] == "done" else None)(link_row(link)), 5)
        check("SessionEnd ends the session", ended is not None and result.returncode == 0, link_row(link))
        kept = card(link)
        check("its tabs stay open with the ended face", kept and kept["tabs"] == tabs and kept["face"] == "ended", kept)
        film("06-ended")
        windows = agent("windows").get("windows", [])
        (OUT / "windows.json").write_text(json.dumps(windows, indent=2))
        (OUT / "shots.json").write_text(json.dumps(shots, indent=2))
    finally:
        subprocess.run([BROADWAY, "--world", WORLD, "quit", "--force"], capture_output=True)
        for _ in range(40):
            if not held():
                break
            time.sleep(0.25)
        for pid in held():
            os.kill(int(pid), signal.SIGKILL)
        server.shutdown()
        shutil.rmtree(FOLDER, ignore_errors=True)
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.rmtree(FRAMES, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print(f"{passed[0]} passed, {len(failures)} failed")
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
