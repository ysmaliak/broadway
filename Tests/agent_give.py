#!/usr/bin/env python3
import json
import os
import secrets
import signal
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Broadway.app"
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"agentgive-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
OUT = Path(os.environ.get("AGENT_GIVE_OUT", ROOT / ".context/give"))
SITE = "example.com"
PASSWORDS = {"sam@example.com": "Give-" + secrets.token_hex(6), "work@example.com": "Work-" + secrets.token_hex(6)}

failures = []
cards = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail, flush=True)
    if not ok:
        failures.append(name)


def clean_env(**more):
    environment = {k: v for k, v in os.environ.items() if k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "BROADWAY_TAB", "SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY")}
    environment.update({"BROADWAY_AGENT": "give-probe", "BROADWAY_AGENT_NAME": "Probe Agent"})
    environment.update(more)
    return environment


def broadway(*words, timeout=60, env=None):
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True,
                          stdin=subprocess.DEVNULL, env=env or clean_env(), timeout=timeout)


def data(*words, env=None):
    result = broadway(*words, "--json", env=env)
    try:
        found = json.loads(result.stdout)
    except ValueError:
        found = {"ok": False, "raw": result.stdout}
    found["_all"] = result.stdout + result.stderr
    return found


def later(*words, json_out=True):
    flags = ["--json"] if json_out else []
    return subprocess.Popen([BROADWAY, "--world", WORLD, *words, *flags, "--wait-person", "1"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, stdin=subprocess.DEVNULL, env=clean_env())


def finished(process, raw=False):
    out, err = process.communicate(timeout=40)
    if raw:
        return {"out": out, "err": err, "code": process.returncode}
    try:
        found = json.loads(out)
    except ValueError:
        found = {"ok": False, "raw": out}
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


def raw_request(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(20)
        s.connect(str(FOLDER / "broadway.sock"))
        s.sendall((json.dumps(request) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
    lines = [line for line in b"".join(chunks).split(b"\n") if line.strip()]
    replies = [json.loads(line) for line in lines]
    return next((reply for reply in replies if "event" not in reply), replies[-1] if replies else {})


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


def no_question():
    time.sleep(0.5)
    return not agent("questions").get("questions")


def note(name, asked, picture=None):
    card = (asked or {}).get("card", {})
    cards.append(f"{name}\n  title: {card.get('title', '')}\n  who: {card.get('who', '')}\n  line: {card.get('body', '')}\n  signer: {card.get('signer', '')}\n  rows: {card.get('choices', [])}\n  quote: {asked.get('label', '') if asked else ''}: {asked.get('quote', '') if asked else ''}\n  picture: {picture or 'none'}")


def shoot(name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    window = agent("stage", size=[1200, 800]).get("window")
    if not window:
        return None
    said = ""
    for _ in range(4):
        said = subprocess.run(["screencapture", "-x", "-o", "-l", str(window), str(path)], capture_output=True, text=True).stderr
        if path.exists() and path.stat().st_size > 0:
            return str(path)
        time.sleep(0.5)
    print(f"  no picture of window {window} for {name}: {said.strip()}", flush=True)
    return None


def keep(users):
    agent("logins", kept=[{"host": SITE, "user": user, "password": PASSWORDS[user], "clear": False} for user in users], reset=True)


def leaked(text):
    return [user for user, password in PASSWORDS.items() if password in text]


def switch_off():
    keep(["sam@example.com"])
    kept = data("logins", "give", SITE)
    keep([])
    empty = data("logins", "give", SITE)
    error = kept.get("error") or {}
    check("off: person_only", error.get("code") == "person_only", kept)
    check("off: the hint names the switch", "Settings › Agents › Let agents ask for a saved password" in error.get("hint", ""), kept)
    check("off: the same answer kept or not", kept.get("error") == empty.get("error"), (kept, empty))
    check("off: no card", no_question(), agent("questions"))
    refused = data("settings", "set", "agents.give", "true")
    check("an agent can't turn the switch on", (refused.get("error") or {}).get("code") == "person_only", refused)
    shown = data("settings", "get", "agents.give")
    check("the switch reads off", "false" in json.dumps(shown.get("data", {})).lower(), shown)


def turn_on():
    said = bench({"do": "settings", "set": "agents.give", "value": True})
    check("the person turns the switch on", (said.get("values") or {}).get("agents.give") in (True, "true", 1) or "error" not in said, said)


def one_account():
    keep(["sam@example.com"])
    asking = later("logins", "give", SITE)
    asked = question()
    picture = shoot("give-one")
    note("One account, Auto", asked, picture)
    card = (asked or {}).get("card", {})
    check("the card asks to give the password", card.get("title") == f"Give Probe Agent the password for {SITE}?", asked)
    check("the card says it can read it", card.get("body") == "It will be able to read the password of sam@example.com", asked)
    check("the card quotes the command", "logins give" in (asked or {}).get("quote", ""), asked)
    agent("answer", **{"with": "yes"})
    said = finished(asking)
    got = said.get("data") or {}
    check("a yes and Touch ID give the user and the password", said.get("ok") and got.get("user") == "sam@example.com" and got.get("password") == PASSWORDS["sam@example.com"], said)
    check("no second card", no_question(), agent("questions"))


def every_mode():
    keep(["sam@example.com"])
    for mode in ("bypass", "ask"):
        agent("mode", mode=mode)
        asking = later("logins", "give", SITE)
        asked = question()
        check(f"{mode} asks too", asked is not None, asked)
        agent("answer", **{"with": "no"})
        said = finished(asking)
        check(f"{mode}: Not Now gives nothing", (said.get("error") or {}).get("code") == "said_no" and not leaked(said["_all"]), said)
    agent("mode", mode="auto")


def several():
    keep(["sam@example.com", "work@example.com"])
    asking = later("logins", "give", SITE)
    asked = question()
    picture = shoot("give-several")
    note("Several accounts", asked, picture)
    card = (asked or {}).get("card", {})
    check("several accounts are rows", card.get("choices") == ["sam@example.com", "work@example.com"], asked)
    listed = data("approvals", "list")
    check("approvals list names no account", not any(user in listed["_all"] for user in PASSWORDS), listed)
    agent("answer", **{"with": "1"})
    said = finished(asking)
    check("a pick gives that account", (said.get("data") or {}).get("password") == PASSWORDS["work@example.com"], said)


def output_forms():
    keep(["sam@example.com"])
    asking = later("logins", "give", SITE, "--password-only", json_out=False)
    question()
    agent("answer", **{"with": "yes"})
    said = finished(asking, raw=True)
    check("--password-only prints the password alone with no line end in a pipe", said["code"] == 0 and said["out"] == PASSWORDS["sam@example.com"], said)
    check("--password-only puts nothing of it on standard error", not leaked(said["err"]), said)
    asking = later("logins", "give", SITE, json_out=False)
    question()
    agent("answer", **{"with": "yes"})
    said = finished(asking, raw=True)
    check("plain output is the user name, then the password", said["out"] == f"sam@example.com\n{PASSWORDS['sam@example.com']}\n", said)
    bad = broadway("logins", "give", SITE, "--password-only", "--json")
    check("--password-only with --json is a usage error", bad.returncode == 2 and not leaked(bad.stdout), bad)


def touch_id_refused():
    keep(["sam@example.com"])
    bench({"do": "ui", "confirm": False})
    asking = later("logins", "give", SITE)
    question()
    agent("answer", **{"with": "yes"})
    said = finished(asking)
    bench({"do": "ui", "confirm": True})
    check("without Touch ID nothing is given", (said.get("error") or {}).get("code") == "said_no" and not leaked(said["_all"]), said)


def fresh_caller():
    keep(["sam@example.com"])
    session = "give-" + secrets.token_hex(8)
    environment = {k: v for k, v in clean_env().items() if k not in ("BROADWAY_AGENT", "BROADWAY_AGENT_NAME")}
    environment["CLAUDE_CODE_SESSION_ID"] = session
    process = subprocess.Popen([BROADWAY, "--world", WORLD, "logins", "give", SITE, "--password-only"], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, stdin=subprocess.DEVNULL, env=environment)
    asked = question()
    picture = shoot("give-fresh")
    note("A program that never used Broadway, no --wait-person", asked, picture)
    listed = data("agents", "list")
    check("a program that never used Broadway still gets a card", asked is not None, (asked, process.poll()))
    agent("answer", **{"with": "yes"})
    out, err = process.communicate(timeout=40)
    check("and its password with no --wait-person", process.returncode == 0 and out == PASSWORDS["sam@example.com"], (process.returncode, out, err))
    check("its session is listed", session[:8] in json.dumps(listed) or len((listed.get("data") or {}).get("agents", [])) > 1, listed)
    print("  the fresh session: " + json.dumps((listed.get("data") or {}).get("agents", [])), flush=True)


def not_in_batch():
    keep(["sam@example.com"])
    said = data("batch", "logins give example.com")
    check("a batch line can't give a password and says why", not said.get("ok") and said["error"]["code"] == "person_only" and "never as a step" in said["error"]["message"] and not leaked(said["_all"]), said)
    scripted = data("run", 'print(logins_give("example.com"))')
    check("a broadway run script can't give a password and says why", not scripted.get("ok") and scripted["error"]["code"] == "person_only" and "in a script" in scripted["error"]["message"] and not leaked(scripted["_all"]), scripted)
    check("no card from a batch or a script", no_question(), agent("questions"))
    look = data("settings", "get", "look")["data"]["value"]
    other = "light" if look == "dark" else "dark"
    one = data("settings", "set", "agents.give", "false")
    several = data("settings", "set", "look", other, "agents.give", "false")
    listed = data("settings", "list", "--can-set")
    ids = [item.get("id") for item in (listed.get("data") or {}).get("settings", [])]
    check("settings set can't touch the switch", not one.get("ok") and one["error"]["code"] == "person_only", one)
    check("settings set with the switch among several changes nothing", not several.get("ok") and several["error"]["code"] == "person_only" and data("settings", "get", "look")["data"]["value"] == look, several)
    check("settings list --can-set leaves the switch out", "look" in ids and "agents.give" not in ids, ids)
    check("the switch is still on", str(data("settings", "get", "agents.give")["data"]["value"]).lower() == "true", data("settings", "get", "agents.give"))


def from_elsewhere():
    keep(["sam@example.com"])
    over = data("logins", "give", SITE, env=clean_env(SSH_CONNECTION="10.0.0.2 51000 10.0.0.1 22"))
    check("over ssh the command refuses", (over.get("error") or {}).get("code") == "person_only" and "Only on the Mac" in over["_all"], over)
    forwarded = raw_request({"op": "do", "noun": "logins", "verb": "give", "arguments": {"site": SITE}, "wait": 30,
                             "agent": {"id": "give-probe", "name": "Probe Agent", "remote": True}})
    check("a forwarded request is refused", (forwarded.get("error") or {}).get("code") == "person_only", forwarded)
    check("no card from elsewhere", no_question(), agent("questions"))


def mcp_more():
    process = subprocess.Popen([BROADWAY, "--world", WORLD, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True, env=clean_env())
    def send(message):
        process.stdin.write(json.dumps(message) + "\n")
        process.stdin.flush()
    def reply(wanted):
        while True:
            line = process.stdout.readline()
            if not line:
                return {}
            found = json.loads(line)
            if found.get("id") == wanted:
                return found
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "1"}}})
    reply(1)
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    def call(n, name, arguments):
        send({"jsonrpc": "2.0", "id": n, "method": "tools/call", "params": {"name": name, "arguments": arguments}})
        return json.dumps(reply(n))
    first = call(2, "logins_give", {"site": SITE})
    said = call(3, "more_tools", {"query": "logins give"})
    called = call(4, "logins_give", {"site": SITE})
    batched = call(5, "batch", {"steps": [{"tool": "logins_give", "arguments": {"site": SITE}}]})
    scripted = call(6, "run", {"code": 'print(logins_give("' + SITE + '"))'})
    scripted_too = call(7, "run", {"code": 'print(give("' + SITE + '"))'})
    look = data("settings", "get", "look")["data"]["value"]
    other = "light" if look == "dark" else "dark"
    one = call(8, "settings_set", {"setting": "agents.give", "value": "false"})
    several = call(9, "settings_set", {"setting": "look", "value": other, "values": ["agents.give", "false"]})
    process.stdin.close()
    process.wait(timeout=10)
    def refused(text, why):
        return '"isError": true' in text and "person_only" in text and why in text and not leaked(text)
    check("logins_give over MCP is refused and says why", refused(first, "never given over MCP"), first)
    check("more_tools says why there is no give over MCP", "never given over MCP" in said and '"logins_give"' not in said, said)
    check("logins_give after more_tools is still refused", refused(called, "never given over MCP"), called)
    check("an MCP batch step can't give a password", refused(batched, "never given over MCP"), batched)
    check("an MCP run script can't call logins_give", refused(scripted, "never as a step or in a script"), scripted)
    check("an MCP run script can't call give", refused(scripted_too, "never as a step or in a script"), scripted_too)
    check("settings_set can't touch the switch", refused(one, "only be changed by the person"), one)
    check("settings_set with the switch among several changes nothing", refused(several, "Nothing was changed") and data("settings", "get", "look")["data"]["value"] == look, several)
    check("the switch is still on after MCP", str(data("settings", "get", "agents.give")["data"]["value"]).lower() == "true", data("settings", "get", "agents.give"))
    check("no card from MCP", no_question(), agent("questions"))


def on_disk():
    places = [FOLDER, Path.home() / f"Library/Preferences/{SUITE}.plist"]
    places += list((Path.home() / "Library/WebKit").glob(f"*{WORLD}*")) + list((Path.home() / "Library/Caches").glob(f"*{WORLD}*"))
    found = []
    for place in places:
        for path in ([place] if place.is_file() else place.rglob("*") if place.exists() else []):
            if not path.is_file():
                continue
            try:
                body = path.read_bytes()
            except OSError:
                continue
            for value in PASSWORDS.values():
                if value.encode() in body or value.encode("utf-16-le") in body:
                    found.append(str(path.relative_to(Path.home())))
    check("no given password is written to the test world's files", not found, found)
    status = data("agents", "status")
    check("agents status holds no password", not leaked(status["_all"]), status)


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        check("the app is up", wait_for(lambda: subprocess.run([BROADWAY, "--world", WORLD, "status"], capture_output=True).returncode == 0, 30) is not None)
        bench({"do": "window"})
        bench({"do": "ui", "confirm": True})
        data("agents", "connect", "--name", "Probe Agent")
        agent("mode", mode="auto")
        switch_off()
        turn_on()
        one_account()
        every_mode()
        several()
        output_forms()
        touch_id_refused()
        fresh_caller()
        not_in_batch()
        from_elsewhere()
        mcp_more()
        on_disk()
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
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "cards.txt").write_text("\n\n".join(cards) + "\n")
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
