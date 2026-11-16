#!/usr/bin/env python3
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
APP = ROOT / "build/Broadway.app"
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"agentmode-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
FRAMES = Path(os.environ.get("AGENT_MODE_FRAMES", ROOT / ".context/frames"))

PAGE = b"""<!doctype html><title>%s</title><h1>%s</h1>
<input id="q" placeholder="Search" style="font-size:20px;width:300px">
<button id="go" type="button" onclick="document.title='clicked'">Go</button>
<p>Some words to read.</p>"""

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = PAGE % (name.encode(), name.encode())
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def clean_env(more=None):
    environment = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID")}
    environment.update(more or {})
    return environment


def broadway(*words, env=None, timeout=60):
    environment = clean_env(env)
    for key in ("BROADWAY_AGENT", "BROADWAY_AGENT_NAME", "BROADWAY_TAB"):
        if not env or key not in env:
            environment.pop(key, None)
    return subprocess.run([BROADWAY, "--world", WORLD, *words, "--json"], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, env=environment, timeout=timeout)


def data(*words, env=None):
    result = broadway(*words, env=env)
    try:
        parsed = json.loads(result.stdout)
    except ValueError:
        return None, result
    return parsed, result


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


def state():
    return agent("state")


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.1)
    return None


def card(named):
    return next((row for row in state().get("area", []) if row["name"] == named), None)


FILMING = Path(tempfile.mkdtemp(prefix="agent-mode-frames-"))


def film(name):
    FRAMES.mkdir(parents=True, exist_ok=True)
    try:
        answer = bench({"do": "film", "action": "none", "path": str(FILMING / name), "frames": 1, "region": "full"})
    except OSError as error:
        answer = {"error": str(error)}
    files = []
    for frame in answer.get("frames", []):
        if frame.get("file") and Path(frame["file"]).exists():
            shutil.copy(frame["file"], FRAMES / Path(frame["file"]).name)
            files.append(str(FRAMES / Path(frame["file"]).name))
    return files[0] if files else None


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


one_row = 52


def connect_and_open(base):
    connected, result = data("agents", "connect", "--name", "Probe Agent")
    check("connect", connected and connected["ok"] and connected["data"]["connected"]["name"] == "Probe Agent", result.stdout + result.stderr)
    check("a connected agent shows before it has tabs", wait_for(lambda: card("Probe Agent")) is not None, state().get("area"))
    first, result = data("open", base + "one")
    second, _ = data("open", base + "two")
    check("open two tabs", first and first["ok"] and second and second["ok"], result.stdout + result.stderr)
    one, two = first["data"]["id"], second["data"]["id"]
    found = wait_for(lambda: (lambda c: c if c and len(c["tabs"]) == 2 else None)(card("Probe Agent")))
    check("the session holds both tabs", found is not None, state())
    check("the area is one folded row", state()["folded"] is True and state()["height"] == one_row, state())
    check("one agent has no heading of its own", [size["headed"] for size in state()["sizes"]] == [False], state()["sizes"])
    listed = state()["listed"]
    check("the agent's tabs left the tab list", found and not any(tab in listed for tab in found["tabs"]), listed)
    check("one session for both commands", len([row for row in state()["links"] if row["name"] == "Probe Agent"]) == 1, state()["links"])
    alias, _ = data("agent", "list")
    check("broadway agent is broadway agents", alias and alias["ok"] and any(row["name"] == "Probe Agent" for row in alias["data"]["agents"]), alias)
    return found, one, two


def drive(found, one):
    row = agent("row", link=found["id"][:8], index=0)
    active = next((tab for tab in row["agentTabs"] if tab["active"]), None)
    check("a row shows its tab", active is not None and active["id"] in found["tabs"], row)
    subprocess.run([BROADWAY, "--world", WORLD, "wait", "--tab", one, "--json"], capture_output=True, timeout=30, env=clean_env())
    snap, result = data("snapshot", "--tab", one)
    refs = [item for item in (snap or {}).get("data", {}).get("elements", []) if isinstance(item, dict)]
    box = next((item["ref"] for item in refs if item.get("role") in ("textbox", "searchbox")), None)
    button = next((item["ref"] for item in refs if item.get("role") == "button"), None)
    check("snapshot gives refs", box and button, result.stdout[:400])
    typed, result = data("type", box or "@e0", "hello agent", "--tab", one)
    check("type", typed and typed["ok"], result.stdout + result.stderr)
    pointer = state()["pointer"]
    check("the pointer shows where it types", pointer.get("kind") == "type" and pointer.get("name") == "Probe Agent", pointer)
    status = card("Probe Agent")["status"]
    check("the status line says what it does", status.startswith("Typing") or status.startswith("Reading"), status)
    film("01-working")
    clicked, result = data("click", button or "@e0", "--tab", one)
    check("click", clicked and clicked["ok"], result.stdout + result.stderr)
    check("the pointer moved to the click", state()["pointer"].get("kind") == "click", state()["pointer"])
    two_links = [row for row in state()["links"] if row["name"] == "Probe Agent"]
    check("still one session", len(two_links) == 1, two_links)


def take_over(one):
    taken = agent("takeover")
    check("take over", taken.get("changed") is True, taken)
    check("the session says you are driving", card("Probe Agent")["mood"] == "driving", card("Probe Agent"))
    refused, _ = data("scroll", "--tab", one)
    check("the agent waits while the person drives", refused and not refused["ok"] and refused["error"]["code"] == "driving", refused)
    back = agent("handback")
    check("hand back", back.get("changed") is True, back)
    first, _ = data("scroll", "--tab", one)
    check("after a hand back the agent is told to look again", first and not first["ok"] and "handed it back" in first["error"]["message"], first)
    look, _ = data("snapshot", "--tab", one)
    check("a look clears it", look and look["ok"], look)


def needs_you(one):
    agent("mode", mode="ask")
    environment = clean_env()
    asking = subprocess.Popen([BROADWAY, "--world", WORLD, "scroll", "--tab", one, "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, stdin=subprocess.DEVNULL, env=environment)
    waiting = wait_for(lambda: (lambda c: c if c and c["attention"] else None)(card("Probe Agent")), 15)
    check("the session asks for the person", waiting is not None and waiting["status"].startswith("Needs you"), card("Probe Agent"))
    check("the face waves", waiting and waiting["mood"] == "waving", waiting)
    questions = agent("questions")["questions"]
    check("the question names the agent's tab", questions and questions[0]["title"], questions)
    film("02-needs-you")
    row = state()["row"]
    check("the folded row says who waits and for what", state()["folded"] and row["attention"] and row["title"] == "Probe Agent needs you" and row["line"], row)
    away = agent("row", link=waiting["id"][:8], index=1)
    check("another tab is in front", not any(tab["active"] and tab["id"].lower().startswith(one) for tab in away.get("agentTabs", [])), away)
    pressed = agent("press")
    check("a press on the folded row opens the tab that asks", any(tab["active"] and tab["id"].lower().startswith(one) for tab in pressed.get("agentTabs", [])), pressed)
    check("and leaves the row folded", pressed["folded"] is True, pressed["folded"])
    again = agent("press")
    check("the next press unfolds it", again["folded"] is False and again["height"] > one_row, again)
    check("and one more folds it", agent("press")["folded"] is True, state()["folded"])
    agent("answer", **{"with": "yes"})
    out, err = asking.communicate(timeout=20)
    check("the yes lets the call through", asking.returncode == 0, out + err)
    again, _ = data("scroll", "--tab", one)
    check("the yes holds for the session", again and again["ok"], again)
    agent("mode", mode="auto")


def late_answer(one, elsewhere):
    agent("mode", mode="ask")
    asking = subprocess.Popen([BROADWAY, "--world", WORLD, "open", elsewhere, "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, stdin=subprocess.DEVNULL, env=clean_env())
    check("it asks again on another site", wait_for(lambda: agent("questions")["questions"], 15) is not None)
    asking.kill()
    asking.wait()
    time.sleep(0.5)
    still = agent("questions")["questions"]
    check("the question stays after the caller leaves", len(still) == 1, still)
    meanwhile, _ = data("snapshot", "--tab", one)
    check("the agent hears it still waits", meanwhile and not meanwhile["ok"] and meanwhile["error"]["code"] == "needs_you", meanwhile)
    before = len(card("Probe Agent")["tabs"])
    agent("answer", **{"with": "yes"})
    time.sleep(0.5)
    check("a yes after the caller left does nothing by itself", len(card("Probe Agent")["tabs"]) == before, card("Probe Agent"))
    after, _ = data("open", elsewhere)
    check("the late yes is a grant for the next try", after and after["ok"], after)
    agent("mode", mode="auto")


def second_agent(base):
    second = {"BROADWAY_AGENT": "second", "BROADWAY_AGENT_NAME": "Second Agent"}
    opened, result = data("open", base + "three", env=second)
    check("a second agent opens its own tab", opened and opened["ok"], result.stdout + result.stderr)
    both = wait_for(lambda: len(state()["area"]) == 2 and state())
    check("two agents share the area", both is not None, state()["area"])
    check("a second agent leaves the row folded, one row tall", both and both["folded"] is True and both["height"] == one_row, both)
    check("the folded row counts them", both and both["row"]["title"] == "Agents" and "2 " in both["row"]["line"], both and both["row"])
    film("03-row")
    open = agent("press")
    check("a press unfolds the row", open["folded"] is False and open["height"] > one_row, open)
    check("several agents each get a heading", [size["headed"] for size in open["sizes"]] == [True, True], open["sizes"])
    film("04-two-agents")
    shut = agent("fold")
    check("and folds it again", shut["folded"] is True and shut["height"] == one_row, shut)
    return second


def done(second):
    ended, result = data("agents", "done", "--summary", "Read two pages and typed a search")
    check("done", ended and ended["ok"], result.stdout + result.stderr)
    found = card("Probe Agent")
    check("the session shows the tick and the summary", found and found["mood"] == "done" and found["status"] == "Read two pages and typed a search", found)
    film("05-done")
    closed = agent("closelink", link=found["id"][:8])
    check("closing its tabs takes the session away", not any(row["name"] == "Probe Agent" for row in closed["area"]), closed["area"])
    gone, _ = data("agents", "disconnect", env=second)
    check("disconnect", gone and gone["ok"], gone)
    other = card("Second Agent")
    agent("closelink", link=other["id"][:8])
    empty = state()
    check("the area leaves with the last session", empty["area"] == [] and empty["height"] == 0, empty)


def process_end(base):
    script = f"import subprocess; subprocess.run([{BROADWAY!r}, '--world', {WORLD!r}, 'open', {base + 'four'!r}, '--json'], capture_output=True)"
    subprocess.run([sys.executable, "-c", script], env=clean_env(), timeout=30)
    named = wait_for(lambda: next((row for row in state()["links"] if row["state"] == "connected" and row["name"] == "Python"), None))
    check("a script that opens a tab gets a session of its own", named is not None, state()["links"])
    swept = agent("linksweep")
    ended = next((row for row in swept["links"] if named and row["id"] == named["id"]), None)
    check("its session ends when the script exits", ended and ended["state"] == "done", swept["links"])
    for row in swept["area"]:
        agent("closelink", link=row["id"][:8])


def hosts(folder):
    source = ROOT / "Tests/agent_host.c"
    versions = Path(folder) / "claude/versions"
    versions.mkdir(parents=True)
    built = subprocess.run(["cc", "-O", "-o", str(versions / "2.1.317"), str(source)], capture_output=True, text=True)
    check("the stand-in agent compiles", built.returncode == 0, built.stderr)
    (Path(folder) / "claude/claude").symlink_to(versions / "2.1.317")
    (Path(folder) / "codex").mkdir()
    shutil.copy(versions / "2.1.317", Path(folder) / "codex/codex")
    return str(Path(folder) / "claude/claude"), str(Path(folder) / "codex/codex")


def ancestors(base):
    with tempfile.TemporaryDirectory() as folder:
        claude, codex = hosts(folder)
        environment = {key: value for key, value in clean_env().items() if not key.startswith("BROADWAY_")}
        line = f"{BROADWAY} --world {WORLD}"
        ran = subprocess.run([claude, "/bin/zsh", "-c", f"{line} open {base}seven --json", f"{line} open {base}eight --json",
                              f"{line} agents done --summary 'Claude-style run' --json"],
                             capture_output=True, text=True, env=environment, timeout=60)
        check("a Claude Code-style agent runs broadway", ran.returncode == 0, ran.stdout + ran.stderr)
        rows = [row for row in state()["links"] if row["name"] == "Claude Code"]
        check("a native Claude Code install is named Claude Code, not its version", len(rows) == 1, state()["links"])
        check("its commands are one session that ended with done", rows and rows[0]["state"] == "done" and rows[0]["tabs"] == 2, rows)
        ran = subprocess.run([codex, "/bin/bash", "-lc", f"{line} agents connect --json", f"{line} open {base}nine --json"],
                             capture_output=True, text=True, env=environment, timeout=60)
        check("a Codex-style agent runs broadway", ran.returncode == 0, ran.stdout + ran.stderr)
        rows = [row for row in state()["links"] if row["name"] == "Codex"]
        check("Codex is named Codex", len(rows) == 1 and rows[0]["tabs"] == 1, state()["links"])
        found = card("Codex")
        swept = agent("linksweep")
        ended = next((row for row in swept["links"] if found and found["id"].lower().startswith(row["id"])), None)
        check("Codex's session ends once it has exited", ended and ended["state"] == "done", swept["links"])
        names = {row["name"]: row["accent"] for row in state()["area"]}
        check("Claude Code and Codex wear different colours", names.get("Claude Code") != names.get("Codex"), names)
        for row in state()["area"]:
            agent("closelink", link=row["id"][:8])
        boxed = subprocess.run(["sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", BROADWAY, "--world", WORLD, "status", "--json"],
                               capture_output=True, text=True, env=environment, timeout=30)
        told = json.loads(boxed.stdout or "{}").get("error", {}).get("code")
        check("an agent in a sandbox that blocks the socket is told so", told == "sandboxed", boxed.stdout + boxed.stderr)
        missing = subprocess.run(["sandbox-exec", "-p", "(version 1)(allow default)(deny network*)", BROADWAY, "--world", WORLD + "-absent",
                                  "open", "https://example.com", "--json"], capture_output=True, text=True, env=environment, timeout=30)
        told = json.loads(missing.stdout or "{}").get("error", {}).get("code")
        check("a sandboxed agent never tries to wake Broadway", told == "sandboxed" and "Starting" not in missing.stderr, missing.stdout + missing.stderr)


def mcp(base):
    process = subprocess.Popen([BROADWAY, "--world", WORLD, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=clean_env())

    def send(message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "claude-code", "version": "1"}, "capabilities": {}}})
    check("an MCP client with no tab gets no card", card("Claude Code") is None, state()["area"])
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "open", "arguments": {"url": base + "five"}}})
    found = wait_for(lambda: card("Claude Code"))
    check("an MCP client is named from its hello", found is not None, state()["area"])
    process.stdin.close()
    process.wait(timeout=10)
    ended = wait_for(lambda: (lambda c: c if c and c["mood"] == "done" else None)(card("Claude Code")))
    check("closing the MCP connection ends its session", ended is not None, card("Claude Code"))
    if ended:
        agent("closelink", link=ended["id"][:8])


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        check("the app is up", wait_for(lambda: subprocess.run([BROADWAY, "--world", WORLD, "status"], capture_output=True).returncode == 0, 30) is not None)
        bench({"do": "window"})
        check("no agents, no area", state()["area"] == [] and state()["height"] == 0, state())
        found, one, _ = connect_and_open(base)
        if found:
            drive(found, one)
            take_over(one)
            needs_you(one)
            late_answer(one, base.replace("127.0.0.1", "localhost") + "six")
            second = second_agent(base)
            done(second)
            process_end(base)
            ancestors(base)
            mcp(base)
    finally:
        subprocess.run([BROADWAY, "--world", WORLD, "quit", "--force"], capture_output=True)
        for _ in range(40):
            if not held():
                break
            time.sleep(0.25)
        for pid in held():
            os.kill(int(pid), signal.SIGKILL)
        shutil.rmtree(FOLDER, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
        server.shutdown()
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
