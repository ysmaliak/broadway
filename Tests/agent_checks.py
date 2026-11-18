#!/usr/bin/env python3
import json
import os
import secrets
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Broadway.app"
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"checks-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
SECRET = "plum-otter-" + secrets.token_hex(3)

AUDIT = """<!doctype html><html><head><meta charset="utf-8"></head><body>
<h2>Orders</h2><h4>Filters</h4>
<img src="/none.png" width="40" height="40">
<input placeholder="Search orders" style="height:30px">
<button style="width:16px;height:16px;padding:0"></button>
<p style="color:#c0c0c0;background:#ffffff">Faint footnote</p>
<div role="button" style="width:90px;height:30px">Open menu</div>
<a href="/next" tabindex="2" style="display:inline-block;padding:8px">Next page</a>
<label for="dup">Name</label><input id="dup" style="height:30px"><span id="dup">Twin</span>
</body></html>"""

STYLES = f"""<!doctype html><html lang="en"><title>Styles</title><body><h1>Styles</h1>
<div id="frame" style="overflow:hidden;width:120px;height:50px"><button style="width:300px;height:30px">Wide button</button></div>
<label for="pw">Password</label><input id="pw" type="password" value="{SECRET}">
</body></html>"""

SLOW = """<!doctype html><html lang="en"><title>Slow</title><body><h1>Slow page</h1>
<img src="/slow.png?session=s3cr3tvalue" alt="Slow picture" width="20" height="20"></body></html>"""

LIST = """<!doctype html><html lang="en"><title>Log</title><body><h1>Dispatch log</h1>
<div id="log" role="list" style="height:300px;overflow-y:auto;position:relative"><div id="room" style="position:relative"></div></div>
<script>
var tall = 30, box = document.getElementById('log'), room = document.getElementById('room'), count = 250;
room.style.height = (count * tall) + 'px';
function draw() {
  var first = Math.max(0, Math.floor(box.scrollTop / tall) - 2), last = Math.min(count, Math.ceil((box.scrollTop + box.clientHeight) / tall) + 2);
  room.textContent = '';
  for (var i = first; i < last; i++) {
    var row = document.createElement('div');
    row.setAttribute('role', 'listitem');
    row.style.cssText = 'position:absolute;left:0;right:0;height:30px;top:' + (i * tall) + 'px';
    row.innerHTML = '<span></span> <span></span>';
    row.children[0].textContent = 'DP-' + (i + 1); row.children[1].textContent = (i % 5 === 0 ? 'Upwell' : 'Garrow');
    room.appendChild(row);
  }
}
box.addEventListener('scroll', draw);
draw();
</script></body></html>"""

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:600])
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/slow.png":
            time.sleep(0.8)
            body, kind = b"not really a picture", "image/png"
        else:
            body = {"/audit": AUDIT, "/styles": STYLES, "/slow": SLOW, "/list": LIST}.get(path, "<!doctype html><title>None</title><p>None").encode()
            kind = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("content-type", kind)
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*words):
    return subprocess.run([str(ROOT / "bench"), "--world", WORLD, *words], capture_output=True, text=True, timeout=30).stdout


def broadway(*words, timeout=60):
    environment = {key: value for key, value in os.environ.items() if not key.startswith("BROADWAY_")}
    environment["BROADWAY_AGENT"] = f"checks-{WORLD}"
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True, timeout=timeout, env=environment)


def envelope(*words):
    done = broadway(*words, "--json")
    try:
        return json.loads(done.stdout)
    except ValueError:
        return {"ok": False, "raw": done.stdout + done.stderr}


def start():
    subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
    for _ in range(60):
        time.sleep(0.5)
        if subprocess.run([str(ROOT / "bench"), "--world", WORLD, "tabs"], capture_output=True).returncode == 0:
            return
    sys.exit("the world did not answer")


def stop():
    subprocess.run([str(ROOT / "bench"), "--world", WORLD, "quit"], capture_output=True)
    for _ in range(40):
        if subprocess.run(["pgrep", "-f", f"SEARCH_PROBE={WORLD}"], capture_output=True).returncode != 0:
            break
        time.sleep(0.25)


class Client:
    def __init__(self):
        environment = {key: value for key, value in os.environ.items() if not key.startswith("BROADWAY_")}
        self.process = subprocess.Popen([BROADWAY, "--world", WORLD, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=environment)
        self.number = 0

    def rpc(self, method, params=None):
        self.number += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.number, "method": method, "params": params or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            message = json.loads(self.process.stdout.readline())
            if "id" in message:
                return message

    def call(self, name, **arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments})["result"]
        return result, "".join(part.get("text", "") for part in result["content"]), result.get("_meta", {}).get("com.broadway/data", {})

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)


def command(base):
    opened = broadway("open", base + "audit")
    check("open", opened.returncode == 0, opened.stderr)
    broadway("wait")
    audit = envelope("audit")
    rules = {row.get("rule") for row in audit.get("data", {}).get("findings", [])}
    wanted = {"page-lang", "page-title", "heading-one", "heading-skip", "img-alt", "field-label", "control-name", "contrast", "target-size", "keyboard", "tab-order", "duplicate-id"}
    check("audit finds each broken rule", wanted <= rules, (wanted - rules, audit))
    plain = broadway("audit")
    check("audit says it is a first pass", "These rules are a first pass and not a full audit" in plain.stdout, plain.stdout[:400])
    check("audit gives refs and words", any(line.startswith("- @e") and '"Faint footnote"' in line for line in plain.stdout.splitlines()), plain.stdout)
    check("audit marks its words as website content", "website" in plain.stderr.lower() or "Website content" in plain.stdout, plain.stderr)

    broadway("go", base + "slow")
    broadway("wait")
    timings = envelope("timings").get("data", {})
    slowest = (timings.get("slowest") or [{}])[0]
    check("timings name the slow picture first", "/slow.png" in slowest.get("url", "") and slowest.get("ms", 0) >= 700, timings)
    check("timings scrub addresses as network does", "s3cr3tvalue" not in json.dumps(timings), slowest)
    check("timings give a first byte", isinstance(timings.get("first_byte_ms"), int), timings)
    recorded = timings.get("recorded")
    check("timings say which kinds WebKit records", isinstance(recorded, list) and "resource" in recorded, timings)
    for key, kind in (("layout_shift", "layout-shift"), ("long_tasks", "longtask"), ("largest_paint", "largest-contentful-paint")):
        value = timings.get(key)
        if kind in (recorded or []):
            check(f"{key} is a number or a list where WebKit records {kind}", not isinstance(value, str) or value == "none recorded", value)
        else:
            check(f"{key} says not available where WebKit doesn't record {kind}", value == "not available", value)
    print("     WebKit records:", ", ".join(recorded or []))

    broadway("go", base + "styles")
    broadway("wait")
    styles = envelope("styles", "Wide button").get("data", {})
    cut = (styles.get("hiddenBy") or [{}])[0]
    check("styles name the ancestor that clips", cut.get("element", "").startswith("div#frame") and any("overflow hidden" in why for why in cut.get("why", [])), styles)
    secret = broadway("styles", "Password", "--json")
    check("styles on a password box", secret.returncode == 0 and json.loads(secret.stdout)["data"].get("secret") is True, secret.stdout[:300])
    check("and never its value", SECRET not in secret.stdout + secret.stderr)
    check("help knows styles", broadway("help", "styles").returncode == 0)

    broadway("go", base + "list")
    broadway("wait")
    rows = envelope("read", "--rows", "--max", "1000").get("data", {})
    check("read --rows gathers a list that draws only near rows", rows.get("count") == 250 and rows.get("end") is True, {k: rows.get(k) for k in ("count", "end", "stopped")})
    check("with each row once", len({tuple(row) for row in rows.get("rows", [])}) == 250)
    capped = broadway("read", "--rows", "--max", "30")
    check("--max stops early and says it is not whole", "Not the whole list. It stopped at 30 rows." in capped.stdout, capped.stdout[:300])
    broadway("close", "--all")


def mcp(base):
    client = Client()
    client.rpc("initialize", {"protocolVersion": "2025-06-18", "clientInfo": {"name": "checks-probe"}})
    listing = client.rpc("tools/list")["result"]["tools"]
    names = {tool["name"] for tool in listing}
    check("the checks wait behind more_tools", not names & {"audit", "timings", "styles"}, names)
    size = len(json.dumps({"tools": listing}, separators=(",", ":")))
    check("the short tools/list is under 6 KB", size < 6144, size)
    read = next(tool for tool in listing if tool["name"] == "read")
    check("rows is an option of read", "rows" in read["inputSchema"]["properties"], read)
    added = client.call("more_tools", query="audit timings styles")
    check("more_tools adds the three", {"audit", "timings", "styles"} <= set(added[2].get("added", [])), added[1])
    listing = client.rpc("tools/list")["result"]["tools"]
    for tool in listing:
        if tool["name"] in ("audit", "timings", "styles"):
            check(f"{tool['name']} is marked read only", tool.get("annotations", {}).get("readOnlyHint") is True, tool)
    client.call("open", url=base + "audit")
    client.call("wait")
    audit = client.call("audit")
    check("audit over MCP", not audit[0].get("isError") and "first pass" in audit[1] and audit[2].get("count", 0) >= 10, audit[1][:300])
    client.call("go", url=base + "styles")
    client.call("wait")
    styled = client.call("styles", target="Password")
    check("styles over MCP keep the password out", not styled[0].get("isError") and SECRET not in styled[1] and SECRET not in json.dumps(styled[2]), styled[1][:300])
    timed = client.call("timings")
    check("timings over MCP", not timed[0].get("isError") and "First byte" in timed[1], timed[1][:300])
    client.call("go", url=base + "list")
    client.call("wait")
    rows = client.call("read", rows=True, max=300)
    check("read with rows over MCP", not rows[0].get("isError") and rows[2].get("count") == 250, rows[1][:300])
    client.call("close", all=True)
    client.close()


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    try:
        start()
        command(base)
        mcp(base)
    finally:
        stop()
        shutil.rmtree(FOLDER, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
        server.shutdown()
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
