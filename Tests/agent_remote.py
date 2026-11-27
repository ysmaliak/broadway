#!/usr/bin/env python3
import json
import os
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOST = os.environ.get("BROADWAY_SSH_HOST", "mini")
TWIN = os.environ.get("BROADWAY_TWIN") or ("~/" + ROOT.relative_to(Path.home()).as_posix() if ROOT.is_relative_to(Path.home()) else str(ROOT))
HELPER = "build/Broadway.app/Contents/Helpers/broadway"
LONG = "--long" in sys.argv
FILE = b"carried across the forward " * 40
BIG = bytes(range(256)) * (5 * 4096 + 7)
GIVE = """<!doctype html><title>Give</title><form method=post enctype=multipart/form-data action=/sent>
<input type=file name=doc id=doc><button id=send>Send it</button></form>"""

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:700], flush=True)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/file.bin"):
            self.send_response(200)
            self.send_header("content-type", "application/octet-stream")
            self.send_header("content-disposition", 'attachment; filename="file.bin"')
            self.send_header("content-length", str(len(FILE)))
            self.end_headers()
            self.wfile.write(FILE)
            return
        if self.path.startswith("/big.bin"):
            self.send_response(200)
            self.send_header("content-type", "application/octet-stream")
            self.send_header("content-disposition", 'attachment; filename="big.bin"')
            self.send_header("content-length", str(len(BIG)))
            self.end_headers()
            self.wfile.write(BIG)
            return
        if self.path.startswith("/give"):
            data = GIVE.encode()
            self.send_response(200)
            self.send_header("content-type", "text/html; charset=utf-8")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        body = f"<h1>{self.path}</h1>"
        if "form" in self.path:
            body += '<form action="/sent"><label>Note <input name="note"></label><button>Send</button></form>'
        data = f"<!doctype html><title>{self.path}</title>{body}".encode()
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def host():
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import split_view as sv
    sv.use(f"remote-{os.getpid()}")
    helper = str(ROOT / HELPER)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sv.wipe()
    for key in ("bench", "agents.on"):
        subprocess.run(["defaults", "write", sv.SUITE, key, "-bool", "true"], check=True)
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", str(ROOT / "build/Broadway.app")], check=True)
    up = False
    for _ in range(400):
        if subprocess.run([helper, "--world", sv.W, "status"], capture_output=True, stdin=subprocess.DEVNULL).returncode == 0:
            up = True
            break
        time.sleep(0.1)
    socket = f"{Path.home()}/Library/Application Support/Broadway ({sv.W})/broadway.sock"

    def answer():
        while True:
            said = subprocess.run([str(ROOT / "bench"), "--world", sv.W, "knowing", "desk", "list"], capture_output=True, text=True).stdout
            try:
                pending = json.loads(said).get("pending") or []
            except ValueError:
                pending = []
            if pending:
                subprocess.run([str(ROOT / "bench"), "--world", sv.W, "knowing", "desk", "yes"], capture_output=True)
            time.sleep(0.3)

    threading.Thread(target=answer, daemon=True).start()
    print(json.dumps({"world": sv.W, "base": f"http://127.0.0.1:{server.server_port}/", "up": up, "socket": socket}), flush=True)
    try:
        sys.stdin.read()
    finally:
        subprocess.run([str(ROOT / "bench"), "--world", sv.W, "quit"], capture_output=True)
        subprocess.run([helper, "--world", sv.W, "quit", "--force"], capture_output=True, stdin=subprocess.DEVNULL)
        time.sleep(2)
        sv.wipe()
        (Path.home() / f"Library/Preferences/{sv.SUITE}.plist").unlink(missing_ok=True)


def ssh(command, timeout=120):
    try:
        return subprocess.run(["ssh", "-o", "ControlPath=none", HOST, command], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)
    except subprocess.TimeoutExpired as late:
        return subprocess.CompletedProcess(late.cmd, 124, "", "timed out")


def parsed(text):
    try:
        return json.loads(text.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"ok": False, "error": {"code": "unparsed", "message": text}}


def data(said):
    return said.get("data") or {}


def error(said):
    return said.get("error") or {}


class MCP:
    def __init__(self, world):
        self.process = subprocess.Popen(["ssh", "-o", "ControlPath=none", HOST, f"{TWIN}/{HELPER} --world {world} mcp"],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.n = 0
        self.rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "remote-probe", "version": "1"}})
        self.note("notifications/initialized")

    def note(self, method):
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "method": method}) + "\n")
        self.process.stdin.flush()

    def rpc(self, method, params):
        self.n += 1
        self.process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": self.n, "method": method, "params": params}) + "\n")
        self.process.stdin.flush()
        while True:
            line = self.process.stdout.readline()
            if not line:
                return {}
            got = json.loads(line)
            if got.get("id") == self.n:
                return got

    def call(self, name, arguments):
        result = self.rpc("tools/call", {"name": name, "arguments": arguments}).get("result", {})
        return {"error": result.get("isError"), "data": (result.get("_meta") or {}).get("com.broadway/data") or {},
                "text": "".join(c.get("text", "") for c in result.get("content", []))}

    def drop(self):
        self.process.kill()
        self.process.wait()


def reachable():
    seen = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", HOST, f"test -x {TWIN}/{HELPER}"],
                          capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if seen.returncode != 0:
        sys.exit(f"needs a second Mac that this one reaches as {HOST} over ssh with a key, with this checkout built at {TWIN} there. "
                 f"Set BROADWAY_SSH_HOST and BROADWAY_TWIN. ssh said: {seen.stderr.strip() or 'no build there'}")


def main():
    if "--host" in sys.argv:
        return host()
    reachable()
    scratch = Path(tempfile.mkdtemp(prefix="bw-remote-"))
    remote = subprocess.Popen(["ssh", "-o", "ControlPath=none", HOST, f"cd {TWIN} && python3 -u Tests/agent_remote.py --host"],
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    hello = json.loads(remote.stdout.readline() or "{}")
    world, base = hello.get("world"), hello.get("base")
    check("a test world is up on the remote Mac", hello.get("up"), hello)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    forward = None
    on = lambda *words: parsed(ssh(f"{TWIN}/{HELPER} --world {world} --json " + " ".join(shlex.quote(str(w)) for w in words)).stdout)
    try:
        copied = subprocess.run(["scp", "-q", f"{HOST}:{TWIN}/{HELPER}", str(scratch / "broadway")], capture_output=True)
        check("the broadway program is copied to this Mac", copied.returncode == 0, copied.stderr)
        forward = subprocess.Popen(["ssh", "-N", "-o", "ControlPath=none", "-o", "StreamLocalBindUnlink=yes", "-o", "ExitOnForwardFailure=yes",
                                    "-L", f"./fwd.sock:{hello.get('socket')}", HOST], cwd=scratch, stdin=subprocess.DEVNULL)
        for _ in range(100):
            if (scratch / "fwd.sock").exists():
                break
            time.sleep(0.1)
        plain = {k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_") and k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID")}

        def raw(*words):
            return subprocess.run([str(scratch / "broadway"), "--socket", "fwd.sock", *words], cwd=scratch, env=plain,
                                  capture_output=True, stdin=subprocess.DEVNULL, timeout=120)

        def here(*words, env=None):
            run = subprocess.run([str(scratch / "broadway"), "--socket", "fwd.sock", "--json", *words], cwd=scratch, env=env or plain,
                                 capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=120)
            return parsed(run.stdout)

        claude = dict(plain, CLAUDE_CODE_SESSION_ID=f"remote-{os.getpid()}")
        named = dict(plain, BROADWAY_AGENT=f"fwd-{os.getpid()}")
        one = data(here("open", base + "forwarded")).get("id")
        two = data(here("open", base + "claude", env=claude)).get("id")
        three = data(here("open", base + "named", env=named)).get("id")
        check("open over a forwarded socket answers with an id", one and two and three, (one, two, three))
        check("the next command over the forward keeps its tab", one and data(here("tab")).get("id") == one)
        time.sleep(40)
        check("after the sweep the forwarded session still has its tab", one and data(here("tab")).get("id") == one, here("tab"))
        check("so does a forwarded Claude Code session keyed by its session id", two and data(here("tab", env=claude)).get("id") == two, here("tab", env=claude))
        check("BROADWAY_AGENT over the forward keeps its own session", three and data(here("tab", env=named)).get("id") == three, here("tab", env=named))
        rows = data(on("agents", "list")).get("agents", [])
        print("agents:", json.dumps(rows), flush=True)
        live = [r for r in rows if r.get("state") != "done"]
        check("three live sessions, none ended", len(live) == 3, rows)
        check("each says it is from another machine", live and all(r.get("program") == "From another machine over ssh" for r in live), live)

        page = data(here("open", base + "long")).get("id")
        made = data(here("pdf", "--tab", page))
        check("pdf over the forward answers with a path on this Mac", made.get("path") and Path(made["path"]).exists() and Path(made["path"]).read_bytes()[:4] == b"%PDF", made)
        streamed = raw("pdf", "--tab", page, "--out", "-")
        check("pdf --out - over the forward writes the PDF's bytes", streamed.returncode == 0 and streamed.stdout[:4] == b"%PDF", (streamed.returncode, streamed.stdout[:40], streamed.stderr[-300:]))
        tiles = data(here("shot", "--tiles", "--tab", page)).get("tiles") or []
        check("shot --tiles over the forward gives tiles on this Mac", tiles and all(Path(t.get("path", "/nowhere")).exists() for t in tiles), tiles)
        fetched = data(here("download", "--url", base + "file.bin", "--tab", page)).get("download") or {}
        check("a download over the forward answers with an id", len(fetched.get("id", "")) == 8, fetched)
        copy = scratch / "got.bin"
        kept = here("downloads", "get", fetched.get("id", "none"), "-o", str(copy))
        check("downloads get ID -o FILE over the forward copies it here", copy.exists() and copy.read_bytes() == FILE, kept)
        got = raw("downloads", "get", fetched.get("id", "none"), "--out", "-")
        check("downloads get ID --out - over the forward writes its bytes", got.returncode == 0 and got.stdout == FILE, (got.returncode, got.stdout[:40], got.stderr[-300:]))
        large = data(here("download", "--url", base + "big.bin", "--tab", page)).get("download") or {}
        many = raw("downloads", "get", large.get("id", "none"), "--out", "-")
        check("a 5 MB download comes across the forward in pieces, byte for byte", many.returncode == 0 and many.stdout == BIG, (many.returncode, len(many.stdout), many.stderr[-300:]))
        left = data(here("downloads", "get", fetched.get("id", "none")))
        check("downloads get ID over the forward says a path on this Mac", left.get("path") and Path(left["path"]).exists(), left)

        form = data(here("open", base + "give")).get("id")
        here("wait", "Send it", "--tab", form)
        elements = data(here("snapshot", "--all", "--tab", form)).get("elements", [])
        named = {e.get("name", ""): "@" + e["ref"] for e in elements if e.get("ref")}
        field = named.get("doc") or next((ref for name, ref in named.items() if "file" in name.lower() or "choose" in name.lower()), None) or "Choose File"
        print("upload field:", field, list(named)[:8], flush=True)
        note = scratch / "note.txt"
        note.write_bytes(FILE)
        given = here("upload", field, str(note), "--tab", form)
        check("upload PATH over the forward sends the file's bytes", given.get("ok") and "note.txt" in json.dumps(given), given)
        piped = subprocess.run([str(scratch / "broadway"), "--socket", "fwd.sock", "--json", "upload", field, "--stdin", "piped.txt", "--tab", form],
                               cwd=scratch, env=plain, input=FILE, capture_output=True, timeout=120)
        check("upload --stdin over the forward sends the bytes", b"piped.txt" in piped.stdout and b'"ok":true' in piped.stdout.replace(b" ", b""), piped.stdout[-400:] + piped.stderr[-300:])
        heavy = scratch / "heavy.bin"
        heavy.write_bytes(BIG)
        sent = here("upload", field, str(heavy), "--tab", form)
        check("a 5 MB upload goes across the forward in pieces", sent.get("ok") and "heavy.bin" in json.dumps(sent), sent)
        twin = scratch / "twin"
        twin.mkdir()
        (twin / "note.txt").write_bytes(FILE)
        same = here("upload", field, str(note), str(twin / "note.txt"), "--tab", form)
        check("two files of one name are refused before anything is sent", not same.get("ok") and (same.get("error") or {}).get("code") == "usage", same)
        big = scratch / "big.bin"
        with open(big, "wb") as out:
            out.truncate(26 * 1024 * 1024)
        huge = here("upload", field, str(big), "--tab", form)
        check("a file over 25 MB is refused with a clear answer", not huge.get("ok") and "25 MB" in json.dumps(huge), huge)

        mcp = MCP(world)
        opened = mcp.call("open", {"url": base + "form-mcp"})
        typed = mcp.call("type", {"target": "Note", "text": "kept for later"})
        mine = opened["data"].get("id")
        check("MCP over ssh opens and types", mine and not typed["error"], (opened, typed))
        if LONG:
            time.sleep(21 * 60)
            after = mcp.call("tabs", {})
            check("after 21 minutes idle the MCP session still has its tab", [t.get("id") for t in after["data"].get("tabs", [])] == [mine], after)
        mcp.drop()
        time.sleep(4)
        rows = data(on("agents", "list")).get("agents", [])
        check("when ssh drops the MCP session ends", any(r.get("name") == "Remote-probe" and r.get("state") == "done" for r in rows), rows)
        again = MCP(world)
        back = again.call("tabs", {})
        check("the same machine connecting again takes back the tab with a form not sent", [t.get("id") for t in back["data"].get("tabs", [])] == [mine], back)
        again.drop()

        down = f"remotedown-{os.getpid()}"
        quiet = parsed(ssh(f"{TWIN}/{HELPER} --world {down} --json open {base}never").stdout)
        print("not running, open:", json.dumps(quiet), flush=True)
        check("over ssh a command doesn't start Broadway and says what to run", error(quiet).get("code") == "not_running" and "broadway serve" in error(quiet).get("hint", ""), quiet)
        time.sleep(3)
        check("and nothing was started", ssh(f"test -e ~/Library/'Application Support'/'Broadway ({down})'/broadway.sock").returncode != 0)
        script = f"({TWIN}/{HELPER} --world {down} serve > /dev/null 2>&1 &) ; sleep 15; {TWIN}/{HELPER} --world {down} --json status; {TWIN}/{HELPER} --world {down} serve --stop"
        served = ssh("bash -c " + shlex.quote(script), timeout=90)
        print("serve over ssh:", served.stdout.strip()[:400], flush=True)
        check("broadway serve over ssh starts it", '"running":true' in served.stdout.replace(" ", ""), served.stdout + served.stderr)
        time.sleep(2)
        ssh(f"rm -rf ~/Library/'Application Support'/'Broadway ({down})'; defaults delete com.ysmaliak.broadway.test.{down}; rm -f ~/Library/Preferences/com.ysmaliak.broadway.test.{down}.plist")

        first = data(on("status")).get("pid")
        ssh(f"cd {TWIN} && open -n -g -j --env SEARCH_PROBE={world} build/Broadway.app")
        time.sleep(10)
        second = data(on("status")).get("pid")
        check("a second copy on the same data folder takes the socket", first and second and first != second, (first, second))
        on("quit", "--force")
        time.sleep(9)
        back = on("status")
        check("once it quits, the copy still running answers again", data(back).get("pid") == first, back)
    finally:
        if forward:
            forward.terminate()
        try:
            remote.stdin.close()
        except OSError:
            pass
        remote.wait(timeout=60)
        shutil.rmtree(scratch, ignore_errors=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good", flush=True)
    sys.exit(1 if failures else 0)


main()
