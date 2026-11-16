#!/usr/bin/env python3
import base64
import json
import os
import secrets
import shutil
import stat
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BROADWAY = str(ROOT / "build/Broadway.app/Contents/Helpers/broadway")
WORLD = f"avemcp-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"

PAGE = b"""<!doctype html><title>Form</title><h1>Sign up</h1><form>
<input id="pass" type="password" value="hunter2-secret">
<input id="card" autocomplete="cc-number" value="4242424242424242">
<input id="plain" placeholder="plain" value="">
</form>
<button id="go" type="button" onclick="document.title='clicked'">Go</button>"""

OTHER = b"""<!doctype html><title>Other</title><h1>Elsewhere</h1><p>Nothing to fill here</p>"""

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = OTHER if self.path.startswith("/other") else PAGE
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*words):
    return subprocess.run([str(ROOT / "bench"), "--world", WORLD, *words], capture_output=True, text=True, timeout=30).stdout


def broadway(*words):
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True, timeout=30)


def start(agents):
    subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", agents], check=True)
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(ROOT / "build/Broadway.app")], check=True)
    for _ in range(40):
        time.sleep(0.5)
        if subprocess.run([str(ROOT / "bench"), "--world", WORLD, "tabs"], capture_output=True).returncode == 0:
            return
    sys.exit("the world did not answer")


def stop():
    subprocess.run([str(ROOT / "bench"), "--world", WORLD, "quit"], capture_output=True)
    for _ in range(20):
        if subprocess.run(["pgrep", "-f", f"{ROOT}/build/Broadway.app"], capture_output=True).returncode != 0:
            break
        time.sleep(0.25)


class Client:
    def __init__(self):
        self.process = subprocess.Popen([BROADWAY, "--world", WORLD, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.number = 0
        self.listing_changed = False

    def rpc(self, method, params=None):
        self.number += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.number, "method": method, "params": params or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            message = json.loads(self.process.stdout.readline())
            if "id" in message:
                return message
            if message.get("method") == "notifications/tools/list_changed":
                self.listing_changed = True

    def call(self, name, **arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})["result"]
        return result, "".join(part.get("text", "") for part in result["content"])

    def data(self, name, **arguments):
        return meta(self.call(name, **arguments)[0])

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=5)


def meta(result, key="data"):
    return result.get("_meta", {}).get("com.broadway/" + key, {})


def on(base):
    mode = os.stat(FOLDER / "broadway.sock").st_mode
    check("socket is user only", stat.S_IMODE(mode) == 0o600 and stat.S_ISSOCK(mode), oct(mode))
    check("status", "Agents: on" in broadway("status").stdout)
    check("a command mistake exits 2", broadway("--cli", "nope", "x").returncode == 2)
    check("open", broadway(base).returncode == 0)
    time.sleep(1)

    client = Client()
    found = client.rpc("initialize", {"protocolVersion": "2025-06-18"})["result"]
    check("initialize", found["serverInfo"]["name"] == "broadway-browser")
    check("the version is the app's", found["serverInfo"]["version"] not in ("", "1.0.0"), found["serverInfo"])
    check("the instructions teach tabs as a choice", "go moves the tab you are in" in found["instructions"] and "one working tab" not in found["instructions"], found["instructions"])
    listing = client.rpc("tools/list")["result"]
    listed = listing["tools"]
    names = {tool["name"] for tool in listed}
    size = len(json.dumps(listing, separators=(",", ":")))
    check("the short tools/list is under 6 KB", size < 6144, (size, {tool["name"]: len(json.dumps(tool, separators=(",", ":"))) for tool in listed}))
    check("no task-only tool for an outside client", not names & {"ask", "sign_in", "autofill", "helper_start", "helper_wait", "mac_read", "mac_run"}, names)
    check("tools speak the command's words", {"go", "read", "shot", "find", "fill", "batch", "handoff", "more_tools"} <= names, names)
    check("run is listed", "run" in names, names)
    check("the short list leaves the rest behind more_tools", not names & {"drag", "select", "upload", "download", "hover", "choose", "resize", "console", "history"}, names)
    more = client.call("more_tools", query="drag select")
    check("more_tools adds what fits", {"drag", "select"} <= set(meta(more[0]).get("added", [])), more)
    check("and says the list changed", client.listing_changed, "no notifications/tools/list_changed")
    names = {tool["name"] for tool in client.rpc("tools/list")["result"]["tools"]}
    check("the added tools are listed", {"drag", "select"} <= names, names)
    stray = client.call("click", element="e1")
    check("an unknown argument is refused with the ones it takes", stray[0]["isError"] and "It takes" in stray[1] and meta(stray[0], "error").get("code") == "usage", stray)
    check("old names are not listed", not names & {"navigate", "text", "screenshot", "locate", "fill_form"}, names)
    check("tab is never required", all("tab" not in tool["inputSchema"].get("required", []) for tool in listed))

    tabs = client.data("tabs", all=True)["tabs"]
    front = next(tab for tab in tabs if tab["front"])
    check("the front tab can't be sent elsewhere", client.call("navigate", tab=front["id"], url=base)[0]["isError"])
    check("the front tab can't be closed", client.call("close", tab=front["id"])[0]["isError"])

    opened = client.call("open", url=base)
    tab = meta(opened[0])
    tab["id"] = tab.get("id") or tab.get("tab")
    check("an agent tab stays behind", tab.get("agent", True) and not tab.get("front", False), tab)
    client.call("wait", tab=tab["id"], selector="#go")
    bare = client.call("snapshot")
    check("snapshot without tab works after open", not bare[0]["isError"] and "Sign up" in bare[1], bare[1])
    check("an action without tab works after open", not client.call("press", key="Tab")[0]["isError"])
    shell = json.loads(broadway("read", "--tab", tab["id"], "--json").stdout)
    mcp = client.data("read", tab=tab["id"])
    check("_meta carries the command's data", shell.get("data") == mcp, (shell.get("data"), mcp))
    check("no structuredContent, so the model reads the fenced text", "structuredContent" not in opened[0])
    stale = client.call("click", tab=tab["id"], ref="e999999")[0]
    error = meta(stale, "error")
    check("an error carries its code", stale["isError"] and error.get("code") in ("stale_ref", "not_found"), stale)
    check("an error carries its hint and retry answer", error.get("hint") and error.get("retry_safe") is True, stale)
    for alias, arguments in (("text", {}), ("screenshot", {}), ("locate", {"text": "Go"}), ("navigate", {"url": base})):
        check(f"the old name {alias} still answers", not client.call(alias, tab=tab["id"], **arguments)[0]["isError"], alias)
    client.call("wait", tab=tab["id"], selector="#go")
    check("wait", not client.call("wait", tab=tab["id"], selector="#go")[0]["isError"])
    check("wait can't read a field", client.call("wait", tab=tab["id"], selector='input[value^="h"]', seconds=1)[0]["isError"])

    check("nor through an escape", client.call("wait", tab=tab["id"], selector="input[v\\61lue^=h]", seconds=1)[0]["isError"])

    snapshot = client.call("snapshot", tab=tab["id"])[1]
    check("values stay on the page", "hunter2" not in snapshot and "4242" not in snapshot, snapshot)
    check("page text is fenced and broadway's facts are not", snapshot.startswith("Tab ") and snapshot.splitlines()[1].startswith("Website content"), snapshot[:200])
    hidden = [line.split()[0] for line in snapshot.splitlines() if "value hidden" in line]
    check("secret boxes are hidden", len(hidden) == 2, snapshot)
    for ref in hidden:
        check("secret boxes refuse typing", client.call("type", tab=tab["id"], ref=ref, text="x")[0]["isError"])
    plain = next(line.split()[0] for line in snapshot.splitlines() if '"plain"' in line)
    check("type", "hello" in client.call("type", tab=tab["id"], ref=plain, text="hello")[1])
    text = client.call("text", tab=tab["id"])[1]
    check("text leaves secrets out", "hunter2" not in text and "4242" not in text)
    check("read leaves secrets out", "hunter2" not in client.call("read", tab=tab["id"])[1])
    picture = client.call("screenshot", tab=tab["id"])[0]
    check("screenshot", any(len(base64.b64decode(part.get("data", ""))) > 1000 for part in picture["content"]))
    client.call("navigate", tab=tab["id"], url=base + "other")
    client.call("wait", tab=tab["id"], text="Elsewhere")
    old = client.call("click", tab=tab["id"], ref=plain)
    check("an old ref is refused", old[0]["isError"] and meta(old[0], "error").get("code") in ("stale_ref", "not_found"), old)
    elsewhere = client.call("snapshot", tab=tab["id"])[1]
    check("and never used again", plain + " " not in elsewhere, elsewhere)
    client.call("navigate", tab=tab["id"], url=base)
    client.call("wait", tab=tab["id"], selector="#go")
    latest = client.call("snapshot", tab=tab["id"])[1]
    button = next(line.split()[0] for line in latest.splitlines() if " button " in line)
    check("click", not client.call("click", tab=tab["id"], ref=button)[0]["isError"])
    for _ in range(20):
        listed = client.call("tabs")[1]
        if "clicked" in listed:
            break
        time.sleep(0.2)
    check("the click landed", "clicked" in listed, listed)
    check("press", not client.call("press", tab=tab["id"], key="Tab")[0]["isError"])
    check("scroll", not client.call("scroll", tab=tab["id"], by=20)[0]["isError"])
    batched = client.call("batch", tab=tab["id"], steps=[{"tool": "press", "arguments": {"key": "Tab"}}, {"tool": "scroll", "arguments": {"by": 20}}])
    check("batch runs its steps over MCP", not batched[0]["isError"] and meta(batched[0]).get("landed") == [1, 2] and "Ran 2 of 2 steps" in batched[1], batched)
    ran = client.call("run", code='scroll({by: 10}); print("rolled " + (read().text ? "and read" : "and empty"))', tab=tab["id"])
    check("run runs a script over MCP", not ran[0]["isError"] and "rolled" in ran[1] and meta(ran[0]).get("landed") == [1, 2], ran)
    empty = client.call("run", code="  ")
    check("run without code is a usage error", empty[0]["isError"] and meta(empty[0], "error").get("code") == "usage", empty)
    lines = client.call("batch", lines=["press Tab"])
    check("batch refuses lines over MCP", lines[0]["isError"] and meta(lines[0], "error").get("code") == "usage", lines)
    check("history", not client.call("history", limit=3)[0]["isError"])
    check("an agent's title stays out of history", "clicked" not in client.call("history", query="127.0.0.1")[1])
    other = client.data("open", url=base + "agentonly")
    other["id"] = other.get("id") or other.get("tab")
    client.call("wait", tab=other["id"], selector="#go")
    check("an agent's visit stays out of history", "agentonly" not in client.call("history", query="agentonly")[1])
    client.call("close", tab=other["id"])
    check("file addresses are refused", client.call("navigate", tab=tab["id"], url="file:///etc/passwd")[0]["isError"])
    check("close", not client.call("close", tab=tab["id"])[0]["isError"])

    private = bench("open", base + "secret", "private").strip()
    time.sleep(1)
    check("a private tab isn't listed", "secret" not in client.call("tabs")[1])
    check("a private tab can't be reached", client.call("snapshot", tab=private[:8])[0]["isError"])
    check("a private tab leaves no history", "secret" not in client.call("history", query="secret")[1])
    bench("close", private)
    client.close()

    bench("ai", "fake", "claude")
    task = broadway("say hello")
    check("a task streams its answer", task.returncode == 0 and "Fake answer: say hello" in task.stdout, task.stderr)


def off(base):
    check("status says off", "Agents: off" in broadway("status").stdout)
    task = broadway("do a thing")
    check("a task is refused", task.returncode == 1 and "Agents are off" in task.stderr, task.stderr)
    client = Client()
    check("no tools", client.rpc("tools/list")["result"]["tools"] == [])
    check("a call is refused", client.call("tabs")[0]["isError"])
    client.close()
    check("open still works", broadway(base).returncode == 0)


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    try:
        start("true")
        on(base)
        stop()
        start("false")
        off(base)
    finally:
        stop()
        shutil.rmtree(FOLDER, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
