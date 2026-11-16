#!/usr/bin/env python3
"""Pictures of making three link rules in Settings › Links, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/link_rule_shots.py OUT`. The
app starts hidden in a world of its own (see split_view.use), Settings opens
as a tab of that hidden window, and each picture is of that one window by its
window id. Nothing is shown or brought forward, and the world is removed
afterwards.

The three rules: an app to a space (links from Slack open in Work), a site to
another browser (figma.com opens in Safari), and a pattern
(github.com/*/pull/* opens in Work). Each is pictured step by step, in dark
and light, with the list before and after.
"""
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("link-rule-shots")
ROOT = Path(__file__).resolve().parents[1]
TMP = Path(os.environ.get("TMPDIR", "/tmp")) / f"link-rule-shots-{os.getpid()}"
SHOT = TMP / "shot"
SLACK = "app:com.tinyspeck.slackmacgap:Slack"
STEPS = {
    "app-to-space": [
        ("1-source", ["rule", "pattern", "*", SLACK, "space", "Personal"]),
        ("2-done", ["rule", "pattern", "*", SLACK, "space", "Work"]),
    ],
    "site-to-browser": [
        ("1-site", ["rule", "site", "figma.com", "anywhere", "space", "Personal"]),
        ("2-done", ["rule", "site", "figma.com", "anywhere", "app", "com.apple.Safari", "Safari"]),
    ],
    "pattern": [
        ("1-typed", ["rule", "pattern", "github.com/*/pull/*", "anywhere", "space", "Personal"]),
        ("2-done", ["rule", "pattern", "github.com/*/pull/*", "anywhere", "space", "Work"]),
    ],
}


def tool():
    TMP.mkdir(parents=True, exist_ok=True)
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(TMP), check=True)


def ui(**f): return sv.cmd({"do": "ui", **f})
def route(*args): return sv.cmd({"do": "route", "args": list(args)})


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "shots").resolve()
    out.mkdir(parents=True, exist_ok=True)
    tool()
    sv.setup(spaces=True, **{"start.fresh": True})
    sv.launch()
    pid = next(iter(sv.holding() & sv.running()))
    shots = []

    def shoot(name):
        path = out / f"{name}.png"
        for _ in range(4):
            got = subprocess.run([str(SHOT), pid, str(number), str(path)], cwd=str(TMP), capture_output=True, text=True)
            if path.exists():
                shots.append(path.name)
                return
            time.sleep(0.8)
        print("no picture", name, got.stdout.strip(), got.stderr.strip()[-300:])

    try:
        sv.cmd({"do": "space", "action": "new", "name": "Work"}); time.sleep(0.8)
        sv.cmd({"do": "space", "action": "go", "index": 1}); time.sleep(0.8)
        sv.cmd({"do": "space", "action": "rename", "name": "Personal"}); time.sleep(0.4)
        sv.cmd({"do": "resize", "width": int(os.environ.get("LINK_SHOTS_WIDTH", 1040)),
                "height": int(os.environ.get("LINK_SHOTS_HEIGHT", 1500)), "steps": 1})
        ui(settings=True); time.sleep(1.5)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(0.8)
        said = {}
        gaps = {}
        for theme in ["dark", "light"]:
            ui(look=theme); time.sleep(0.8)
            route("clear")
            ui(settingsPage="links"); time.sleep(1.2)
            shoot(f"0-list-empty-{theme}")
            try:
                ui(settingsPress="settings.links.add"); time.sleep(1.2)
                shoot(f"0-new-rule-{theme}")
            except RuntimeError as error:
                print("no Add Rule to press:", error)
            for name, steps in STEPS.items():
                for step, args in steps:
                    ui(settingsPage="links"); time.sleep(0.4)
                    route("clear")
                    said[f"{name}-{step}"] = route(*args).get("routes")
                    ui(settingsDetail="linkrule"); time.sleep(1.2)
                    shoot(f"{name}-{step}-{theme}")
            try:
                ui(settingsPress="settings.row.link.more"); time.sleep(1.2)
                shoot(f"pattern-3-more-{theme}")
                gaps[theme] = [gap for w in sv.cmd({"do": "axaudit"})["windows"] for gap in w["gaps"]]
            except RuntimeError as error:
                print("no More Options to press:", error)
            ui(settingsPage="links"); time.sleep(0.4)
            route("clear")
            for steps in STEPS.values():
                route(*steps[-1][1])
            time.sleep(1.2)
            shoot(f"9-list-three-{theme}")
        (out / "rules.json").write_text(json.dumps(said, indent=1))
        (out / "access.json").write_text(json.dumps(gaps, indent=1))
        print("gaps VoiceOver would meet on the rule's page:", {theme: len(found) for theme, found in gaps.items()})
        print(f"{len(shots)} pictures in {out}")
    finally:
        sv.finish()
        shutil.rmtree(TMP, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
