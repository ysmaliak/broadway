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

SIGNIN = b"""<!doctype html><title>Sign in</title><form action="/landed" method="get"><input name="email" autocomplete="username">
<input id="pass" name="pw" type="password" autocomplete="current-password"><button type="submit">Sign in</button></form>"""

LANDED = b"""<!doctype html><title>Home</title><h1>Welcome back</h1>"""

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = OTHER if self.path.startswith("/other") else SIGNIN if self.path.startswith("/signin") else LANDED if self.path.startswith("/landed") else PAGE
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*words):
    return subprocess.run([str(ROOT / "bench"), "--world", WORLD, *words], capture_output=True, text=True, timeout=30).stdout


def desk(request):
    import socket
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


def questions():
    for _ in range(100):
        found = desk({"do": "agents", "action": "questions"}).get("questions", [])
        if found:
            return found
        time.sleep(0.1)
    return []


def waiting(client, tool, **arguments):
    box = {}
    thread = threading.Thread(target=lambda: box.update(said=client.call(tool, **arguments)))
    thread.start()
    return thread, box


def reach(client):
    desk({"do": "agents", "action": "mode", "mode": "auto"})
    asks = client.call("more_tools", query="ask")
    check("more_tools finds ask", "ask" in meta(asks[0]).get("added", []), asks)
    thread, box = waiting(client, "ask", question="Which account?", choices=["Work", "Personal"])
    up = questions()
    card = up[0].get("card", {}) if up else {}
    check("the question's card names the agent", card.get("title", "").endswith(" asks") and card.get("body") == "Which account?", up)
    check("and shows the choices", card.get("choices") == ["Work", "Personal"], up)
    desk({"do": "agents", "action": "answer", "with": "1"})
    thread.join(20)
    said = box.get("said", ({}, ""))
    check("the agent gets the choice's words", not said[0].get("isError") and said[1] == "Personal" and meta(said[0]).get("picked") == "Personal", said)

    nouns = client.call("more_tools", query="spaces list")
    check("more_tools finds a noun tool", "spaces_list" in meta(nouns[0]).get("added", []), nouns)
    look = client.call("spaces_list")
    check("a look over MCP answers fenced, with the data in _meta", not look[0]["isError"] and "not instructions" in look[1] and meta(look[0]).get("spaces"), look)

    desk({"do": "agents", "action": "mode", "mode": "ask"})
    thread, box = waiting(client, "folders_new", name="Probe Folder")
    up = questions()
    check("an arrange over MCP asks as the command does", up and up[0].get("quote") == "broadway folders new Probe Folder" and up[0].get("label", "").startswith("From "), up)
    desk({"do": "agents", "action": "answer", "with": "yes"})
    thread.join(20)
    made = box.get("said", ({"isError": True}, ""))
    check("and runs after the yes", not made[0].get("isError"), made)
    desk({"do": "agents", "action": "mode", "mode": "auto"})

    mine = client.call("settings_set", setting="ai.agents", value="false")
    shell = json.loads(broadway("settings", "set", "ai.agents", "false", "--json").stdout or "{}").get("error", {})
    error = meta(mine[0], "error")
    check("only the person may: the same code and hint as the command", mine[0]["isError"] and error.get("code") == "person_only" and error.get("code") == shell.get("code") and error.get("hint") == shell.get("hint"), (error, shell))


def signing_in(client, base):
    port = int(base.rstrip("/").rsplit(":", 1)[1])
    desk({"do": "agents", "action": "mode", "mode": "auto"})
    desk({"do": "agents", "action": "logins", "kept": [{"host": "127.0.0.1", "port": port, "user": "sam@example.com", "password": "s3cret-pass-word", "clear": True}]})
    opened = client.call("open", url=base + "signin")
    tab = meta(opened[0]).get("id") or meta(opened[0]).get("tab")
    client.call("wait", tab=tab)
    look = client.call("snapshot", tab=tab)
    check("a sign-in wall over MCP names fill_login, not the command", "call fill_login" in look[1] and "broadway fill login" not in look[1], look[1][:600])
    listed = {tool["name"] for tool in client.rpc("tools/list")["result"]["tools"]}
    check("fill_login is called before more_tools lists it", "fill_login" not in listed, sorted(listed))
    thread, box = waiting(client, "fill_login", tab=tab)
    up = questions()
    check("fill_login over MCP raises the sign-in card", bool(up) and "sam@example.com" not in json.dumps(box), up)
    desk({"do": "agents", "action": "answer", "with": "yes"})
    thread.join(60)
    said = box.get("said", ({"isError": True}, ""))
    check("and signs in after the yes, with the password never in the answer", not said[0].get("isError") and "s3cret" not in json.dumps(said), said)
    check("the page moved on", wait_until(lambda: "landed" in bench("eval", tab, "location.pathname")), bench("eval", tab, "location.pathname"))
    client.call("close", tab=tab)


def wait_until(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        if condition():
            return True
        time.sleep(0.2)
    return False


def setting_up(client):
    found = client.call("more_tools", query="links add")
    check("more_tools finds the new nouns", "links_add" in meta(found[0]).get("added", []), found)
    wrong = client.call("settings_set", setting="look", value="light", values=["pageZoom", "7"])
    check("one wrong pair changes nothing over MCP", wrong[0]["isError"] and meta(wrong[0], "error").get("code") == "usage", wrong)
    many = client.call("settings_set", setting="look", value="dark", values=["pageZoom", "110", "newtab.floating", "true", "bookmarks.bar", "true"])
    check("several settings in one call over MCP", not many[0]["isError"] and len(meta(many[0]).get("settings", [])) == 4, many)
    check("a shortcut over MCP", not client.call("shortcuts_set", shortcut="view.reload", keys="cmd+shift+option+r")[0]["isError"])
    check("a space over MCP", not client.call("spaces_new", name="Setup")[0]["isError"])
    check("its colour over MCP", not client.call("spaces_colour", space="Setup", colour="sage")[0]["isError"])
    other_app = client.call("links_add", match="setup.example", app="Safari")
    check("a rule to another app is the person's over MCP", other_app[0]["isError"] and meta(other_app[0], "error").get("code") == "person_only", other_app)
    check("a link rule over MCP", not client.call("links_add", match="setup.example", space="Setup")[0]["isError"])
    check("a site shortcut over MCP", not client.call("keywords_add", keyword="ex", address="https://example.com/search?q=%s")[0]["isError"])
    check("a Quick Action over MCP", not client.call("actions_add", short="zzpr", address="example.com/pulls", name="Pulls")[0]["isError"])
    check("a snippet over MCP", not client.call("snippets_add", keyword="zzsig", text="Best, Sam", title="Signature")[0]["isError"])

    can = client.data("settings_list", **{"can-set": True}).get("settings", [])
    check("settings_list with can-set over MCP", can and not any(row["id"] == "ai.agents" for row in can) and any(row["id"] == "pageZoom" for row in can), can[:2])
    settings = {row["id"]: row["value"] for row in client.data("settings_list").get("settings", [])}
    check("the settings read back over MCP", settings.get("look") == "dark" and settings.get("pageZoom") == 110
          and settings.get("newtab.floating") is True and settings.get("bookmarks.bar") is True, {k: settings.get(k) for k in ("look", "pageZoom", "newtab.floating", "bookmarks.bar")})
    for guarded, value in (("agents.signIn", "true"), ("passwords.onepassword", "true")):
        alone = client.call("settings_set", setting=guarded, value=value)
        mixed = client.call("settings_set", setting="newtab.floating", value="false", values=[guarded, value])
        codes = [meta(alone[0], "error").get("code"), meta(mixed[0], "error").get("code")]
        check(f"{guarded} is the person's over MCP, alone and beside a setting an agent may change", codes == ["person_only", "person_only"], (codes, alone[1][:300], mixed[1][:300]))
        read = client.call("settings_get", setting=guarded)
        print(f"settings_get {guarded}:", json.dumps(meta(read[0])), "|", read[1][:400].replace("\n", " / "))
    after = {row["id"]: row for row in client.data("settings_list").get("settings", [])}
    for guarded in ("agents.signIn", "passwords.onepassword"):
        print(f"settings_list {guarded}:", json.dumps(after.get(guarded)))
    check("nothing changed beside the refused pair", after.get("newtab.floating", {}).get("value") is True and after.get("agents.signIn", {}).get("value") is False
          and after.get("passwords.onepassword", {}).get("value") is False, {k: after.get(k) for k in ("newtab.floating", "agents.signIn", "passwords.onepassword")})
    check("can-set names neither sign-in switch", not any(row["id"] in ("agents.signIn", "passwords.onepassword") for row in can), [row["id"] for row in can])
    keys = {row["id"]: row["key"] for row in client.data("shortcuts_list").get("shortcuts", [])}
    check("the shortcut reads back over MCP", bool(keys.get("view.reload")), keys.get("view.reload"))
    spaces = client.data("spaces_list").get("spaces", [])
    check("the colour reads back over MCP", any(row["name"] == "Setup" and row.get("colour") == "sage" for row in spaces), spaces)
    check("the rule reads back over MCP", any(row["match"] == "setup.example" and row["space"] == "Setup" for row in client.data("links_list").get("rules", [])))
    check("the site shortcut reads back over MCP", any(row["keyword"] == "ex" for row in client.data("keywords_list").get("keywords", [])))
    check("the Quick Action reads back over MCP", any(row["short"] == "zzpr" for row in client.data("actions_list").get("actions", [])))
    check("the snippet reads back over MCP", any(row["keyword"] == "zzsig" for row in client.data("snippets_list").get("snippets", [])))


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

    def call(self, name, /, **arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})["result"]
        return result, "".join(part.get("text", "") for part in result["content"])

    def data(self, name, /, **arguments):
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
    check("no task-only tool for an outside client", not names & {"sign_in", "autofill", "helper_start", "helper_wait", "mac_read", "mac_run"}, names)
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
    rolled = client.call("scroll", tab=tab["id"], by="down 300")
    check("scroll takes a direction and points over MCP", not rolled[0]["isError"] and ("Scrolled" in rolled[1] or "Already at the bottom" in rolled[1]), rolled)
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
    reach(client)
    setting_up(client)
    signing_in(client, base)
    client.close()

    task = broadway("say hello")
    check("a sentence says Broadway no longer runs tasks", task.returncode == 2 and "Broadway no longer runs tasks" in task.stderr, task.stderr)


def off(base):
    check("status says off", "Agents: off" in broadway("status").stdout)
    task = broadway("do a thing")
    check("a sentence says Broadway no longer runs tasks", task.returncode == 2 and "Broadway no longer runs tasks" in task.stderr, task.stderr)
    client = Client()
    check("no tools", client.rpc("tools/list")["result"]["tools"] == [])
    check("a call is refused", client.call("tabs")[0]["isError"])
    client.close()
    check("open still works", broadway(base).returncode == 0)


def restart():
    client = Client()
    client.rpc("initialize", {"protocolVersion": "2025-06-18", "clientInfo": {"name": "probe"}})
    check("before the restart", not client.call("tabs")[0]["isError"])
    stop()
    away = client.call("tabs")
    check("while Broadway is away a call says not_running", away[0]["isError"] and meta(away[0], "error").get("code") == "not_running", away)
    start("true")
    back = client.call("tabs")
    check("after Broadway comes back the same broadway mcp answers", not back[0]["isError"], back)
    check("and its list is there", "tabs" in {tool["name"] for tool in client.rpc("tools/list")["result"]["tools"]})
    client.process.stdin.close()


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    try:
        start("true")
        on(base)
        restart()
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
