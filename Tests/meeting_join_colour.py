#!/usr/bin/env python3
"""The meeting card's Join button reads green whether Broadway is in front or not.

Build first (`./build.sh`), then `python3 Tests/meeting_join_colour.py`. A
test copy shows one fake meeting and puts a copy of its card, in the same
never-key panel the real card uses, under the desktop. The copy captures its
own window, light and dark, once while another app is in front and once
after making itself the front app for a moment. Beside the card sit control
swatches of the same green glass: interactive, still, tinted after it is in a
window, and a plain fill. The probe reads the colour inside each from the
picture. Pictures go to .context/meeting-join/<label>.
"""
import base64
import os
import struct
import subprocess
import sys
import time
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("meeting-join")
t = sv.T()
ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".context" / "meeting-join" / os.environ.get("JOIN_LABEL", "now")


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


def shoot(theme, front, key=False, tag=""):
    name = f"{'front' if front else 'behind'}{'-key' if key else ''}{tag}-{theme}"
    state = sv.cmd({"do": "meetalert", "action": "shot-start", "dark": theme == "dark", "front": front, "controls": True, "key": key})
    try:
        time.sleep(1.0)
        took = sv.cmd({"do": "meetalert", "action": "shot-take"})
    finally:
        sv.cmd({"do": "meetalert", "action": "shot-end"})
    png = base64.b64decode(took.get("png") or "")
    if not png:
        return name, None, took, state
    (WORK / f"{name}.png").write_bytes(png)
    image = read_png(png)
    return name, {key: face(image, spot) for key, spot in state["spots"].items()}, took, state


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    sv.setup()
    sv.launch()
    try:
        sv.cmd({"do": "meetalert", "action": "fixture", "lead": "1", "hosts": {"127.0.0.1": "meet"},
                "events": [{"title": "Design sync", "in": 0.5, "link": f"{sv.BASE}/abc-defg-hij"}]})
        t.ok("one card is up", len(sv.cmd({"do": "meetalert"})["due"]) == 1)
        for front in (False, True):
            for theme in ("light", "dark"):
                name, faces, took, state = shoot(theme, front)
                t.ok(f"{name}: a picture of the probe's own window", faces is not None, {k: v for k, v in took.items() if k != "png"})
                if faces is None:
                    continue
                if front and took.get("frontApp") == "loginwindow":
                    print(f"  skip {name}: this Mac shows its login window, so no app can come to the front")
                    continue
                said = "in front" if front else "behind"
                t.ok(f"{name}: Broadway is {said} as asked", took.get("active") == front and not took.get("key"),
                     {k: v for k, v in took.items() if k != "png"})
                for key, (mean, green) in sorted(faces.items()):
                    print(f"        {name:13} {key:18} rgb{mean} green {green:+d}")
                t.ok(f"{name}: Join reads green", faces["join"][1] >= 40, faces["join"])
                t.ok(f"{name}: Snooze stays quiet", faces["snooze"][1] < 25, faces["snooze"])
        name, faces, took, _ = shoot("light", True, key=True)
        if took.get("frontApp") == "loginwindow":
            print("  skip the key control: this Mac shows its login window")
        else:
            t.ok("control: the same panel made key in front", took.get("key") is True, {k: v for k, v in took.items() if k != "png"})
            for key, (mean, green) in sorted((faces or {}).items()):
                print(f"        {name:17} {key:18} rgb{mean} green {green:+d}")
            t.ok("control: glass keeps its green tint only in a key window", faces is not None and faces["glass still"][1] >= 40, faces)
        subprocess.run(["defaults", "write", sv.SUITE, "contrast.testRaised", "-bool", "true"])
        time.sleep(0.5)
        for theme in ("light", "dark"):
            name, faces, _, _ = shoot(theme, False, tag="-contrast")
            for key, (mean, green) in sorted((faces or {}).items()):
                if key in ("join", "snooze"):
                    print(f"        {name:22} {key:18} rgb{mean} green {green:+d}")
            t.ok(f"{name}: Join is a deeper green with Increase Contrast",
                 faces is not None and faces["join"][1] >= 40 and sum(faces["join"][0]) < 330, faces and faces["join"])
        subprocess.run(["defaults", "delete", sv.SUITE, "contrast.testRaised"])
        print("        pictures in", WORK)
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()
