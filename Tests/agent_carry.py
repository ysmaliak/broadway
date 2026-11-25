#!/usr/bin/env python3
import json
import os
import re
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
WORLD = f"agentcarry-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
CARDS = Path(os.environ.get("AGENT_CARRY_CARDS", ROOT / ".context/carry-cards.txt"))
SSH = Path(os.environ.get("AGENT_CARRY_SSH", ROOT / ".context/carry-ssh.json"))

TOKEN = "tok-7Hq2Lm9Xc4Vb8Nz1"
HELD = "s3cr3t-Held-Value-42"
PIPED = "p1ped-Value-Over-Pipe"
FILED = "f1led-Value-From-Disk"
SSHED = "ssh-Value-From-MacBook-9"
MCPED = "mcp-Value-From-Env-5"
CODE = "482913"

ECHO = "<script>document.querySelectorAll('input').forEach(function(b){b.addEventListener('input',function(){document.getElementById('echo').textContent='You typed '+b.value;document.title='Now '+b.value})})</script>"

PAGES = {
    "/form": "<!doctype html><title>Sign in</title><form action='/landed' method='get'><input name=email autocomplete=username><input id=p name=pw type=password autocomplete=current-password><button type=submit>Sign in</button></form>",
    "/landed": "<!doctype html><title>Home</title><h1>Welcome back</h1><p id=echo></p><script>var q=new URLSearchParams(location.search).get('pw');document.title='Hello '+q;echo.textContent='Your password is '+q</script>",
    "/secret": "<!doctype html><title>Settings</title><label for=p>Password</label><input id=p type=password><label for=n>Name</label><input id=n name=nickname><p id=echo></p>" + ECHO,
    "/token": "<!doctype html><title>API token</title><h1>API token</h1><p>Copy it now, it is shown once</p><code id=tok>" + TOKEN + "</code><label for=k>Account key</label><input id=k type=password value='" + TOKEN + "'>",
    "/smtp": "<!doctype html><title>SMTP</title><label for=sp>SMTP password</label><input id=sp type=password><label for=u>User</label><input id=u name=user><p id=echo></p><p id=match></p>" + ECHO + "<script>sp.addEventListener('input',function(){match.textContent=sp.value==='" + TOKEN + "'?'Match yes':'Match no'})</script>",
    "/code": "<!doctype html><title>Check your mail</title><p>We emailed a code to you</p><form action='/in' method='get'><label for=c>Code</label><input id=c name=c autocomplete=one-time-code inputmode=numeric><button>Verify</button></form><p id=echo></p>" + ECHO,
    "/split": "<!doctype html><title>Check your mail</title><p>Enter the code we emailed you</p><form action='/in' method='get'>" + "".join(f"<input name=d{i} maxlength=1 inputmode=numeric autocomplete={'one-time-code' if i == 0 else 'off'} aria-label='Digit {i + 1}'>" for i in range(6)) + "<button>Verify</button></form>",
    "/app": "<!doctype html><title>Two-step</title><p>Enter the code from your authenticator app</p><input autocomplete=one-time-code>",
    "/sms": "<!doctype html><title>Two-step</title><p>We sent a text message with a code to your phone ending 42</p><input autocomplete=one-time-code>",
    "/in": "<!doctype html><title>Signed in</title><h1>You are in</h1><p id=got></p><script>var s=new URLSearchParams(location.search);got.textContent='Code was '+(s.get('c')||[0,1,2,3,4,5].map(function(i){return s.get('d'+i)}).join(''))</script>",
}

failures = []
cards = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:600], flush=True)
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


def clean_env(**more):
    environment = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "BROADWAY_TAB")}
    environment.update({"BROADWAY_AGENT": "carry-probe", "BROADWAY_AGENT_NAME": "Probe Agent"})
    environment.update(more)
    return environment


def broadway(*words, timeout=90, stdin=None, env=None):
    return subprocess.run([BROADWAY, "--world", WORLD, *words, "--json"], capture_output=True, text=True,
                          input=stdin, stdin=None if stdin is not None else subprocess.DEVNULL, env=env or clean_env(), timeout=timeout)


def parsed(result):
    try:
        found = json.loads(result.stdout)
    except ValueError:
        found = {"ok": False, "raw": result.stdout + result.stderr}
    found["_all"] = result.stdout + result.stderr
    return found


def data(*words, **options):
    return parsed(broadway(*words, **options))


def later(*words, env=None, stdin=None):
    waiting = [] if words[0] in ("type", "carry") else ["--wait-person", "1"]
    process = subprocess.Popen([BROADWAY, "--world", WORLD, *words, "--json", *waiting], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL, text=True, env=env or clean_env())
    if stdin is not None:
        process.stdin.write(stdin)
        process.stdin.close()
    return process


def finished(process):
    out, err = process.communicate(timeout=90)
    try:
        found = json.loads(out)
    except ValueError:
        found = {"ok": False, "raw": out + err}
    found["_all"] = out + err
    return found


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


def question(seconds=15):
    return wait_for(lambda: (agent("questions").get("questions") or [None])[0], seconds)


def no_question():
    time.sleep(0.5)
    return not agent("questions").get("questions")


def note(name, asked):
    card = (asked or {}).get("card", {})
    cards.append(f"{name}\n  title: {card.get('title', '')}\n  who: {card.get('who', '')}\n  line: {card.get('body', '')}\n  rows: {card.get('choices', [])}\n  keys: {card.get('keys', '')}\n  quote: {asked.get('label', '') if asked else ''}: {asked.get('quote', '') if asked else ''}")


def opened(base, path, env=None):
    made = data("open", base + path, env=env)
    tab = made.get("data", {}).get("id")
    broadway("wait", "--tab", tab or "", env=env)
    return tab


def shown(tab):
    return data("read", "--tab", tab)["_all"] + data("snapshot", "--tab", tab)["_all"] + data("tabs")["_all"]


def holds(words, *values):
    return [value for value in values if value in words]


def person_tab(base, path):
    subprocess.run([BROADWAY, "--world", WORLD, base + path], capture_output=True, stdin=subprocess.DEVNULL, env=clean_env(), timeout=30)
    found = wait_for(lambda: [row for row in data("tabs", "--all").get("data", {}).get("tabs", []) if not row.get("agent") and row.get("url", "").endswith("/" + path)], 10)
    return found[0]["id"] if found else ""


def seals_of_closed_tabs(base, port):
    agent("mode", mode="bypass")
    agent("logins", kept=[{"host": "127.0.0.1", "port": port, "user": "sam@example.com", "password": "pw-Sam-Kept-Secret", "clear": True}], reset=True)
    tab = person_tab(base, "form")
    check("the person's tab is open", bool(tab), tab)
    broadway("wait", "--tab", tab)
    said = data("fill", "login", "--tab", tab)
    check("fill login sends the form with the password in the address", said.get("ok"), said)
    wait_for(lambda: "Hello" in data("tabs", "--all")["_all"], 10)
    open_words = data("tabs", "--all")["_all"] + data("history")["_all"]
    check("while the tab is open, tabs and history hide the password", not holds(open_words, "pw-Sam-Kept-Secret"), open_words)
    closing = later("tabs", "close", tab)
    if question(5):
        agent("answer", **{"with": "yes"})
    finished(closing)
    time.sleep(0.5)
    closed = data("tabs", "closed")["_all"]
    history = data("history")["_all"] + data("history", "list")["_all"]
    print("tabs closed: " + closed[:700], flush=True)
    print("history: " + history[:900], flush=True)
    check("the closed tab is listed", "Hello" in closed or "landed" in closed, closed)
    check("tabs closed hides a closed tab's sealed password", not holds(closed, "pw-Sam-Kept-Secret"), closed)
    check("history hides a closed tab's sealed password", not holds(history, "pw-Sam-Kept-Secret"), history)
    reopening = later("tabs", "reopen")
    if question(5):
        agent("answer", **{"with": "yes"})
    finished(reopening)
    time.sleep(1.5)
    after = data("tabs", "--all")["_all"]
    print("after reopen: " + after[:900], flush=True)
    check("a tab reopened in the same run keeps its seals", "Hello" in after and not holds(after, "pw-Sam-Kept-Secret"), after)
    agent("mode", mode="auto")


def type_secret(base, port):
    agent("mode", mode="auto")
    agent("logins", kept=[], reset=True)
    tab = opened(base, "secret")
    plain = data("type", "--label", "Password", HELD, "--tab", tab)
    check("a secret as plain text into a password box stays refused", plain.get("error", {}).get("code") == "secret_field", plain)
    check("the refusal names --secret-env", "--secret-env" in plain["_all"], plain)

    unset = data("type", "--label", "Password", "--secret-env", "NOT_SET_ANYWHERE", "--tab", tab)
    check("an unset variable is a usage error naming it", unset.get("error", {}).get("code") == "usage" and "NOT_SET_ANYWHERE" in unset["_all"], unset)

    asking = later("type", "--label", "Password", "--secret-env", "HELD_TOKEN", "--tab", tab, env=clean_env(HELD_TOKEN=HELD))
    asked = question()
    note("Type a secret, Auto, first time", asked)
    check("Auto asks the first time", asked is not None, asked)
    check("the card names the field and the site", asked and asked["title"] == "Type a secret into Password on 127.0.0.1?", asked)
    check("the card never shows the value", asked and HELD not in json.dumps(asked) and str(len(HELD)) not in json.dumps(asked.get("card", {})), asked)
    agent("answer", **{"with": "always"})
    said = finished(asking)
    check("the answer says a secret was typed", said.get("ok") and "Typed a secret into Password" in said["_all"], said)
    check("the answer never holds the value", HELD not in said["_all"], said)
    words = shown(tab)
    check("the page's echo of the value is sealed in every later look", not holds(words, HELD) and "You typed" in words, words)
    picture = data("shot", "--tab", tab, "-o", str(ROOT / ".context/carry-secret-shot.png"))
    check("a shot of the page works and its answer holds no value", picture.get("ok") and HELD not in picture["_all"], picture)

    again = data("type", "--label", "Password", "--secret-env", "HELD_TOKEN", "--tab", tab, env=clean_env(HELD_TOKEN=HELD))
    check("Always Here covers the next secret on that site", again.get("ok") and no_question(), again)

    into_plain = data("type", "--label", "Name", "--secret-env", "HELD_TOKEN", "--tab", tab, env=clean_env(HELD_TOKEN=HELD))
    check("a secret into a plain box is refused", not into_plain.get("ok") and into_plain.get("error", {}).get("code") == "refused", into_plain)
    check("the refusal says why", "next look" in into_plain["_all"], into_plain)

    piped = data("type", "--label", "Password", "--secret-stdin", "--tab", tab, stdin=PIPED + "\n")
    check("--secret-stdin types what was piped", piped.get("ok") and PIPED not in piped["_all"], piped)
    check("a piped value is sealed too", not holds(shown(tab), PIPED), "")
    path = ROOT / ".context/carry-secret.txt"
    path.write_text(FILED + "\n")
    filed = data("type", "--label", "Password", "--secret-file", str(path), "--tab", tab)
    path.unlink()
    check("--secret-file types the file's value", filed.get("ok") and FILED not in filed["_all"], filed)
    check("a filed value is sealed too", not holds(shown(tab), FILED), "")
    both = data("type", "--label", "Password", "words", "--secret-env", "HELD_TOKEN", "--tab", tab, env=clean_env(HELD_TOKEN=HELD))
    check("text and a secret together is a usage error", both.get("error", {}).get("code") == "usage", both)

    agent("mode", mode="ask")
    asking = later("type", "--label", "Password", "--secret-env", "HELD_TOKEN", "--tab", tab, env=clean_env(HELD_TOKEN=HELD))
    asked = question()
    note("Type a secret, Ask", asked)
    check("Ask asks every time, Always Here or not", asked is not None, asked)
    agent("answer", **{"with": "no"})
    said = finished(asking)
    check("Not Now is said_no", said.get("error", {}).get("code") == "said_no", said)

    agent("mode", mode="bypass")
    other = opened(base.replace("127.0.0.1", "localhost"), "secret")
    quiet = data("type", "--label", "Password", "--secret-env", "HELD_TOKEN", "--tab", other, env=clean_env(HELD_TOKEN=HELD))
    check("Bypass types a secret without a card", quiet.get("ok") and no_question(), quiet)
    agent("site", site="localhost", rule="never")
    never = data("type", "--label", "Password", "--secret-env", "HELD_TOKEN", "--tab", other, env=clean_env(HELD_TOKEN=HELD))
    check("Never Here refuses", never.get("error", {}).get("code") == "never_here", never)
    agent("site", site="localhost", rule="")
    agent("mode", mode="auto")
    return tab


def over_ssh(base, tab):
    if os.environ.get("AGENT_CARRY_SSH_WAIT") != "1":
        print("skip ssh: set AGENT_CARRY_SSH_WAIT=1 and pipe from another machine", flush=True)
        return
    agent("mode", mode="bypass")
    SSH.write_text(json.dumps({"world": WORLD, "tab": tab, "broadway": BROADWAY}))
    print("waiting for ssh: " + str(SSH), flush=True)
    landed = wait_for(lambda: "You typed" in data("read", "--tab", tab)["_all"] and (Path(str(SSH) + ".done").exists()), 240)
    said = Path(str(SSH) + ".done").read_text() if Path(str(SSH) + ".done").exists() else ""
    check("a secret piped over ssh is typed", landed is not None and '"ok":true' in said.replace(" ", ""), said)
    check("the ssh answer never holds the value", SSHED not in said, said)
    check("the value piped over ssh is sealed", not holds(shown(tab), SSHED), "")
    SSH.unlink(missing_ok=True)
    agent("mode", mode="auto")


def carry(base, port):
    agent("mode", mode="bypass")
    source = opened(base, "token")
    target = opened(base, "smtp")
    asking = later("carry", TOKEN, "--to", "SMTP password", "--to-tab", target, "--tab", source)
    asked = question()
    note("Carry a plain-text token, Bypass", asked)
    check("carry asks in Bypass too", asked is not None, asked if asked else finished(asking))
    title = (asked or {}).get("title", "")
    check("the card names both ends", title.startswith("Copy the value of ") and " on 127.0.0.1 into SMTP password on 127.0.0.1?" in title, asked)
    check("the card never shows the value", asked and TOKEN not in json.dumps(asked), asked)
    check("the card offers no Always Here", asked and "Always" not in json.dumps(asked.get("card", {})), asked)
    agent("answer", **{"with": "yes"})
    said = finished(asking)
    check("the answer says it carried", said.get("ok") and "Carried a value of 20 characters" in said["_all"], said)
    check("the answer never holds the value", TOKEN not in said["_all"], said)
    read = data("read", "--tab", target)["_all"]
    check("the target got the very value", "Match yes" in read, read)
    check("the target's echo of it is sealed", TOKEN not in shown(target), "")
    check("the source shows it sealed too", TOKEN not in shown(source), "")
    data("shot", "--tab", source, "-o", str(ROOT / ".context/carry-source-shot.png"))
    data("shot", "--tab", target, "-o", str(ROOT / ".context/carry-target-shot.png"))

    fresh = opened(base, "smtp")
    asking = later("carry", "API token", "--to", "SMTP password", "--to-tab", fresh, "--tab", source)
    asked = question()
    note("Carry by the heading above the token", asked)
    check("carry by a heading takes the value under it", asked and asked.get("title") == "Copy the value of API token on 127.0.0.1 into SMTP password on 127.0.0.1?", asked if asked else finished(asking))
    agent("answer", **{"with": "yes"})
    said = finished(asking)
    read = data("read", "--tab", fresh)["_all"]
    check("the heading's value landed, not the heading", said.get("ok") and "Carried a value of 20 characters" in said["_all"] and "Match yes" in read, (said, read))

    plain = later("carry", TOKEN, "--to", "User", "--to-tab", target, "--tab", source)
    said = finished(plain)
    check("carry into a plain box is refused before any card", said.get("error", {}).get("code") == "refused" and no_question(), said)

    asking = later("carry", "--label", "Account key", "--to", "SMTP password", "--to-tab", target, "--tab", source)
    asked = question()
    note("Carry from a password box", asked)
    check("a secret source is named by its label", asked and asked["title"] == "Copy the value of Account key on 127.0.0.1 into SMTP password on 127.0.0.1?", asked)
    agent("answer", **{"with": "no"})
    said = finished(asking)
    check("Not Now leaves the target alone", said.get("error", {}).get("code") == "said_no", said)

    mine = bench({"do": "agents", "action": "persontab", "url": base + "smtp"}).get("tab", "")
    refused = data("carry", TOKEN, "--to", "SMTP password", "--to-tab", mine or "ffffffff", "--tab", source)
    check("carry never goes into the person's tab", not refused.get("ok") and refused.get("error", {}).get("code") in ("not_yours", "no_tab"), refused)
    agent("site", site="127.0.0.1", rule="never")
    never = data("carry", TOKEN, "--to", "SMTP password", "--to-tab", target, "--tab", source)
    check("Never Here on a site refuses", never.get("error", {}).get("code") == "never_here", never)
    agent("site", site="127.0.0.1", rule="")
    agent("mode", mode="auto")


def fill_code(base, port):
    agent("mode", mode="bypass")
    agent("codes", text="Your verification code is " + CODE, sender="Probe Site", address="noreply@127.0.0.1", patience=4)
    tab = opened(base, "code")
    said = data("fill", "code", "--tab", tab)
    check("fill code fills the mailed code", said.get("ok") and "Filled the code" in said["_all"], said)
    check("the answer never holds the digits", CODE not in said["_all"], said)
    landed = data("read", "--tab", tab)["_all"]
    check("the page got the code and was sent", "You are in" in landed and "Code was" in landed, landed)
    check("the digits are sealed on the tab", CODE not in shown(tab), "")
    data("shot", "--tab", tab, "-o", str(ROOT / ".context/carry-code-shot.png"))

    split = opened(base, "split")
    said = data("fill", "code", "--tab", split)
    landed = data("read", "--tab", split)["_all"]
    check("six one-digit boxes take the code", said.get("ok") and "You are in" in landed, (said, landed))

    agent("codes", text="Your verification code is 771122", sender="Elsewhere", address="noreply@other.example", patience=3)
    stranger = opened(base, "code")
    said = data("fill", "code", "--tab", stranger)
    check("a code from another sender is left alone", said.get("error", {}).get("code") == "nothing_kept" and "handoff" in said["_all"], said)

    app = opened(base, "app")
    said = data("fill", "code", "--tab", app)
    check("an authenticator code says so and to hand over", said.get("error", {}).get("code") == "nothing_kept" and "authenticator" in said["_all"] and "handoff" in said["_all"], said)
    sms = opened(base, "sms")
    said = data("fill", "code", "--tab", sms)
    check("a texted code says so and to hand over", said.get("error", {}).get("code") == "nothing_kept" and "text message" in said["_all"], said)

    agent("codes", gmail=False)
    off = opened(base, "code")
    said = data("fill", "code", "--tab", off)
    check("Codes from Gmail off says so", said.get("error", {}).get("code") == "nothing_kept" and "Codes from Gmail is off" in said["_all"], said)
    agent("codes", gmail=True, text="Your verification code is " + CODE, sender="Probe Site", address="noreply@127.0.0.1", patience=4)

    agent("mode", mode="auto")
    other = clean_env(BROADWAY_AGENT="carry-probe-code", BROADWAY_AGENT_NAME="Code Agent")
    fresh = opened(base, "code", env=other)
    asking = later("fill", "code", "--tab", fresh, env=other)
    asked = question()
    note("Fill code, Auto, no sign-in before", asked)
    check("with no sign-in before, it asks", asked and asked["title"] == "Fill the code Gmail received for 127.0.0.1?", asked)
    agent("answer", **{"with": "yes"})
    said = finished(asking)
    check("a yes fills it", said.get("ok"), said)

    agent("logins", kept=[{"host": "127.0.0.1", "port": port, "user": "sam@example.com", "password": "pw-Sam-Kept-Secret", "clear": True}], reset=True)
    agent("mode", mode="bypass")
    signin = opened(base, "form")
    data("fill", "login", "--tab", signin)
    data("go", base + "code", "--tab", signin)
    data("wait", "--tab", signin)
    agent("mode", mode="ask")
    said = data("fill", "code", "--tab", signin)
    check("after this agent's sign-in on the site, no second card", said.get("ok") and no_question(), said)
    agent("mode", mode="auto")


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def mcp_secret(base):
    agent("mode", mode="bypass")
    process = subprocess.Popen([BROADWAY, "--world", WORLD, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                               env=clean_env(MCP_TOKEN=MCPED))
    asked = iter(range(1, 100))

    def send(name, arguments, meta=None):
        params = {"name": name, "arguments": arguments}
        if meta:
            params["_meta"] = meta
        process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": next(asked), "method": "tools/call", "params": params}) + "\n")
        process.stdin.flush()
        return json.loads(process.stdout.readline())

    process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "clientInfo": {"name": "carry-probe", "version": "1"}, "capabilities": {}}}) + "\n")
    process.stdin.flush()
    process.stdout.readline()
    opened_page = json.dumps(send("open", {"url": base + "secret"}))
    tab = (re.search(r'\\?"tab\\?":\s*\\?"([0-9a-f]{8})', opened_page) or [None, ""])[1]
    check("MCP opens a page", bool(tab), opened_page)
    said = json.dumps(send("type", {"tab": tab, "label": "Password", "secret_env": "MCP_TOKEN"}))
    check("MCP types a secret from secret_env", "Typed a secret into Password" in said and '"isError": true' not in said, said)
    check("the MCP answer never holds the value", MCPED not in said, said)
    read = json.dumps(send("text", {"tab": tab}))
    check("the page got it and its echo is sealed over MCP", "You typed" in read and MCPED not in read, read)
    said = json.dumps(send("type", {"tab": tab, "label": "Password", "secret_env": "NOT_SET_HERE"}))
    check("an unset secret_env is refused by broadway mcp", '"isError": true' in said and "NOT_SET_HERE is not set" in said, said)
    said = json.dumps(send("type", {"tab": tab, "label": "Password"}, meta={"com.broadway/secret": "smuggled-Value-1"}))
    read = json.dumps(send("text", {"tab": tab}))
    check("a secret an agent puts in _meta is dropped", '"isError": true' in said and "smuggled-Value-1" not in read, said + read)
    process.stdin.close()
    process.wait(timeout=10)
    agent("mode", mode="auto")


def on_disk():
    places = [FOLDER, Path.home() / f"Library/Preferences/{SUITE}.plist"]
    places += list((Path.home() / "Library/WebKit").glob(f"*{WORLD}*")) + list((Path.home() / "Library/Caches").glob(f"*{WORLD}*"))
    found = {}
    for place in places:
        for path in ([place] if place.is_file() else place.rglob("*") if place.exists() else []):
            if not path.is_file():
                continue
            try:
                body = path.read_bytes()
            except OSError:
                continue
            for name, value in (("HELD", HELD), ("PIPED", PIPED), ("SSHED", SSHED), ("MCPED", MCPED), ("TOKEN", TOKEN), ("CODE", CODE)):
                if value.encode() in body or value.encode("utf-16-le") in body:
                    found.setdefault(name, []).append(str(path.relative_to(Path.home())))
    typed = {name: paths for name, paths in found.items() if name in ("HELD", "PIPED", "SSHED", "MCPED")}
    check("no secret typed by an agent is written to disk", not typed, typed)
    print("on disk, from the pages themselves: " + json.dumps({name: paths for name, paths in found.items() if name not in typed}), flush=True)


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_port
    base = f"http://127.0.0.1:{port}/"
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    only = set(sys.argv[1:])
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        check("the app is up", wait_for(lambda: subprocess.run([BROADWAY, "--world", WORLD, "status"], capture_output=True).returncode == 0, 30) is not None)
        bench({"do": "window"})
        data("agents", "connect", "--name", "Probe Agent")
        for name, run in [("seals", lambda: seals_of_closed_tabs(base, port)), ("type", lambda: over_ssh(base, type_secret(base, port))), ("mcp", lambda: mcp_secret(base)),
                          ("carry", lambda: carry(base, port)), ("code", lambda: fill_code(base, port))]:
            if only and name not in only:
                continue
            print(f"-- {name}", flush=True)
            try:
                run()
            except Exception as error:
                check(f"{name} ran to its end", False, repr(error))
    finally:
        subprocess.run([BROADWAY, "--world", WORLD, "quit", "--force"], capture_output=True)
        for _ in range(40):
            if not held():
                break
            time.sleep(0.25)
        for pid in held():
            os.kill(int(pid), signal.SIGKILL)
        on_disk()
        shutil.rmtree(FOLDER, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
        server.shutdown()
    CARDS.parent.mkdir(parents=True, exist_ok=True)
    CARDS.write_text("\n\n".join(cards) + "\n")
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
