#!/usr/bin/env python3
import json
import os
import shlex
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOST = os.environ.get("BROADWAY_SSH_HOST", "mini")
TWIN = os.environ.get("BROADWAY_TWIN") or ("~/" + ROOT.relative_to(Path.home()).as_posix() if ROOT.is_relative_to(Path.home()) else str(ROOT))
HELPER = "build/Broadway.app/Contents/Helpers/broadway"
SCRATCH = Path(os.environ.get("BROADWAY_SSH_SCRATCH") or ROOT / ".context")

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail, flush=True)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        data = f"<!doctype html><title>{self.path}</title><h1>{self.path}</h1>".encode()
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
    sv.use(f"ssh-{os.getpid()}")
    suite = sv.SUITE
    helper = str(ROOT / HELPER)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    sv.wipe()
    for key in ("bench", "agents.on"):
        subprocess.run(["defaults", "write", suite, key, "-bool", "true"], check=True)
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", str(ROOT / "build/Broadway.app")], check=True)
    up = False
    for _ in range(400):
        if subprocess.run([helper, "--world", sv.W, "status"], capture_output=True, stdin=subprocess.DEVNULL).returncode == 0:
            up = True
            break
        time.sleep(0.1)
    print(json.dumps({"world": sv.W, "base": f"http://127.0.0.1:{server.server_port}/", "up": up}), flush=True)
    try:
        sys.stdin.read()
    finally:
        subprocess.run([str(ROOT / "bench"), "--world", sv.W, "quit"], capture_output=True)
        time.sleep(2)
        subprocess.run(["pkill", "-f", f"SEARCH_PROBE={sv.W}"], capture_output=True)
        sv.wipe()
        (Path.home() / f"Library/Preferences/{suite}.plist").unlink(missing_ok=True)


def ssh(command, options=()):
    try:
        return subprocess.run(["ssh", *options, HOST, command], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=90)
    except subprocess.TimeoutExpired as late:
        return subprocess.CompletedProcess(late.cmd, 124, "", "timed out")


def line(world, words, prefix=""):
    return f"{prefix}{TWIN}/{HELPER} --world {world} --json " + " ".join(shlex.quote(str(w)) for w in words)


def parsed(result):
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"ok": False, "error": {"code": "unparsed", "message": result.stdout + result.stderr}}


def data(said):
    return said.get("data") or {}


def ids(said):
    return [row.get("id") for row in data(said).get("tabs", [])]


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
    SCRATCH.mkdir(parents=True, exist_ok=True)
    remote = subprocess.Popen(["ssh", HOST, f"cd {TWIN} && python3 -u Tests/agent_ssh.py --host"], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, text=True)
    hello = json.loads(remote.stdout.readline() or "{}")
    world, base = hello.get("world"), hello.get("base")
    check("a test world is up on the remote Mac", hello.get("up"), hello)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    multiplex = ["-o", "ControlMaster=auto", "-o", "ControlPath=cm-%C", "-o", "ControlPersist=20"]
    try:
        address = ssh("echo $SSH_CONNECTION").stdout.split()[0]
        call = lambda *words, prefix="", options=(): parsed(ssh(line(world, words, prefix), options))

        first = call("open", base + "one")
        one = data(first).get("id")
        check("open over ssh answers with an id", first.get("ok") and one, first)
        current = call("tab")
        check("the next ssh command keeps the tab", data(current).get("id") == one, current)
        second = data(call("open", base + "two")).get("id")
        listed = call("tabs")
        check("tabs over ssh lists both tabs of the machine", ids(listed) == [one, second], listed)

        agents = data(call("agents", "list")).get("agents", [])
        remote_rows = [a for a in agents if a.get("name") == f"SSH from {address}"]
        check("one machine is one session named for its address", len(remote_rows) == 1 and remote_rows[0].get("tabs") == 2, agents)
        check("no session is named for sshd", not [a for a in agents if "sshd" in a.get("name", "").lower()], agents)

        os.chdir(SCRATCH)
        muxed = [call("tab", options=multiplex) for _ in range(2)]
        check("over a multiplexed connection the tab carries", all(data(m).get("id") == second for m in muxed), muxed)
        subprocess.run(["ssh", *multiplex, "-O", "exit", HOST], capture_output=True)
        tty = parsed(ssh(line(world, ["tab"]), ["-tt"]))
        check("with ssh -t the tab carries", data(tty).get("id") == second, tty)

        mine = call("open", base + "three", prefix="BROADWAY_AGENT=one ")
        theirs = call("open", base + "four", prefix="BROADWAY_AGENT=two ")
        three, four = data(mine).get("id"), data(theirs).get("id")
        check("BROADWAY_AGENT=id before the command works over ssh", mine.get("ok") and theirs.get("ok"), (mine, theirs))
        check("two ids from one machine keep apart", ids(call("tabs", prefix="BROADWAY_AGENT=one ")) == [three]
              and ids(call("tabs", prefix="BROADWAY_AGENT=two ")) == [four])
        check("env BROADWAY_AGENT=id works too", ids(call("tabs", prefix="env BROADWAY_AGENT=one ")) == [three])
        named = call("open", base + "five", prefix="BROADWAY_AGENT_NAME=Reviewer ")
        five = data(named).get("id")
        check("a name alone makes a session apart", named.get("ok") and ids(call("tabs", prefix="BROADWAY_AGENT_NAME=Reviewer ")) == [five], named)
        check("the machine's own session keeps only its tabs", ids(call("tabs")) == [one, second])

        out = f"{TWIN}/.context/ssh-screen-{os.getpid()}.json"
        ssh(f"screen -dmS bwssh{os.getpid()} sh -c {shlex.quote(line(world, ['tab']) + ' > ' + out)}")
        time.sleep(3)
        screened = parsed(ssh(f"cat {out}; rm -f {out}"))
        check("inside screen on the remote Mac the tab carries", data(screened).get("id") == second, screened)

        after = data(call("agents", "list")).get("agents", [])
        check("still one session for the machine", len([a for a in after if a.get("name", "").startswith("SSH from")]) == 1, after)

        down = f"sshdown-{os.getpid()}"
        quiet = parsed(ssh(line(down, ["status"])))
        woke = parsed(ssh(line(down, ["open", base + "six"])))
        print("not running, status:", json.dumps(quiet), flush=True)
        print("not running, open:", json.dumps(woke), flush=True)
        check("status over ssh with Broadway not running says what to do", (quiet.get("error") or {}).get("hint"), quiet)
        check("open over ssh with Broadway not running starts it or says what to do", woke.get("ok") or (woke.get("error") or {}).get("hint"), woke)
        ssh(line(down, ["quit", "--force"]))
        time.sleep(2)
        ssh(f"pkill -f SEARCH_PROBE={down}; rm -rf ~/Library/'Application Support'/'Broadway ({down})'; "
            f"defaults delete com.ysmaliak.broadway.test.{down}; rm -f ~/Library/Preferences/com.ysmaliak.broadway.test.{down}.plist")
    finally:
        try:
            remote.stdin.close()
        except OSError:
            pass
        remote.wait(timeout=60)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
