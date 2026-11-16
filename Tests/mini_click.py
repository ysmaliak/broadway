#!/usr/bin/env python3
import json
import os
import shutil
import struct
import subprocess
import sys
import threading
import time
import zlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-mini-click")
if os.environ.get("BROADWAY_APP"):
    sv.APP = os.environ["BROADWAY_APP"]
ROOT = Path(__file__).resolve().parents[1]
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context/mini-click").resolve()
ONLY = os.environ.get("MINI_CLICK_ONLY", "")
REDUCED = os.environ.get("MINI_REDUCED") == "1"
LIGHT = os.environ.get("MINI_LIGHT") == "1"
SONG = 285
LEAD = 0.4
TITLE = "Did you know that there's a tunnel under Ocean Blvd"
NOIR = {"colours": ["000000"], "intensity": 1.0, "transparency": 0.12, "grain": 0.45, "glass": False}
t = sv.T()


def wav(seconds, rate=8000):
    step = struct.pack("<h", -1) * 9 + struct.pack("<h", 1) * 9
    count = seconds * rate * 2
    frames = (step * (count // len(step) + 1))[:count]
    head = b"RIFF" + struct.pack("<I", 36 + len(frames)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    return head + b"data" + struct.pack("<I", len(frames)) + frames


def png(size, colour):
    raw = b"".join(b"\x00" + bytes(colour(y / size)) * size for y in range(size))

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(raw, 1)) + chunk(b"IEND", b"")


def shade(far):
    return [int(196 - 120 * far), int(128 - 60 * far), int(96 + 40 * far)]


LONG = wav(SONG)
ART = png(300, shade)
BIG = png(2000, shade)

SONGPAGE = """<!doctype html><title>Lana Del Rey | Player</title><p>song</p>
<audio id=main src=/long.wav></audio><script>
var asked = new URLSearchParams(location.search);
var how = asked.get('seek') || 'site';
var main = document.getElementById('main'); main.volume = 0.01; window.log = [];
navigator.mediaSession.metadata = new MediaMetadata({ title: asked.get('title') || %s, artist: asked.get('artist') || 'Lana Del Rey',
  album: 'An Album', artwork: [asked.get('art') === 'big' ? { src: '/big.png', sizes: '2000x2000', type: 'image/png' }
    : { src: '/art.png', sizes: '300x300', type: 'image/png' }] });
window.start = function () { var p = main.play(); if (p && p.catch) p.catch(function () {}); return 1; };
navigator.mediaSession.setActionHandler('play', function () { log.push('play'); start(); });
navigator.mediaSession.setActionHandler('pause', function () { log.push('pause'); main.pause(); });
navigator.mediaSession.setActionHandler('previoustrack', function () { log.push('previous'); });
navigator.mediaSession.setActionHandler('nexttrack', function () { log.push('next'); });
navigator.mediaSession.setActionHandler('seekto', function (d) {
  log.push('to:' + Math.round(d.seekTime));
  if (how === 'plain') { main.currentTime = d.seekTime; return; }
  if (how === 'late') { setTimeout(function () { main.currentTime = d.seekTime; }, 800); return; }
  var was = !main.paused;
  if (was) main.pause();
  setTimeout(function () { main.currentTime = d.seekTime; }, 150);
  setTimeout(function () { if (was) start(); }, 550);
});
</script>""" % json.dumps(TITLE)


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/song":
            return self.send(SONGPAGE.encode(), "text/html")
        files = {"/long.wav": (LONG, "audio/wav"), "/art.png": (ART, "image/png"), "/big.png": (BIG, "image/png")}
        if path in files:
            return self.send(*files[path])
        return self.send(b"<!doctype html><title>Other page</title><p>other</p>", "text/html")

    def send(self, body, kind):
        total = len(body)
        wanted = self.headers.get("Range")
        if wanted and wanted.startswith("bytes="):
            first, _, last = wanted[6:].partition("-")
            start = int(first or 0)
            end = min(int(last) if last else total - 1, total - 1)
            self.send_response(206)
            self.send_header("Content-Range", f"bytes {start}-{end}/{total}")
            body = body[start:end + 1]
        else:
            self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *a):
        pass


def mini(action="state", *values):
    return sv.cmd({"do": "mini", "action": action, "values": [str(v) for v in values]})


def shown():
    return mini().get("shown") or {}


def until(check, within=8):
    end = time.time() + within
    while time.time() < end:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.1)
    try:
        return bool(check())
    except Exception:
        return False


def opened(base, path):
    tab = sv.cmd({"do": "open", "url": f"{base}/{path}"})["id"]
    sv.cmd({"do": "wait", "id": tab, "seconds": 10})
    return tab


def clock(text):
    first = (text or "").split(" / ")[0]
    parts = first.split(":")
    if len(parts) != 2 or not all(p.isdigit() for p in parts):
        return None
    return int(parts[0]) * 60 + int(parts[1])


def act(name, steps, seconds):
    folder = OUT / name
    shutil.rmtree(folder, ignore_errors=True)
    got = mini("act", json.dumps({"steps": steps, "for": seconds, "film": str(folder)}))
    rows = got.get("rows") or []
    (OUT / f"{name}.json").write_text(json.dumps(rows))
    lines = []
    for row in rows:
        if "mark" in row:
            lines.append(f"{row['t'] * 1000:7.0f} ms  ---- {row['mark']}")
            continue
        lines.append(
            f"{row['t'] * 1000:7.0f} ms  f{row.get('frame', -1):03d}  title {row['title']:7.1f} {'slides' if row['sliding'] else 'rests '}"
            f"  time '{row['time']}' share {row['timeShare']:.2f}  line {row['drawn']:.1f}pt fill {row['fill']:6.1f}"
            f"{' runs' if row['runs'] else '     '}  key {row['key']:5s}  hover card {int(row['card'])} line {int(row['line'])}"
            f"  card {row['opacity']:.2f}{' FACE' if row['face'] else ''}{' scrub' if row['scrub'] >= 0 else ''}"
            f"  at {row['at']:.2f}")
    (OUT / f"{name}.txt").write_text("\n".join(lines) + "\n")
    return rows


def sheet(name, tag, rows, when, count, every=1, across=4):
    folder = OUT / name
    last = len(list(folder.glob("*.png")))
    if last == 0:
        return False
    first = max(0, min(frame_at(rows, when), last - 1))
    picks = [k for k in range(first, last, every)][:count]
    inputs = []
    for k in picks:
        inputs += ["-i", str(folder / f"{k:04d}.png")]
    high = -(-len(picks) // across)
    chain = "".join(f"[{k}:v]" for k in range(len(picks))) + f"concat=n={len(picks)}:v=1:a=0,tile={across}x{high}:padding=6:color=gray"
    made = OUT / f"{name}-{tag}.png"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex", chain, "-frames:v", "1", str(made)], capture_output=True)
    (OUT / f"{name}-{tag}.frames.txt").write_text(" ".join(f"f{k:03d}" for k in picks) + "\n")
    return made.exists()


def movie(name):
    folder = OUT / name
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2,format=yuv420p", str(OUT / f"{name}.mp4")], capture_output=True)


def frames(rows):
    return [row for row in rows if "mark" not in row]


def marks(rows, *words):
    return [(row["t"], row["mark"].split()) for row in rows if "mark" in row and row["mark"].split()[0] in words]


def mark(rows, word, spot=None):
    found = [when for when, said in marks(rows, word) if spot is None or said[1] == spot]
    return found[0] if found else None


def frame_at(rows, when):
    return next((row.get("frame", 0) for row in frames(rows) if row["t"] >= when), 0)


def jumps(values):
    return [abs(b - a) for a, b in zip(values, values[1:])]


def check_pace(name, times):
    gaps = [round((b - a) * 1000) for a, b in zip(times, times[1:])]
    late = [gap for gap in gaps if gap > 34]
    t.ok(f"[{name}] every frame comes on time (longest wait {max(gaps or [0])} ms, over 34 ms {len(late)})", len(gaps) > 6 and not late, gaps)


def check_leave(name, rows):
    off = mark(rows, "point", "off")
    seen = frames(rows)
    earlier = [row for row in seen if row["t"] < off]
    later = [row for row in seen if row["t"] >= off]
    was = earlier[-1]
    far = abs(was["title"])
    if REDUCED:
        t.ok(f"[{name}] with Reduce Motion the title never scrolls", all(row["title"] == 0 and not row["sliding"] for row in seen), far)
        return
    t.ok(f"[{name}] the pointer leaves while the title is mid-scroll", far > 20 and was["timeShare"] == 1, (far, was["timeShare"]))
    places = [was["title"]] + [row["title"] for row in later]
    steps = jumps(places)
    worst = max(steps)
    at = later[steps.index(worst)]
    t.ok(f"[{name}] the title never cuts (most in one frame {worst:.1f} pt of {far:.1f}, at frame f{at.get('frame', -1):03d})",
         worst <= max(3, 0.4 * far), (round(worst, 1), round(far, 1)))
    t.ok(f"[{name}] it goes one way back to its start", all(abs(b) <= abs(a) + 1 for a, b in zip(places, places[1:])) and abs(places[-1]) < 0.5,
         [round(v, 1) for v in places[:30]])
    between = [v for v in places if 0.5 < abs(v) < far - 0.5]
    t.ok(f"[{name}] over several frames", len(between) >= 5, len(between))
    leads = [row["edges"][1] if len(row["edges"]) == 4 else 0 for row in [was] + later]
    t.ok(f"[{name}] the fade at the title's start goes with it", leads[0] > 0 and max(jumps(leads)) <= max(0.004, 0.4 * leads[0]) and leads[-1] == 0,
         [round(v, 3) for v in leads[:30]])
    shares = [row["timeShare"] for row in later]
    t.ok(f"[{name}] the time rolls out one way", all(b <= a + 1e-9 for a, b in zip(shares, shares[1:])) and shares[-1] == 0, shares[-1])


def check_click(name, rows, playing=True):
    seen = frames(rows)
    width = seen[0]["lineWidth"]
    aims = [(when, float(said[2])) for when, said in marks(rows, "down", "drag", "up")]
    down, up = aims[0][0], aims[-1][0]
    off = mark(rows, "point", "off")
    on = [row for row in seen if off is None or row["t"] < off]

    def aim(when):
        return [share for at, share in aims if at <= when][-1]

    def fresh(when):
        return when - [at for at, _ in aims if at <= when][-1]

    was = [row for row in seen if row["t"] < down][-1]
    far = abs(aims[0][1] * width - was["fill"])
    held = [row for row in on if row["t"] >= down]
    fills = [was["fill"]] + [row["fill"] for row in held]
    steps = jumps(fills)
    worst = max(steps)
    at = held[steps.index(worst)]
    if not REDUCED:
        t.ok(f"[{name}] the fill never jumps (most in one frame {worst:.1f} pt of {far:.1f}, at frame f{at.get('frame', -1):03d})",
             worst <= max(4.5, 0.4 * far), (round(worst, 1), round(far, 1)))
    off_spot = []
    for row in held:
        gap = row["fill"] - aim(row["t"]) * width
        if row["t"] < up:
            if fresh(row["t"]) > 0.45 and abs(gap) > 1.5:
                off_spot.append((round(row["t"], 3), round(gap, 1)))
            elif row["t"] > down + 0.45 and abs(gap) > 5:
                off_spot.append((round(row["t"], 3), round(gap, 1)))
        elif row["t"] > up + 0.45 or fresh(row["t"]) > 0.45:
            most = (row["t"] - up) * width / SONG + 1.5 if playing else 1.5
            if gap < -1.5 or gap > most:
                off_spot.append((round(row["t"], 3), round(gap, 1)))
    t.ok(f"[{name}] the fill goes to the pressed spot once and stays or runs on from there", not off_spot, off_spot[:8])
    let_go = [row for row in held if up - 0.02 <= row["t"] <= up + 0.3]
    away = [abs(row["fill"] - aim(row["t"]) * width) for row in let_go]
    back = [(f"f{row.get('frame', -1):03d}", round(b, 1), row["time"]) for row, a, b in zip(let_go[1:], away, away[1:]) if b > a + 1]
    t.ok(f"[{name}] no frame after the release goes back towards the old spot", len(let_go) > 6 and not back, back[:6])
    wrong = []
    last = None
    for row in held:
        if row["t"] < up and fresh(row["t"]) < 0.03:
            continue
        said = clock(row["time"])
        want = int(aim(row["t"]) * SONG)
        if row["t"] < up:
            if said != want:
                wrong.append((round(row["t"], 3), row["time"]))
        else:
            if said is None or said < want or said > want + (row["t"] - up) + 1 or (last is not None and said < last):
                wrong.append((round(row["t"], 3), row["time"]))
            last = said if said is not None else last
    t.ok(f"[{name}] the clock says the pressed spot and never steps back", not wrong, wrong[:8])
    t.ok(f"[{name}] the time stays shown and the line stays thick while the pointer is on it",
         all(row["timeShare"] == 1 and row["drawn"] == 4 and row["time"] for row in on),
         [(round(row["t"], 3), row["timeShare"], row["drawn"]) for row in on if row["timeShare"] != 1 or row["drawn"] != 4][:6])
    keys = [(round(row["t"], 3), row["key"]) for row in seen]
    turns = [b for a, b in zip(keys, keys[1:]) if a[1] != b[1]]
    t.ok(f"[{name}] the play and pause key does not flip", not turns, turns)
    t.ok(f"[{name}] the card stays whole and its face does not cross-fade",
         all(row["opacity"] > 0.999 and row["shown"] and not row["face"] and not row["leaving"] for row in seen),
         [(round(row["t"], 3), row["opacity"], row["face"]) for row in seen if row["opacity"] <= 0.999 or row["face"]][:6])
    t.ok(f"[{name}] the card says the same track throughout", len({row["words"] for row in seen}) == 1, sorted({row["words"] for row in seen}))
    t.ok(f"[{name}] the pointer is still over the card and the line", all(row["card"] and row["line"] for row in on),
         [(round(row["t"], 3), row["card"], row["line"]) for row in on if not (row["card"] and row["line"])][:6])
    if not REDUCED:
        slides = jumps([row["title"] for row in on])
        t.ok(f"[{name}] the title keeps scrolling through the press", max(slides) <= 3, round(max(slides), 1))


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"
    prefs = {}
    if REDUCED:
        prefs["motion.testReduced"] = True
    sv.setup(**prefs)
    sv.launch()
    try:
        sv.cmd({"do": "agents", "action": "stage", "dark": not LIGHT, "size": [1100, 720]})
        time.sleep(0.6)
        if not LIGHT:
            sv.cmd({"do": "space", "action": "look", **NOIR})
        sv.cmd({"do": "ui", "sideWidth": 276})
        time.sleep(0.6)
        other = opened(base, "other")
        song = opened(base, "song")
        sv.cmd({"do": "select", "id": song})
        time.sleep(0.4)
        sv.ev(song, "main.currentTime = 30, start()")
        t.ok("the song plays", until(lambda: sv.ev(song, "main.paused") is False))
        sv.cmd({"do": "select", "id": other})
        t.ok("the card shows it", until(lambda: shown().get("title") == TITLE and shown().get("art")), mini())
        time.sleep(1.2)

        def place(seconds, playing=True, how="site"):
            mini("point", "off")
            sv.ev(song, f"how = '{how}', main.currentTime = {seconds}, 1")
            if playing:
                sv.ev(song, "start()")
            until(lambda: abs(shown().get("time", -9) - seconds) < 3 and shown().get("playing") is playing, 4)
            time.sleep(0.8)

        def hover(share, wait=2.4):
            mini("point", "line", share)
            time.sleep(wait)

        def run(name, steps, seconds):
            rows = act(name, steps, seconds)
            t.ok(f"[{name}] filmed every frame", len(frames(rows)) > seconds * 40, len(frames(rows)))
            movie(name)
            return rows

        def click(share):
            return [{"at": LEAD, "do": "down", "share": share}, {"at": LEAD + 0.09, "do": "up", "share": share}]

        def wanted(name):
            return not ONLY or name in ONLY.split(",")

        spot = 72.5 / SONG
        if wanted("leave"):
            place(30)
            hover(spot)
            rows = run("leave", [{"at": LEAD, "do": "point", "spot": "off"}], LEAD + 1.05)
            sheet("leave", "cut", rows, mark(rows, "point", "off") - 0.02, 16)
            check_leave("leave", rows)

        if wanted("stay"):
            place(30)
            hover(spot)
            rows = run("stay", click(spot), LEAD + 2.05)
            sheet("stay", "press", rows, mark(rows, "down") - 0.02, 16)
            sheet("stay", "seek", rows, mark(rows, "up"), 16, every=6)
            check_click("stay", rows)

        if wanted("clickleave"):
            place(30)
            hover(spot)
            rows = run("clickleave", click(spot) + [{"at": LEAD + 0.85, "do": "point", "spot": "off"}], LEAD + 2.05)
            sheet("clickleave", "press", rows, mark(rows, "down") - 0.02, 16)
            sheet("clickleave", "cut", rows, mark(rows, "point", "off") - 0.02, 16)
            check_click("clickleave", rows)
            check_leave("clickleave", rows)

        if wanted("drag"):
            place(30)
            hover(spot)
            steps = [{"at": LEAD, "do": "down", "share": spot}]
            for k in range(1, 25):
                steps.append({"at": LEAD + 0.35 + k * 0.02, "do": "drag", "share": spot + (0.62 - spot) * k / 24})
            steps.append({"at": LEAD + 0.95, "do": "up", "share": 0.62})
            rows = run("drag", steps, LEAD + 2.65)
            sheet("drag", "press", rows, mark(rows, "down") - 0.02, 16)
            sheet("drag", "whole", rows, mark(rows, "down"), 24, every=10)
            check_click("drag", rows)

        if wanted("forward"):
            place(20)
            hover(0.86)
            rows = run("forward", click(0.86), LEAD + 2.05)
            sheet("forward", "press", rows, mark(rows, "down") - 0.02, 16)
            check_click("forward", rows)

        if wanted("back"):
            place(245)
            hover(0.08)
            rows = run("back", click(0.08), LEAD + 2.05)
            sheet("back", "press", rows, mark(rows, "down") - 0.02, 16)
            check_click("back", rows)

        if wanted("late"):
            place(30, how="late")
            late = 72.6 / SONG
            hover(late)
            rows = run("late", click(late), LEAD + 2.05)
            sheet("late", "seek", rows, mark(rows, "up"), 16, every=6)
            check_click("late", rows)

        if wanted("plain"):
            place(30, how="plain")
            hover(spot)
            rows = run("plain", click(spot), LEAD + 2.05)
            check_click("plain", rows)

        if wanted("paused"):
            place(30)
            mini("toggle")
            until(lambda: shown().get("playing") is False, 4)
            time.sleep(0.6)
            hover(0.5)
            rows = run("paused", click(0.5), LEAD + 2.05)
            sheet("paused", "press", rows, mark(rows, "down") - 0.02, 16)
            check_click("paused", rows, playing=False)
            mini("point", "off")
            mini("toggle")
            until(lambda: shown().get("playing") is True, 4)

        if wanted("picked"):
            two = opened(base, "song?title=Born%20To%20Fly&artist=A%20Singer")
            sv.cmd({"do": "select", "id": two})
            time.sleep(0.4)
            sv.ev(two, "main.currentTime = 100, start()")
            sv.cmd({"do": "select", "id": other})
            t.ok("[picked] a second tab plays and takes the card", until(lambda: shown().get("title") == "Born To Fly"), shown())
            mini("choose", song[:8])
            t.ok("[picked] the first is picked back from the menu", until(lambda: shown().get("title") == TITLE), shown())
            place(30)
            hover(spot)
            rows = run("picked", click(spot), LEAD + 2.05)
            sheet("picked", "seek", rows, mark(rows, "up"), 16, every=6)
            check_click("picked", rows)
            sv.ev(two, "main.pause(), 1")
            sv.cmd({"do": "close", "id": two})

        if wanted("pace"):
            big = opened(base, "song?art=big&title=Born%20To%20Fly%20in%20a%20very%20large%20picture&artist=A%20Singer")
            sv.cmd({"do": "select", "id": big})
            time.sleep(0.4)
            sv.ev(big, "how = 'plain', main.currentTime = 30, start()")
            sv.cmd({"do": "select", "id": other})
            t.ok("[pace] a track with a 2000 pixel picture takes the card",
                 until(lambda: shown().get("title", "").startswith("Born To Fly in") and shown().get("art")), shown())
            time.sleep(1.5)
            for way, where in (("in", "line"), ("out", "off")):
                mini("point", where, spot)
                time.sleep(1.2)
                trace = (mini().get("view") or {}).get("swap") or []
                check_pace(f"pace roll {way}", [row[0] for row in trace])
                if way == "in":
                    got = mini("act", json.dumps({"steps": click(spot), "for": LEAD + 1.2})).get("rows") or []
                    (OUT / "pace.json").write_text(json.dumps(got))
                    pressed = mark(got, "down")
                    check_pace("pace click", [row["t"] for row in frames(got) if pressed - 0.1 <= row["t"] <= pressed + 0.9])
                    time.sleep(0.6)
            sv.ev(big, "main.pause(), 1")
            sv.cmd({"do": "close", "id": big})

        mini("point", "off")
        sv.ev(song, "main.pause(), 1")
    finally:
        sv.quit()
        sv.finish()
        server.shutdown()
    t.done()
    sys.exit(1 if t.failed else 0)


main()
