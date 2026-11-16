#!/usr/bin/env python3
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("set-chrome")
ROOT = Path(__file__).resolve().parents[1]
SHOT = Path(os.environ.get("TMPDIR", "/tmp")) / f"settings-chrome-{os.getpid()}"
PLACES = [("page", "privacy"), ("page", "passwords"), ("page", "general"), ("detail", "languages"),
          ("find", "tab"), ("page", "extensions")]
PLACES += [(k, n) for k, n in [("page", "livefolders"), ("page", "agents")] if os.environ.get("SETTINGS_CHROME_ALL")]
if os.environ.get("SETTINGS_CHROME_CLOSE_ONLY"):
    PLACES = []


def windows(pid):
    out = subprocess.run([str(SHOT), str(pid), "list"], capture_output=True, text=True).stdout
    return [line.split("\t") for line in out.splitlines() if line.count("\t") == 2]


def go(kind, name):
    if kind == "find":
        sv.cmd({"do": "ui", "settingsFind": name})
    else:
        sv.cmd({"do": "ui", "settingsFind": ""})
        time.sleep(0.3)
        sv.cmd({"do": "ui", "settingsPage" if kind == "page" else "settingsDetail": name})
    time.sleep(1.3)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "shots")
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/SettingsShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup(spaces=True, ai=True, **{"start.fresh": True})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    report = {}
    failures = []
    wheel_failures = []
    try:
        main_windows = {w[0] for w in windows(pid)}
        sv.cmd({"do": "ui", "settings": True})
        time.sleep(1.5)
        settings = [w for w in windows(pid) if w[0] not in main_windows]
        if not settings:
            print("SKIP: no Settings window to shoot", windows(pid))
            return 0
        number = settings[0][0]
        if os.environ.get("SETTINGS_CHROME_KEY", "1") == "1":
            sv.cmd({"do": "idle", "action": "front"})
            time.sleep(0.3)
            sv.cmd({"do": "ui", "settings": True})
            time.sleep(0.8)
        for theme in ["dark", "light"]:
            sv.cmd({"do": "ui", "look": theme})
            time.sleep(0.8)
            for kind, name in PLACES:
                go(kind, name)
                rest = None
                for state, y in [("rest", 0.0), ("scrolled", 160.0)]:
                    if state == "rest":
                        reply = sv.cmd({"do": "settings", "find": "", "scroll": y, "chrome": True})
                    else:
                        sv.cmd({"do": "settings", "find": "", "wheel": [y, 560.0, 420.0]})
                        time.sleep(0.4)
                        reply = sv.cmd({"do": "settings", "find": "", "chrome": True})
                        offset = next((s["offset"] for s in reply.get("chrome", {}).get("scrolls", []) if s.get("content")), None)
                        wheeled = offset is not None and rest is not None and offset > rest + 20
                        print(name, theme, "wheel moved the page" if wheeled else "WHEEL DID NOT MOVE THE PAGE", rest, offset)
                        room = next((s["document"] - s["frame"][3] for s in reply.get("chrome", {}).get("scrolls", []) if s.get("content")), 0)
                        if not wheeled and room > 40:
                            wheel_failures.append(f"{name} {theme}")
                            reply = sv.cmd({"do": "settings", "find": "", "scroll": y, "chrome": True})
                    time.sleep(0.6)
                    path = out / f"{name}-{theme}-{state}.png"
                    subprocess.run([str(SHOT), str(pid), number, str(path)], capture_output=True, text=True)
                    chrome = reply.get("chrome", {})
                    content = [s for s in chrome.get("scrolls", []) if s.get("content")]
                    report[f"{name}-{theme}-{state}"] = chrome
                    if state == "rest":
                        rest = next((s["offset"] for s in content), None)
                    if state == "rest" and not reply.get("scrolled"):
                        failures.append(f"{name} {theme} {state}: no content scroll view")
                    print(name, theme, state, "scrolled" if reply.get("scrolled") else "NOT SCROLLED",
                          "separator", chrome.get("separator"), "items", chrome.get("items"),
                          "content", [(s["class"], s["frame"], s["insetTop"], s["offset"]) for s in content])
                sv.cmd({"do": "settings", "find": "", "scroll": 0.0})
        (out / "chrome.json").write_text(json.dumps(report, indent=1))
        print("shots and chrome.json in", out)
        if os.environ.get("SETTINGS_CHROME_CLOSE", "1") == "1":
            sv.cmd({"do": "open", "url": "about:blank"})
            sv.cmd({"do": "open", "url": "about:blank"})
            time.sleep(0.5)
            sv.cmd({"do": "ui", "settings": True})
            time.sleep(0.8)
            closed = sv.cmd({"do": "closekey", "settings": True})
            print("cmd-w with Settings key:", closed)
            if closed.get("settingsOpen") or closed["tabs"][0] != closed["tabs"][1]:
                failures.append(f"cmd-w with Settings key: {closed}")
            closed = sv.cmd({"do": "closekey"})
            print("cmd-w with the browser key:", closed)
            if closed["tabs"][1] != closed["tabs"][0] - 1:
                failures.append(f"cmd-w with the browser key: {closed}")
    finally:
        sv.cmd({"do": "ui", "settingsFind": ""})
        sv.finish()
    for failure in wheel_failures:
        print("WHEEL", failure)
    for failure in failures:
        print("FAIL", failure)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
