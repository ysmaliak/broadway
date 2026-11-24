#!/usr/bin/env python3
"""A floating panel's glass stays lit while the panel is not key and Broadway is behind.

Build first (`./build.sh`), then `python3 Tests/glass_lit.py`. A hidden test
copy shows one fake meeting and puts a copy of its card, in the same never-key
panel the real card uses, under the desktop. Broadway is never brought to the
front. The copy pictures its own window by its id, once with the hold on and
once with the test switch turning it off. Beside the card sit swatches of green
glass. A key window keeps that green (meeting_join_colour.py's control), a
dimmed one loses it. The probe passes when the held picture keeps the green and
the two pictures clearly differ. Exit 3 means this screen draws no glass, so
nothing can be told. Pictures go to .context/glass-lit/<label>.
"""
import base64
import json
import os
import struct
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("glass-lit")
t = sv.T()
ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".context" / "glass-lit" / os.environ.get("GLASS_LABEL", "now")
CANNOT_TELL = 3


def read_png(data):
    pos, idat, width, height, kind = 8, b"", 0, 0, 6
    while pos < len(data):
        size, name = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + size]
        pos += 12 + size
        if name == b"IHDR":
            width, height, _, kind = struct.unpack(">IIBB", body[:10])
        elif name == b"IDAT":
            idat += body
    step = {6: 4, 2: 3}[kind]
    raw, stride = zlib.decompress(idat), width * step
    rows, above, at = [], bytearray(stride), 0
    for _ in range(height):
        kind_of, line = raw[at], bytearray(raw[at + 1:at + 1 + stride])
        at += 1 + stride
        for x in range(stride):
            a = line[x - step] if x >= step else 0
            b = above[x]
            c = above[x - step] if x >= step else 0
            if kind_of == 1: line[x] = (line[x] + a) & 255
            elif kind_of == 2: line[x] = (line[x] + b) & 255
            elif kind_of == 3: line[x] = (line[x] + (a + b) // 2) & 255
            elif kind_of == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(bytes(line))
        above = line
    return width, height, step, rows


def face(image, spot):
    width, height, step, rows = image
    x, y, w, h = spot
    picked = []
    for row in range(y + h // 4, y + h - h // 4):
        for col in range(x + h // 2, x + w - h // 2):
            if 0 <= row < height and 0 <= col < width:
                picked.append(tuple(rows[row][col * step:col * step + 3]))
    if not picked:
        return (0, 0, 0), 0
    picked.sort(key=sum)
    picked = picked[:max(1, len(picked) * 7 // 10)]
    mean = tuple(sum(p[i] for p in picked) // len(picked) for i in range(3))
    return mean, mean[1] - max(mean[0], mean[2])


def shoot(theme, hold, ground=None):
    sv.cmd({"do": "lights", "hold": hold})
    name = f"{'held' if hold else 'unheld'}-{theme}" + (f"-{ground}" if ground else "")
    state = sv.cmd({"do": "meetalert", "action": "shot-start", "dark": theme == "dark", "front": False, "controls": True,
                    "ground": ground})
    try:
        time.sleep(1.0)
        lights = sv.cmd({"do": "lights"})
        took = sv.cmd({"do": "meetalert", "action": "shot-take"})
    finally:
        sv.cmd({"do": "meetalert", "action": "shot-end"})
    panel = next((p for p in lights.get("panels", []) if p.get("number") == state.get("window")), {})
    print(f"        {name}: Broadway hidden {lights.get('hidden')}, the copy's window visible {panel.get('visible')}")
    png = base64.b64decode(took.get("png") or "")
    if not png:
        return name, None, None, took, panel
    (WORK / f"{name}.png").write_bytes(png)
    image = read_png(png)
    return name, image, {key: face(image, spot) for key, spot in state["spots"].items()}, took, panel


def apart(a, b):
    width, height, step, rows = a
    _, _, step_b, rows_b = b
    total, count = 0, 0
    for y in range(0, min(height, len(rows_b)), 2):
        for x in range(0, width, 2):
            for i in range(3):
                total += abs(rows[y][x * step + i] - rows_b[y][x * step_b + i])
            count += 3
    return total / max(1, count)


def real_card(hold):
    sv.cmd({"do": "lights", "hold": hold})
    sv.cmd({"do": "meetalert", "action": "off"})
    sv.cmd({"do": "meetalert", "action": "fixture", "lead": "1", "hosts": {"127.0.0.1": "meet"},
            "events": [{"title": "Design sync", "in": 0.5, "link": f"{sv.BASE}/abc-defg-hij"}]})
    end = time.time() + 6
    while True:
        lights = sv.cmd({"do": "lights"})
        panel = next((p for p in lights.get("panels", []) if p.get("kind") == "Lifted"), {})
        lit = [g["lit"] for g in panel.get("glass", [])]
        if (len(lit) == 4 and None not in lit) or time.time() > end:
            break
        time.sleep(0.3)
    return lights, panel, {g["owner"]: g["lit"] for g in panel.get("glass", [])}, lit


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    sv.setup()
    sv.launch()
    blind = []
    try:
        sv.cmd({"do": "meetalert", "action": "fixture", "lead": "1", "hosts": {"127.0.0.1": "meet"},
                "events": [{"title": "Design sync", "in": 0.5, "link": f"{sv.BASE}/abc-defg-hij"}]})
        t.ok("one card is up", len(sv.cmd({"do": "meetalert"})["due"]) == 1)
        for hold in (True, False, True):
            lights, panel, owners, lit = real_card(hold)
            word = "held" if hold else "unheld"
            print(f"        real card {word}: active {lights.get('active')} hidden {lights.get('hidden')} key {lights.get('keyWindow')!r} glass {panel.get('glass')}")
            t.ok(f"real card {word}: Broadway is behind and no window of it is key", not lights.get("active") and not lights.get("keyWindow"), lights.get("keyWindow"))
            t.ok(f"real card {word}: the ground, both keys and Join are glass",
                 set(owners) == {"KitGlass", "KitGlassKey", "MeetingJoinButton"} and len(lit) == 4, panel.get("glass"))
            t.ok(f"real card {word}: every glass is {'lit' if hold else 'dim'}", lit == [hold] * 4, panel.get("glass"))
        for theme, ground in (("light", None), ("dark", None), ("light", "clear"), ("dark", "clear")):
            label = theme + (f" {ground}" if ground else "")
            shots = {}
            for hold in (True, False):
                name, image, faces, took, panel = shoot(theme, hold, ground)
                t.ok(f"{name}: a picture of the probe's own window", image is not None, {k: v for k, v in took.items() if k != "png"})
                t.ok(f"{name}: Broadway is behind and the panel is not key", not took.get("active") and not took.get("key"),
                     {k: v for k, v in took.items() if k != "png"})
                t.ok(f"{name}: the panel answers {'lit' if hold else 'as AppKit does'}",
                     panel.get("held") is hold and panel.get("lit") is hold, panel)
                for key, (mean, green) in sorted((faces or {}).items()):
                    print(f"        {name:13} {key:18} rgb{mean} green {green:+d}")
                shots[hold] = (image, faces)
            (held_image, held), (unheld_image, unheld) = shots[True], shots[False]
            if held is None or unheld is None:
                continue
            drawn = max(held["glass still"][1], unheld["glass still"][1], held["glass interactive"][1], unheld["glass interactive"][1])
            moved = apart(held_image, unheld_image)
            print(f"        {label}: the two pictures differ by {moved:.1f} a channel on average")
            if drawn < 15 and moved < 2:
                blind.append(label)
                print(f"  {label}: glass is not drawn on this screen, cannot tell")
                continue
            t.ok(f"{label}: the held glass keeps the green a key window shows", held["glass still"][1] >= 40, held["glass still"])
            t.ok(f"{label}: without the hold the glass dims", unheld["glass still"][1] < held["glass still"][1] - 15,
                 (held["glass still"], unheld["glass still"]))
            t.ok(f"{label}: the two pictures differ clearly", moved >= 2, moved)
        print("        pictures in", WORK)
    finally:
        try:
            sv.cmd({"do": "lights", "hold": True})
        except Exception:
            pass
        sv.quit()
        sv.finish()
    t.done()
    if blind and not t.failed:
        print("glass is not drawn on this screen, cannot tell")
        sys.exit(CANNOT_TELL)
    sys.exit(1 if t.failed else 0)


main()
