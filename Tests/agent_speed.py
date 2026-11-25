#!/usr/bin/env python3
import json
import os
import signal
import statistics
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("SPEED_APP") or ROOT / "build/Broadway.app")
BROADWAY = str(APP / "Contents/Helpers/broadway")
BENCH = str(ROOT / "bench")
sv.use(f"speed-{os.getpid()}")
WORLD = sv.W
FOLDER = Path(sv.SUPPORT)
SUITE = sv.SUITE
RUNS = int(os.environ.get("SPEED_RUNS", "30"))
ONLY = [word for word in os.environ.get("SPEED_ONLY", "").split(",") if word]
GATE = os.environ.get("SPEED_GATE", "1") != "0"
SLACK = 1.3

QUIET = float(os.environ.get("SPEED_QUIET", "8"))

MINI = {
    "cli status": 5,
    "cli tabs": 5,
    "cli snapshot": 20,
    "cli snapshot since": 16,
    "cli read": 23,
    "cli find": 17,
    "cli click": 533,
    "cli type": 540,
    "cli scroll": 633,
    "cli go": 740,
    "cli shot": 16,
    "cli wait": 606,
    "cli wait idle": 577,
    "cli open": 109,
    "cli click timer": 709,
    "cli click fetch": 655,
    "cli click tick": 5105,
    "cli click quiet": 601,
    "cli batch of 5 clicks": 2908,
    "mcp tabs": 0,
    "mcp snapshot": 12,
    "mcp read": 13,
    "mcp find": 7,
    "mcp click": 574,
    "mcp type": 544,
    "mcp scroll": 576,
    "mcp go": 703,
    "mcp shot": 8,
    "mcp open": 70,
}

STATIC = b"""<!doctype html><title>Static</title><h1>Static page</h1>
<p>A quiet page with nothing in flight.</p>
<button id="still" type="button" onclick="window.pressed = (window.pressed || 0) + 1">Still</button>
<a href="/static?again">Again</a>"""

FORM = b"""<!doctype html><title>Form</title><h1>Form</h1><form onsubmit="return false">
<label>Name <input id="name"></label>
<label>Email <input id="email" type="email"></label>
<label><input id="agree" type="checkbox"> Agree</label>
<button id="send" type="button">Send</button></form>"""

TABLE = (b"<!doctype html><title>Table</title><h1>Table</h1><table><thead><tr><th>Row</th><th>Name</th><th>Amount</th><th>Edit</th></tr></thead><tbody>"
         + b"".join(b"<tr><td>%d</td><td>Row %d name</td><td>%d.00</td><td><button type=\"button\">Edit %d</button></td></tr>" % (n, n, n * 7, n) for n in range(1, 201))
         + b"</tbody></table>")

TIMER = b"""<!doctype html><title>Timer</title><h1>Timer</h1>
<button id="later" type="button" onclick="setTimeout(function () { var p = document.createElement('p'); p.textContent = 'Timer line ' + (++window.lines); document.body.appendChild(p); }, 100)">Later</button>
<script>window.lines = 0;</script>"""

TICK = b"""<!doctype html><title>Tick</title><h1>Tick</h1><p id="clock">0</p>
<button id="poke" type="button" onclick="window.poked = (window.poked || 0) + 1">Poke</button>
<script>var n = 0; setInterval(function () { document.getElementById('clock').textContent = String(++n); }, 100);</script>"""

FETCH = b"""<!doctype html><title>Fetch</title><h1>Fetch</h1>
<button id="load" type="button" onclick="fetch('/data?' + Date.now()).then(function (r) { return r.text(); }).then(function (t) { var p = document.createElement('p'); p.textContent = t + ' ' + (++window.loads); document.body.appendChild(p); })">Load</button>
<script>window.loads = 0;</script>"""

PAGES = {"/static": STATIC, "/form": FORM, "/table": TABLE, "/timer": TIMER, "/tick": TICK, "/fetch": FETCH}

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:1500], flush=True)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/data":
            time.sleep(0.05)
            body = b"Fetched line"
        else:
            body = PAGES.get(path, STATIC)
        self.send_response(200)
        self.send_header("content-type", "text/html" if path != "/data" else "text/plain")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def environment(extra=None, drop=()):
    found = dict(os.environ, **(extra or {}))
    for key in drop:
        found.pop(key, None)
    return found


def broadway(*words, env=None, timeout=60):
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True, stdin=subprocess.DEVNULL, env=env, timeout=timeout)


def envelope(*words, env=None):
    result = broadway(*words, "--json", env=env)
    try:
        return result, json.loads(result.stdout)
    except ValueError:
        return result, {"ok": False, "data": None, "error": {"code": "unparsed", "message": result.stdout + result.stderr}}


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def gone():
    for _ in range(60):
        if not held():
            return True
        time.sleep(0.25)
    return False


def load():
    return os.getloadavg()[0]


def ref_of(tab, name, role="button"):
    _, parsed = envelope("snapshot", "--tab", tab)
    found = [e for e in (parsed.get("data") or {}).get("elements", []) if e["name"] == name and e["role"] == role]
    return "@" + found[0]["ref"] if found else "@e0"


def opened(base, path):
    tab = broadway("open", base + path).stdout.strip()
    broadway("wait", "--tab", tab, "--idle")
    return tab


def summary(times):
    times = sorted(times)
    return statistics.median(times), times[min(len(times) - 1, int(len(times) * 0.95))]


results = {}


def record(name, times, began_load):
    middle, slow = summary(times)
    after = load()
    results[name] = {"median": round(middle), "p95": round(slow), "load": round((began_load + after) / 2, 1)}
    print(f"     {name:<22} median {middle:6.0f} ms   p95 {slow:6.0f} ms   load {began_load:.1f}-{after:.1f}", flush=True)


def stopwatch(name, step, before=None, runs=None):
    times = []
    began_load = load()
    for n in range(runs or RUNS):
        if before:
            before(n)
        began = time.perf_counter()
        step(n)
        times.append((time.perf_counter() - began) * 1000)
    record(name, times, began_load)
    return times


def timeline(name, *words, env=None):
    result = subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True, stdin=subprocess.DEVNULL,
                            env=environment({"BROADWAY_TIMING": "1"}, ()) if env is None else dict(env, BROADWAY_TIMING="1"), timeout=60)
    spawned = time.time() * 1000
    line = next((row for row in result.stderr.splitlines() if row.startswith("broadway timing ")), None)
    if not line:
        print(f"     {name}: no timing line", result.stderr[-300:], flush=True)
        return None
    said = json.loads(line[len("broadway timing "):])
    marks = [("cli " + n, t) for n, t in said.get("cli", [])] + [("app " + n, t) for n, t in said.get("app", [])]
    marks.sort(key=lambda m: m[1])
    first = marks[0][1]
    steps = []
    for (was, at), (now, then) in zip(marks, marks[1:]):
        steps.append(f"{now} +{then - at:.1f}")
    total = marks[-1][1] - first
    print(f"     {name} ({total:.0f} ms, load {load():.1f}): " + ", ".join(steps), flush=True)
    del spawned
    return said


class MCP:
    def __init__(self, env):
        self.process = subprocess.Popen([BROADWAY, "--world", WORLD, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, env=env)
        self.counter = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "speed"}})
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
        self.process.stdin.flush()

    def rpc(self, method, params=None):
        self.counter += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.counter, "method": method, "params": params or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            answer = json.loads(self.process.stdout.readline())
            if answer.get("id") == self.counter:
                return answer.get("result") or answer

    def tool(self, name, **arguments):
        out = self.rpc("tools/call", {"name": name, "arguments": arguments})
        return out, bool(out.get("isError"))

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)


def said(result):
    return result.stdout + result.stderr


def cli_cases(base):
    static = opened(base, "static")
    form = opened(base, "form")
    table = opened(base, "table")
    timer = opened(base, "timer")
    tick = opened(base, "tick")
    fetch = opened(base, "fetch")
    still = ref_of(static, "Still")
    name = ref_of(form, "Name", "textbox")
    later = ref_of(timer, "Later")
    poke = ref_of(tick, "Poke")
    load_ref = ref_of(fetch, "Load")
    cases = {
        "status": (lambda n: broadway("status"),),
        "tabs": (lambda n: broadway("tabs"),),
        "snapshot": (lambda n: broadway("snapshot", "--tab", table),),
        "snapshot since": (lambda n: broadway("snapshot", "--since", "--tab", table),),
        "read": (lambda n: broadway("read", "--tab", table),),
        "find": (lambda n: broadway("find", "Edit 150", "--tab", table),),
        "click": (lambda n: broadway("click", still, "--tab", static),),
        "type": (lambda n: broadway("type", name, f"Ada {n}", "--replace", "--tab", form),),
        "scroll": (lambda n: broadway("scroll", "down" if n % 2 == 0 else "up", "--tab", table),),
        "go": (lambda n: broadway("go", base + f"static?n={n}", "--tab", static),),
        "shot": (lambda n: broadway("shot", "--tab", static, "--out", str(FOLDER / "speed.png")),),
        "wait": (lambda n: broadway("wait", "--tab", static),),
        "wait idle": (lambda n: broadway("wait", "--idle", "--tab", static),),
    }
    for key, (step,) in cases.items():
        if ONLY and key not in ONLY:
            continue
        stopwatch("cli " + key, step)
    if not ONLY or "open" in ONLY:
        made = []
        stopwatch("cli open", lambda n: made.append(broadway("open", base + f"static?open={n}").stdout.strip()))
        for tab in made:
            broadway("close", "--tab", tab)
    if not ONLY or "acts" in ONLY:
        answers = []
        stopwatch("cli click timer", lambda n: answers.append(said(broadway("click", later, "--tab", timer))))
        check("every timer click reports its line", sum("Timer line" in a for a in answers) == len(answers), [a for a in answers if "Timer line" not in a][:2])
        answers = []
        stopwatch("cli click fetch", lambda n: answers.append(said(broadway("click", load_ref, "--tab", fetch))))
        check("every fetch click reports its line", sum("Fetched line" in a for a in answers) == len(answers), [a for a in answers if "Fetched line" not in a][:2])
        stopwatch("cli click tick", lambda n: broadway("click", poke, "--tab", tick), runs=min(RUNS, 5))
        answers = []
        stopwatch("cli click quiet", lambda n: answers.append(said(broadway("click", still, "--tab", static))))
        check("a quiet click says nothing changed", all("Clicked" in a or "nothing" in a.lower() or "no change" in a.lower() for a in answers), answers[:2])
    if not ONLY or "batch" in ONLY:
        steps = "\n".join([f"click {still} --tab {static}"] * 5) + "\n"
        times = []
        began_load = load()
        for _ in range(max(3, RUNS // 5)):
            began = time.perf_counter()
            subprocess.run([BROADWAY, "--world", WORLD, "batch"], input=steps, capture_output=True, text=True, timeout=120)
            times.append((time.perf_counter() - began) * 1000)
        record("cli batch of 5 clicks", times, began_load)
    if not ONLY or "breakdown" in ONLY:
        print("== where the time goes", flush=True)
        timeline("status", "status")
        timeline("tabs", "tabs")
        timeline("snapshot", "snapshot", "--tab", table)
        timeline("read", "read", "--tab", table)
        timeline("find", "find", "Edit 150", "--tab", table)
        for _ in range(int(os.environ.get("SPEED_CLICKS", "1"))):
            timeline("click", "click", still, "--tab", static)
        timeline("click timer", "click", later, "--tab", timer)
        timeline("click fetch", "click", load_ref, "--tab", fetch)
        timeline("type", "type", name, "Bo", "--replace", "--tab", form)
        timeline("scroll", "scroll", "down", "--tab", table)
        timeline("go", "go", base + "static?timed", "--tab", static)
        timeline("shot", "shot", "--tab", static, "--out", str(FOLDER / "speed.png"))
        timeline("open", "open", base + "static?timed")
        walked = environment({"CLAUDE_CODE_SESSION_ID": "speed-walk"}, ("BROADWAY_AGENT", "BROADWAY_AGENT_NAME", "SSH_CONNECTION", "SSH_CLIENT"))
        timeline("snapshot with the ancestor walk", "snapshot", "--tab", static, env=walked)
        bare = environment({}, ("BROADWAY_AGENT", "BROADWAY_AGENT_NAME", "SSH_CONNECTION", "SSH_CLIENT", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"))
        timeline("snapshot with the full walk", "snapshot", "--tab", static, env=bare)
        batch = subprocess.run([BROADWAY, "--world", WORLD, "batch"], input="\n".join([f"click {still} --tab {static}"] * 5) + "\n",
                               capture_output=True, text=True, env=environment({"BROADWAY_TIMING": "1"}), timeout=120)
        line = next((row for row in batch.stderr.splitlines() if row.startswith("broadway timing ")), "")
        if line:
            told = json.loads(line[len("broadway timing "):])
            marks = sorted([("cli " + n, t) for n, t in told.get("cli", [])] + [("app " + n, t) for n, t in told.get("app", [])], key=lambda m: m[1])
            settles = [round(b[1] - a[1]) for a, b in zip(marks, marks[1:]) if b[0] == "app settle"]
            print(f"     batch of 5 clicks ({marks[-1][1] - marks[0][1]:.0f} ms): settles {settles}", flush=True)
            if os.environ.get("SPEED_CLICKS"):
                print("     " + ", ".join(f"{now} +{then - at:.1f}" for (was, at), (now, then) in zip(marks, marks[1:])), flush=True)
    return {"static": static, "form": form, "table": table}


def element(answer, name, role):
    data = (answer.get("_meta") or {}).get("com.broadway/data") or {}
    found = [e for e in data.get("elements", []) if e.get("name") == name and e.get("role") == role]
    return found[0]["ref"] if found else "e0"


def mcp_cases(base, tabs):
    if ONLY and "mcp" not in ONLY:
        return
    server = MCP(os.environ)
    try:
        static, form, table = tabs["static"], tabs["form"], tabs["table"]
        out, err = server.tool("snapshot", tab=static)
        still = element(out, "Still", "button")
        out, err = server.tool("snapshot", tab=form)
        name = element(out, "Name", "textbox")
        steps = {
            "tabs": lambda n: server.tool("tabs"),
            "snapshot": lambda n: server.tool("snapshot", tab=table),
            "read": lambda n: server.tool("read", tab=table),
            "find": lambda n: server.tool("find", tab=table, text="Edit 150"),
            "click": lambda n: server.tool("click", tab=static, ref=still),
            "type": lambda n: server.tool("type", tab=form, ref=name, text=f"Ada {n}", replace=True),
            "scroll": lambda n: server.tool("scroll", tab=table, by="down" if n % 2 == 0 else "up"),
            "go": lambda n: server.tool("go", tab=static, url=base + f"static?m={n}"),
            "shot": lambda n: server.tool("shot", tab=static),
        }
        for key, step in steps.items():
            out, err = step(0)
            check(f"mcp {key} answers", not err, json.dumps(out)[:400])
            stopwatch("mcp " + key, step)
        made = []

        def opening(n):
            out, err = server.tool("open", url=base + f"static?mopen={n}")
            data = (out.get("_meta") or {}).get("com.broadway/data") or {}
            made.append(data.get("id") or data.get("tab"))
        stopwatch("mcp open", opening)
        for tab in made:
            if tab:
                broadway("close", "--tab", tab)
    finally:
        server.close()


def gate():
    if not MINI or not GATE:
        return
    for name, limit in MINI.items():
        if name not in results:
            continue
        if results[name]["load"] > QUIET:
            print(f"     {name}: not judged, load {results[name]['load']} is above {QUIET}", flush=True)
            continue
        allowed = max(limit * SLACK, limit + 2)
        check(f"{name} median within {int((SLACK - 1) * 100)} % of {limit} ms", results[name]["median"] <= allowed, results[name])


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    os.environ["BROADWAY_AGENT"] = WORLD
    os.environ["BROADWAY_AGENT_NAME"] = "Speed Probe"
    os.environ.pop("BROADWAY_TAB", None)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sv.wipe()
    print(f"app {APP}, {RUNS} runs, load {load():.1f}", flush=True)
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        broadway("tabs")
        tabs = cli_cases(base)
        mcp_cases(base, tabs)
        gate()
        print("RESULTS " + json.dumps(results), flush=True)
    finally:
        subprocess.run([BENCH, "--world", WORLD, "quit"], capture_output=True)
        if not gone():
            for pid in held():
                os.kill(int(pid), signal.SIGKILL)
        sv.wipe()
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
