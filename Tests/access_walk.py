#!/usr/bin/env python3
"""Every control VoiceOver can reach has a name, in a test copy of its own.

Build first (`./build.sh`), then `python3 Tests/access_walk.py [--json PATH]
[--list]`. A test copy in a world of its own, shown behind the app in front
(SEARCH_SHOWN), never brought forward. It fills the column (pins, a folder,
loose tabs), then walks the AppKit view tree of every window with bench
`axaudit` at each stop: the shell, the internal pages and every Settings page
and drill-in. A gap is a button-like element with no label, or a view that
takes clicks but is hidden from VoiceOver. `--list` prints every gap.
"""
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("access-walk")

PAGES = ["bookmarks", "history", "downloads", "files", "passwords", "import"]
SETTINGS = ["general", "field", "appearance", "websites", "tabs", "shortcuts", "agents", "livefolders", "passwords", "privacy",
            "extensions"]
DETAILS = ["linkrule"]


DIRECT = None


def launch():
    global DIRECT
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    if "--direct" in sys.argv:
        log = open(Path(__file__).resolve().parents[1] / ".context/access-walk-app.log", "w")
        DIRECT = subprocess.Popen([f"{sv.APP}/Contents/MacOS/Broadway"], stdout=log, stderr=subprocess.STDOUT,
                                  env={**os.environ, "SEARCH_PROBE": sv.W, "SEARCH_SHOWN": "1"})
    else:
        subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)


def audit(stop, only_settings=False):
    found = []
    print(f"  {stop}: pids {sv.pids()}", flush=True)
    for w in sv.cmd({"do": "axaudit"})["windows"]:
        if only_settings and w["type"] != "SettingsFrame": continue
        for gap in w["gaps"]:
            found.append({**gap, "stop": stop, "window": w["type"]})
    return found


def key(gap):
    return (gap["kind"], gap["type"], gap["id"], gap["path"], gap["near"])


def main():
    out = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    t = sv.T()
    gaps = []
    try:
        sv.setup(spaces=True, sidebar=True, **{"tabs.groups": True, "start.fresh": True})
        launch()
        a = sv.page("a"); b = sv.page("b"); c = sv.page("c"); d = sv.page("d"); e = sv.page("e")
        sv.cmd({"do": "pin", "id": a}); time.sleep(0.3)
        sv.cmd({"do": "group", "id": c, "new": True, "name": "Work"}); sv.cmd({"do": "group", "id": d, "name": "Work"}); time.sleep(0.6)
        sv.sp("select", id=e); time.sleep(0.6)
        gaps += audit("shell")
        for page in PAGES:
            sv.cmd({"do": "ui", "lead": page}); time.sleep(0.9)
            gaps += [g for g in audit(f"page:{page}") if g["window"] != "SettingsFrame"]
        sv.cmd({"do": "ui", "settings": True}); time.sleep(1.5)
        for page in SETTINGS:
            sv.cmd({"do": "ui", "settingsPage": page}); time.sleep(0.8)
            gaps += audit(f"settings:{page}", only_settings=True)
        for detail in DETAILS:
            sv.cmd({"do": "ui", "settingsDetail": detail}); time.sleep(0.8)
            gaps += audit(f"settings:{detail}", only_settings=True)
    except Exception as error:
        t.ok("the walk ran to the end", False, error)
        if DIRECT is not None:
            time.sleep(1)
            print("app exit status:", DIRECT.poll())
    finally:
        sv.finish()
    unique = {}
    for g in gaps:
        unique.setdefault(key(g), {**g, "stops": []})["stops"].append(g["stop"])
    rows = sorted(unique.values(), key=lambda g: (g["window"], g["kind"], g["type"], g["path"]))
    if "--list" in sys.argv or not out:
        for g in rows:
            print(f"{g['kind']:22} {g['type']:28} id={g['id']!r:24} near={g['near']!r:40} {g['path']}  [{', '.join(sorted(set(g['stops'])))[:80]}]")
    if out:
        Path(out).write_text(json.dumps(rows, indent=1))
    t.ok("every reachable control has a name", not rows, f"{len(rows)} gaps")
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
