#!/usr/bin/env python3
"""Pictures of the Tempo speed HUD, from a hidden test copy of its own.

Build first (`./build.sh`), then `python3 Tests/tempo_hud_shots.py <label> [rev]`;
a rev cuts the fixture's HUD from that commit's Tempo.swift instead.
Shots land in `.context/tempo-hud/<label>/`, one per speed, taken by the
bench's page snapshot (the test copy's tab only, never the screen). The
speeds a key can reach (0.5, 1.0, 2.5, 3.0) are pressed over a landscape and
a portrait video. 10.0 and 16.0 are past Tempo's 3.0 limit, so a fixture page
runs the HUD's own functions, cut from Tempo.swift, on a box the size of the
landscape video. Each shot's ink is read back from its pixels: the columns
the HUD's light glyphs cover, the gaps between them and how far the last
glyph sits from the video's right edge.
"""
import functools
import json
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

sv.use("tempo-hud-shots")

LABEL = sys.argv[1] if len(sys.argv) > 1 else "now"
SOURCE_AT = sys.argv[2] if len(sys.argv) > 2 else None
OUT = ROOT / ".context" / "tempo-hud" / LABEL
FIXTURE = [None]
BACKGROUND = "0x2a2d30"
SPEEDS = ["0.5", "1.0", "1.5", "2.0", "2.5", "3.0"]
FUNCTIONS = [
    "ensureSpeedOverlay", "ensureOverlayRootPosition", "getOverlayVariant", "getOverlayLayout",
    "renderOverlayContent", "renderSpeedOverlay", "createDigitNode", "tightenSpeedGlyphs",
    "measureGlyphInk", "fitOverlayBadge", "sameOverlayBox", "measureOverlayFit", "measureOverlayBadge",
    "positionOverlayHost", "setHostStyle", "clamp",
]


class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def cut(source, name):
    start = source.find(f"function {name}(")
    if start < 0:
        return ""
    depth, index = 0, source.index("{", start)
    while True:
        depth += {"{": 1, "}": -1}.get(source[index], 0)
        index += 1
        if depth == 0:
            return source[start:index]


def fixture_script():
    source = (subprocess.run(["git", "-C", str(ROOT), "show", f"{SOURCE_AT}:Sources/Search/Tempo.swift"],
                             capture_output=True, text=True, check=True).stdout
              if SOURCE_AT else (ROOT / "Sources" / "Search" / "Tempo.swift").read_text())
    lines = re.findall(r"^\s*((?:const|let) (?:SPEED_\w+|GLYPH_\w+|FIT_\w+|HUD_FADE_MS|SAME_BOX_SLACK|glyphCanvas|glyphInkCache|hud\w+) = [^\n]*;)$",
                       source, re.M)
    return "\n".join(lines + [cut(source, name) for name in FUNCTIONS])


def ink(path, width, height, box):
    raw = subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-f", "rawvideo",
                          "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
    scale = width / box["pageWidth"]
    left, top = int(box["left"] * scale), int(box["top"] * scale)
    right, bottom = int(box["right"] * scale), int(box["bottom"] * scale)
    lit = []
    for x in range(left, right):
        lit.append(any(raw[y * width + x] > 110 for y in range(top, bottom, 2)))
    runs, start = [], None
    for offset, on in enumerate(lit + [False]):
        if on and start is None:
            start = offset
        if not on and start is not None:
            runs.append((left + start, left + offset))
            start = None
    runs = [run for run in runs if run[1] - run[0] > 2]
    gaps = [round((b[0] - a[1]) / scale, 1) for a, b in zip(runs, runs[1:])]
    widths = [round((b - a) / scale, 1) for a, b in runs]
    spans = [[round((a - left) / scale, 1), round((b - left) / scale, 1)] for a, b in runs]
    return {"glyphWidths": widths, "gaps": gaps, "runs": spans,
            "rightOfInk": round((right - runs[-1][1]) / scale, 1) if runs else None}


GEOMETRY = """(() => {
  const badge = window.__broadwayTempoBadge ? window.__broadwayTempoBadge() : window.hudBadge;
  const host = badge && badge.getRootNode().host;
  const video = document.getElementById(%s);
  if (!badge || !video) return null;
  const b = badge.getBoundingClientRect(), v = video.getBoundingClientRect();
  return { text: badge.textContent, rate: video.playbackRate, paused: video.paused, shown: host.style.opacity, fontSize: parseFloat(badge.style.fontSize),
    badge: { left: b.left, top: b.top, right: b.right, bottom: b.bottom },
    video: { left: v.left, top: v.top, right: v.right, bottom: v.bottom },
    margins: Array.from(badge.querySelectorAll('.tempo-digit, .tempo-dot')).map(n => n.style.marginLeft || ''),
    cells: Array.from(badge.querySelectorAll('.tempo-digit, .tempo-dot')).map(n => {
      const r = n.getBoundingClientRect();
      return [+(r.left - v.left).toFixed(2), +(r.right - v.left).toFixed(2)];
    }),
    pageWidth: document.documentElement.clientWidth };
})()"""


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="broadway-tempo-hud-") as folder:
        root = Path(folder)
        for name, size in [("wide.mp4", "960x540"), ("tall.mp4", "360x640")]:
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                            f"color=c={BACKGROUND}:size={size}:rate=24", "-t", "60", "-c:v", "libx264",
                            "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(root / name)], check=True)
        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=folder))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_port}"
        (root / "wide.html").write_text("""<!doctype html><title>wide</title><body style='margin:0;background:#2a2d30'>
        <video id=video src=wide.mp4 muted loop playsinline style='display:block;width:960px;height:540px'></video>""")
        (root / "tall.html").write_text("""<!doctype html><title>tall</title><body style='margin:0;background:#2a2d30'>
        <video id=video src=tall.mp4 muted loop playsinline style='display:block;width:360px;height:640px'></video>""")
        (root / "fixture.html").write_text("""<!doctype html><title>fixture</title><body style='margin:0;background:#2a2d30'>
        <div id=video style='position:relative;width:960px;height:540px;background:#2a2d30'></div>
        <script>
        """ + fixture_script() + """
        window.__broadwayTempoBadge = () => hudBadge;
        window.show = (text) => {
          const box = document.getElementById('video');
          const host = ensureSpeedOverlay(box);
          const badge = hudBadge;
          const rect = box.getBoundingClientRect();
          const variant = getOverlayVariant(text);
          const layout = { ...getOverlayLayout(rect, variant), scale: 1 };
          badge.style.fontSize = FIT_PROBE_PX + 'px';
          renderOverlayContent(badge, text, variant);
          const size = fitOverlayBadge(host, badge, layout);
          positionOverlayHost(host, rect, rect, { left: 0, top: 0 }, size, layout);
          hudFit = null;
          setHostStyle(host, { transition: 'none', opacity: '1' });
          return badge.textContent;
        };
        </script>""")

        report = {}
        try:
            sv.setup(**{"float.leave": False})
            sv.launch()
            sv.cmd({"do": "window"})
            sv.cmd({"do": "resize", "width": 1400, "height": 960, "steps": 1})
            time.sleep(1)

            def ev(tab, js):
                return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")

            def shoot(tab, name):
                if tab != FIXTURE[0]:
                    sv.cmd({"do": "eval", "id": tab, "world": "search", "js": "(() => { const h = __broadwayTempoBadge().getRootNode().host; "
                            "h.style.setProperty('transition', 'none', 'important'); h.style.setProperty('opacity', '1', 'important'); return 1; })()"})
                geometry = sv.cmd({"do": "eval", "id": tab, "js": GEOMETRY % "'video'",
                                   **({} if tab == FIXTURE[0] else {"world": "search"})}).get("value")
                taken = root / f"{name}.png"
                shot = sv.cmd({"do": "shot", "id": tab, "path": str(taken)})
                path = OUT / f"{name}.png"
                shutil.copyfile(taken, path)
                if geometry and "width" in shot:
                    box = {**geometry["video"], "pageWidth": geometry["pageWidth"]}
                    geometry["ink"] = ink(path, shot["width"], shot["height"], box)
                    geometry["shotWidth"] = shot["width"]
                report[name] = geometry
                print(name, json.dumps(geometry))

            for page in ["wide", "tall"]:
                tab = sv.sp("open", url=f"{base}/{page}.html")["resultID"]
                sv.cmd({"do": "select", "id": tab})
                time.sleep(2.5)
                ev(tab, "document.getElementById('video').play(), true")
                ev(tab, "document.head.appendChild(Object.assign(document.createElement('style'), "
                        "{ textContent: '#tempo-hud-host { opacity: 1 !important; transition: none !important; }' })), true")
                for name, keys in [("1.0", "fs"), ("0.5", "sssss"), ("1.5", "d" + "f" * 5), ("2.0", "d" + "f" * 10),
                                   ("2.5", "d" + "f" * 15), ("3.0", "fffff")]:
                    for key in keys:
                        sv.cmd({"do": "key", "id": tab, "text": key})
                        time.sleep(0.12)
                    deadline = time.time() + 10
                    while ev(tab, "document.getElementById('video').playbackRate") != float(name) and time.time() < deadline:
                        time.sleep(0.2)
                    time.sleep(0.1)
                    shoot(tab, f"{page}-{name}")
                    time.sleep(1.3)

            tab = sv.sp("open", url=f"{base}/fixture.html")["resultID"]
            FIXTURE[0] = tab
            sv.cmd({"do": "select", "id": tab})
            time.sleep(1.5)
            for text in SPEEDS + ["1.8", "10.0", "16.0"]:
                ev(tab, f"show('{text}')")
                time.sleep(0.2)
                shoot(tab, f"fixture-{text}")
        finally:
            sv.finish()
            server.shutdown()
        (OUT / "geometry.json").write_text(json.dumps(report, indent=2))
        for page in ["wide", "tall", "fixture"]:
            strip(page, report)


def strip(page, report):
    shots = [(OUT / f"{page}-{speed}.png", report.get(f"{page}-{speed}")) for speed in SPEEDS]
    shots = [(path, geometry) for path, geometry in shots if path.exists() and geometry]
    if len(shots) < 2:
        return
    left = min(g["badge"]["left"] for _, g in shots) - 12
    top = min(g["badge"]["top"] for _, g in shots) - 12
    right = max(g["badge"]["right"] for _, g in shots) + 12
    bottom = max(g["badge"]["bottom"] for _, g in shots) + 12
    scale = shots[0][1].get("shotWidth", shots[0][1]["pageWidth"]) / shots[0][1]["pageWidth"]
    crop = (f"crop={int((right - left) * scale)}:{int((bottom - top) * scale)}"
            f":{int(left * scale)}:{int(top * scale)}")
    inputs = sum([["-i", str(path)] for path, _ in shots], [])
    cropped = ";".join(f"[{i}:v]{crop}[c{i}]" for i in range(len(shots)))
    labels = "".join(f"[c{i}]" for i in range(len(shots)))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex",
                    f"{cropped};{labels}vstack=inputs={len(shots)}", str(OUT / f"strip-{page}.png")], check=True)
    chain = "[c0]"
    steps = []
    for i in range(1, len(shots)):
        steps.append(f"{chain}[c{i}]blend=all_mode=lighten[o{i}]")
        chain = f"[o{i}]"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *inputs, "-filter_complex",
                    f"{cropped};" + ";".join(steps), "-map", chain, str(OUT / f"overlay-{page}.png")], check=True)


if __name__ == "__main__":
    main()
