#!/usr/bin/env python3
"""How well a model agent uses the broadway command, measured on invented sites.

    python3 Tests/agent_field.py                   the offline self-test, also run by run-probes
    python3 Tests/agent_field.py run [options]     the field: one fresh world and one fresh agent per task
    python3 Tests/agent_field.py table DIR         the summary table again, from a finished run
    python3 Tests/agent_field.py serve             the fixture sites alone, to look at by hand

Build first with ./build.sh. Each task gets a fresh test world of build/Broadway.app, two invented sites
served on this machine's loopback, and a fresh headless agent (claude -p) that is given the task sentence,
the text of broadway guide and a broadway on its PATH. That broadway is a shim: it logs the call and runs the
real command against the test world's socket, never the real browser. With --host the world and the sites
run on that Mac over one shared ssh connection while the agent runs here, so the agent's machine stays free.
"""

import argparse
import base64
import collections
import fcntl
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests" / "AgentFieldFixtures"
sys.path.insert(0, str(FIXTURES))

from sites import Field, multipart, serve  # noqa: E402
from tasks import BY_NAME, TASKS  # noqa: E402

APP = ROOT / "build" / "Broadway.app"
BROADWAY = APP / "Contents" / "Helpers" / "broadway"
BENCH = ROOT / "bench"
PREFIX = "/tmp/agent-field-"
AGENT_NAME = "Claude Code"
PERSON_DELAY = 2.0
WITH_VALUE = {"--socket", "--world", "--tab", "-o", "--output", "--timeout"}
BARE_GLOBALS = {"--json", "-q", "--quiet", "--no-color", "-h", "--help", "-V", "--version"}
NOUNS = {"spaces", "space", "tabs", "folders", "groups", "split", "windows", "bookmarks", "downloads", "files", "history",
         "tasks", "live", "logins", "fill", "page", "site", "settings", "shortcuts", "extensions", "shields", "permissions",
         "skills", "replies", "now", "plans", "agents", "agent", "approvals", "helpers", "session"}
ALIASES = {"navigate": "go", "text": "read", "screenshot": "shot", "agent": "agents", "find": "page find", "zoom": "page zoom",
           "pdf": "pdf", "translate": "page translate"}
LOOKS = {"snapshot", "read", "shot", "locate", "tabs", "tabs list", "tabs show", "page info", "page find", "console", "network",
         "dialog", "agents status", "downloads list", "files list"}
ACTIONS = {"click", "type", "press", "choose", "fill", "select", "scroll", "hover", "drag", "upload", "download", "go", "open",
           "close", "resize", "dialog accept", "dialog dismiss", "fill login", "fill details", "fill card", "page back",
           "page forward", "page reload", "tabs close", "tabs new"}
REFUSED_VERBS = {"setup", "remove", "serve", "mcp", "quit", "completions"}
FAILURES = [
    ("older snapshot", "stale_ref"), ("left the page", "stale_ref"), ("changed since the snapshot", "stale_ref"),
    ("No such tab", "no_tab"), ("isn't showing a web page", "not_a_page"), ("Timed out", "timeout"),
    ("covers that element", "not_actionable"), ("is hidden", "not_actionable"), ("is disabled", "not_actionable"),
    ("read-only", "not_actionable"), ("not a box", "not_actionable"), ("did not take the text", "not_actionable"),
    ("never type in password", "refused"), ("can't look at what is in a field", "refused"), ("never takes it elsewhere", "refused"),
    ("macOS is asking", "needs_you"), ("the clipboard is the person's", "refused"), ("Nothing was filled", "refused"),
    ("Only tabs an agent", "refused"), ("Nothing was attached", "refused"), ("isn't a web address", "refused"),
    ("isn't one of the keys", "bad_input"), ("gave no answer", "no_answer"), ("nothing to read", "no_answer"),
    ("Broadway has no window", "no_window"), ("waits for the person's yes", "needs_you"), ("only a task can ask", "needs_task"),
    ("Only a running task", "needs_task"), ("runs without the person", "refused"), ("The person is driving", "refused"),
    ("handed it back", "refused"), ("hasn't answered", "refused"), ("said not now", "refused"), ("said never here", "refused"),
    ("never lets agents", "refused"), ("A sandbox kept broadway", "sandboxed"), ("isn't running", "not_running"),
    ("Nothing is listening", "not_running"), ("didn't answer in time", "not_answering"), ("the field harness", "harness"),
]
EXIT_CODES = {2: "usage", 3: "needs_you", 4: "not_answering", 130: "stopped"}


def parse_call(argv):
    globals_seen, rest, index = [], [], 0
    while index < len(argv):
        word = argv[index]
        index += 1
        flag = word.split("=", 1)[0] if word.startswith("--") else word
        if word == "--":
            rest.extend(argv[index:])
            break
        if flag in WITH_VALUE:
            globals_seen.append(flag)
            if "=" not in word and index < len(argv):
                index += 1
            continue
        if flag in BARE_GLOBALS:
            globals_seen.append(flag)
            continue
        rest.append(word)
    words = [word for word in rest if not word.startswith("-")]
    flags = sorted({word.split("=", 1)[0] for word in rest if word.startswith("-") and not re.fullmatch(r"-\d+(\.\d+)?", word)} | set(globals_seen))
    if not words:
        return ("help" if "-h" in flags or "--help" in flags else "none"), flags
    first = words[0]
    if "://" in first or first.startswith("www."):
        return "open person", flags
    first = ALIASES.get(first, first)
    if " " in first:
        return first, flags
    if first == "dialog":
        action = next((word for word in words[1:] if word in ("accept", "dismiss", "inspect")), None)
        return (f"dialog {action}" if action and action != "inspect" else "dialog"), flags
    if first in NOUNS:
        verb = words[1] if len(words) > 1 and re.fullmatch(r"[a-z][a-z-]*", words[1]) else None
        if first in ("fill",) and verb not in ("login", "details", "card"):
            return "fill", flags
        if first in ("history", "space") and verb is None:
            return first, flags
        return (f"{first} {verb}" if verb else first), flags
    return first, flags


def error_code(exit_code, stdout, stderr, wants_json):
    if exit_code == 0:
        return None
    if wants_json:
        for line in stdout.splitlines():
            try:
                envelope = json.loads(line)
            except ValueError:
                continue
            if isinstance(envelope, dict) and isinstance(envelope.get("error"), dict):
                return envelope["error"].get("code") or "failed"
    message = next((line[len("broadway: "):] for line in stderr.splitlines() if line.startswith("broadway: ")), "")
    if exit_code in EXIT_CODES and not (exit_code == 2 and "the field harness" in message):
        return EXIT_CODES[exit_code]
    for said, code in FAILURES:
        if said in message:
            return code
    return "failed"


def agent_tabs(listing):
    return sum(1 for line in listing.splitlines() if line.startswith("⚗"))


def transcript(lines):
    usage_by_message, turns, commands, denied, result, model = {}, set(), [], 0, None, None
    for line in lines:
        try:
            event = json.loads(line)
        except ValueError:
            continue
        kind = event.get("type")
        if kind == "system" and event.get("subtype") == "init":
            model = event.get("model")
        if kind == "system" and event.get("subtype") == "permission_denied":
            denied += 1
        if kind == "assistant":
            message = event.get("message", {})
            if message.get("usage"):
                usage_by_message[message.get("id")] = message["usage"]
            for block in message.get("content", []):
                if block.get("type") == "tool_use":
                    turns.add(message.get("id"))
                    if block.get("name") == "Bash":
                        commands.append(block.get("input", {}).get("command", ""))
        if kind == "result":
            result = event
    keys = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")
    if result and result.get("usage"):
        usage = {key: int(result["usage"].get(key) or 0) for key in keys}
    else:
        usage = {key: sum(int(u.get(key) or 0) for u in usage_by_message.values()) for key in keys}
    return {
        "model": model,
        "turns": len(turns),
        "commands": commands,
        "denied": denied,
        "usage": usage,
        "fresh_tokens": usage["input_tokens"] + usage["cache_creation_input_tokens"] + usage["output_tokens"],
        "cost": (result or {}).get("total_cost_usd"),
        "finished": result is not None,
        "said": ((result or {}).get("result") or "")[-600:],
    }


def measure(calls, sleeps, story, questions, tabs, verdict):
    verbs = collections.Counter(call["verb"] for call in calls)
    codes = collections.Counter(call["code"] for call in calls if call["code"])
    looks = sum(count for verb, count in verbs.items() if verb in LOOKS)
    actions = sum(count for verb, count in verbs.items() if verb in ACTIONS)
    commands = story["commands"]
    after_wait = 0
    for index, command in enumerate(commands):
        waited = re.search(r"broadway\s+(\S+\s+)*wait\b", command)
        if waited and (re.search(r"\bsleep\s+\d", command[waited.end():]) or (index + 1 < len(commands) and re.match(r"\s*sleep\s+\d", commands[index + 1]))):
            after_wait += 1
    checked = sum(1 for before, after in zip(calls, calls[1:]) if before["verb"] in ACTIONS and before["verb"] not in ("open", "go")
                  and (after["verb"] in LOOKS or after["verb"] == "wait"))
    return {
        "ok": verdict[0],
        "detail": verdict[1],
        "calls": len(calls),
        "failed": sum(1 for call in calls if call["exit"] != 0),
        "codes": dict(codes),
        "verbs": dict(verbs),
        "open": verbs["open"],
        "go": verbs["go"],
        "snapshot": verbs["snapshot"],
        "read": verbs["read"],
        "shot": verbs["shot"],
        "wait": verbs["wait"],
        "tabs_calls": verbs["tabs"] + verbs["tabs list"],
        "locate": verbs["locate"],
        "sleep": len(sleeps),
        "looks": looks,
        "actions": actions,
        "snapshot_bytes": sum(call["out_bytes"] for call in calls if call["verb"] == "snapshot"),
        "snapshot_grep": sum(1 for c in commands if re.search(r"broadway\s+(--\S+\s+)*snapshot[^|]*\|\s*(grep|head|tail|sed|awk)", c)),
        "open_tail": sum(1 for c in commands if re.search(r"broadway\s+open[^|]*\|\s*tail", c)),
        "guessed_flags": sum(1 for call in calls if call["code"] == "usage"),
        "sleep_after_wait": after_wait,
        "checked_actions": checked,
        "acts": sum(1 for call in calls if call["verb"] in ACTIONS and call["verb"] not in ("open", "go")),
        "tabs_peak": max([0] + tabs),
        "tabs_end": tabs[-1] if tabs else 0,
        "questions": len(questions),
        "shell_calls": len(commands),
        "turns": story["turns"],
        "denied": story["denied"] + len(story.get("refused", [])),
        "fresh_tokens": story["fresh_tokens"],
        "cache_read": story["usage"]["cache_read_input_tokens"],
        "output_tokens": story["usage"]["output_tokens"],
        "cost": story["cost"],
    }


def ratio(top, bottom):
    return round(top / bottom, 2) if bottom else None


def summarise(rows):
    def block(group):
        wins = sum(1 for row in group if row["ok"])
        calls = sum(row["calls"] for row in group)
        return {
            "runs": len(group),
            "passed": wins,
            "success": ratio(wins, len(group)),
            "calls": calls,
            "calls_per_success": ratio(calls, wins),
            "tabs_peak_mean": ratio(sum(row["tabs_peak"] for row in group), len(group)),
            "tabs_end_mean": ratio(sum(row["tabs_end"] for row in group), len(group)),
            "looks_per_action": ratio(sum(row["looks"] for row in group), sum(row["actions"] for row in group)),
            "failed_share": ratio(sum(row["failed"] for row in group), calls),
            "sleeps": sum(row["sleep"] for row in group),
            "sleep_after_wait": sum(row.get("sleep_after_wait", 0) for row in group),
            "checked_share": ratio(sum(row.get("checked_actions", 0) for row in group), sum(row.get("acts", 0) for row in group)),
            "open_calls": sum(row["open"] for row in group),
            "go_calls": sum(row["go"] for row in group),
            "fresh_tokens": sum(row["fresh_tokens"] for row in group),
            "cache_read": sum(row["cache_read"] for row in group),
            "cost": round(sum(row["cost"] or 0 for row in group), 2),
            "seconds": round(sum(row.get("seconds", 0) for row in group)),
        }
    by_model = collections.defaultdict(list)
    for row in rows:
        by_model[row["model"]].append(row)
    return {"total": block(rows), "models": {model: block(group) for model, group in by_model.items()}}


def table(rows):
    head = ["task", "model", "ok", "calls", "failed", "open", "go", "snap", "read", "shot", "wait", "sleep", "tabs peak/end",
            "looks/act", "snap KB", "asked", "turns", "fresh tok", "cache read", "s", "stop"]
    lines = ["| " + " | ".join(head) + " |", "|" + "---|" * len(head)]
    for row in rows:
        lines.append("| " + " | ".join(str(value) for value in [
            row["task"], row["model"], "yes" if row["ok"] else "no", row["calls"], row["failed"], row["open"], row["go"],
            row["snapshot"], row["read"], row["shot"], row["wait"], row["sleep"], f"{row['tabs_peak']}/{row['tabs_end']}",
            ratio(row["looks"], row["actions"]), round(row["snapshot_bytes"] / 1024, 1), row["questions"], row["turns"],
            row["fresh_tokens"], row["cache_read"], round(row.get("seconds", 0)), row.get("stop", "")]) + " |")
    summary = summarise(rows)
    lines += ["", "| who | runs | passed | success | calls per success | tabs peak (mean) | tabs at end (mean) | looks per action | acts followed by a look | failed share | open / go | shell sleeps (after a wait) | fresh tokens | cache read | cost USD | minutes |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for name, block in [*summary["models"].items(), ("all", summary["total"])]:
        lines.append("| " + " | ".join(str(value) for value in [
            name, block["runs"], block["passed"], block["success"], block["calls_per_success"], block["tabs_peak_mean"],
            block["tabs_end_mean"], block["looks_per_action"], block["checked_share"], block["failed_share"], f"{block['open_calls']} / {block['go_calls']}",
            f"{block['sleeps']} ({block['sleep_after_wait']})", block["fresh_tokens"],
            block["cache_read"], block["cost"], round(block["seconds"] / 60, 1)]) + " |")
    return "\n".join(lines) + "\n"


def encode(value):
    return base64.urlsafe_b64encode(json.dumps(value).encode()).decode()


def decode(text):
    return json.loads(base64.urlsafe_b64decode(text.encode()))


def world_socket(world):
    return f"{os.path.expanduser('~')}/Library/Application Support/Broadway ({world})/broadway.sock"


def bench(world, *words, timeout=30):
    return subprocess.run([str(BENCH), "--world", world, *words], capture_output=True, text=True, timeout=timeout).stdout


def append(path, row):
    with open(path, "a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        stream.write(json.dumps(row) + "\n")
        fcntl.flock(stream, fcntl.LOCK_UN)


def read_rows(path):
    try:
        return [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    except FileNotFoundError:
        return []


def command_call(payload):
    world, run = payload["world"], payload["run"]
    if not world.startswith("field-") or not run.startswith(PREFIX):
        sys.stderr.write("broadway: the field harness only works in its own test worlds\n")
        return 2
    argv, original = payload["argv"], payload.get("original", payload["argv"])
    verb, flags = parse_call(original)
    began = time.time()
    if any(word in ("--socket", "--world") or word.startswith(("--socket=", "--world=")) for word in argv):
        out, err, code = b"", b"broadway: the field harness chooses the browser, so --world and --socket are refused here\n", 2
    elif verb.split(" ")[0] in REFUSED_VERBS:
        out, err, code = b"", f"broadway: the field harness keeps {verb} for itself\n".encode(), 2
    else:
        environment = {key: value for key, value in os.environ.items() if not key.startswith("BROADWAY_")}
        environment.update(BROADWAY_AGENT=payload["agent"], BROADWAY_AGENT_NAME=payload.get("name", AGENT_NAME))
        if payload.get("tab"):
            environment["BROADWAY_TAB"] = payload["tab"]
        cwd = payload.get("cwd") or run
        if not os.path.isdir(cwd):
            cwd = run
        finished = subprocess.run([str(BROADWAY), "--socket", world_socket(world), *argv], cwd=cwd, env=environment,
                                  stdin=sys.stdin.buffer if payload.get("stdin") else subprocess.DEVNULL, capture_output=True)
        out, err, code = finished.stdout, finished.stderr, finished.returncode
    ended = time.time()
    sys.stdout.buffer.write(out)
    sys.stdout.buffer.flush()
    sys.stderr.buffer.write(err)
    sys.stderr.buffer.flush()
    tabs = None
    try:
        tabs = agent_tabs(bench(world, "tabs", timeout=10))
    except (OSError, subprocess.SubprocessError):
        pass
    text_out, text_err = out.decode(errors="replace"), err.decode(errors="replace")
    append(f"{run}/calls.jsonl", {
        "t": began, "seconds": round(ended - began, 3), "argv": original, "verb": verb, "flags": flags, "exit": code,
        "code": error_code(code, text_out, text_err, "--json" in original), "out_bytes": len(out),
        "err": text_err.strip()[:300], "agent_tabs": tabs})
    return code


def command_put(payload):
    path = payload["path"]
    if not path.startswith(PREFIX):
        return 2
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(sys.stdin.buffer.read())
    return 0


def kept_download(path, world):
    folder = os.path.dirname(world_socket(world))
    return world.startswith("field-") and os.path.realpath(path).startswith(os.path.realpath(folder) + "/") and "/Agent Downloads/" in path


def command_get(payload):
    path = payload["path"]
    if not path.startswith(PREFIX) and not kept_download(path, payload.get("world", "")):
        return 2
    sys.stdout.buffer.write(Path(path).read_bytes())
    return 0


def say(kind, body):
    sys.stdout.write(f"FIELD {kind} {json.dumps(body)}\n")
    sys.stdout.flush()


def command_world(payload):
    import split_view as sv
    task = BY_NAME[payload["task"]]
    run = payload["run"]
    if not run.startswith(PREFIX):
        raise SystemExit("not a field folder")
    for folder in ("work", "out", "mirror"):
        Path(run, folder).mkdir(parents=True, exist_ok=True)
    field = Field()
    servers, copperline, fernway = serve(field)
    sv.use("field")
    world = sv.W
    sv.owned_suites.add(sv.SUITE)
    questions, tab_samples, stop = [], [], threading.Event()
    sv.wipe()
    try:
        for key in ("bench", "agents.on"):
            subprocess.run(["defaults", "write", sv.SUITE, key, "-bool", "true"], check=True)
        woke = subprocess.run([str(BROADWAY), "--world", world, "tabs"], capture_output=True, text=True, timeout=60,
                              env=dict({k: v for k, v in os.environ.items() if not k.startswith("BROADWAY_")}, BROADWAY_AGENT="field-harness"))
        if woke.returncode != 0:
            raise RuntimeError(f"the test world did not start: {woke.stderr.strip()}")
        if "login" in task.needs:
            sheet = Path(run, "logins.csv")
            sheet.write_text(f"url,username,password\n{fernway}/,sam@example.com,{field.password}\n")
            bench(world, "import-file", str(sheet))
            sheet.unlink()
        guide = subprocess.run([str(BROADWAY), "--socket", world_socket(world), "guide"], capture_output=True, text=True, timeout=30).stdout

        def person():
            seen, last_tabs = None, 0
            while not stop.is_set():
                try:
                    pending = json.loads(bench(world, "knowing", "desk", "list", timeout=10) or "{}").get("pending", [])
                except (ValueError, OSError, subprocess.SubprocessError):
                    pending = []
                now = time.time()
                if pending:
                    first = json.dumps(pending[0], sort_keys=True)
                    if seen is None or seen[0] != first:
                        seen = (first, now)
                    elif now - seen[1] >= PERSON_DELAY:
                        bench(world, "knowing", "desk", "yes", timeout=10)
                        questions.append({"t": seen[1], "answered": now, **pending[0]})
                        seen = None
                else:
                    seen = None
                if now - last_tabs > 2:
                    try:
                        tab_samples.append(agent_tabs(bench(world, "tabs", timeout=10)))
                    except (OSError, subprocess.SubprocessError):
                        pass
                    last_tabs = now
                stop.wait(0.4)

        watcher = threading.Thread(target=person, daemon=True)
        watcher.start()
        say("READY", {"world": world, "copperline": copperline, "fernway": fernway, "guide": guide, "run": run})
        for line in sys.stdin:
            if line.strip() == "stop":
                break
        stop.set()
        watcher.join(timeout=15)
        end_tabs = agent_tabs(bench(world, "tabs", timeout=10))
        calls = read_rows(f"{run}/calls.jsonl")
        tabs = [call["agent_tabs"] for call in calls if call.get("agent_tabs") is not None] + tab_samples + [end_tabs]
        state = field.state()
        ok, detail = task.check(state)
        say("FINAL", {"state": state, "questions": questions, "tabs": tabs, "tabs_end": end_tabs, "calls": calls, "ok": ok, "detail": detail})
    finally:
        stop.set()
        bench(world, "quit")
        for _ in range(40):
            if not sv.pids():
                break
            time.sleep(0.25)
        for pid in sv.pids():
            subprocess.run(["kill", pid])
        label = f"Broadway ({world})"
        while subprocess.run(["security", "delete-internet-password", "-l", label], capture_output=True, timeout=10).returncode == 0:
            pass
        sv.wipe()
        for server in servers:
            server.shutdown()
        if payload.get("clean"):
            shutil.rmtree(run, ignore_errors=True)
    return 0


SHIM = r'''#!/usr/bin/env python3
import base64, json, os, subprocess, sys, time, uuid
CONFIG = json.loads(base64.b64decode(__CONFIG__))
def enc(value): return base64.urlsafe_b64encode(json.dumps(value).encode()).decode()
def over(sub, value, **kw):
    words = CONFIG["remote"] + [CONFIG["runner"].replace("SUB", sub).replace("ARG", enc(value))] if CONFIG["remote"] else [CONFIG["python"], CONFIG["script"], sub, enc(value)]
    return subprocess.run(words, **kw)
original = sys.argv[1:]
argv, outputs, swaps, index = [], [], [], 0
while index < len(original):
    word = original[index]
    index += 1
    target = None
    if word in ("-o", "--output") and index < len(original):
        target = original[index]; index += 1; prefix = [word]
    elif word.startswith("--output="):
        target = word.split("=", 1)[1]; prefix = None
    if target is not None and CONFIG["remote"] and target != "-":
        local = os.path.abspath(target)
        far = CONFIG["run"] + "/out/" + uuid.uuid4().hex[:8] + "-" + os.path.basename(local)
        outputs.append((far, local)); swaps.append((far, local))
        argv += (prefix + [far]) if prefix else ["--output=" + far]
    elif target is not None:
        argv += (prefix + [target]) if prefix else [word]
    else:
        argv.append(word)
if CONFIG["remote"] and "upload" in argv:
    start = argv.index("upload") + 1
    for i in range(start, len(argv)):
        path = os.path.abspath(argv[i])
        if not argv[i].startswith("-") and not argv[i].startswith("@") and os.path.isfile(path):
            far = CONFIG["run"] + "/mirror" + path
            with open(path, "rb") as source:
                over("put", {"path": far}, stdin=source, capture_output=True)
            argv[i] = far; swaps.append((far, path))
piped = not sys.stdin.isatty() and not os.environ.get("FIELD_NO_STDIN")
payload = {"argv": argv, "original": original, "world": CONFIG["world"], "run": CONFIG["run"], "agent": CONFIG["agent"],
           "name": CONFIG["name"], "cwd": os.getcwd(), "tab": os.environ.get("BROADWAY_TAB", ""), "stdin": piped}
began = time.time()
done = over("call", payload, stdin=sys.stdin if piped else subprocess.DEVNULL, capture_output=True)
out, err = done.stdout, done.stderr
for far, local in swaps:
    out = out.replace(far.encode(), local.encode()); err = err.replace(far.encode(), local.encode())
if CONFIG["remote"] and done.returncode == 0 and "download" in original[:4]:
    import re
    for found in set(re.findall(r'(/[^"\n]*/Broadway \(field-[^)/]+\)/Agent Downloads/[^"\n]+)', out.decode(errors="replace"))):
        path = found.strip()
        fetched = over("get", {"path": path, "world": CONFIG["world"]}, capture_output=True)
        if fetched.returncode == 0 and "/Broadway (" + CONFIG["world"] + ")/" in path:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as sink:
                sink.write(fetched.stdout)
for far, local in outputs:
    fetched = over("get", {"path": far}, capture_output=True)
    if fetched.returncode == 0:
        os.makedirs(os.path.dirname(local) or ".", exist_ok=True)
        with open(local, "wb") as sink:
            sink.write(fetched.stdout)
sys.stdout.buffer.write(out); sys.stdout.buffer.flush()
sys.stderr.buffer.write(err); sys.stderr.buffer.flush()
with open(CONFIG["log"], "a") as log:
    log.write(json.dumps({"t": began, "seconds": round(time.time() - began, 3), "argv": original, "exit": done.returncode}) + "\n")
sys.exit(done.returncode)
'''

SLEEP = r'''#!/bin/sh
printf '{"t": %s, "args": "%s"}\n' "$(date +%s)" "$*" >> __LOG__
exec /bin/sleep "$@"
'''

FRAME = """The broadway command on your PATH drives the person's own web browser. This is its guide, from broadway guide.

{guide}"""

OFF_LIMITS = re.compile(
    r"Broadway\.app|\.local/bin/broadway|/Helpers/broadway|BROADWAY_SOCKET|--socket|--world"
    r"|(^|[;&|(`]\s*|\$\(\s*)(open|osascript|ssh|scp|curl|wget|sudo|killall|pkill|kill|defaults|security|launchctl|nc|python3?|perl|ruby|node)\b"
    r"|\brm\s+-[a-z]*r")


def judge(tool, given, run):
    if tool == "Bash":
        command = given.get("command", "")
        if OFF_LIMITS.search(command):
            return False, "This test only lets you use the broadway command and plain shell text tools for that"
        return True, ""
    if tool == "Read":
        path = os.path.realpath(given.get("file_path", ""))
        if path.startswith(os.path.realpath(run) + "/") or path.startswith("/private/tmp/"):
            return True, ""
        return False, "This test only lets you read files in your working folder or a temporary folder"
    return False, "That tool is not part of this test"


class Remote:
    def __init__(self, host, repo, python):
        self.host, self.repo, self.python = host, repo, python
        self.control = None
        if host:
            self.control = tempfile.mktemp(prefix="af-", dir="/tmp")
            subprocess.run(["ssh", "-M", "-S", self.control, "-o", "ControlPersist=yes", "-o", "BatchMode=yes", "-fN", host], check=True)

    def ssh(self):
        return ["ssh", "-S", self.control, "-o", "ControlMaster=no", "-o", "BatchMode=yes", self.host] if self.host else []

    def runner(self, sub="SUB", arg="ARG"):
        inner = f"cd {shlex.quote(self.repo)} && exec {self.python} -u Tests/agent_field.py {sub} {arg}"
        return shlex.join(["/bin/bash", "-c", inner])

    def words(self, sub, payload):
        if self.host:
            return self.ssh() + [self.runner(sub, encode(payload))]
        return [sys.executable, "-u", str(Path(__file__).resolve()), sub, encode(payload)]

    def close(self):
        if self.control:
            subprocess.run(["ssh", "-S", self.control, "-O", "exit", self.host], capture_output=True)


class World:
    def __init__(self, remote, task, run):
        self.process = subprocess.Popen(remote.words("world", {"task": task, "run": run, "clean": bool(remote.host)}), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.errors = []
        threading.Thread(target=lambda: self.errors.extend(self.process.stderr), daemon=True).start()
        self.ready = self.wait("READY", 180)

    def wait(self, kind, seconds):
        until = time.time() + seconds
        while time.time() < until:
            line = self.process.stdout.readline()
            if not line:
                break
            if line.startswith(f"FIELD {kind} "):
                return json.loads(line[len(f"FIELD {kind} "):])
        raise RuntimeError(f"the world gave no {kind}: {''.join(self.errors[-20:])}")

    def finish(self):
        self.process.stdin.write("stop\n")
        self.process.stdin.flush()
        final = self.wait("FINAL", 120)
        try:
            self.process.wait(timeout=90)
        except subprocess.TimeoutExpired:
            os.killpg(self.process.pid, signal.SIGTERM)
        return final

    def abandon(self):
        try:
            self.process.stdin.close()
            self.process.wait(timeout=90)
        except (OSError, subprocess.TimeoutExpired):
            os.killpg(self.process.pid, signal.SIGTERM)


def shims(remote, ready, run, agent):
    folder = Path(run, "bin")
    folder.mkdir(parents=True, exist_ok=True)
    config = {"remote": remote.ssh(), "runner": remote.runner() if remote.host else "", "python": sys.executable,
              "script": str(Path(__file__).resolve()), "world": ready["world"], "run": run, "agent": agent, "name": AGENT_NAME,
              "log": str(Path(run, "shim.jsonl"))}
    shim = folder / "broadway"
    shim.write_text(SHIM.replace("__CONFIG__", repr(base64.b64encode(json.dumps(config).encode()).decode())))
    sleeper = folder / "sleep"
    sleeper.write_text(SLEEP.replace("__LOG__", shlex.quote(str(Path(run, "sleeps.jsonl")))))
    for path in (shim, sleeper):
        path.chmod(0o755)
    return folder


def agent_environment(folder, run):
    keep = {key: os.environ[key] for key in ("HOME", "USER", "LOGNAME", "LANG", "TMPDIR") if key in os.environ}
    return {**keep, "PATH": f"{folder}:/usr/bin:/bin:/usr/sbin:/sbin", "SHELL": "/bin/bash", "TERM": "dumb",
            "BROADWAY_SOCKET": str(Path(run, "no-broadway-here.sock")), "NO_COLOR": "1"}


def run_agent(claude, model, prompt, system, run, folder, turns, seconds):
    work = Path(run, "work")
    work.mkdir(parents=True, exist_ok=True)
    words = [claude, "-p", "--model", model, "--safe-mode", "--strict-mcp-config", "--no-chrome", "--no-session-persistence",
             "--tools", "Bash,Read", "--permission-mode", "default", "--permission-prompt-tool", "stdio", "--append-system-prompt", system,
             "--max-turns", str(turns), "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
    lines, began, refusals = [], time.time(), []
    process = subprocess.Popen(words, cwd=work, env=agent_environment(folder, run), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, start_new_session=True)
    errors = []
    threading.Thread(target=lambda: errors.extend(process.stderr), daemon=True).start()

    def send(message):
        try:
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()
        except (BrokenPipeError, ValueError):
            pass

    def listen():
        for line in process.stdout:
            lines.append(line)
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") == "control_request" and event.get("request", {}).get("subtype") == "can_use_tool":
                request = event["request"]
                allowed, why = judge(request.get("tool_name"), request.get("input", {}), run)
                if not allowed:
                    refusals.append({"tool": request.get("tool_name"), "input": request.get("input", {})})
                answer = {"behavior": "allow", "updatedInput": request.get("input", {})} if allowed else {"behavior": "deny", "message": why}
                send({"type": "control_response", "response": {"subtype": "success", "request_id": event["request_id"], "response": answer}})
            if event.get("type") == "result":
                try:
                    process.stdin.close()
                except OSError:
                    pass

    threading.Thread(target=listen, daemon=True).start()
    send({"type": "control_request", "request_id": "field-init", "request": {"subtype": "initialize", "hooks": None}})
    send({"type": "user", "message": {"role": "user", "content": prompt}, "parent_tool_use_id": None, "session_id": "default"})
    stop = "done"
    while process.poll() is None:
        time.sleep(0.5)
        if time.time() - began > seconds:
            stop = "time limit"
        elif transcript(list(lines))["turns"] > turns:
            stop = "turn limit"
        if stop != "done":
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
            break
    time.sleep(0.5)
    story = transcript(list(lines))
    story["refused"] = refusals
    if stop == "done" and not story["finished"]:
        stop = "ended without a result"
    if stop == "done" and story["turns"] >= turns:
        stop = "turn limit"
    return story, stop, time.time() - began, list(lines), "".join(errors)[-2000:]


def one(remote, claude, task, model, turns, seconds, out):
    tag = secrets.token_hex(3)
    run = f"{PREFIX}{task.name}-{model}-{tag}"
    agent = f"field-{task.name}-{model}-{tag}"
    Path(run).mkdir(parents=True, exist_ok=True)
    world = World(remote, task.name, run)
    try:
        ready = world.ready
        folder = shims(remote, ready, run, agent)
        prompt = task.say(ready["copperline"], ready["fernway"])
        story, stop, took, lines, errors = run_agent(claude, model, prompt, FRAME.format(guide=ready["guide"].strip()), run, folder, turns, seconds)
        final = world.finish()
    except BaseException:
        world.abandon()
        raise
    sleeps = read_rows(Path(run, "sleeps.jsonl"))
    row = {"task": task.name, "model": model, "prompt": prompt, "stop": stop, "seconds": round(took, 1),
           **measure(final["calls"], sleeps, story, final["questions"], final["tabs"], (final["ok"], final["detail"]))}
    row["tabs_end"] = final["tabs_end"]
    keep = Path(out, f"{task.name}-{model}")
    keep.mkdir(parents=True, exist_ok=True)
    (keep / "transcript.jsonl").write_text("".join(lines))
    (keep / "calls.json").write_text(json.dumps(final["calls"], indent=1))
    (keep / "questions.json").write_text(json.dumps(final["questions"], indent=1))
    (keep / "shim.jsonl").write_text(Path(run, "shim.jsonl").read_text() if Path(run, "shim.jsonl").exists() else "")
    (keep / "agent-stderr.txt").write_text(errors)
    (keep / "said.txt").write_text(story["said"])
    shutil.rmtree(run, ignore_errors=True)
    if remote.host:
        mirrored = Path.home() / "Library" / "Application Support" / f"Broadway ({ready['world']})"
        if ready["world"].startswith("field-") and mirrored.is_dir():
            shutil.rmtree(mirrored, ignore_errors=True)
    return row


def command_run(args):
    if not args.host and not BROADWAY.exists():
        raise SystemExit("build first: ./build.sh")
    claude = shutil.which(args.claude) or args.claude
    if not os.access(claude, os.X_OK):
        raise SystemExit(f"no agent command at {args.claude}")
    names = [name for name in args.tasks.split(",") if name] if args.tasks != "all" else [task.name for task in TASKS]
    unknown = [name for name in names if name not in BY_NAME]
    if unknown:
        raise SystemExit(f"no such task: {', '.join(unknown)}")
    models = [model for model in args.models.split(",") if model]
    out = Path(args.out or ROOT / ".context" / "agent-field" / time.strftime("%Y%m%d-%H%M%S"))
    out.mkdir(parents=True, exist_ok=True)
    remote = Remote(args.host, args.repo or str(ROOT), args.python)
    rows, spent, began = [], 0, time.time()
    try:
        for name in names:
            for model in models:
                for _ in range(args.repeat):
                    if spent > args.budget:
                        print(f"stopped: {spent} fresh tokens is past the budget of {args.budget}", flush=True)
                        raise StopIteration
                    print(f"{name} with {model}…", flush=True)
                    try:
                        row = one(remote, claude, BY_NAME[name], model, args.turns, args.minutes * 60, out)
                    except RuntimeError as trouble:
                        print(f"  harness trouble: {trouble}", flush=True)
                        continue
                    rows.append(row)
                    spent += row["fresh_tokens"]
                    append(out / "results.jsonl", row)
                    print(f"  {'passed' if row['ok'] else 'failed'}: {row['calls']} calls, {row['stop']}, {row['seconds']} s, "
                          f"{row['fresh_tokens']} fresh tokens, {row['cache_read']} cached. {row['detail']}", flush=True)
    except StopIteration:
        pass
    finally:
        remote.close()
    (out / "summary.md").write_text(table(rows) + f"\nWall clock {round((time.time() - began) / 60, 1)} min.\n")
    print(table(rows))
    print(f"kept in {out}")
    return 0


def command_table(args):
    rows = read_rows(Path(args.folder, "results.jsonl"))
    print(table(rows))
    return 0


def command_serve(_):
    field = Field()
    _, copperline, fernway = serve(field)
    print(f"Copperline {copperline}\nFernway {fernway}\nFernway sign-in: sam@example.com / {field.password}", flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        return 0


class Parsing(unittest.TestCase):
    def test_verbs(self):
        self.assertEqual(parse_call(["open", "https://a.example"])[0], "open")
        self.assertEqual(parse_call(["--json", "--tab", "abcd1234", "snapshot"]), ("snapshot", ["--json", "--tab"]))
        self.assertEqual(parse_call(["--tab=abcd", "click", "@e5"]), ("click", ["--tab"]))
        self.assertEqual(parse_call(["navigate", "https://a.example"])[0], "go")
        self.assertEqual(parse_call(["text"])[0], "read")
        self.assertEqual(parse_call(["screenshot", "-o", "a.png"]), ("shot", ["-o"]))
        self.assertEqual(parse_call(["tabs"])[0], "tabs")
        self.assertEqual(parse_call(["tabs", "close", "abcd"])[0], "tabs close")
        self.assertEqual(parse_call(["fill", "login"])[0], "fill login")
        self.assertEqual(parse_call(["fill", '{"@e4": "Sam"}'])[0], "fill")
        self.assertEqual(parse_call(["https://a.example"])[0], "open person")
        self.assertEqual(parse_call(["dialog"])[0], "dialog")
        self.assertEqual(parse_call(["dialog", "accept", "--id", "d1"])[0], "dialog accept")
        self.assertEqual(parse_call(["agent", "done", "--summary", "x"])[0], "agents done")
        self.assertEqual(parse_call(["wait", "--idle"]), ("wait", ["--idle"]))
        self.assertEqual(parse_call(["scroll", "-400"]), ("scroll", []))
        self.assertEqual(parse_call(["history"])[0], "history")
        self.assertEqual(parse_call([])[0], "none")
        self.assertEqual(parse_call(["--help"])[0], "help")
        self.assertEqual(parse_call(["find", "price"])[0], "page find")

    def test_codes(self):
        self.assertIsNone(error_code(0, "", "", False))
        self.assertEqual(error_code(1, "", "broadway: That element is from an older snapshot. Take a new one.\nhint: Run broadway snapshot\n", False), "stale_ref")
        self.assertEqual(error_code(2, "", "broadway: wait has no --second\nhint: Did you mean --seconds\n", False), "usage")
        self.assertEqual(error_code(3, "", "broadway: This waits for the person's yes\n", False), "needs_you")
        self.assertEqual(error_code(1, "", "broadway: A sandbox kept broadway from reaching Broadway\n", False), "sandboxed")
        self.assertEqual(error_code(1, "", "broadway: something new\n", False), "failed")
        self.assertEqual(error_code(2, "", "broadway: the field harness chooses the browser, so --world and --socket are refused here\n", False), "harness")
        envelope = json.dumps({"ok": False, "command": "click", "data": None, "error": {"code": "busy", "message": "m", "hint": "", "retry_safe": True}})
        self.assertEqual(error_code(1, envelope + "\n", "", True), "busy")

    def test_tabs(self):
        listing = "● f152262c  —  \n⚗ c666342b  —  http://127.0.0.1:5/long …\n⚗ d777  —  x\n"
        self.assertEqual(agent_tabs(listing), 2)
        self.assertEqual(agent_tabs(""), 0)

    def test_transcript(self):
        lines = [json.dumps({"type": "system", "subtype": "init", "model": "m"}),
                 json.dumps({"type": "assistant", "message": {"id": "a", "usage": {"input_tokens": 3, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 50},
                                                               "content": [{"type": "tool_use", "name": "Bash", "input": {"command": "broadway snapshot | grep Save"}}]}}),
                 json.dumps({"type": "assistant", "message": {"id": "a", "usage": {"input_tokens": 3, "output_tokens": 9, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 50},
                                                               "content": [{"type": "tool_use", "name": "Bash", "input": {"command": "tab=$(broadway open https://a.example | tail -1)"}}]}}),
                 json.dumps({"type": "system", "subtype": "permission_denied"}),
                 "not json"]
        story = transcript(lines)
        self.assertEqual(story["turns"], 1)
        self.assertEqual(story["usage"]["output_tokens"], 9)
        self.assertEqual(story["fresh_tokens"], 3 + 50 + 9)
        self.assertEqual(story["denied"], 1)
        self.assertFalse(story["finished"])
        lines.append(json.dumps({"type": "result", "usage": {"input_tokens": 10, "output_tokens": 20, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}, "total_cost_usd": 0.5, "result": "Done"}))
        story = transcript(lines)
        self.assertEqual(story["fresh_tokens"], 30)
        self.assertTrue(story["finished"])
        calls = [{"verb": "open", "exit": 0, "code": None, "out_bytes": 9}, {"verb": "snapshot", "exit": 0, "code": None, "out_bytes": 2048},
                 {"verb": "click", "exit": 1, "code": "stale_ref", "out_bytes": 0}, {"verb": "wait", "exit": 2, "code": "usage", "out_bytes": 0}]
        story["commands"].append("broadway wait --idle && sleep 2")
        row = measure(calls, [{"args": "2"}], story, [{"title": "Send on x?"}], [0, 1, 2, 1], (True, "fine"))
        self.assertEqual(row["sleep_after_wait"], 1)
        self.assertEqual((row["acts"], row["checked_actions"]), (1, 1))
        self.assertEqual((row["calls"], row["failed"], row["looks"], row["actions"]), (4, 2, 1, 2))
        self.assertEqual((row["snapshot_grep"], row["open_tail"], row["guessed_flags"], row["sleep"]), (1, 1, 1, 1))
        self.assertEqual((row["tabs_peak"], row["tabs_end"], row["questions"]), (2, 1, 1))
        summary = summarise([dict(row, model="m", seconds=60), dict(row, model="m", ok=False, seconds=30)])
        self.assertEqual(summary["total"]["success"], 0.5)
        self.assertEqual(summary["total"]["calls_per_success"], 8.0)
        self.assertEqual(summary["total"]["failed_share"], 0.5)
        self.assertIn("| all |", table([dict(row, task="t", model="m", stop="done", seconds=60)]))

    def test_judge(self):
        run = "/tmp/agent-field-x"
        for command in ['tab=$(broadway open https://a.example | tail -1)', "broadway snapshot | grep -i save", "for i in 1 2; do broadway press Tab; done",
                        "sleep 2 && broadway wait --idle", "broadway read > page.txt; wc -c page.txt"]:
            self.assertTrue(judge("Bash", {"command": command}, run)[0], command)
        for command in ["open https://a.example", "/Applications/Broadway.app/Contents/Helpers/broadway tabs", "~/.local/bin/broadway tabs",
                        "broadway --world other tabs", "BROADWAY_SOCKET=/x broadway tabs", "echo x && osascript -e y", "curl http://127.0.0.1:5/",
                        "python3 -c 'print(1)'", "rm -rf work", "x=$(ssh h ls)"]:
            self.assertFalse(judge("Bash", {"command": command}, run)[0], command)
        self.assertTrue(judge("Read", {"file_path": run + "/work/page.png"}, run)[0])
        self.assertTrue(judge("Read", {"file_path": "/tmp/shot.png"}, run)[0])
        self.assertFalse(judge("Read", {"file_path": "/etc/hosts"}, run)[0])
        self.assertFalse(judge("WebFetch", {}, run)[0])

    def test_encoding(self):
        value = {"argv": ["fill", '{"@e4": "O\'Brien \\\\ é"}'], "n": 1}
        self.assertEqual(decode(encode(value)), value)
        self.assertNotIn("'", encode(value))


class Checks(unittest.TestCase):
    def setUp(self):
        self.field = Field(seed=7)

    def verdict(self, name):
        return BY_NAME[name].check(self.field.state())

    def test_untouched_fails_every_task(self):
        for task in TASKS:
            self.assertFalse(task.check(self.field.state())[0], task.name)

    def test_order_note(self):
        self.field.orders["CL-4471"]["note"] = "Leave at the side door."
        self.assertTrue(self.verdict("order_note")[0])
        self.field.orders["CL-4470"]["note"] = "Leave at the side door"
        self.assertFalse(self.verdict("order_note")[0])

    def test_digest(self):
        self.field.settings["digest"] = True
        self.assertFalse(self.verdict("digest")[0])
        self.field.settings_saves = 1
        self.assertTrue(self.verdict("digest")[0])
        key = next(key for key in self.field.settings if key != "digest")
        self.field.settings[key] = not self.field.settings[key]
        self.assertFalse(self.verdict("digest")[0])

    def test_warehouses(self):
        self.field.warehouses_saved = ["Ruthven", "Aldermoor", "Brackwater"]
        self.assertTrue(self.verdict("warehouses")[0])
        self.field.warehouses_saved.append("Corrin Bay")
        self.assertFalse(self.verdict("warehouses")[0])

    def test_tracking(self):
        self.field.recorded_codes.append({"shipment": "SH-208", "code": "TRK-WRONG1"})
        self.assertFalse(self.verdict("tracking")[0])
        self.field.recorded_codes.append({"shipment": "SH-208", "code": self.field.tracking["SH-208"]})
        self.assertTrue(self.verdict("tracking")[0])
        self.field.recorded_codes.append({"shipment": "SH-209", "code": self.field.tracking["SH-209"]})
        self.assertTrue(self.verdict("tracking")[0])

    def test_archive(self):
        self.field.campaigns["Spring promo"] = True
        self.assertTrue(self.verdict("archive")[0])
        self.field.campaigns["Spring refill"] = True
        self.assertFalse(self.verdict("archive")[0])

    def test_help_question(self):
        self.field.questions.append("Which file format does the Invoice Export use?")
        self.assertTrue(self.verdict("help_question")[0])

    def test_reorder(self):
        self.field.reorders.append({"item": "A4 paper", "qty": 12})
        self.assertTrue(self.verdict("reorder")[0])
        self.field.reorders.append({"item": "A4 paper", "qty": 12})
        self.assertFalse(self.verdict("reorder")[0])

    def test_approve(self):
        self.field.invoices["FW-1093"] = True
        self.assertFalse(self.verdict("approve")[0])
        self.field.signins.append({"ok": True})
        self.assertTrue(self.verdict("approve")[0])
        self.field.invoices["FW-1094"] = True
        self.assertFalse(self.verdict("approve")[0])

    def test_stock_import(self):
        self.field.imports.append({"name": "x.csv", "bytes": 3, "same": False})
        self.assertFalse(self.verdict("stock_import")[0])
        self.field.imports.append({"name": "stock.csv", "bytes": 3, "same": True})
        self.assertTrue(self.verdict("stock_import")[0])

    def test_supplier_email(self):
        self.field.suppliers["halden-oak"]["email"] = self.field.directory["halden-oak"].upper()
        self.assertTrue(self.verdict("supplier_email")[0])
        self.field.suppliers["halden-oak"]["email"] = self.field.directory["halden-oakes"]
        self.assertFalse(self.verdict("supplier_email")[0])

    def test_assign(self):
        self.field.tickets["T-388"] = "Odile Vance"
        self.assertFalse(self.verdict("assign")[0])
        self.field.tickets["T-388"] = "Odile Varga"
        self.assertTrue(self.verdict("assign")[0])

    def test_sentences_name_both_places(self):
        for task in TASKS:
            said = task.say("http://127.0.0.1:1", "http://localhost:2")
            self.assertNotIn("{", said, task.name)
            self.assertTrue("127.0.0.1:1" in said or "localhost:2" in said, task.name)

    def test_multipart(self):
        raw = (b"--XyZ\r\nContent-Disposition: form-data; name=\"sheet\"; filename=\"stock.csv\"\r\nContent-Type: text/csv\r\n\r\n"
               b"sku,item\r\n1,a\r\n--XyZ--\r\n")
        self.assertEqual(multipart(raw, "multipart/form-data; boundary=XyZ"), [("stock.csv", b"sku,item\r\n1,a")])
        self.assertEqual(multipart(b"", "text/plain"), [])


class Served(unittest.TestCase):
    def test_sites_answer_and_record(self):
        from urllib.request import Request, urlopen
        field = Field(seed=3)
        servers, copperline, fernway = serve(field)
        fernway = fernway.replace("localhost", "127.0.0.1")
        try:
            self.assertIn("CL-4471", urlopen(f"{copperline}/orders?page=3").read().decode())
            self.assertIn("Next page", urlopen(f"{copperline}/orders").read().decode())
            urlopen(Request(f"{copperline}/api/orders/CL-4471/note", data=b'{"note": "Leave at the side door"}', headers={"content-type": "application/json"}))
            self.assertTrue(BY_NAME["order_note"].check(field.state())[0])
            self.assertIn("Aldermoor", urlopen(f"{copperline}/warehouses").read().decode())
            urlopen(Request(f"{copperline}/api/warehouses", data=b'{"ticked": ["Ruthven"]}', headers={"content-type": "application/json"}))
            self.assertIn('value="Ruthven" checked', urlopen(f"{copperline}/warehouses").read().decode())
            urlopen(Request(f"{copperline}/reorder/send", data=b"item=A4+paper&qty=12"))
            self.assertTrue(BY_NAME["reorder"].check(field.state())[0])
            self.assertIn("Sign in to Fernway", urlopen(f"{fernway}/account/invoices").read().decode())
            self.assertIn(field.directory["halden-oak"], urlopen(f"{fernway}/directory").read().decode())
            self.assertEqual(urlopen(f"{copperline}/files/stock-week-46.csv").read().decode(), field.stock_csv)
            body = (f"--b\r\nContent-Disposition: form-data; name=\"sheet\"; filename=\"s.csv\"\r\n\r\n{field.stock_csv}\r\n--b--\r\n").encode()
            urlopen(Request(f"{fernway}/import", data=body, headers={"content-type": "multipart/form-data; boundary=b"}))
            self.assertTrue(BY_NAME["stock_import"].check(field.state())[0])
        finally:
            for server in servers:
                server.shutdown()


def command_test(_):
    suite = unittest.TestSuite()
    for case in (Parsing, Checks, Served):
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(case))
    result = unittest.TextTestRunner(verbosity=1).run(suite)
    return 0 if result.wasSuccessful() else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("test", help="the offline self-test")
    run = commands.add_parser("run", help="run the field")
    run.add_argument("--host", help="run the worlds and sites on this Mac over ssh, from a checkout at --repo")
    run.add_argument("--repo", help="the checkout on --host, built, at the same commit")
    run.add_argument("--python", default="python3", help="python on --host")
    run.add_argument("--claude", default="claude", help="the agent command, Claude Code's claude")
    run.add_argument("--models", default="haiku,opus", help="comma separated, each run as a fresh agent")
    run.add_argument("--tasks", default="all", help="comma separated task names, or all")
    run.add_argument("--repeat", type=int, default=1)
    run.add_argument("--turns", type=int, default=40, help="the most model turns an agent gets for one task")
    run.add_argument("--minutes", type=float, default=8, help="the most wall clock an agent gets for one task")
    run.add_argument("--budget", type=int, default=2_000_000, help="stop starting tasks past this many fresh tokens")
    run.add_argument("--out", help="where results go, .context/agent-field/TIME by default")
    shown = commands.add_parser("table", help="print the table of a finished run")
    shown.add_argument("folder")
    commands.add_parser("serve", help="serve the fixture sites")
    for name in ("call", "put", "get", "world"):
        hidden = commands.add_parser(name)
        hidden.add_argument("payload")
    args = parser.parse_args()
    if args.command in ("call", "put", "get", "world"):
        return {"call": command_call, "put": command_put, "get": command_get, "world": command_world}[args.command](decode(args.payload))
    return {"run": command_run, "table": command_table, "serve": command_serve, "test": command_test, None: command_test}[args.command](args)


if __name__ == "__main__":
    sys.exit(main())
