#!/usr/bin/env python3
import json
import subprocess
import time
from pathlib import Path

import visual_diff as vd

GROUNDS = {"white": "#ffffff", "black": "#000000", "picture": "picture"}
GLASS = {
    "float-feedback", "call-bar", "link-bubble", "driving-bar", "capture-question", "screen-question", "password-offer",
    "shield-offer", "find-bar", "find-bar-empty", "find-bar-narrow", "form-fill-card", "form-fill-done", "form-fill-offer",
    "form-drafts-working", "form-drafts-card", "form-drafts-warned", "meeting-alert", "meeting-alert-two",
    "meeting-alert-faces", "meeting-alert-long", "agent-card", "agent-badge", "recent-downloads", "selection-result", "command-list",
    "site-file", "announcement", "agent-ask-outside", "offer-bar", "link-preview", "account-list",
    "update-card", "stuck-card", "field-bar", "mini-player", "float-controls",
}
SURFACES = [
    ("site-file", "site", {"kind": "site"}),
    ("site-file", "more", {"kind": "site", "more": True}),
    ("site-file", "insecure", {"kind": "insecure"}),
    ("site-file", "narrow", {"kind": "insecure", "width": 320}),
    ("announcement", "plain", {"text": "Copied the address without tracking"}),
    ("announcement", "undo", {"text": "Closed 3 tabs", "trailing": "Undo"}),
    ("announcement", "hint", {"text": "⌘W closes a tab"}),
    ("agent-ask-outside", "shown", {}),
    ("offer-bar", "link-notice", {"text": "Open links from Mail in this space?"}),
    ("offer-bar", "developer", {"text": "Turn on Developer Mode for ⌥⌘I?"}),
    ("link-preview", "shown", {}),
    ("update-card", "shown", {}),
    ("stuck-card", "stuck", {}),
    ("stuck-card", "leave", {"kind": "leave"}),
]
NOTES = {"own": "on a colour of its own", "picked": "on the system's selection colour", "off": "on a key that is switched off",
         "video": "straight on the video"}
MUTED_LARGE = 18
unmeasured = set()


def limit(mark):
    return 3.0 if mark.get("muted") and mark.get("size", 0) >= MUTED_LARGE else 4.5


def named(mark):
    words = " ".join(str(mark.get("text", "")).split())
    return f"{mark.get('kind', '')} “{words[:28]}”"


def measure(shown, blank, marks, points):
    kept = blank.with_suffix(".json")
    kept.write_text(json.dumps(marks))
    ran = subprocess.run([str(vd.tool("ink", "InkContrast.swift")), str(shown), str(blank), str(kept), str(points)],
                         capture_output=True, text=True)
    kept.unlink(missing_ok=True)
    if ran.returncode != 0 or not ran.stdout.strip():
        raise RuntimeError((ran.stdout + ran.stderr).strip()[-200:] or "the measure said nothing")
    return json.loads(ran.stdout)


def judge(t, sv, shot, pid, made, label, path, pad, ground, numbers):
    blank = path.parent / "blank" / path.name
    blank.parent.mkdir(parents=True, exist_ok=True)
    blank.unlink(missing_ok=True)
    marks = made.get("inks", [])
    unmeasured.update(made.get("others", []))
    sv.cmd({"do": "surface", "action": "blank"})
    time.sleep(0.4)
    for _ in range(3):
        subprocess.run([str(shot), str(pid), str(made["number"]), str(blank)], capture_output=True, text=True)
        if blank.exists():
            break
        time.sleep(0.5)
    if not blank.exists():
        t.ok(f"{label}: pictured without its words", False, "no still")
        return
    corner = {"kind": "ground", "text": "", "box": [1, 1, 6, 6], "size": 0, "muted": False}
    try:
        said = measure(path, blank, marks + [corner], made["size"][0] + pad * 2)
    except RuntimeError as error:
        t.ok(f"{label}: measured", False, str(error))
        return
    seen = said.pop()
    if ground.startswith("#") and seen.get("behind") is not None:
        want = [int(ground[i:i + 2], 16) for i in (1, 3, 5)]
        t.ok(f"{label}: the ground in the still is the ground asked for", all(abs(a - b) <= 6 for a, b in zip(seen["behind"], want)),
             f"{seen['behind']} for {want}")
    t.ok(f"{label}: has words or symbols to measure", bool(said), str(made.get("others", "")))
    numbers[label] = said
    for mark in said:
        need = limit(mark)
        if mark.get("note") in NOTES:
            continue
        t.ok(f"{label}: {named(mark)} reads at {need:g} to 1 or more", mark["worst"] >= need,
             f"{mark['worst']:g} to 1 at its worst, {mark.get('typical', 0):g} typical, ink {mark.get('ink')}, behind {mark.get('behind')}")


def sheet(folder, state, tag):
    cells = [(f"{look} on {ground}", folder / f"{state}-{look}-{ground}-{tag}.png") for look in ("light", "dark") for ground in GROUNDS]
    cells = [(name, path) for name, path in cells if path.exists()]
    if not cells:
        return None
    sizes = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(cells[0][1])], capture_output=True, text=True).stdout.split()
    wide, tall = int(sizes[-3]), int(sizes[-1])
    out = folder / f"{state}-sheet-{tag}.png"
    subprocess.run([str(vd.tool("sheet", "ContactSheet.swift")), str(out), str(len(GROUNDS)), str(wide), str(tall)]
                   + [f"{name}={path}" for name, path in cells], capture_output=True)
    return out if out.exists() else None


def table(numbers):
    rows = {}
    for label, marks in numbers.items():
        surface, rest = label.split(", ", 1)
        if not marks:
            continue
        some = [m for m in marks if m.get("note") not in NOTES]
        if not some:
            continue
        low = min(some, key=lambda m: m["worst"])
        under = sum(1 for m in some if m["worst"] < limit(m))
        rows.setdefault(surface, {})[rest] = (low["worst"], under, len(some), named(low))
    return rows


def listed(numbers):
    found = {}
    for label, marks in numbers.items():
        surface, rest = label.split(", ", 1)
        for mark in marks:
            if mark.get("note") not in NOTES:
                continue
            key = (NOTES[mark["note"]], f"{surface}: {named(mark)}")
            if key not in found or mark["worst"] < found[key][0]:
                found[key] = (mark["worst"], rest)
    lines = []
    for heading in sorted({key[0] for key in found}):
        lines.append(f"Marks {heading}, listed and not judged")
        for (kind, name), (low, where) in sorted(found.items()):
            if kind == heading:
                lines.append(f"  {name}: lowest {low:g} to 1 ({where})")
    return lines


def summary(numbers):
    lines = []
    for surface, cells in sorted(table(numbers).items()):
        low = min(cells.values(), key=lambda c: c[0])
        under = sum(c[1] for c in cells.values())
        total = sum(c[2] for c in cells.values())
        where = min(cells, key=lambda k: cells[k][0])
        lines.append(f"{surface}: lowest {low[0]:g} to 1 ({low[3]}, {where}), {under} of {total} under the measure")
    return lines


if __name__ == "__main__":
    import sys
    if sys.argv[1] == "sheets":
        root, tag = Path(sys.argv[2]), sys.argv[3]
        for folder in sorted(p for p in root.iterdir() if p.is_dir()):
            for state in sorted({p.name.split("-light-")[0] for p in folder.glob(f"*-light-white-{tag}.png")}):
                print(sheet(folder, state, tag))
    else:
        numbers = json.loads(Path(sys.argv[1]).read_text())
        for line in summary(numbers) + listed(numbers):
            print(line)
