#!/usr/bin/env python3
"""Turning agents on sets up Claude Code and Codex, against an invented home only.

Build first (`./build.sh`), then `python3 Tests/agent_setup.py`. A test copy in a
world of its own, started with BROADWAY_HOME pointing at a temporary folder that
holds made-up ~/.claude and ~/.codex folders:

1. Agents off at launch: nothing is added, and a hook that fires is quiet and exits 0.
2. Turning agents on adds the skill and both hooks to both tools, keeps the mark, and
   the Settings row for the broadway command says so without reopening the page.
   With nothing at .local/bin/broadway it links the build's helper there, and the
   hook as written in settings.json reaches Broadway through that link.
3. Agents already on with no mark: setup runs once at launch and leaves the link as it is.
4. After broadway remove claude codex, a relaunch adds nothing.
5. Turning agents off leaves the files alone, and on again adds them again, leaving a
   link that points somewhere else as it is.
6. An update for someone set up before Cursor, opencode and Gemini CLI were covered:
   the first launch writes opencode's skill once, the Settings row reads no fault, a
   relaunch runs nothing, and a skill then removed by hand stays removed.

Nothing under the real home is opened. Its broadway files are compared by stat only.
"""
import json
import os
import secrets
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("BROADWAY_APP", ROOT / "build/Broadway.app"))
BROADWAY = str(APP / "Contents/Helpers/broadway")
WORLD = f"agentsetup-{os.getpid()}-{secrets.token_hex(3)}"
FOLDER = Path.home() / f"Library/Application Support/Broadway ({WORLD})"
SUITE = f"com.ysmaliak.broadway.test.{WORLD}"
SESSION = "0a1b2c3d-0000-4000-8000-0000000005e7"
LINKED = "0a1b2c3d-0000-4000-8000-0000000005e8"
ELSEWHERE = "/tmp/invented-elsewhere/broadway"
FOREIGN = '{\n    "model": "opus",\n    "hooks": {\n        "Stop": [\n            {\n                "hooks": [{"type": "command", "command": "say done"}]\n            }\n        ]\n    }\n}'
WATCHED = [".claude/settings.json", ".claude/skills/broadway/SKILL.md", ".codex/hooks.json",
           ".codex/skills/broadway/SKILL.md", ".local/bin/broadway", ".cursor/skills/broadway/SKILL.md",
           ".config/opencode/skills/broadway/SKILL.md", ".gemini/skills/broadway/SKILL.md"]

failures = []
passed = [0]


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:600], flush=True)
    if ok:
        passed[0] += 1
    else:
        failures.append(name)


def real_home():
    seen = {}
    for name in WATCHED:
        try:
            info = os.lstat(Path.home() / name)
            seen[name] = (info.st_mtime_ns, info.st_size, info.st_ino)
        except FileNotFoundError:
            seen[name] = None
    return seen


def clean_env(more):
    environment = {k: v for k, v in os.environ.items()
                   if not k.startswith("BROADWAY_") and k not in ("CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID")}
    environment.update(more)
    return environment


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.2)
    return None


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


def settings(**more):
    return bench(dict({"do": "settings"}, **more))


def setup_state():
    return settings(find="agents").get("agentSetup", {})


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def defaults(key):
    return subprocess.run(["defaults", "read", SUITE, key], capture_output=True, text=True).stdout.strip()


def launch(home):
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", "--env", f"BROADWAY_HOME={home}", str(APP)], check=True)
    up = wait_for(lambda: subprocess.run([BROADWAY, "--world", WORLD, "status"], capture_output=True, env=clean_env({})).returncode == 0, 30)
    check("the app is up", up is not None)
    bench({"do": "window"})


def quit():
    subprocess.run([BROADWAY, "--world", WORLD, "quit", "--force"], capture_output=True, env=clean_env({}))
    for _ in range(40):
        if not held():
            break
        time.sleep(0.25)
    for pid in held():
        os.kill(int(pid), signal.SIGKILL)
    time.sleep(0.5)


class Home:
    def __init__(self, folder):
        self.folder = folder
        (folder / ".claude").mkdir(parents=True)
        (folder / ".codex").mkdir(parents=True)
        self.settings = folder / ".claude/settings.json"
        self.settings.write_text(FOREIGN)
        self.codex = folder / ".codex/hooks.json"
        self.claude_skill = folder / ".claude/skills/broadway/SKILL.md"
        self.codex_skill = folder / ".codex/skills/broadway/SKILL.md"
        self.link = folder / ".local/bin/broadway"

    def everything(self):
        return {str(path.relative_to(self.folder)): path.read_bytes() for path in sorted(self.folder.rglob("*")) if path.is_file()}

    def set_up(self):
        if not (self.claude_skill.exists() and self.codex_skill.exists() and self.codex.exists()):
            return False
        claude = json.loads(self.settings.read_text())
        codex = json.loads(self.codex.read_text())
        mine = "agents idle --hook"
        return (all(mine + " claude" in json.dumps(claude["hooks"].get(event, [])) for event in ("Stop", "SessionEnd"))
                and all(mine + " codex" in json.dumps(codex["hooks"].get(event, [])) for event in ("Stop", "SessionEnd"))
                and "say done" in json.dumps(claude["hooks"]["Stop"]))

    def bare(self):
        return (self.settings.read_text() == FOREIGN and not self.claude_skill.exists() and not self.codex_skill.exists()
                and not self.codex.exists())

    def held_link(self):
        try:
            info = os.lstat(self.link)
            return (os.readlink(self.link), info.st_ino)
        except (FileNotFoundError, OSError):
            return None

    def stop_hook(self):
        stops = json.loads(self.settings.read_text())["hooks"]["Stop"]
        return next(hook["command"] for entry in stops for hook in entry["hooks"] if "agents idle --hook claude" in hook["command"])

    def remove(self):
        return subprocess.run([BROADWAY, "remove", "claude", "codex", "--json"], capture_output=True, text=True,
                              env=clean_env({"BROADWAY_HOME": str(self.folder)}))


def hook_while_off():
    payload = json.dumps({"session_id": SESSION, "transcript_path": "/tmp/invented.jsonl", "cwd": "/tmp", "hook_event_name": "Stop"})
    started = time.time()
    result = subprocess.run([BROADWAY, "--world", WORLD, "agents", "idle", "--hook", "claude"], capture_output=True, text=True,
                            env=clean_env({}), input=payload, timeout=20)
    took = time.time() - started
    check("a hook firing while agents are off exits 0 and prints nothing",
          result.returncode == 0 and result.stdout == "" and result.stderr == "" and took < 5, (result, took))
    area = bench({"do": "agents", "action": "state"}).get("area", [])
    check("and leaves no card", not area, area)


def hook_through_link(home):
    opened = subprocess.run([BROADWAY, "--world", WORLD, "open", "about:blank", "--json"], capture_output=True, text=True,
                            env=clean_env({"CLAUDE_CODE_SESSION_ID": LINKED, "BROADWAY_AGENT_NAME": "Claude Code"}),
                            stdin=subprocess.DEVNULL, timeout=60)
    found = wait_for(lambda: next((row for row in bench({"do": "agents", "action": "state"}).get("area", []) if row["name"] == "Claude Code"), None), 10)
    check("an invented Claude Code session has a card", found is not None, opened.stdout + opened.stderr)
    if not found:
        return
    payload = json.dumps({"session_id": LINKED, "transcript_path": "/tmp/invented.jsonl", "cwd": "/tmp", "hook_event_name": "Stop",
                          "stop_hook_active": False, "background_tasks": [], "session_crons": []})
    command = home.stop_hook()
    result = subprocess.run(["/bin/sh", "-c", command], capture_output=True, text=True, input=payload, timeout=20,
                            env=clean_env({"HOME": str(home.folder), "BROADWAY_SOCKET": str(FOLDER / "broadway.sock")}))
    check("the Stop hook as written exits 0 and prints nothing", result.returncode == 0 and result.stdout == "" and result.stderr == "", (command, result))
    finished = wait_for(lambda: next((row for row in bench({"do": "agents", "action": "state"}).get("area", [])
                                      if row["id"] == found["id"] and row["status"].startswith("Finished")), None), 8)
    check("and reaches Broadway through the new link, so the card reads finished", finished is not None,
          bench({"do": "agents", "action": "state"}).get("area"))


def command_row():
    return (settings(row="ai.command").get("row") or {}).get("detail", "")


def open_agents_page():
    bench({"do": "ui", "settings": True})
    time.sleep(1.2)
    bench({"do": "ui", "settingsPage": "agents"})


def update_stage(home):
    quit()
    home.link.unlink()
    os.symlink(BROADWAY, home.link)
    opencode = home.folder / ".config/opencode"
    opencode.mkdir(parents=True)
    skill = opencode / "skills/broadway/SKILL.md"
    subprocess.run(["defaults", "write", SUITE, "agents.setUp", "-bool", "true"], check=True)
    subprocess.run(["defaults", "delete", SUITE, "agents.setUpFor"], capture_output=True)
    launch(home.folder)
    ran = wait_for(lambda: setup_state().get("runs") == 1, 20)
    check("marked by an earlier version: the first launch brings the newer agents once", ran is not None, setup_state())
    check("and opencode gets Broadway's skill", wait_for(skill.exists, 5) is not None, home.everything().keys())
    check("and Cursor and Gemini CLI, with no folder here, get nothing",
          not (home.folder / ".cursor").exists() and not (home.folder / ".gemini").exists(), home.everything().keys())
    check("and the covered agents are kept", "opencode" in defaults("agents.setUpFor"), defaults("agents.setUpFor"))
    open_agents_page()
    row = wait_for(lambda: (lambda d: d if d.startswith("On your PATH") else None)(command_row()), 15)
    print("     row now reads:", row, flush=True)
    check("the Settings row calls no absent skill a fault", row is not None and "SKILL.md isn't there" not in row and "opencode/" not in row, row)
    check("and shows no full home path", row is not None and str(home.folder) not in row, row)
    switch = settings(row="ai.agents").get("row") or {}
    print(f"     the switch's line takes {switch.get('detailLines')} lines at {switch.get('detailWidth')} pt:", switch.get("detail"), flush=True)
    check("the switch says what it does",
          switch.get("detail") == "Turning it on adds Broadway's skill to the coding agents on this Mac, and hooks to Claude Code and Codex", switch)
    quit()

    launch(home.folder)
    time.sleep(3)
    again = setup_state()
    check("a relaunch after the update runs no setup", again.get("runs") == 0, again)
    quit()

    skill.unlink()
    launch(home.folder)
    time.sleep(3)
    removed = setup_state()
    check("a skill removed by hand after the update is not written again", removed.get("runs") == 0 and not skill.exists(),
          (removed, home.everything().keys()))
    open_agents_page()
    row = wait_for(lambda: (lambda d: d if d.startswith("On your PATH") else None)(command_row()), 15)
    print("     row now reads:", row, flush=True)
    check("and the row still calls no absent skill a fault", row is not None and "SKILL.md isn't there" not in row and "opencode" not in row, row)
    check("and shows no full home path", row is not None and str(home.folder) not in row, row)


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    before = real_home()
    scratch = Path(tempfile.mkdtemp(prefix="agent-setup-"))
    home = Home(scratch / "home")
    shutil.rmtree(FOLDER, ignore_errors=True)
    subprocess.run(["defaults", "delete", SUITE], capture_output=True)
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "false"], check=True)

        launch(home.folder)
        first = setup_state()
        check("with BROADWAY_HOME set, the test world's guard is open", first.get("open") is True, first)
        time.sleep(3)
        first = setup_state()
        check("agents off at launch: setup does not run", first.get("runs") == 0 and first.get("on") is False and first.get("marked") is False, first)
        check("and nothing is added", home.bare(), home.everything().keys())
        hook_while_off()

        bench({"do": "ui", "settings": True})
        time.sleep(1.2)
        bench({"do": "ui", "settingsPage": "agents"})
        shown = wait_for(lambda: (lambda d: d if d and "Run tasks" not in d else None)(command_row()), 15)
        check("Settings › Agents shows the broadway command row", shown is not None and "Broadway's skill" not in shown, shown)

        turned = settings(set="ai.agents", value=True).get("agentSetup", {})
        check("the switch goes on", turned.get("on") is True and turned.get("marked") is True, turned)
        ran = wait_for(lambda: setup_state().get("runs") == 1, 20)
        check("turning agents on runs setup once", ran is not None, setup_state())
        check("the skill and both hooks are in both tools, and the person's own hook is kept", home.set_up(), home.everything().keys())
        linked = home.held_link()
        check("with nothing there, the command is linked to the build's helper",
              linked is not None and os.path.realpath(home.link) == os.path.realpath(BROADWAY), (linked, BROADWAY))
        check("and no completions are written",
              not (home.folder / ".config").exists() and not (home.folder / ".local/share").exists(), home.everything().keys())
        check("the mark is kept in the store", defaults("agents.setUp") == "1", defaults("agents.setUp"))
        fresh = wait_for(lambda: (lambda d: d if d != shown and "Run tasks" not in d else None)(command_row()), 15)
        print("     row now reads:", fresh, flush=True)
        check("the Settings row shows the new state without reopening the page",
              fresh is not None and fresh.startswith("On your PATH"), command_row())
        hook_through_link(home)
        quit()

        removed = home.remove()
        check("remove takes it all back out", removed.returncode == 0 and home.bare(), removed.stdout + removed.stderr)
        subprocess.run(["defaults", "delete", SUITE, "agents.setUp"], check=True)
        launch(home.folder)
        ran = wait_for(lambda: setup_state().get("runs") == 1, 20)
        check("agents already on and no mark: setup runs once at launch", ran is not None, setup_state())
        check("and adds the skill and hooks", wait_for(home.set_up, 5) is not None, home.everything().keys())
        check("and keeps the mark", setup_state().get("marked") is True and defaults("agents.setUp") == "1", setup_state())
        check("and leaves the link there as it was", home.held_link() == linked, (home.held_link(), linked))
        quit()

        removed = home.remove()
        check("the person removes it with broadway remove", removed.returncode == 0 and home.bare(), removed.stdout + removed.stderr)
        launch(home.folder)
        time.sleep(3)
        again = setup_state()
        check("with the mark kept, a relaunch does not run setup", again.get("on") is True and again.get("runs") == 0, again)
        check("and adds nothing", home.bare(), home.everything().keys())

        off = settings(set="ai.agents", value=False).get("agentSetup", {})
        time.sleep(2)
        check("turning agents off runs nothing and leaves the files", off.get("on") is False and setup_state().get("runs") == 0 and home.bare(),
              (setup_state(), home.everything().keys()))
        hook_while_off()
        home.link.unlink()
        os.symlink(ELSEWHERE, home.link)
        elsewhere = home.held_link()
        settings(set="ai.agents", value=True)
        ran = wait_for(lambda: setup_state().get("runs") == 1, 20)
        check("off then on again runs setup again", ran is not None, setup_state())
        check("and the skill and hooks are back", home.set_up(), home.everything().keys())
        check("a link that points somewhere else is left as it was", home.held_link() == elsewhere and elsewhere[0] == ELSEWHERE,
              (home.held_link(), elsewhere))
        update_stage(home)
    finally:
        quit()
        shutil.rmtree(FOLDER, ignore_errors=True)
        shutil.rmtree(scratch, ignore_errors=True)
        subprocess.run(["defaults", "delete", SUITE], capture_output=True)
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    after = real_home()
    check("nothing under the real home changed (stat only)", before == after,
          {name: (before[name], after[name]) for name in WATCHED if before[name] != after[name]})
    print(f"{passed[0]} passed, {len(failures)} failed")
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
