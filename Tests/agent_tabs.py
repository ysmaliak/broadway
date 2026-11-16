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
APP = ROOT / "build/Broadway.app"
BROADWAY = str(APP / "Contents/Helpers/broadway")
BENCH = str(ROOT / "bench")
sv.use(f"tabs-{os.getpid()}")
WORLD = sv.W
FOLDER = Path(sv.SUPPORT)
SUITE = sv.SUITE

SHOP = """<!doctype html><title>Lumen Tea Co.</title>
<h1>Lumen Tea Co.</h1>
<a href="/gift" target="_blank">Gift cards</a>
<button onclick="window.open('/help')">Help</button>
<p id="said">Basket: 0 items</p>"""

PAGES = {
    "/shop": SHOP,
    "/gift": "<!doctype html><title>Gift cards</title><h1>Gift cards</h1>",
    "/help": "<!doctype html><title>Help</title><h1>Help</h1>",
    "/basket": "<!doctype html><title>Basket</title><h1>Basket</h1>",
    "/mine": "<!doctype html><title>Their page</title><h1>Their page</h1>",
}

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail, flush=True)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        data = PAGES.get(self.path.split("?")[0].split("#")[0], "<!doctype html><title>Nothing</title>").encode()
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.send_header("cache-control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def session_env(session):
    env = dict(os.environ)
    env.pop("BROADWAY_AGENT", None)
    env.pop("BROADWAY_AGENT_NAME", None)
    env["CLAUDE_CODE_SESSION_ID"] = session
    return env


def broadway(*words, timeout=60, agent=None, env=None):
    env = dict(env or os.environ)
    if agent:
        env["BROADWAY_AGENT"] = agent
    words = [str(w) for w in words]
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout, env=env)


def envelope(*words, timeout=60, agent=None):
    try:
        result = broadway(*words, "--json", timeout=timeout, agent=agent)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": {"code": "probe_timeout", "message": " ".join(words)}}
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


def every_tab():
    return data(envelope("tabs", "--all")).get("tabs", [])


def mine():
    return data(envelope("tabs")).get("tabs", [])


def ref(tab, name):
    elements = data(envelope("snapshot", "--tab", tab)).get("elements", [])
    found = next((e for e in elements if name in e.get("name", "")), None)
    return "@" + found["ref"] if found else None


def mcp(lines, agent=None, env=None):
    env = dict(env or os.environ)
    if agent:
        env["BROADWAY_AGENT"] = agent
    process = subprocess.Popen([BROADWAY, "--world", WORLD, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, env=env)
    answers = {}
    try:
        for line in lines:
            process.stdin.write(json.dumps(line) + "\n")
            process.stdin.flush()
            until = time.time() + 40
            while line.get("id") not in answers and time.time() < until:
                said = process.stdout.readline()
                if not said:
                    return answers
                try:
                    found = json.loads(said)
                except ValueError:
                    continue
                if "id" in found:
                    answers[found["id"]] = found
    finally:
        process.stdin.close()
        process.terminate()
    return answers


def start():
    subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
    env = ["--env", f"SEARCH_PROBE={WORLD}", "--env", "SEARCH_MEASURE=1"]
    subprocess.run(["open", "-n", "-g", "-j", *env, str(APP)], check=True)
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


def drive(base):
    person = broadway("tabs", "new", base + "mine", "--front")
    rows = wait_for(lambda: [t for t in every_tab() if not t.get("agent") and "/mine" in t.get("url", "")], 15) or []
    theirs = rows[0]["id"] if rows else ""
    check("the person has a tab of their own", bool(theirs), (person.stderr, every_tab()))

    no_tab = envelope("press", "Tab")
    check("an action without a tab of one's own fails no_tab", code(no_tab) == "no_tab", no_tab)

    first = broadway("open", base + "shop")
    first_id = first.stdout.strip()
    check("off a terminal, open prints the bare tab id", len(first_id) == 8 and "\n" not in first_id, first.stdout)
    second = envelope("open", base + "shop#top")
    third = envelope("open", base + "basket")
    second_id, third_id = data(second).get("id"), data(third).get("id")
    listed = mine()
    check("three open calls make three tabs of the session", [t["id"] for t in listed] == [first_id, second_id, third_id], listed)
    check("open says how many tabs the session holds", data(second).get("tabs") == 2 and data(third).get("tabs") == 3, (second, third))
    check("open names a tab of the session on the same address", data(second).get("same") == [first_id] and "same" not in data(third), second)
    check("open answers with the loaded page", (data(third).get("page") or {}).get("title") == "Basket", third)
    check("the newest tab is current", data(envelope("tab")).get("id") == third_id)

    switched = envelope("tab", first_id)
    check("tab ID makes one of the session's tabs current", switched.get("ok") and data(envelope("tab")).get("id") == first_id, switched)
    refused = envelope("tab", theirs)
    check("tab refuses the person's tab with not_yours", code(refused) == "not_yours", refused)
    session_list = envelope("tabs")
    rows = data(session_list).get("tabs", [])
    check("tabs lists the session's own first with the current one marked",
          [r["id"] for r in rows] == [first_id, second_id, third_id] and [r.get("working") for r in rows] == [True, False, False], session_list)
    check("tabs counts the person's tabs", data(session_list).get("others", 0) >= 1, session_list)
    plain = broadway("tabs")
    check("tabs names the current tab and the way to the person's tabs", f"Your current tab is {first_id}" in plain.stderr and "broadway tabs --all" in plain.stderr, plain.stderr)

    went = envelope("go", base + "help")
    check("go sends the current tab and answers after the load",
          went.get("ok") and data(went).get("tab") == first_id and (data(went).get("page") or {}).get("title") == "Help", went)
    check("go opened no tab", len(mine()) == 3)
    old_go = envelope("go", base + "basket", "--tab", second_id)
    check("go --tab ID still sends that tab", old_go.get("ok") and data(old_go).get("tab") == second_id, old_go)
    check("a tab named with --tab becomes current", data(envelope("tab")).get("id") == second_id)
    person_go = envelope("go", base + "basket", "--tab", theirs)
    check("go never takes the person's tab elsewhere", not person_go.get("ok"), person_go)

    shop = data(envelope("go", base + "shop")).get("tab")
    gift = ref(shop, "Gift cards")
    help_button = ref(shop, "Help")
    clicked = envelope("click", gift or "@e0")
    wait_for(lambda: len(mine()) == 4, 10)
    scripted = envelope("click", help_button or "@e0")
    wait_for(lambda: len(mine()) == 5, 10)
    later = envelope("console")
    reported = []
    for said in (clicked, scripted, later):
        tabs = data(said).get("tabs")
        if isinstance(tabs, dict):
            reported += [t.get("id") for t in tabs.get("opened", [])]
    every = every_tab()
    popups = [t for t in every if "/gift" in t.get("url", "") or "/help" in t.get("url", "")]
    session_ids = {t["id"] for t in mine()}
    check("a target=_blank link opens a tab of the session", any("/gift" in t.get("url", "") and t.get("agent") and t["id"] in session_ids for t in every), every)
    check("a window.open opens a tab of the session",
          len([t for t in every if "/help" in t.get("url", "") and t.get("agent") and t["id"] in session_ids]) >= 1, every)
    check("no popup became the person's tab", not [t for t in popups if not t.get("agent")], popups)
    check("the answers name the new tabs", len(set(reported)) == 2, (clicked, scripted, later))
    check("a popup does not take the current tab", data(envelope("tab")).get("id") == shop)

    others = envelope("close", "--others")
    check("close --others keeps only the current tab", others.get("ok") and [t["id"] for t in mine()] == [shop], (others, mine()))
    check("close --others left the person's tab", any(t["id"] == theirs for t in every_tab()))
    extra = data(envelope("open", base + "gift")).get("id")
    closed = envelope("close", "--tab", extra)
    check("close --tab ID still closes that tab", closed.get("ok") and extra not in [t["id"] for t in mine()], closed)
    everything = envelope("close", "--all")
    check("close --all closes every tab of the session", everything.get("ok") and mine() == [], (everything, mine()))
    check("after close --all there is no current tab", code(envelope("tab")) == "no_tab")

    kept_id = data(envelope("open", base + "shop")).get("id")
    sv.cmd({"do": "agents", "action": "look", "tab": kept_id})
    time.sleep(0.5)
    sv.cmd({"do": "agents", "action": "look"})
    unseen_id = data(envelope("open", base + "basket")).get("id")
    done = envelope("agents", "done", "--close", "--summary", "Looked at the tea shop", "--tab", unseen_id)
    left = [t["id"] for t in data(done).get("tabs", [])]
    check("agents done takes --tab without failing", done.get("ok"), done)
    check("agents done --close closes the tab the person never looked at", data(done).get("closed") == [unseen_id], done)
    check("agents done keeps and lists the tab the person looked at", left == [kept_id], done)
    check("agents done gives the count in its first line", (data(done).get("message") or "").startswith("Ended. 1 tab of yours left open"), done)
    extra_id = data(envelope("open", base + "help", agent=f"{WORLD}-other")).get("id")
    back = data(envelope("tabs"))
    check("after done the same agent's next command takes back its open tab as current", [t["id"] for t in back.get("tabs", [])] == [kept_id]
          and back.get("current") == kept_id, back)
    went = envelope("go", base + "gift")
    check("after done go works in the tab taken back", went.get("ok") and data(envelope("tab")).get("id") == kept_id, went)
    spare = data(envelope("open", base + "basket")).get("id")
    envelope("tab", spare)
    others = envelope("close", "--others")
    check("after done close --others closes the other tabs of the agent", others.get("ok") and [t["id"] for t in mine()] == [spare], (others, mine()))
    check("close --others leaves another agent's tab alone", extra_id in [t["id"] for t in every_tab()], every_tab())

    other = f"{WORLD}-mcp"
    answers = mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "probe"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "open", "arguments": {"url": base + "shop"}}},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "snapshot", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "tab", "arguments": {}}},
    ], agent=other)
    snapshot = (answers.get(3) or {}).get("result") or {}
    texts = " ".join(c.get("text", "") for c in snapshot.get("content", []))
    check("over MCP a snapshot without tab works after open", snapshot and not snapshot.get("isError") and "Lumen Tea Co." in texts, answers.get(3))
    check("over MCP tab names the current tab", not ((answers.get(4) or {}).get("result") or {}).get("isError", True), answers.get(4))

    several = envelope("open", base + "gift", base + "help", agent=f"{WORLD}-many")
    opened = [row.get("id") for row in data(several).get("opened") or []]
    listed = [row["id"] for row in data(envelope("tabs", agent=f"{WORLD}-many")).get("tabs") or []]
    check("open with two addresses makes two tabs and opens neither twice", several.get("ok") and len(opened) == 2 and sorted(listed) == sorted(opened), (several, listed))

    shared = session_env(f"probe-{os.getpid()}")
    own = broadway("open", base + "gift", env=shared).stdout.strip()
    joined = mcp([
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "probe"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "tab", "arguments": {}}},
    ], env=shared)
    seen = json.dumps((joined.get(2) or {}).get("result") or {})
    check("the shell and the MCP of one agent share a session", len(own) == 8 and own in seen, (own, joined.get(2)))
    time.sleep(1)
    after = broadway("tab", "--json", env=shared)
    check("closing the MCP keeps the shell's session and its current tab", after.returncode == 0 and own in after.stdout, after.stdout + after.stderr)

    rooms = [w for w in sv.cmd({"do": "agents", "action": "windows"}).get("windows", []) if w.get("room")]
    check("the agent page room is never ordered in", not any(w["visible"] for w in rooms), rooms)
    return {first_id, second_id, third_id}


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    os.environ["BROADWAY_AGENT"] = WORLD
    os.environ["BROADWAY_AGENT_NAME"] = "Tabs Probe"
    for name in ("BROADWAY_TAB", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"):
        os.environ.pop(name, None)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sv.wipe()
    try:
        check("the app is up", start())
        drive(base)
        before = every_tab()
        stop()
        check("the app is up again", start())
        after = wait_for(lambda: every_tab(), 15) or []
        stray = [t for t in after if not t.get("agent") and any(p in t.get("url", "") for p in ("/gift", "/help"))]
        check("after quit and relaunch no agent popup is among the person's tabs", not stray, (before, after))
    finally:
        stop()
        sv.wipe()
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
