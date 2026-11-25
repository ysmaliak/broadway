#!/usr/bin/env python3
import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("BROADWAY_APP", ROOT / "build/Broadway.app"))
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"agentsigner-{os.getpid()}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
SCRATCH = Path(tempfile.mkdtemp(prefix="broadway-signer-"))
HOST = SCRATCH / "claude"
OUT = ROOT / ".context/agent-signer-cards.json"

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:600], flush=True)
    if not ok:
        failures.append(name)


def bench(request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(60)
        s.connect(str(FOLDER / "bench.sock"))
        s.sendall((json.dumps(request) + "\n").encode())
        chunks = []
        while True:
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            chunks.append(chunk)
    return json.loads(b"".join(chunks).split(b"\n", 1)[0] or b"{}")


def wait_for(probe, seconds):
    end = time.time() + seconds
    while time.time() < end:
        found = probe()
        if found:
            return found
        time.sleep(0.2)
    return None


def environment(session=None):
    kept = {k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_") and k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "SSH_CONNECTION", "SSH_CLIENT")}
    if session:
        kept["CLAUDE_CODE_SESSION_ID"] = f"signer-{os.getpid()}-{session}"
    return kept


def command(*words):
    return " ".join(shlex.quote(w) for w in [BROADWAY, "--world", WORLD, *words, "--json"])


def card(question):
    up = wait_for(lambda: [c for c in bench({"do": "knowing", "action": "desk"}).get("pending", []) if c.get("title") == question], 20)
    bench({"do": "knowing", "action": "desk", "text": "pick 1"})
    return (up or [{}])[0].get("card", {})


def card_while_asking(launch, question):
    asking = subprocess.Popen(launch, env=environment(), cwd=SCRATCH, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    found = card(question)
    asking.wait(timeout=60)
    return found


class Agent:
    def __init__(self, session):
        self.process = subprocess.Popen([str(HOST), "/bin/sh", "-c", 'while IFS= read -r line; do eval "$line"; done'], cwd=SCRATCH,
                                        env=environment(session), stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, text=True)
        self.count = 0

    def run(self, *words):
        self.count += 1
        out = SCRATCH / f"agent-{self.count}.json"
        self.process.stdin.write(f"{command(*words)} > {shlex.quote(str(out))} 2>&1 < /dev/null\n")
        self.process.stdin.flush()
        return out

    def ask(self, question):
        self.run("ask", question, "--choice", "One", "--choice", "Two", "--seconds", "30")
        return card(question)

    def stop(self):
        self.process.stdin.close()
        self.process.wait(timeout=30)


def asked(words):
    return ["/bin/sh", "-c", command("ask", words, "--choice", "One", "--choice", "Two", "--seconds", "30")]


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    subprocess.run(["cc", "-O2", "-o", str(HOST), str(ROOT / "Tests/agent_host.c")], check=True)
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    cards = {}
    try:
        for key in ("bench", "agents.on"):
            subprocess.run(["defaults", "write", SUITE, key, "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.mode", "-string", "auto"], check=True)
        subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", str(APP)], check=True)
        check("a test world is up", wait_for(lambda: (FOLDER / "bench.sock").exists(), 40))
        time.sleep(2)
        bench({"do": "window"})

        agent = Agent("fake")
        fake = agent.ask("Which one, fake?")
        cards["fake claude"] = fake
        check("a program called claude that is not Anthropic's is named plainly on its first question",
              fake.get("signer") == "Calls itself Claude Code, not signed", fake)
        again = agent.ask("Which one, again?")
        cards["fake claude, second question"] = again
        check("a later question from the same session leaves the line out", again.get("signer", "") == "", again)

        found = card_while_asking(["/usr/bin/find", str(SCRATCH), "-maxdepth", "0", "-exec", *asked("Which one, find?"), ";"], "Which one, find?")
        cards["find"] = found
        check("a system program is signed by Apple", found.get("signer") == "Find, signed by Apple", found)

        script = f"import subprocess; subprocess.run({asked('Which one, python?')!r})"
        python = card_while_asking(["/usr/bin/python3", "-c", script], "Which one, python?")
        cards["python"] = python
        check("a script run by an interpreter shows no signer", python.get("signer", "") == "" and python.get("title"), python)

        listed = agent.run("agents", "list")
        wait_for(lambda: listed.exists() and listed.read_text().strip().endswith("}"), 20)
        rows = json.loads(listed.read_text() or "{}").get("data", {}).get("agents", [])
        agent.stop()
        cards["agents list"] = rows
        check("agents list carries the line as program", any(r.get("program") == "Calls itself Claude Code, not signed" for r in rows), rows)
    finally:
        OUT.parent.mkdir(parents=True, exist_ok=True)
        OUT.write_text(json.dumps(cards, indent=2))
        try:
            bench({"do": "quit"})
        except OSError:
            pass
        time.sleep(2)
        for pid in subprocess.run(["lsof", "-t", "--", str(FOLDER / "bench.sock")], capture_output=True, text=True).stdout.split():
            subprocess.run(["kill", pid], capture_output=True)
        shutil.rmtree(FOLDER, ignore_errors=True)
        shutil.rmtree(SCRATCH, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good", flush=True)
    sys.exit(1 if failures else 0)


main()
