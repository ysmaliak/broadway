#!/usr/bin/env python3
import json
import shutil
import subprocess
import sys
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import side_chrome as sc  # noqa: E402

sv.use("door-centre")
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/door-centre")
sc.OUT = OUT
SIZE = sc.SIZE
t = sv.T()
FACTS = {}
WITHIN = 0.25
LIT = 1.08
READING = 0.03


def pixels(path, box):
    k = sc.scale_of(path)
    x, y, w, h = [round(v * k) for v in box]
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-vf", f"crop={w}:{h}:{x}:{y}",
                          "-f", "rawvideo", "-pix_fmt", "rgb24", "-"], capture_output=True).stdout
    lum = [(raw[i] * 299 + raw[i + 1] * 587 + raw[i + 2] * 114) / 1000 for i in range(0, w * h * 3, 3)]
    return k, x, y, w, h, lum


def median(values):
    return sorted(values)[len(values) // 2]


def span(marked):
    on = [i for i, v in enumerate(marked) if v]
    return (on[0], on[-1] + 1) if on else None


def plate_of(rest, hot, said):
    reach = 1.5
    region = [said[0] - reach, said[1] - reach, said[2] + 2 * reach, said[3] + 2 * reach]
    k, x, y, w, h, a = pixels(rest, region)
    b = pixels(hot, region)[5]
    diff = [abs(p - q) for p, q in zip(a, b)]
    edge = round(reach * k)
    inner = [diff[row * w + col] for row in range(edge + 4, h - edge - 4) for col in range(edge + 4, w - edge - 4)]
    lift = median(inner)
    if lift < 1.5:
        return None
    level = lift / 2
    cols = span([sum(diff[row * w + col] > level for row in range(h)) >= h / 4 for col in range(w)])
    rows = span([sum(diff[row * w + col] > level for col in range(w)) >= w / 4 for row in range(h)])
    if not cols or not rows or cols[0] == 0 or rows[0] == 0 or cols[1] == w or rows[1] == h:
        return None
    return [(x + cols[0]) / k, (y + rows[0]) / k, (cols[1] - cols[0]) / k, (rows[1] - rows[0]) / k]


def edges(profile, top):
    floor = top * 0.15
    on = [i for i, v in enumerate(profile) if v > floor]
    if not on:
        return None
    first, last = on[0], on[-1]
    return first + 1 - min(1, profile[first] / top), last + min(1, profile[last] / top)


def ink_of(path, plate):
    inset = 2.5
    k, x, y, w, h, lum = pixels(path, [plate[0] + inset, plate[1] + inset, plate[2] - 2 * inset, plate[3] - 2 * inset])
    ground = median(lum)
    far = [abs(v - ground) for v in lum]
    top = sorted(far)[-max(1, len(far) // 200)]
    if top < 30:
        return None
    cols = edges([max(far[row * w + col] for row in range(h)) for col in range(w)], top)
    rows = edges([max(far[row * w + col] for col in range(w)) for row in range(h)], top)
    if not cols or not rows:
        return None
    return {"box": [(x + cols[0]) / k, (y + rows[0]) / k, (cols[1] - cols[0]) / k, (rows[1] - rows[0]) / k], "contrast": top}


def off(ink, plate):
    if not ink or not plate:
        return None
    mid = sc.mid(plate)
    box = sc.mid(ink["box"])
    return [round(box[0] - mid[0], 3), round(box[1] - mid[1], 3)]


def doors(on):
    said = sv.cmd({"do": "space", "action": "point", "door": "all", "on": on})["doors"]
    return {door["icon"]: door["plate"] for door in said}


def spot(on):
    sv.cmd({"do": "space", "action": "point", "index": 1, "on": on})


def scene(name, dark, checks=True):
    sc.stage(dark)
    doors(False)
    spot(False)
    time.sleep(0.6)
    rest = sc.shoot(f"{name}-rest")
    said = doors(True)
    spot(True)
    time.sleep(0.6)
    hot = sc.shoot(f"{name}-hot")
    mark = sv.cmd({"do": "columnscroll"}).get("marks", {}).get("Personal")
    doors(False)
    spot(False)
    facts = {}
    if mark:
        said["space"] = mark
    for icon, plate in said.items():
        seen = plate_of(rest, hot, plate) if icon != "space" else None
        used = seen or plate
        at_rest = ink_of(rest, used)
        hovered = ink_of(hot, used)
        facts[icon] = {"said": plate, "seen": seen, "rest": off(at_rest, used), "hot": off(hovered, used),
                       "ink": at_rest and at_rest["box"]}
        if not checks:
            continue
        if icon in ("plus", "downloads"):
            t.ok(f"{name}: the {icon} plate is found in the pixels", bool(seen), plate)
        if seen:
            drift = max(abs(a - b) for a, b in zip(seen, plate))
            t.ok(f"{name}: the {icon} plate is where the app says", drift <= WITHIN, (seen, plate))
        for state, got in (("rest", facts[icon]["rest"]), ("hot", facts[icon]["hot"])):
            t.ok(f"{name}: the {icon} glyph is found {state}", bool(got), used)
            if got:
                within = (WITHIN * LIT if icon == "space" else WITHIN) + READING
                t.ok(f"{name}: the {icon} ink is centred in its plate {state}", abs(got[0]) <= within and abs(got[1]) <= within, got)
    FACTS[name] = facts
    foot = [0, SIZE[1] - 110, sc.COLUMN + 26, 110]
    for state, path in (("rest", rest), ("hot", hot)):
        sc.cut(path, f"{name}-{state}-foot", foot)
        if "plus" in said:
            plate = said["plus"]
            sc.cut(path, f"{name}-{state}-plus", [plate[0] - 8, plate[1] - 8, plate[2] + 16, plate[3] + 16], zoom=8)
        if "downloads" in said:
            plate = said["downloads"]
            sc.cut(path, f"{name}-{state}-downloads", [plate[0] - 8, plate[1] - 8, plate[2] + 16, plate[3] + 16], zoom=8)
        if mark:
            sc.cut(path, f"{name}-{state}-space", [mark[0] - 8, mark[1] - 8, mark[2] + 16, mark[3] + 16], zoom=8)
        sc.cut(path, f"{name}-{state}-top", [0, 0, sc.COLUMN + 26, 96], zoom=4)
    plate = sv.cmd({"do": "space", "action": "point", "door": "plus", "on": True})["doors"][0]["plate"]
    time.sleep(0.6)
    alone = sc.shoot(f"{name}-plus-alone")
    sv.cmd({"do": "space", "action": "point", "door": "plus", "on": False})
    sc.cut(alone, f"{name}-plus-alone-foot", foot, zoom=2)
    sc.cut(alone, f"{name}-plus-alone-crop", [plate[0] - 40, plate[1] - 30, 77, 66], zoom=6)
    return facts


def main():
    shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), sc.Pages)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    sv.setup(spaces=True)
    sv.launch()
    try:
        sc.stage(True)
        sv.cmd({"do": "ui", "spaces": True, "cards": True, "downloadsbutton": True, "sideWidth": sc.COLUMN})
        sv.cmd({"do": "space", "action": "rename", "name": "Personal", "icon": "house"})
        plain = sc.opened(base, "Example page")
        sv.cmd({"do": "ui", "lead": "import"})
        time.sleep(1.0)
        rows, tabs = sc.rows_now()
        bring = next(id for id, tab in tabs.items() if "import" in str(tab.get("internal") or ""))
        for id in [id for id in rows if id not in (plain, bring)]:
            try:
                sv.sp("close", id=id)
            except RuntimeError:
                pass
        time.sleep(1.0)
        sc.look(sc.NOIR)
        scene("noir-dark", True, checks=False)
        scene("noir-light", False, checks=False)
        sc.look(sc.FLAT)
        scene("flat-dark", True)
        scene("flat-light", False)
        sc.look(sc.PALE)
        scene("pale-light", False)
        sc.look(sc.NOIR)
    finally:
        sv.finish()
        server.shutdown()
    (OUT / "facts.json").write_text(json.dumps(FACTS, indent=1))
    for name, facts in FACTS.items():
        for icon, got in facts.items():
            faint = "" if got["seen"] or icon == "space" else " (the frame the app reports, too faint in the pixels)"
            print(f"{name:11} {icon:26} rest {got['rest']} hot {got['hot']} plate {got['seen'] or got['said']}{faint}")
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
