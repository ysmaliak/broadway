#!/usr/bin/env python3
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("set-confirm")
ROOT = Path(__file__).resolve().parents[1]
SHOT = Path(os.environ.get("TMPDIR", "/tmp")) / f"settings-confirm-shot-{os.getpid()}"
SHOTS = os.environ.get("SETTINGS_CONFIRM_SHOTS")


def ui(**f): return sv.cmd({"do": "ui", **f})
def rules(): return sv.cmd({"do": "route", "args": []})["routes"]
def recent(): return sv.cmd({"do": "route", "args": []})["recent"]
def speeds(): return sv.cmd({"do": "settings"})["speeds"]


def windows(pid):
    out = subprocess.run([str(SHOT), str(pid), "list"], capture_output=True, text=True).stdout
    return {line.split("\t")[0]: line.split("\t")[1] for line in out.splitlines() if line.count("\t") == 2}


def go(page, detail=None):
    ui(settingsFind="")
    time.sleep(0.2)
    ui(settingsPage=page)
    time.sleep(0.8)
    if detail:
        ui(settingsDetail=detail)
        time.sleep(1)


def key(code, chars):
    sv.cmd({"do": "press", "code": code, "chars": chars, "sheet": True})
    time.sleep(0.8)


def sheet():
    said = sv.cmd({"do": "probe"})
    return said.get("sheetReturn", "") if said.get("sheet") else None


def answer(title):
    ui(sheetPress=title)
    time.sleep(0.8)


def main():
    t = sv.T()
    sv.setup(spaces=True, **{"video.speed": True})
    subprocess.run(["defaults", "write", sv.SUITE, "rate.youtube.com", "-float", "1.5"], check=True)
    sv.launch()
    pid = next(iter(sv.holding() & sv.running()))
    try:
        ui(settings=True)
        time.sleep(1)
        sv.cmd({"do": "route", "args": ["add", "notion.so", "peek"]})
        sv.cmd({"do": "route", "args": ["pattern", "127.0.0.1:9/*", "front"]})
        sv.cmd({"do": "route", "args": ["arrive", "http://127.0.0.1:9/confirm"]})
        time.sleep(1)
        ui(settings=True)
        time.sleep(1)
        t.ok("a recent link to clear", len(recent()) == 1, recent())
        t.ok("a rule to delete", [r["site"] for r in rules()][:1] == ["notion.so"] and len(rules()) == 2, rules())
        t.ok("a video speed to forget", speeds() == {"youtube.com": 1.5}, speeds())

        go("links", "linkrule")
        ui(confirm=False)
        ui(settingsPress="settings.row.link.delete")
        time.sleep(0.5)
        t.ok("Delete Rule… answered No keeps the rule", len(rules()) == 2, rules())
        go("websites")
        ui(settingsPress="settings.privacy.forget")
        time.sleep(0.5)
        t.ok("Forget Choices… answered No keeps every choice", speeds() == {"youtube.com": 1.5}, speeds())
        go("links")
        ui(settingsPress="settings.links.clearRecent")
        time.sleep(0.5)
        t.ok("Clear… answered No keeps the recent links", len(recent()) == 1, recent())

        ui(confirm="ask")
        places = [("rule", ("links", "linkrule"), "settings.row.link.delete", "Cancel"),
                  ("choices", ("websites",), "settings.privacy.forget", "Cancel"),
                  ("recent", ("links",), "settings.links.clearRecent", "")]
        if SHOTS:
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/SheetShot.swift"), "-o", str(SHOT)], check=True)
            out = Path(SHOTS)
            out.mkdir(parents=True, exist_ok=True)
            parent = str(sv.cmd({"do": "idle"})["number"])
            for theme in ["dark", "light"]:
                ui(look=theme)
                time.sleep(0.8)
                for name, place, control, default in places:
                    go(*place)
                    before = set(windows(pid))
                    ui(settingsPress=control)
                    time.sleep(1.2)
                    sheets = [w for w in windows(pid) if w not in before]
                    t.ok(f"{name}: the question is up as a sheet ({theme})", len(sheets) == 1, sheets)
                    t.ok(f"{name}: Return is {default or 'no button'}'s ({theme})", sheet() == default, sheet())
                    if sheets:
                        said = subprocess.run([str(SHOT), str(pid), parent, sheets[0], str(out / f"{name}-{theme}.png")],
                                              capture_output=True, text=True).stdout.strip()
                        print("  ", said)
                        t.ok(f"{name}: pictured ({theme})", (out / f"{name}-{theme}.png").exists(), said)
                    answer("Cancel")
                    t.ok(f"{name}: Cancel takes the question away ({theme})", sheet() is None, sheet())
        go("links", "linkrule")
        ui(settingsPress="settings.row.link.delete")
        time.sleep(1)
        t.ok("Delete Rule… asks, and Return is Cancel's", sheet() == "Cancel", sheet())
        key(53, "\u001b")
        t.ok("Escape on Delete Rule… takes it away and the rule stays", sheet() is None and len(rules()) == 2, (sheet(), rules()))
        t.ok("after every Cancel nothing was lost", speeds() == {"youtube.com": 1.5} and len(rules()) == 2 and len(recent()) == 1,
             (speeds(), rules(), recent()))
        go("links")
        ui(settingsPress="settings.links.clearRecent")
        time.sleep(1)
        answer("Clear")
        t.ok("Clear pressed on the real question empties the list", sheet() is None and recent() == [], (sheet(), recent()))

        ui(confirm=True)
        go("links", "linkrule")
        ui(settingsPress="settings.row.link.delete")
        time.sleep(0.5)
        t.ok("Delete Rule… answered Yes deletes it", len(rules()) == 1, rules())
        go("websites")
        ui(settingsPress="settings.privacy.forget")
        time.sleep(0.5)
        t.ok("Forget Choices… answered Yes forgets", speeds() == {}, speeds())
        ui(confirm="ask")
    finally:
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
