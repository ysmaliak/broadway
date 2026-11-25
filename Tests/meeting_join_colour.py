#!/usr/bin/env python3
"""The meeting card's Join button is the system green whether Broadway is in front or not, with nothing outside its capsule.

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


def write_png(path, width, height, rows):
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(name, body):
        return struct.pack(">I", len(body)) + name + body + struct.pack(">I", zlib.crc32(name + body) & 0xffffffff)

    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def pixel(image, x, y):
    width, height, step, rows = image
    if 0 <= x < width and 0 <= y < height:
        return tuple(rows[y][x * step:x * step + 3])
    return (0, 0, 0)


def zoom(image, spot, margin, factor, path):
    x, y, w, h = spot
    out = []
    for row in range(y - margin, y + h + margin):
        line = b"".join(bytes(pixel(image, col, row)) * factor for col in range(x - margin, x + w + margin))
        out += [line] * factor
    write_png(path, (w + margin * 2) * factor, (h + margin * 2) * factor, out)


def corners(image, spot, scale):
    x, y, w, h = spot
    gap = max(2, round(3 * scale))
    worst = {}
    for name, cx, cy, step_x, step_y, gx in (("top left", x, y, 1, 1, x - gap), ("top right", x + w - 1, y, -1, 1, x + w - 1 + gap),
                                            ("bottom left", x, y + h - 1, 1, -1, x - gap),
                                            ("bottom right", x + w - 1, y + h - 1, -1, -1, x + w - 1 + gap)):
        diffs = []
        for inset in range(0, max(2, round(2 * scale))):
            here = pixel(image, cx + step_x * inset, cy + step_y * inset)
            beside = pixel(image, gx, cy + step_y * inset)
            diffs.append((max(abs(a - b) for a, b in zip(here, beside)), here, beside))
        worst[name] = max(diffs)
    return worst


def capture(request):
    for _ in range(3):
        state = sv.cmd(request)
        try:
            time.sleep(1.0)
            took = sv.cmd({"do": "meetalert", "action": "shot-take"})
        finally:
            sv.cmd({"do": "meetalert", "action": "shot-end"})
        if took.get("png"):
            break
        time.sleep(0.5)
    return state, took


def plates():
    out = WORK / "plates"
    out.mkdir(parents=True, exist_ok=True)
    cases = [(theme, ground, pose, False) for theme in ("dark", "light") for ground in ("white", "black", "clear")
             for pose in ("rest", "hover", "press")]
    cases += [(theme, "white", "focus", False) for theme in ("dark", "light")]
    cases += [(theme, ground, "rest", True) for theme in ("dark", "light") for ground in ("white", "black")]
    for theme, ground, pose, raised in cases:
        if raised:
            subprocess.run(["defaults", "write", sv.SUITE, "contrast.testRaised", "-bool", "true"])
            time.sleep(0.5)
        name = f"{theme}-on-{ground}-{pose}{'-raised' if raised else ''}"
        focus = pose == "focus"
        request = {"do": "meetalert", "action": "shot-start", "dark": theme == "dark", "ground": ground,
                   "front": focus, "key": focus}
        if pose != "rest":
            request["join"] = pose
        try:
            state, took = capture(request)
        finally:
            if raised:
                subprocess.run(["defaults", "delete", sv.SUITE, "contrast.testRaised"])
        join = took.get("join", {})
        if os.environ.get("JOIN_LAYERS") and pose == "rest" and not raised:
            print(f"        {name} views:\n          " + "\n          ".join(join.get("views", [])))
            print(f"        {name} layers:\n          " + "\n          ".join(join.get("layers", [])))
        png = base64.b64decode(took.get("png") or "")
        t.ok(f"{name}: a picture of the probe's own window", bool(png), {k: v for k, v in took.items() if k != "png"})
        if not png:
            continue
        if focus and not took.get("key"):
            print(f"  skip {name}: the probe window could not be made key here, so no focus ring draws")
            continue
        (out / f"{name}.png").write_bytes(png)
        image = read_png(png)
        spot = state["spots"]["join"]
        scale = join.get("scale", 1)
        zoom(image, spot, round(4 * scale), 4, out / f"{name}-join-4x.png")
        zoom(image, state["spots"]["snooze"], round(4 * scale), 4, out / f"{name}-snooze-4x.png")
        worst = corners(image, spot, scale)
        for corner, (diff, here, beside) in worst.items():
            print(f"        {name:28} {corner:12} corner rgb{here} beside rgb{beside} differs by {diff}")
        t.ok(f"{name}: nothing shows outside the Join capsule at its four corners", max(d for d, _, _ in worst.values()) <= 10, worst)
        print(f"        {name:28} pressed={join.get('pressed')} hovering={join.get('hovering')} focused={join.get('focused')}"
              f" face={join.get('face')} system green={join.get('systemGreen')}")
        if pose == "rest":
            mean, _ = face(image, spot)
            want = join.get("systemGreen", [])[:3]
            t.ok(f"{name}: the face is the system green", bool(want) and join.get("face", [])[:3] == want, (join.get("face"), want))
            t.ok(f"{name}: the drawn green is the system green", bool(want) and max(abs(a - b) for a, b in zip(mean, want)) <= 8,
                 (mean, want))
    print("        plates in", out)


def glass_radius(join):
    for line in join.get("views", []):
        if "KitGlass " in line and "glassRadius=" in line:
            return float(line.split("glassRadius=")[1].split()[0])
    return None


def real_card():
    out = WORK / "real"
    out.mkdir(parents=True, exist_ok=True)

    def look(step, picture=True):
        joins = sv.cmd({"do": "meetalert", "action": "join-facts"}).get("joins", [])
        radii = [glass_radius(j) for j in joins]
        frames = [next((line.strip() for line in j.get("views", []) if "MeetingJoinButton" in line), "") for j in joins]
        print(f"        real {step:24} glass radius {radii} {frames}")
        t.ok(f"real card, {step}: the Join key has no glass behind it", bool(radii) and all(r is None for r in radii), frames)
        if not picture:
            return
        state, took = capture({"do": "meetalert", "action": "real-shot"})
        png = base64.b64decode(took.get("png") or "")
        t.ok(f"real card, {step}: a picture of the real panel", bool(png), {k: v for k, v in took.items() if k != "png"})
        if not png or "join" not in state.get("spots", {}):
            return
        name = step.replace(" ", "-")
        (out / f"{name}.png").write_bytes(png)
        image = read_png(png)
        scale = took.get("join", {}).get("scale", 1)
        zoom(image, state["spots"]["join"], round(4 * scale), 4, out / f"{name}-join-4x.png")
        worst = corners(image, state["spots"]["join"], scale)
        for corner, (diff, here, beside) in worst.items():
            print(f"        real {step:24} {corner:12} corner rgb{here} beside rgb{beside} differs by {diff}")
        t.ok(f"real card, {step}: nothing shows outside the Join capsule", max(d for d, _, _ in worst.values()) <= 10, worst)

    event = {"id": "life", "title": "Design sync", "in": 0.12, "link": f"{sv.BASE}/abc-defg-hij"}
    sv.cmd({"do": "meetalert", "action": "fixture", "lead": "1", "hosts": {"127.0.0.1": "meet"}, "events": [event]})
    look("first shown")
    sv.cmd({"do": "meetalert", "action": "fixture", "lead": "1", "hosts": {"127.0.0.1": "meet"},
            "events": [dict(event, title="Design sync, moved", **{"in": 0.1})]})
    look("rebuilt in place")
    sv.cmd({"do": "meetalert", "action": "changed"})
    look("calendar changed", picture=False)
    time.sleep(8)
    look("after the start ticked")
    print("        real card pictures in", out)


def shoot(theme, front, key=False, tag=""):
    name = f"{'front' if front else 'behind'}{'-key' if key else ''}{tag}-{theme}"
    state, took = capture({"do": "meetalert", "action": "shot-start", "dark": theme == "dark", "front": front, "controls": True, "key": key})
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
        plates()
        real_card()
        sv.cmd({"do": "meetalert", "action": "fixture", "lead": "1", "hosts": {"127.0.0.1": "meet"},
                "events": [{"title": "Design sync", "in": 0.5, "link": f"{sv.BASE}/abc-defg-hij"}]})
        if os.environ.get("JOIN_ONLY") == "plates":
            return
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
            name, faces, took, _ = shoot(theme, False, tag="-contrast")
            for key, (mean, green) in sorted((faces or {}).items()):
                if key in ("join", "snooze"):
                    print(f"        {name:22} {key:18} rgb{mean} green {green:+d}")
            want = took.get("join", {}).get("systemGreen", [])[:3]
            t.ok(f"{name}: Join keeps the system's own green, which follows Increase Contrast by itself",
                 faces is not None and bool(want) and max(abs(a - b) for a, b in zip(faces["join"][0], want)) <= 8,
                 (faces and faces["join"], want))
        subprocess.run(["defaults", "delete", sv.SUITE, "contrast.testRaised"])
        print("        pictures in", WORK)
    finally:
        sv.quit()
        sv.finish()


main()
t.done()
sys.exit(1 if t.failed else 0)
