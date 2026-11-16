#!/usr/bin/env python3
"""Manual folder emoji through the folder actions, in a hidden test world."""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("folder-emojis")


def ai(*args):
    return sv.cmd({"do": "aigroups", "args": list(args)})


def folders(*args):
    return sv.cmd({"do": "folders", "args": list(args)})


def settled():
    until = time.time() + 5
    state = ai("state")
    while state["folderEmojiBusy"] and time.time() < until:
        time.sleep(0.05)
        state = ai("state")
    return state


def group(name):
    return next((g for g in settled()["groups"] if g["name"] == name), {})


def main():
    t = sv.T()
    try:
        sv.setup(**{"tabs.groups": True, "ai": True})
        subprocess.run(["defaults", "write", sv.SUITE, "ai.groups", "-bool", "false"], check=True)
        sv.launch()
        tab = sv.page("swift")
        ai("folder-fake")
        folders("with", "References", tab)
        made = group("References")
        t.ok("New Folder with tabs gets an emoji with automatic grouping off",
             made.get("emoji") == "🧑‍💻" and not made.get("ai") and not ai("state")["on"], made)
        sv.sp("save")
        saved = next(g for g in sv.session()["groups"] if g["name"] == "References")
        t.ok("the folder's emoji is saved", saved.get("aiEmoji") == "🧑‍💻", saved)

        another = sv.page("lisbon")
        sv.cmd({"do": "group", "id": another, "new": True, "name": "Trip"})
        t.ok("New Folder from a tab gets its emoji", group("Trip").get("emoji") == "✈️", group("Trip"))

        ai("emoji", "off")
        folders("new", "Off")
        t.ok("the shared emoji switch stops new emoji", group("Off").get("emoji") == "", group("Off"))
        ai("emoji", "on")
        ai("folder-unavailable")
        folders("new", "Unavailable")
        t.ok("no available on-device model means no emoji", group("Unavailable").get("emoji") == "", group("Unavailable"))

        ai("folder-fake", "0.8")
        folders("new", "Manual")
        sv.cmd({"do": "icon", "args": ["set", "folder", "Manual", "emoji", "🌵"]})
        t.ok("an icon picked while the model works wins", group("Manual").get("emoji") == "🌵", group("Manual"))

        folders("new", "Clear")
        sv.cmd({"do": "icon", "args": ["clear", "folder", "Clear"]})
        t.ok("clearing the icon is also the user's choice", group("Clear").get("emoji") == "", group("Clear"))

        ai("folder-fake", "0", "fail")
        folders("new", "Failed")
        t.ok("a model failure leaves the folder usable without an emoji", group("Failed").get("emoji") == "", group("Failed"))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
