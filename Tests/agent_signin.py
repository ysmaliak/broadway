#!/usr/bin/env python3
import json
import os
import secrets
import signal
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Broadway.app"
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"agentsignin-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
CARDS = Path(os.environ.get("AGENT_SIGNIN_CARDS", ROOT / ".context/signin-cards.txt"))

PAGES = {
    "/form": "<!doctype html><title>Sign in</title><form action='/landed' method='get'><input name=email autocomplete=username><input id=p name=pw type=password autocomplete=current-password><button type=submit>Sign in</button></form>",
    "/landed": "<!doctype html><title>Home</title><h1>Welcome back</h1>",
    "/wrong": "<!doctype html><title>Sign in</title><p>Wrong password</p><form action='/wrong' method='get'><input name=email autocomplete=username><input id=p name=pw type=password><button type=submit>Sign in</button></form>",
    "/first": "<!doctype html><title>Sign in</title><form action='/second' method='get'><input id=e name=email type=email autocomplete=username><button type=submit>Next</button></form>",
    "/second": "<!doctype html><title>Sign in</title><form action='/landed' method='get'><input id=p name=pw type=password autocomplete=current-password><button type=submit>Sign in</button></form>",
    "/shop": "<!doctype html><title>Pay</title><form><input autocomplete=cc-number name=card><input autocomplete=cc-exp name=exp></form>",
}

failures = []
cards = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path.split("?")[0], "<!doctype html><title>None</title>").encode()
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def clean_env():
    environment = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "BROADWAY_TAB")}
    environment.update({"BROADWAY_AGENT": "signin-probe", "BROADWAY_AGENT_NAME": "Probe Agent"})
    return environment


def broadway(*words, timeout=60):
    return subprocess.run([BROADWAY, "--world", WORLD, *words, "--json"], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, env=clean_env(), timeout=timeout)


def data(*words):
    result = broadway(*words)
    try:
        return json.loads(result.stdout)
    except ValueError:
        return {"ok": False, "raw": result.stdout + result.stderr}


def later(*words):
    return subprocess.Popen([BROADWAY, "--world", WORLD, *words, "--json", "--wait-person", "1"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, stdin=subprocess.DEVNULL, env=clean_env())


def finished(process):
    out, err = process.communicate(timeout=40)
    try:
        return json.loads(out)
    except ValueError:
        return {"ok": False, "raw": out + err}


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


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.1)
    return None


def question():
    return wait_for(lambda: (agent("questions").get("questions") or [None])[0], 15)


def note(name, asked):
    card = (asked or {}).get("card", {})
    cards.append(f"{name}\n  title: {card.get('title', '')}\n  who: {card.get('who', '')}\n  line: {card.get('body', '')}\n  rows: {card.get('choices', [])}\n  quote: {asked.get('label', '') if asked else ''}: {asked.get('quote', '') if asked else ''}")


def keep(port, users, reset=False):
    agent("logins", kept=[{"host": "127.0.0.1", "port": port, "user": user, "password": f"pw-{user.split('@')[0]}-secret", "clear": True} for user in users], reset=reset)


def tab_url(tab):
    found = data("tabs")
    return next((row.get("url", "") for row in found.get("data", {}).get("tabs", []) if row.get("id") == tab), "")


def opened(base, path):
    made = data("open", base + path)
    tab = made.get("data", {}).get("id")
    broadway("wait", "--tab", tab or "")
    return tab


def several(base, port):
    agent("mode", mode="auto")
    keep(port, ["sam@example.com", "work@example.com"], reset=True)
    tab = opened(base, "form")
    asking = later("fill", "login", "--tab", tab)
    asked = question()
    note("Several accounts, Auto", asked)
    check("one card asks which account", asked and asked["card"]["choices"] == ["sam@example.com", "work@example.com"], asked)
    check("the card is titled for the site", asked and asked["title"] == "Sign in on 127.0.0.1?", asked)
    listed = data("approvals", "list")
    check("approvals list names no account", "example.com" not in json.dumps(listed), listed)
    agent("answer", **{"with": "1"})
    said = finished(asking)
    check("a pick is the yes and fills that account", said.get("ok") and "Filled as work@example.com" in said["data"]["message"], said)
    check("Broadway sends the form", "/landed" in tab_url(tab), tab_url(tab))
    check("no second question", not agent("questions").get("questions"), agent("questions"))


def one_and_always(base, port):
    agent("mode", mode="auto")
    keep(port, ["sam@example.com"], reset=True)
    tab = opened(base, "form")
    asking = later("fill", "login", "--tab", tab)
    asked = question()
    note("One account, Auto", asked)
    check("one account is a line on the card", asked and asked["card"]["body"] == "As sam@example.com", asked)
    agent("answer", **{"with": "always"})
    said = finished(asking)
    check("Always Here signs in", said.get("ok"), said)
    broadway("go", base + "form", "--tab", tab)
    broadway("wait", "--tab", tab)
    quiet = data("fill", "login", "--tab", tab)
    check("Always Here covers that account next time", quiet.get("ok") and "Filled as sam@example.com" in quiet["data"]["message"], quiet)
    shown = bench({"do": "small", "action": "login"}).get("said", "")
    check("a fill without a card shows a notice", shown == "Probe Agent signed in as sam@example.com", shown)
    status = data("agents", "status")
    check("agents status lists the site, not the account", "sign_in" in json.dumps(status) and "sam@" not in json.dumps(status), status)


def bypass(base, port):
    agent("mode", mode="bypass")
    keep(port, ["sam@example.com"], reset=True)
    tab = opened(base, "wrong")
    said = data("fill", "login", "--tab", tab)
    check("Bypass with one account asks nothing", said.get("ok") and not agent("questions").get("questions"), said)
    check("the answer says the password was not taken", "still asks for the password" in json.dumps(said), said)
    keep(port, [])
    none = data("fill", "login", "--tab", tab)
    check("Bypass with nothing kept says to hand over", not none.get("ok") and none.get("error", {}).get("code") == "nothing_kept" and "handoff" in json.dumps(none), none)
    refused = data("settings", "set", "agents.signIn", "true")
    check("the switch is the person's", refused.get("error", {}).get("code") == "person_only", refused)
    agent("mode", mode="auto")


def two_steps(base, port):
    agent("mode", mode="auto")
    keep(port, ["sam@example.com"], reset=True)
    tab = opened(base, "first")
    agent("mode", mode="ask")
    asking = later("fill", "login", "--tab", tab)
    asked = question()
    note("One account, Ask", asked)
    check("Ask asks even with one account", asked is not None and asked["card"]["body"] == "As sam@example.com", asked)
    agent("answer", **{"with": "yes"})
    said = finished(asking)
    url = tab_url(tab)
    check("one yes carries the name step and the password step", said.get("ok") and "/landed" in url, (said, url))
    agent("mode", mode="auto")


def nothing_kept(base, port):
    agent("mode", mode="auto")
    keep(port, [], reset=True)
    tab = opened(base, "form")
    asking = later("fill", "login", "--tab", tab)
    asked = question()
    note("No sign-in kept, Auto", asked)
    check("the card says nothing is kept", asked and "no saved sign-in" in asked["card"]["body"], asked)
    agent("answer", **{"with": "no"})
    said = finished(asking)
    check("Not Now is said_no", said.get("error", {}).get("code") == "said_no", said)
    shop = opened(base, "shop")
    asking = later("fill", "card", "--tab", shop)
    asked = question()
    note("No card kept", asked)
    check("fill card asks before saying nothing is kept", asked and asked["card"]["body"] == "Broadway has no saved card", asked)
    agent("answer", **{"with": "no"})
    finished(asking)


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    base = f"http://127.0.0.1:{port}/"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        check("the app is up", wait_for(lambda: subprocess.run([BROADWAY, "--world", WORLD, "status"], capture_output=True).returncode == 0, 30) is not None)
        bench({"do": "window"})
        data("agents", "connect", "--name", "Probe Agent")
        several(base, port)
        one_and_always(base, port)
        bypass(base, port)
        two_steps(base, port)
        nothing_kept(base, port)
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
    CARDS.parent.mkdir(parents=True, exist_ok=True)
    CARDS.write_text("\n\n".join(cards) + "\n")
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
