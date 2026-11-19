#!/usr/bin/env python3
"""The join: a pull request row at the moment it turns merged, filmed.

Build first (`./build.sh`), then `python3 Tests/merged_join_film.py [OUT]`.
Needs ffmpeg and screen recording. A shown test copy in a world of its own
opens its window behind every other and reads a fake signed-in GitHub on ::1
through `integrations.api` (the fake of Tests/merged_stack.py), so the rows
carry github.com addresses and nothing is asked of the real site. Every pull
request, repository and person is invented. Nothing comes to the front,
nothing makes a sound and Settings is never opened.

The top row turns merged and the window is filmed by its number
(Tests/WindowCapture.swift), never a region of the display, through the turn,
the hold and the leaving. A window gives a frame only when it changes, so the
film is laid out by the time of every frame.

What is judged is the 16 pt box of the row's icon, where the two branches
draw and meet. Frames are held against the one where the sign has settled,
never against the first frame of the film. The same box on the row below,
which does not turn, is measured over the same pairs of frames and taken
away, so a change that crosses the whole window (a first frame unlike the
rest, a step in brightness) counts for nothing. The join is drawn in motion
when two frames of the turn are unlike the settled sign and unlike each
other: a plain swap has one picture before it and one after. The sign has
taken the icon's place when its box is unlike the icon before the turn, or
unlike the icon of the row that moves up once the row has left.

OUT (default .context/merged-join-film) gets join.mp4 with the sidebar
around the row, join.png with a strip of its frames, and
merged-join-film.json.

Where the window gives no frames (no screen recording, a locked screen), or
it is filmed and nothing changes in it, the probe says "cannot tell on this
screen" and exits with 3. A row that changes and shows no join fails.

Exit 0 passed, 1 failed, 3 cannot tell on this screen.
"""
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ARGS = sys.argv[1:]
OUT = (Path(ARGS[0]) if ARGS else ROOT / ".context" / "merged-join-film").resolve()

CANNOT_TELL = 3
HOLD = 1.6
SCALE = 2
LEAD = 0.6
LASTS = LEAD + HOLD + 1.1
SETTLED = 1.2
DRAWS = 0.6
LEFT = 0.9
SEEN = 0.01
ABOVE = 46
BELOW = 84
BADGE = 3
TITLES = ["Fix a typo in the guide", "Cache the build graph so cold builds stop resolving every package", "Bump Swift to 6.2",
          "Teach the rocket to count", "Keep the legs folded until the last stage", "Name the stages", "Draw the fuel gauge",
          "Trim the launch log"]


def gap(a, b):
    if not a or len(a) != len(b):
        return 1.0
    return sum(abs(p - q) for p, q in zip(a, b)) / (len(a) * 255)


def shape(a, b):
    if not a or len(a) != len(b):
        return 1.0
    lift = (sum(b) - sum(a)) / len(a)
    return sum(abs(q - p - lift) for p, q in zip(a, b)) / (len(a) * 255)


def latest(times, moment):
    found = 0
    for index, when in enumerate(times):
        if when <= moment:
            found = index
    return found


def judge(times, icon, control, row, turned, hold=HOLD):
    before = latest(times, turned - 0.02)
    settled = latest(times, turned + SETTLED)
    after = latest(times, turned + hold + LEFT)

    def own(index, other):
        return gap(icon[index], icon[other]) - gap(control[index], control[other])

    between = [index for index, when in enumerate(times) if turned - 0.02 < when <= turned + DRAWS]
    unlike = [index for index in between if own(index, settled) > SEEN]
    motion = max([min(own(one, settled), own(other, settled), own(one, other))
                  for place, one in enumerate(unlike) for other in unlike[place + 1:]] or [0])
    rest = max([abs(own(index, before)) for index, when in enumerate(times) if when <= turned - 0.02] or [0])
    held = max([abs(own(index, settled)) for index, when in enumerate(times) if turned + SETTLED <= when <= turned + hold - 0.1] or [0])
    sign = max(own(before, settled), own(after, settled))
    left = shape(row[settled], row[after])
    return {"before": before, "settled": settled, "after": after, "between": len(between), "sign": sign, "motion": motion, "rest": rest,
            "held": held, "left": left, "changes": sign > SEEN or left > SEEN, "signed": sign > SEEN, "drawn": motion > SEEN,
            "leaves": left > SEEN}


def seed(ms):
    rows = {300 + k: ("acme/rocket", "main", f"film-{k}", None, None, title) for k, title in enumerate(TITLES, 1)}
    ms.PR.clear()
    ms.PR.update(rows)
    ms.ORDER[:] = sorted(rows)
    ms.STATE.clear()
    ms.STATE.update({k: "open" for k in rows})
    ms.STAMPS.clear()
    ms.STAMPS.update({k: "2026-11-10T09:00:00Z" for k in rows})
    found = ms.read()
    for _ in range(30):
        if sorted(found) == sorted(rows):
            break
        time.sleep(0.5)
        found = ms.read()
    for k in rows:
        ms.live("seen", ms.url(k))
    time.sleep(0.4)
    return sorted(rows), found


def even(value):
    value = int(value)
    return value - value % 2


def box(frame, pad):
    x, y, w, h = frame
    return [even((x - pad) * SCALE), even((y - pad) * SCALE), even((w + 2 * pad) * SCALE), even((h + 2 * pad) * SCALE)]


def grays(folder, count, crop):
    x, y, w, h = crop
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"), "-vf", f"crop={w}:{h}:{x}:{y}",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
    size = w * h
    return [raw[index * size:(index + 1) * size] for index in range(min(count, len(raw) // size))]


def quoted(path):
    return "'" + str(path).replace("'", "'\\''") + "'"


def moments(turned):
    early = [turned - 0.04 + index * 0.04 for index in range(12)]
    rest = [early[-1] + (index + 1) * (turned + HOLD + 0.35 - early[-1]) / 12 for index in range(12)]
    return early + rest


def cut(shot, crop, out, turned):
    x, y, w, h = crop
    listing = out.with_suffix(".txt")
    lines = []
    for index, (moment, frame) in enumerate(shot):
        ends = shot[index + 1][0] if index + 1 < len(shot) else max(LASTS, moment + 1 / 60)
        lines += [f"file {quoted(frame)}", f"duration {max(ends - moment, 1 / 120):.4f}"]
    lines.append(f"file {quoted(shot[-1][1])}")
    listing.write_text("\n".join(lines) + "\n")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", str(listing), "-vf",
                    f"crop={w}:{h}:{x}:{y},fps=60", "-c:v", "libx264", "-pix_fmt", "yuv420p", str(out.with_suffix(".mp4"))], check=True)
    listing.unlink()
    kept = [max([row for row in shot if row[0] <= at] or shot[:1], key=lambda row: row[0])[1] for at in moments(turned)]
    strip = out.with_suffix(".strip")
    shutil.rmtree(strip, ignore_errors=True)
    strip.mkdir(parents=True)
    for index, frame in enumerate(kept):
        os.symlink(frame, strip / f"{index:04d}.png")
    columns = 6
    rows = max(1, (len(kept) + columns - 1) // columns)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "60", "-i", str(strip / "%04d.png"), "-vf",
                    f"crop={w}:{h}:{x}:{y},tile={columns}x{rows}:padding=4:color=gray", "-frames:v", "1", str(out.with_suffix(".png"))], check=True)
    shutil.rmtree(strip)
    return len(kept)


def main():
    sys.argv = sys.argv[:1]
    sys.path.insert(0, str(ROOT / "Tests"))
    import glass_keys as gk
    import merged_stack as ms
    import split_view as sv

    if not shutil.which("ffmpeg"):
        sys.exit("merged_join_film needs ffmpeg")
    t = sv.T()
    OUT.mkdir(parents=True, exist_ok=True)
    if not gk.CAPTURE.exists():
        gk.CAPTURE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(gk.CAPTURE)], check=True)
    gk.SCALE[0] = SCALE
    report = {}
    unseen = None
    work = OUT / "frames"
    try:
        sv.use("merged-join-film-" + uuid.uuid4().hex[:6])
        sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
        sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
        subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", ms.BASE], check=True)
        gk.launch()
        pid = next(iter(sv.started))
        sv.cmd({"do": "resize", "width": 640, "height": 440, "steps": 1})
        ms.PR.clear()
        ms.ORDER[:] = []
        ms.live("add-page", "PRs", "pullRequests", ms.PULLS)
        ms.live("unfold", "PRs")
        numbers, found = seed(ms)
        t.ok("the invented pull requests are listed", sorted(found) == numbers, sorted(found))
        window = sv.cmd({"do": "windowbehind"})["number"]
        set_up = sv.cmd({"do": "mergedturn", "hold": HOLD, "sight": True})
        t.ok("the row is held for the hold", set_up.get("hold") == HOLD, set_up)
        time.sleep(0.6)
        tabs = {tab["key"]: tab["id"] for tab in ms.prs().get("tabs", [])}
        placed = sv.cmd({"do": "rowframes"})
        turning, under = tabs.get(ms.url(numbers[0])), tabs.get(ms.url(numbers[1]))
        row = placed["rows"].get(turning)
        icon, control = placed["icons"].get(turning), placed["icons"].get(under)
        t.ok("the top row, its icon and the icon of the row under it are in the window", bool(row and icon and control), (row, icon, control))
        report = {"row": row, "icon": icon, "control": control}
        if row and icon and control:
            step = placed["rows"][under][1] - row[1]
            t.ok("the icon lies inside its row", row[0] <= icon[0] and icon[0] + icon[2] <= row[0] + row[2]
                 and row[1] <= icon[1] and icon[1] + icon[3] <= row[1] + row[3], (row, icon))
            t.ok("the icon under it is the same box one row lower",
                 step > 0 and all(abs(a - b) < 0.5 for a, b in zip(control, [icon[0], icon[1] + step, icon[2], icon[3]])), (icon, control, step))
            marks = {}

            def act(start):
                time.sleep(LEAD)
                marks["turn"] = time.time() - start
                ms.STATE[numbers[0]] = "merged"
                ms.live("merged", ms.url(numbers[0]))
                time.sleep(LASTS - LEAD)

            shot, said = gk.film(pid, window, work, LASTS, act)
            if shot is None:
                unseen = f"the window gave no frames ({said.strip()})"
            else:
                turned = marks["turn"]
                times = [moment for moment, _ in shot]
                found = judge(times, grays(work, len(shot), box(icon, BADGE)), grays(work, len(shot), box(control, BADGE)),
                              grays(work, len(shot), box(row, 0)), turned)
                top = max(0, row[1] - ABOVE)
                wide = [0, even(top * SCALE), even((row[0] + row[2] + 10) * SCALE), even((row[1] + row[3] + BELOW - top) * SCALE)]
                kept = cut(shot, wide, OUT / "join", turned)
                report.update({"frames": len(shot), "turned": round(turned, 3), "strip": kept, **found})
                print(f"  {len(shot)} frames, the icon's box changes {found['sign']:.4f}, is in between by {found['motion']:.4f}, "
                      f"and the row leaves by {found['left']:.4f} (at rest {found['rest']:.4f}, held {found['held']:.4f})", flush=True)
                if not found["changes"]:
                    unseen = "the window is filmed, and nothing changes in it"
                else:
                    t.ok("the sign takes the icon's place", found["signed"], found)
                    t.ok("the join is drawn in motion", found["drawn"], found)
                    t.ok("the sign rests through the hold", found["held"] <= SEEN, found)
                    t.ok("the row leaves when the hold ends", found["leaves"], found)
    finally:
        report["cannotTell"] = unseen
        (OUT / "merged-join-film.json").write_text(json.dumps(report, indent=2, sort_keys=True))
        shutil.rmtree(work, ignore_errors=True)
        t.done()
        sv.finish()
    if t.failed:
        return 1
    if unseen:
        print(f"cannot tell on this screen: {unseen}")
        return CANNOT_TELL
    return 0


if __name__ == "__main__":
    sys.exit(main())
