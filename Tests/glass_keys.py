#!/usr/bin/env python3
"""Every pressable glass key, pressed in a shown test copy, and films of a few.

Build first (`./build.sh`), then `python3 Tests/glass_keys.py [OUT]`. The bench's
`glasskeys` gallery holds one of each glass key Broadway has, built from the
real classes, in a window of its own that stands off the screen. The test copy
is shown, as a hidden app's windows take no events. Each key is pressed with a
real mouse down and up sent to that window: the press must land inside the
key's glass, the glass must swell while it is held and settle after, and the
key's action must run once. A key that is off must stay still. The system's
own glass button is pressed too, as a reference.

Then the gallery is brought one pixel onto the screen and filmed by its window
number (Tests/WindowCapture.swift, never a region of the screen) while a few
keys are pressed and while the video key changes from pause to play and back.
Where the capture gives no frames the films are skipped and said so. The play
key's frames are also drawn from its own layers by PlayPauseFramesTests, which
needs no screen recording.

GLASS_FILMS_ONLY=1 skips the press table.
"""
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "glass-keys")
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

CAPTURE = ROOT / ".context" / "capture-glass"
SCALE = [1]
NO_ACTION = {"update card hide", "choice thumb", "look glass bead", "system glass button"}

sv.use("glass-keys")


def cmd(req, wait=120):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as c:
        c.settimeout(wait)
        c.connect(f"{sv.SUPPORT}/bench.sock")
        c.sendall(json.dumps(req).encode() + b"\n")
        data = b""
        while True:
            chunk = c.recv(65536)
            if not chunk:
                break
            data += chunk
    answer = json.loads(data.split(b"\n", 1)[0] or b"{}")
    if "error" in answer:
        raise RuntimeError(f"{req}: {answer['error']}")
    return answer


def launch():
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    if not os.path.exists(sv.SOCK):
        raise RuntimeError(f"{sv.W} did not open its bench socket")


def glass(action, **fields):
    return cmd({"do": "glasskeys", "action": action, **fields})


def film(pid, window, folder, seconds, during):
    if folder.exists():
        shutil.rmtree(folder)
    capture = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(window), str(SCALE[0])],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for _ in range(100):
        if (folder / "ready").exists() or capture.poll() is not None:
            break
        time.sleep(0.05)
    if not (folder / "ready").exists():
        capture.wait()
        during(time.time())
        return None, capture.stdout.read()
    start = time.time()
    during(start)
    said = capture.communicate()[0]
    if "SKIP" in said:
        return None, said
    times = json.loads((folder / "times.json").read_text())
    frames = sorted(folder.glob("[0-9][0-9][0-9][0-9].png"))
    return list(zip(times, frames)), said


def gray(frame, crop):
    x, y, w, h = crop
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(frame), "-vf", f"crop={w}:{h}:{x}:{y}",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
    return raw


def distance(a, b):
    if not a or len(a) != len(b):
        return 1.0
    return sum(abs(p - q) for p, q in zip(a, b)) / (len(a) * 255)


def sheet(frames, crop, out, columns=8):
    x, y, w, h = crop
    folder = out.with_suffix(".frames")
    if folder.exists():
        shutil.rmtree(folder)
    folder.mkdir(parents=True)
    for index, (_, frame) in enumerate(frames):
        shutil.copy(frame, folder / f"{index:04d}.png")
    rows = max(1, (len(frames) + columns - 1) // columns)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(folder / "%04d.png"), "-vf",
                    f"crop={w}:{h}:{x}:{y},scale=iw*2:ih*2:flags=neighbor,tile={columns}x{rows}:padding=4:color=white",
                    "-frames:v", "1", str(out.with_suffix(".png"))], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "60", "-i", str(folder / "%04d.png"), "-vf",
                    f"crop={w}:{h}:{x}:{y},scale=ceil(iw*2/2)*2:ceil(ih*2/2)*2", "-c:v", "libx264", "-pix_fmt", "yuv420p",
                    str(out.with_suffix(".mp4"))], check=True)
    shutil.rmtree(folder)


def scaled(frame, scale, pad=10):
    x, y, w, h = frame
    return [int((x - pad) * scale), int((y - pad) * scale), int((w + 2 * pad) * scale), int((h + 2 * pad) * scale)]


def table(t, look):
    opened = glass("open", look=look)
    time.sleep(0.6)
    rows = [glass("press", name=key["name"], hold=260) for key in opened["keys"]]
    for row in rows:
        name = row["name"]
        off = name == "glass key off"
        if name != "system glass button":
            t.ok(f"{look}: {name} rests still", row["restSwelled"] is False, row)
            t.ok(f"{look}: {name} {'stays still under a press' if off else 'swells under a press'}", row["pressSwelled"] is (not off), row)
            t.ok(f"{look}: {name} settles after", row["settled"] is True, row)
        if name == "system glass button":
            print(f"  reference {look}: the system's glass button swells {row['pressSwelled']} and settles within 0.5 s {row['settled']}")
            continue
        t.ok(f"{look}: {name} {'keeps' if off else 'takes'} the press {'outside' if off else 'inside'} its glass", row["hitInGlass"] is (not off), row)
        if name not in NO_ACTION:
            t.ok(f"{look}: {name} runs its action {'never' if off else 'once'}", row["fired"] == (0 if off else 1), row)
    return rows


def traces(rows, names):
    out = {}
    for row in rows:
        if row["name"] in names and row.get("trace"):
            trace = row["trace"]
            peak = max(trace, key=lambda p: abs(p[1] - 1))
            out[row["name"]] = {"peak": peak, "end": trace[-1], "trace": trace}
            print(f"  swell {row['name']}: rest 1.0, peak {peak[1]} at {int(peak[0])} ms, {trace[-1][1]} at {int(trace[-1][0])} ms")
    return out


def main():
    t = sv.T()
    OUT.mkdir(parents=True, exist_ok=True)
    if not CAPTURE.exists():
        CAPTURE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowCapture.swift"), "-o", str(CAPTURE)], check=True)
    report = {}
    try:
        sv.setup(sidebar=True)
        launch()
        pid = next(iter(sv.started))
        for look in [] if os.environ.get("GLASS_FILMS_ONLY") else ["dark", "light"]:
            report[look] = table(t, look)
            report[f"swell-{look}"] = traces(report[look], {"float play", "glass key primary", "call mic", "float subtitles", "meeting join"})

        opened = glass("open", look="dark", behind=True)
        time.sleep(0.8)
        for look in ["dark", "light"]:
            rest, said = film(pid, glass("open", look=look, behind=True)["window"], OUT / f"rest-{look}", 0.6, lambda start: None)
            if rest:
                subprocess.run(["cp", str(rest[-1][1]), str(OUT / f"gallery-{look}.png")])
        opened = glass("open", look="dark", behind=True)
        time.sleep(0.8)
        window, scale = opened["window"], opened["scale"]
        SCALE[0] = scale
        report["filmPress"] = glass("press", name="glass key")
        frames = {k["name"]: k["frame"] for k in opened["keys"]}
        films = {}
        for name in ["float play", "glass key primary", "call mic", "float subtitles"]:
            crop = scaled(frames[name], scale)
            shot, said = film(pid, window, OUT / f"press-{name.replace(' ', '-')}", 2.0,
                              lambda start, name=name: (time.sleep(0.4), glass("press", name=name, hold=450)))
            if shot is None:
                print("  film skipped:", said.strip())
                films[name] = {"skipped": said.strip()}
                continue
            rest = gray(shot[0][1], crop)
            changes = [distance(rest, gray(frame, crop)) for _, frame in shot]
            films[name] = {"frames": len(shot), "mostChangeFromRest": max(changes)}
            t.ok(f"the film of {name} changes under the press", max(changes) > 0.004, films[name])
            sheet(shot[:: max(1, len(shot) // 24)][:24], crop, OUT / f"glass-{name.replace(' ', '-')}")

        glass("play", playing=True)
        time.sleep(0.6)
        transport = frames["float play"]
        key = [transport[0] + (transport[2] - 48) / 2, transport[1] + (transport[3] - 48) / 2, 48, 48]
        crop = scaled(key, scale, pad=4)
        before = glass("state")

        def flip(start):
            time.sleep(0.4)
            glass("play", playing=False)
            time.sleep(1.0)
            glass("play", playing=True)

        shot, said = film(pid, window, OUT / "play-pause", 2.6, flip)
        after = glass("state")
        t.ok("pause to play and back is two swaps of the mark", after["swaps"] - before["swaps"] == 2, (before, after))
        t.ok("the key ends on pause", after["mark"] == "pause", after)
        if shot is None:
            print("  film skipped:", said.strip())
            report["playPause"] = {"skipped": said.strip()}
        else:
            pixels = [(time_, gray(frame, crop)) for time_, frame in shot]
            near = [p for p in pixels if 0.3 <= p[0] <= 1.3]
            first, last = near[0][1], near[-1][1]
            ends = distance(first, last)
            path = [[round(time_, 3), distance(p, first), distance(p, last)] for time_, p in near]
            between = [row for row in path if row[1] > ends * 0.15 and row[2] > ends * 0.15]
            report["playPause"] = {"frames": len(shot), "ends": ends, "between": len(between), "path": path}
            t.ok("frames between pause and play differ from both", len(between) >= 2 and ends > 0.004, report["playPause"]["between"])
            start = next(i for i, p in enumerate(pixels) if p[0] >= 0.35)
            sheet(shot[start:start + 24], crop, OUT / "play-pause")
        report["films"] = films
        glass("close")
    finally:
        (OUT / "glass-keys.json").write_text(json.dumps(report, indent=2, sort_keys=True))
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
