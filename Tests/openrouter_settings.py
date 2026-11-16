#!/usr/bin/env python3
"""The OpenRouter key row in Settings › Tabs, against a local stub that stands in for OpenRouter.

    ./build.sh && python3 Tests/openrouter_settings.py [OUT]

Pictures of the Settings window by id, light and dark: no key, a refused key, a
saved key and a saved key after trouble. It checks the row's words, that the
stub saw only key checks, and that nothing in the bench's answers holds a key.
"""
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import openrouter_stub  # noqa: E402

SHOT = Path(tempfile.gettempdir()) / f"openrouter-settings-shot-{os.getpid()}"
GOOD = "sk-or-good-probe-key"
BAD = "sk-or-refused-probe-key"
failures = []


def check(what, ok, seen=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {what}" + ("" if ok else f": {seen}"), flush=True)
    if not ok:
        failures.append(what)


def windows(pid):
    out = subprocess.run([str(SHOT), str(pid), "list"], capture_output=True, text=True).stdout
    return [line.split("\t") for line in out.splitlines() if len(line.split("\t")) == 3]


def key(action, value=None):
    request = {"do": "aigroups", "args": ["key", action]}
    if value is not None:
        request["key"] = value
    said = sv.cmd(request)
    check(f"the bench's answer to key {action} holds no key", "sk-or" not in json.dumps(said), said)
    return said


def row(name):
    items = sv.cmd({"do": "settings"}).get("items", [])
    return next((item for item in items if item.get("id") == name), {})


def onboarding(action="state"):
    said = sv.cmd({"do": "onboarding", "action": action})
    check(f"the onboarding's answer to {action.partition(':')[0]} holds no key", "sk-or" not in json.dumps(said), said)
    return said


def settle(test, seconds=5):
    said = onboarding()
    for _ in range(int(seconds * 10)):
        if test(said):
            break
        time.sleep(0.1)
        said = onboarding()
    return said


def walk():
    onboarding("close")
    sv.cmd({"do": "onboarding", "action": "replay", "reduced": True})
    onboarding("skip")
    said = onboarding()
    for _ in range(len(said.get("steps", []))):
        if said.get("step") == "key":
            break
        said = onboarding("later")
    steps = said.get("steps", [])
    check("the onboarding reaches the key step", said.get("step") == "key", said.get("step"))
    check("the key step is neither first nor last", "key" in steps and 0 < steps.index("key") < len(steps) - 1, steps)
    onboarding("keys-page")
    said = onboarding()
    check("Get a Key goes to OpenRouter's keys page", said.get("opened") == ["https://openrouter.ai/settings/keys"], said.get("opened"))
    onboarding("key:" + BAD)
    onboarding("primary")
    said = settle(lambda s: s.get("keyNote") not in ("", "Checking the key with OpenRouter"))
    check("a refused key says so in place", said.get("keyNote") == "OpenRouter turned this key down", said.get("keyNote"))
    check("a refused key stays on the step", said.get("step") == "key" and not said.get("keySaved"), said)
    onboarding("key:" + GOOD)
    onboarding("primary")
    said = settle(lambda s: s.get("step") != "key")
    check("a good key is saved and the walk goes on", said.get("step") == "bring" and said.get("keySaved"), said)
    key("remove")
    sv.cmd({"do": "onboarding", "action": "go:key"})
    onboarding("key:" + BAD)
    onboarding("later")
    said = onboarding()
    check("Not Now goes on past a typed key without checking it", said.get("step") == "bring" and not said.get("keySaved"), said)
    onboarding("close")


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "after" / "openrouter-settings")
    out.mkdir(parents=True, exist_ok=True)
    log = Path(tempfile.gettempdir()) / f"openrouter-stub-{os.getpid()}.jsonl"
    server, base = openrouter_stub.start(0, str(log))
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/SettingsShot.swift"), "-o", str(SHOT)], check=True)
    sv.use("openrouter-settings")
    sv.setup(ai=True, **{"start.fresh": True, "tabs.groups": True, "ai.groups": True})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1",
                    "--env", f"SEARCH_OPENROUTER_BASE={base}", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        main_windows = {w[0] for w in windows(pid)}
        sv.cmd({"do": "ui", "settings": True})
        time.sleep(1.5)
        settings = [w for w in windows(pid) if w[0] not in main_windows]
        if not settings:
            print("no Settings window to shoot", windows(pid))
            return 1
        number = max(settings, key=lambda w: int(w[1].partition("x")[0] or 0) * int(w[1].partition("x")[2] or 0))[0]

        def shoot(name):
            sv.cmd({"do": "ui", "settingsPage": "general"})
            time.sleep(0.4)
            sv.cmd({"do": "ui", "settingsPage": "tabs"})
            time.sleep(1.2)
            for theme in ("light", "dark"):
                sv.cmd({"do": "ui", "look": theme})
                time.sleep(0.8)
                path = out / f"{name}-{theme}.png"
                subprocess.run([str(SHOT), str(pid), number, str(path)], capture_output=True, text=True)
                print("  shot", path.name, flush=True)

        key("remove")
        shoot("1-no-key")
        check("with no key the row offers one", row("groups.openrouter").get("title") == "OpenRouter key", row("groups.openrouter"))
        said = key("save", BAD)
        check("a refused key is not saved", not said.get("present"), said)
        check("a refused key says so plainly", said.get("trouble") == "OpenRouter turned this key down", said)
        shoot("2-refused-key")
        said = key("save", GOOD)
        check("a good key is saved", said.get("present") and not said.get("trouble"), said)
        state = sv.cmd({"do": "aigroups", "args": ["state"]})
        check("with a key, OpenRouter names", state.get("namer") == "openRouter", state.get("namer"))
        shoot("3-saved-key")
        key("fail")
        shoot("4-saved-key-trouble")
        key("remove")
        state = sv.cmd({"do": "aigroups", "args": ["state"]})
        check("removing the key goes back to this Mac", state.get("namer") in ("thisMac", ""), state.get("namer"))
        walk()
        asked = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        check("the stub saw only key checks", asked and all(a["method"] == "GET" and a["path"].endswith("/key") for a in asked), asked)
    finally:
        sv.finish()
        server.shutdown()
    print(f"{len(failures)} failed" if failures else "all passed", "· shots in", out)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
