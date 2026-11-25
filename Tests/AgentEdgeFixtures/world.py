import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv

APP = Path(os.environ.get("BROADWAY_PROBE_APP") or ROOT / "build/Broadway.app")
BROADWAY = str(APP / "Contents/Helpers/broadway")
BENCH = str(ROOT / "bench")


class Reply:
    def __init__(self, body=b"", status=200, headers=None, kind="text/html; charset=utf-8"):
        self.body = body if isinstance(body, bytes) else body.encode()
        self.status = status
        self.headers = dict(headers or {})
        self.kind = kind


class Site:
    def __init__(self, pages, name="127.0.0.1"):
        self.pages = pages
        self.name = name
        self.hits = []
        site = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def answer(self):
                path = self.path.split("?")[0]
                site.hits.append((self.command, self.path, dict(self.headers)))
                found = site.pages.get(path)
                if found is None:
                    found = site.pages.get("*")
                if callable(found):
                    found = found(self, site)
                    if found is None:
                        return
                if found is None:
                    found = Reply(b"<!doctype html><title>Missing</title><p>No page here", 404)
                if not isinstance(found, Reply):
                    found = Reply(found)
                body = found.body.replace(b"{{other}}", site.other.encode() if hasattr(site, "other") else b"")
                body = body.replace(b"{{third}}", site.third.encode() if hasattr(site, "third") else b"")
                body = body.replace(b"{{base}}", site.base.encode())
                self.send_response(found.status)
                self.send_header("content-type", found.kind)
                self.send_header("content-length", str(len(body)))
                for key, value in found.headers.items():
                    self.send_header(key, value)
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)

            def do_GET(self):
                self.answer()

            def do_POST(self):
                length = int(self.headers.get("content-length") or 0)
                self.posted = self.rfile.read(length) if length else b""
                self.answer()

            def do_HEAD(self):
                self.answer()

            def log_message(self, *_):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.base = f"http://{name}:{self.server.server_port}/"


class World:
    def __init__(self, name, agent="Edge Probe"):
        sv.use(f"{name}-{os.getpid()}")
        self.name = sv.W
        self.folder = Path(sv.SUPPORT)
        self.suite = sv.SUITE
        os.environ["BROADWAY_AGENT"] = self.name
        os.environ["BROADWAY_AGENT_NAME"] = agent
        os.environ.pop("BROADWAY_TAB", None)

    def start(self, **defaults):
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
        sv.wipe()
        settings = {"bench": True, "agents.on": True}
        settings.update(defaults)
        for key, value in settings.items():
            kind = "-bool" if isinstance(value, bool) else "-string"
            word = ("true" if value else "false") if isinstance(value, bool) else str(value)
            subprocess.run(["defaults", "write", self.suite, key, kind, word], check=True)
        return self.launch()

    def launch(self):
        said = None
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={self.name}", str(APP)], check=True)
        until = time.time() + 120
        while time.time() < until:
            said = self.broadway("tabs", timeout=30)
            if said.returncode == 0:
                return True
            time.sleep(0.5)
        print(f"the world did not answer: {said.returncode} {said.stdout[-400:]} {said.stderr[-400:]}", flush=True)
        return False

    def stop(self):
        subprocess.run([BENCH, "--world", self.name, "quit"], capture_output=True)
        for _ in range(60):
            if not self.held():
                break
            time.sleep(0.25)
        for pid in self.held():
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass
        sv.wipe()
        (Path.home() / f"Library/Preferences/{self.suite}.plist").unlink(missing_ok=True)

    def quit(self):
        subprocess.run([BENCH, "--world", self.name, "quit"], capture_output=True)
        for _ in range(60):
            if not self.held():
                return True
            time.sleep(0.25)
        return False

    def held(self):
        return subprocess.run(["lsof", "-t", "--", str(self.folder / "broadway.sock")], capture_output=True, text=True).stdout.split()

    def broadway(self, *words, timeout=60, stdin=None, env=None):
        merged = dict(os.environ, **(env or {}))
        try:
            return subprocess.run([BROADWAY, "--world", self.name, *[str(w) for w in words]], capture_output=True, text=True,
                                  input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL, timeout=timeout, env=merged)
        except subprocess.TimeoutExpired as late:
            out = late.stdout.decode() if isinstance(late.stdout, bytes) else (late.stdout or "")
            return subprocess.CompletedProcess(late.cmd, 124, out, "probe timed out")

    def envelope(self, *words, **options):
        result = self.broadway(*words, "--json", **options)
        try:
            return result, json.loads(result.stdout)
        except ValueError:
            return result, {"ok": False, "data": None, "error": {"code": "unparsed", "message": result.stdout + result.stderr}}

    def timed(self, *words, json_out=True, **options):
        began = time.perf_counter()
        if json_out:
            result, parsed = self.envelope(*words, **options)
        else:
            result, parsed = self.broadway(*words, **options), None
        return result, parsed, time.perf_counter() - began

    def bench(self, *words, timeout=30):
        try:
            return subprocess.run([BENCH, "--world", self.name, *words], capture_output=True, text=True, timeout=timeout).stdout
        except subprocess.TimeoutExpired:
            return ""

    def desk(self, request):
        import socket
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(30)
            s.connect(str(self.folder / "bench.sock"))
            s.sendall((json.dumps(request) + "\n").encode())
            chunks = []
            while True:
                chunk = s.recv(1 << 16)
                if not chunk:
                    break
                chunks.append(chunk)
        try:
            return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")
        except ValueError:
            return {}

    def open(self, address, *extra):
        result = self.broadway("open", address, *extra)
        tab = result.stdout.strip().splitlines()[-1] if result.returncode == 0 and result.stdout.strip() else ""
        if not tab:
            raise RuntimeError(f"open {address} failed: {result.stdout[-300:]} {result.stderr[-300:]}")
        self.broadway("wait", "--tab", tab, "--idle")
        return tab

    def questions(self):
        return self.desk({"do": "agents", "action": "questions"}).get("questions") or []

    def mode(self, kind):
        return self.desk({"do": "agents", "action": "mode", "mode": kind})

    def answered(self, *words, choice="yes", seconds=15, wait=True):
        began = time.perf_counter()
        process = subprocess.Popen([BROADWAY, "--world", self.name, *[str(w) for w in words], "--json", *(["--wait-person", "1"] if wait else [])],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL)
        asked = []
        until = time.time() + seconds
        while time.time() < until and process.poll() is None:
            asked = self.questions()
            if asked:
                self.desk({"do": "agents", "action": "answer", "with": choice})
                break
            time.sleep(0.1)
        try:
            out, err = process.communicate(timeout=90)
        except subprocess.TimeoutExpired:
            process.kill()
            out, err = process.communicate()
        result = subprocess.CompletedProcess(process.args, process.returncode, out, err)
        try:
            parsed = json.loads(out)
        except ValueError:
            parsed = {"ok": False, "error": {"code": "unparsed", "message": out + err}}
        return result, parsed, time.perf_counter() - began, asked

    def mcp(self):
        return Client(self.name)


class Client:
    def __init__(self, world):
        self.process = subprocess.Popen([BROADWAY, "--world", world, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.number = 0

    def rpc(self, method, params=None):
        self.number += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.number, "method": method, "params": params or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                return {}
            message = json.loads(line)
            if message.get("id") == self.number:
                return message

    def raw(self, method, params=None):
        self.number += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.number, "method": method, "params": params or {}}) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                return ""
            if json.loads(line).get("id") == self.number:
                return line

    def call(self, name, /, **arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments}).get("result", {})
        return result, "".join(part.get("text", "") for part in result.get("content", []))

    def close(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()


class Ledger:
    def __init__(self, path=None):
        self.rows = []
        self.failures = []
        self.surprises = []
        self.path = path

    def check(self, case, name, ok, answer="", seconds=None, expect="pass"):
        row = {"case": case, "check": name, "expect": expect, "answer": str(answer)[:1200]}
        if seconds is not None:
            row["seconds"] = round(seconds, 2)
        if expect == "skip":
            row["result"] = "skip"
            print(f"skip {case}: {name} ({answer})", flush=True)
        elif ok:
            row["result"] = "pass"
            if expect == "fail":
                self.surprises.append(f"{case}: {name}")
                print(f"PASS {case}: {name} (marked as expected to fail: unmark it)", flush=True)
            else:
                print(f"ok   {case}: {name}", flush=True)
        else:
            row["result"] = "fail"
            if expect == "fail":
                print(f"xfail {case}: {name} {str(answer)[:400]}", flush=True)
            else:
                self.failures.append(f"{case}: {name}")
                print(f"FAIL {case}: {name} {str(answer)[:1500]}", flush=True)
        self.rows.append(row)
        self.save()
        return ok

    def save(self):
        if self.path:
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
            Path(self.path).write_text(json.dumps(self.rows, indent=1))

    def finish(self):
        if self.surprises:
            print("PASSED BUT MARKED TO FAIL: " + ", ".join(self.surprises), flush=True)
        print("FAILED: " + ", ".join(self.failures) if self.failures else "all good", flush=True)
        return 1 if self.failures or self.surprises else 0
