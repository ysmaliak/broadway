#!/usr/bin/env python3
"""An agent's tabs close when its session ends, on a test copy driven by the real broadway.

Build first (`./build.sh`), then `python3 Tests/agent_sessions.py`. A test copy in a world
of its own, with spaces on, driven by invented agents through the real `broadway` command:

1. agents done closes the session's tabs.
2. tabs keep, then agents done, leaves one ordinary tab of the person's.
3. A session left quiet past its limit ends and closes its tab (the bench's clock skips ahead).
4. A tab with a typed form waits, and closes once the form is gone.
5. A returning agent that names a closed tab gets session_ended.
6. A tab in a space that isn't on screen closes too.

No window is pictured. Out: nothing but the lines it prints.
"""
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("BROADWAY_APP", ROOT / "build/Broadway.app"))
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"agentsessions-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"

failures = []
passed = [0]


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:600], flush=True)
    if ok:
        passed[0] += 1
    else:
        failures.append(name)


FORM = ("<!doctype html><title>form</title><body style='font:16px system-ui'><h1>form</h1>"
        "<form id='f'><label>Note <input id='note' name='note'></label><button>Send</button></form>"
        "<script>addEventListener('input', () => setTimeout(() => { location.href = '/plain' }, 6000))</script>")


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        text = FORM if name == "form" else (f"<!doctype html><title>{name}</title><body style='font:16px system-ui'>"
                                            f"<h1>{name}</h1><p>An invented page.</p>")
        body = text.encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def env_for(session, name="Claude Code"):
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith("BROADWAY_") and k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID")}
    environment.update({"CLAUDE_CODE_SESSION_ID": session, "BROADWAY_AGENT_NAME": name})
    return environment


def session():
    return "0a1b2c3d-0000-4000-8000-" + secrets.token_hex(6)


def run(*words, env, timeout=120):
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True, env=env,
                          stdin=subprocess.DEVNULL, timeout=timeout)


def call(*words, env):
    result = run(*words, "--json", env=env)
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"ok": False, "raw": result.stdout + result.stderr}


def data(said):
    return said.get("data") or {}


def code(said):
    return (said.get("error") or {}).get("code")


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


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.25)
    return None


def agent_tabs():
    return {row["id"][:8].lower() for row in agent("state").get("agentTabs", [])}


def every_tab(env):
    return {row["id"]: row for row in data(call("tabs", "--all", env=env)).get("tabs", [])}


def opened(url, env):
    said = call("open", url, env=env)
    check(f"open {url.rsplit('/', 1)[-1]} works", said.get("ok"), said)
    return data(said).get("id") or ""


def done_closes(base):
    env = env_for(session())
    first = opened(base + "one", env)
    second = opened(base + "two", env)
    done = call("agents", "done", "--summary", "Looked at two pages", env=env)
    closed = data(done).get("closed") or []
    check("agents done closes both of its tabs", sorted(closed) == sorted([first, second]) and data(done).get("left") == 0, done)
    check("they are gone from the window", not ({first, second} & agent_tabs()), agent_tabs())
    back = call("read", "--tab", first, env=env)
    check("the same agent naming a closed tab gets session_ended", code(back) == "session_ended", back)
    check("with a hint to open the page again", "open" in ((back.get("error") or {}).get("hint") or ""), back)


def keep_then_done(base):
    env = env_for(session())
    kept = opened(base + "keep", env)
    other = opened(base + "other", env)
    process = subprocess.Popen([BROADWAY, "--world", WORLD, "tabs", "keep", kept, "--json"], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, env=env, stdin=subprocess.DEVNULL)
    asked = wait_for(lambda: agent("questions").get("questions"), 20)
    if asked:
        agent("answer", **{"with": "yes"})
    out, _ = process.communicate(timeout=120)
    try:
        said = json.loads(out)
    except ValueError:
        said = {"raw": out}
    check("tabs keep goes through once the person says yes", said.get("ok") is True, said)
    done = call("agents", "done", env=env)
    check("agents done then closes only the other tab", data(done).get("closed") == [other], done)
    row = every_tab(env_for(session(), "Someone")).get(kept)
    check("the kept tab is an ordinary tab of the person's", row is not None and not row.get("agent"), row)


def quiet_ends(base):
    env = env_for(session())
    tab = opened(base + "quiet", env)
    time.sleep(3.5)
    swept = agent("linksweep", after=20 * 60 + 5)
    check("a session left quiet past its limit ends and closes its tab", tab not in {r["id"][:8].lower() for r in swept.get("agentTabs", [])},
          swept.get("agentTabs"))
    back = call("read", "--tab", tab, env=env)
    check("coming back it hears its session ended", code(back) == "session_ended" and "20 minutes" in (back.get("error") or {}).get("message", ""), back)


def form_waits(base):
    env = env_for(session())
    tab = opened(base + "form", env)
    typed = call("type", "#note", "an invented note", env=env)
    if not typed.get("ok"):
        typed = call("type", "Note", "an invented note", env=env)
    check("the agent types in the form", typed.get("ok"), typed)
    done = call("agents", "done", env=env)
    kept = data(done).get("kept") or []
    check("a tab with a typed form is kept open", [k.get("id") for k in kept] == [tab] and "form" in kept[0].get("why", ""), done)
    check("and done says why", "form there is not sent" in data(done).get("message", ""), done)
    gone = wait_for(lambda: tab not in {r["id"][:8].lower() for r in agent("sweep").get("agentTabs", [])}, 30)
    check("once the form is gone the tab closes", gone, agent("state").get("agentTabs"))


def parked_space(base):
    env = env_for(session())
    opened(base + "here", env)
    made = call("spaces", "new", "Away", env=env)
    check("a second space is there", made.get("ok"), made)
    tab = data(call("open", base + "away", "--space", "Away", env=env)).get("id") or ""
    check("the agent has a tab in the space that isn't on screen", bool(tab) and tab not in agent_tabs(), (tab, agent_tabs()))
    done = call("agents", "done", env=env)
    check("agents done closes the tab in the other space too", tab in (data(done).get("closed") or []), done)
    check("and nothing of it is left anywhere", tab not in every_tab(env_for(session(), "Someone")), done)


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def main():
    if not Path(BROADWAY).exists():
        sys.exit("build first: ./build.sh")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}/"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    try:
        for key, kind, value in [("bench", "-bool", "true"), ("agents.on", "-bool", "true"), ("spaces", "-bool", "true"),
                                 ("agents.mode", "-string", "auto")]:
            subprocess.run(["defaults", "write", SUITE, key, kind, value], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        check("the app is up", wait_for(lambda: subprocess.run([BROADWAY, "--world", WORLD, "status"], capture_output=True).returncode == 0, 30) is not None)
        bench({"do": "window"})
        for part in (done_closes, keep_then_done, form_waits, parked_space, quiet_ends):
            try:
                part(base)
            except Exception as error:
                check(f"{part.__name__} ran to its end", False, repr(error))
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
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print(f"{passed[0]} passed, {len(failures)} failed")
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
