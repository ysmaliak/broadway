#!/usr/bin/env python3
"""The join: a pull request row at the moment it turns merged, pictured.

Build first (`./build.sh`), then `python3 Tests/merged_join_shots.py [OUT]`.

A hidden test copy in a world of its own reads a fake signed-in GitHub on
::1 through `integrations.api` (the fake of Tests/merged_stack.py), so the
rows carry github.com addresses and nothing is asked of the real site. Every
pull request, repository and person is invented.

A row turns merged and the copy draws its own sidebar at fixed moments
through the turn (`mergedturn`, test runs only), as its layers stand at that
moment: the icon gives way to two branches that draw and meet in a node, the
sign rests through the hold, and the row leaves. Nothing is taken from a
screen. The scenes: a plain sidebar light and dark, a tinted one light and
dark, the row under the pointer, the row of the page in front, a stack whose
members turn with it, three unrelated rows in one go, and Reduce Motion.

The probe also asks each row how it turned: the one row that plays draws all
of it, a stack member and the other rows of one read fade the sign in, and
under Reduce Motion the sign is simply there.

OUT (default .context/merged-join-shots) gets one folder per scene with
every frame, sheet-turn.png with the turn on four grounds, sheet-rows.png
with the other scenes, and merged-join-shots.json.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARGS = sys.argv[1:]
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import merged_stack as ms  # noqa: E402
import split_view as sv  # noqa: E402

OUT = (Path(ARGS[0]) if ARGS else ROOT / ".context" / "merged-join-shots").resolve()
HOLD = 1.6
TIMES = [0.06, 0.14, 0.24, 0.36, 0.5, 0.8, 1.2, 1.5]
AFTER = [0.02, 0.06, 0.1, 0.4]
MOMENTS = ["before"] + [f"{m:.2f}" for m in TIMES] + [f"left-{m:.2f}" for m in AFTER]
LEAVING = "left-0.06"
GONE = "left-0.40"
LATE = 0.045
PEAK = "0.36"
REST = "1.20"
SIGN = 4
TINT = {"custom": "3139FB", "intensity": 2.0, "glass": False, "transparency": 0, "grain": 0}
SCALE = 2
TALL = 150
TOOLS = ROOT / ".context" / "merged-join-tools"
SHEET = TOOLS / "sheet"
t = sv.T()
rounds = [0]


def seed():
    rounds[0] += 1
    n = 100 * rounds[0]
    rows = {
        n + 1: ("acme/rocket", "main", f"guide-{n}", None, None, "Fix a typo in the guide"),
        n + 2: ("acme/rocket", "main", f"graph-{n}", None, None, "Cache the build graph so cold builds stop resolving every package"),
        n + 3: ("acme/rocket", "main", f"swift-{n}", None, None, "Bump Swift to 6.2"),
        n + 4: ("acme/rocket", "main", f"rail-model-{n}", n, 1, "Rail - Add the model"),
        n + 5: ("acme/rocket", f"rail-model-{n}", f"rail-store-{n}", n, 2, "Rail - Keep rails in the store"),
        n + 6: ("acme/rocket", f"rail-store-{n}", f"rail-view-{n}", n, 3, "Rail - Show the rail beside the list"),
        n + 7: ("acme/rocket", "main", f"count-{n}", None, None, "Teach the rocket to count"),
    }
    ms.PR.clear()
    ms.PR.update(rows)
    ms.ORDER[:] = sorted(rows)
    ms.STATE.clear()
    ms.STATE.update({k: "open" for k in rows})
    ms.STAMPS.clear()
    ms.STAMPS.update({k: "2026-11-10T09:00:00Z" for k in rows})
    found = ms.read()
    for _ in range(30):
        if sorted(found) == sorted(rows) and " 3/3" in (found.get(n + 6) or {}).get("byline", ""):
            break
        time.sleep(0.5)
        found = ms.read()
    for k in rows:
        ms.live("seen", ms.url(k))
    time.sleep(0.4)
    return n, found


def turn(**fields):
    return sv.cmd({"do": "mergedturn", **fields})


def frames(name, turned, around, **fields):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    for number in turned:
        ms.STATE[number] = "merged"
    drawn = Path(tempfile.mkdtemp())
    try:
        got = turn(frames=str(drawn), turn=[ms.url(k) for k in turned], place=[ms.url(around)], times=TIMES, after=AFTER, scale=SCALE, height=430, **fields)
        for file in sorted(drawn.glob("*.png")):
            shutil.move(str(file), str(folder / file.name))
    finally:
        shutil.rmtree(drawn, ignore_errors=True)
    got["folder"] = str(folder)
    (folder / "frames.json").write_text(json.dumps(got, indent=1, sort_keys=True))
    time.sleep(0.5)
    return got


def lateness(got):
    worst = 0
    for shot in got["frames"]:
        name = shot["name"]
        if name == "before":
            continue
        asked = float(name.split("-")[-1])
        worst = max(worst, abs(shot["t"] - asked))
    return worst


def crop(got, name, moment, around):
    shot = next((f for f in got["frames"] if f["name"] == moment and f.get("file")), None)
    if not shot:
        return None
    x, y, w, h = got["rows"][ms.url(around)]
    top = max(0, min(got["size"][1] - TALL, y + h / 2 - TALL / 2))
    out = OUT / f"{name}-{moment}.png"
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(Path(got["folder"]) / shot["file"]), "-vf",
                    f"crop={int(got['size'][0] * SCALE)}:{int(TALL * SCALE)}:0:{int(top * SCALE)},scale=iw*2:ih*2:flags=lanczos", str(out)], check=True)
    return out


def sheet(out, columns, cells, width):
    if not SHEET.exists():
        TOOLS.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/ContactSheet.swift"), "-o", str(SHEET)], check=True)
    made = [f"{label}={path}" for label, path in cells if path]
    subprocess.run([str(SHEET), str(out), str(columns), str(width * SCALE * 2), str(TALL * SCALE * 2), *made], check=True, capture_output=True)
    return out.exists()


def tab_of(number):
    for tab in ms.prs().get("tabs", []):
        if tab["key"] == ms.url(number):
            return tab["id"]
    raise RuntimeError(f"no row for #{number}")


def said_at(got, moment):
    shot = next((f for f in got["frames"] if f["name"] == moment), None)
    return {row["url"]: row for row in (shot or {}).get("rows", [])}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sv.use("merged-join-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", ms.BASE], check=True)
    sv.launch()
    said = {"scenes": {}}
    cells = []
    try:
        ms.PR.clear()
        ms.ORDER[:] = []
        ms.live("add-page", "PRs", "pullRequests", ms.PULLS)
        ms.live("unfold", "PRs")
        set_up = turn(hold=HOLD, sight=True)
        t.ok("the row is held for the hold", set_up["hold"] == HOLD, set_up)
        width = None

        def scene(label, turned, forms, around=None, moments=None, before=None, **fields):
            nonlocal width
            slow = 0
            for attempt in range(4):
                n, found = seed()
                numbers = [n + k for k in turned]
                if before:
                    before(n)
                    time.sleep(0.6)
                middle = n + (around or turned[len(turned) // 2])
                got = frames(label, numbers, middle, **fields)
                slow = lateness(got)
                if slow <= LATE:
                    break
            width = got["size"][0]
            shown = [f for f in got["frames"] if f.get("file")]
            t.ok(f"{label}: every frame is drawn", len(shown) == len(MOMENTS), [f["name"] for f in got["frames"]])
            t.ok(f"{label}: every frame is taken at its moment", slow <= LATE, (slow, attempt))
            t.ok(f"{label}: the row is let go when the hold ends", HOLD - 0.01 <= got["left"] <= HOLD + 0.3, got["left"])
            held = said_at(got, REST)
            watched = numbers + ([middle] if middle not in numbers else [])
            how = [held.get(ms.url(k), {}).get("form") for k in watched]
            t.ok(f"{label}: the rows turn as {' and '.join(forms)}", sorted(how) == sorted(forms), how)
            t.ok(f"{label}: every turning row wears the whole sign", all(held.get(ms.url(k), {}).get("drawn") == SIGN for k in watched), held)
            first = said_at(got, "before")
            played = sum(row.get("plays", 0) for row in held.values()) - sum(row.get("plays", 0) for row in first.values())
            t.ok(f"{label}: one row plays at most", played == forms.count("full"), (first, held))
            gone = said_at(got, GONE)
            t.ok(f"{label}: nothing of it is left after the hold",
                 all(not gone.get(ms.url(k), {}).get("merging") and gone.get(ms.url(k), {}).get("drawn", 0) == 0 for k in watched), gone)
            said["scenes"][label] = {"late": round(slow, 3), "left": got["left"], "tries": attempt + 1, "forms": how,
                                     "frames": [(f["name"], f["t"], [(r["merging"], r["shown"], r["form"], r["plays"], r["drawn"]) for r in f["rows"]])
                                                for f in got["frames"]]}
            for moment in moments or MOMENTS:
                cells.append((f"{label} {moment}", crop(got, label, moment, middle)))
            return got

        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(0.5)
            scene(f"plain-{look}", [2], ["full"])
        sv.cmd({"do": "ui", "look": "light"})
        time.sleep(0.5)
        few = ["before", PEAK, "0.50", REST, LEAVING]
        scene("hovered", [2], ["full"], moments=few, before=lambda n: sv.cmd({"do": "rowhover", "id": tab_of(n + 2), "on": True}))
        scene("selected", [2], ["full"], moments=few, before=lambda n: turn(lit=ms.url(n + 2)))
        scene("stack", [6], ["full", "quiet"], around=5, moments=few)
        scene("three", [1, 2, 3], ["full", "quiet", "quiet"], moments=few)
        turn(reduced=True)
        scene("reduced", [2], ["still"], moments=few)
        turn(reduced=None)
        sv.cmd({"do": "space", "action": "look", **TINT})
        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            time.sleep(0.6)
            scene(f"tinted-{look}", [2], ["full"])
        ordered = [c for c in cells if c[0].startswith(("plain-", "tinted-"))]
        t.ok("a contact sheet of the turn on four grounds", sheet(OUT / "sheet-turn.png", len(MOMENTS), ordered, width))
        rest = [c for c in cells if not c[0].startswith(("plain-", "tinted-"))]
        t.ok("a contact sheet of the other rows", sheet(OUT / "sheet-rows.png", len(few), rest, width))
        said["width"] = width
    finally:
        sv.finish()
        (OUT / "merged-join-shots.json").write_text(json.dumps(said, indent=1))
        shutil.rmtree(TOOLS, ignore_errors=True)
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
