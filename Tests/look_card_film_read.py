#!/usr/bin/env python3
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
folder = ROOT / ".context" / "look-card" / f"film-{sys.argv[1] if len(sys.argv) > 1 else 'now'}"
PIXEL = ROOT / ".context" / "look-card-tools" / "pixel"
STRIP = ROOT / ".context" / "look-card-tools" / "film-strip"
if not PIXEL.exists():
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/GroundPixel.swift"), "-o", str(PIXEL)], check=True)
if not STRIP.exists():
    subprocess.run(["swiftc", str(ROOT / "Tests/film_strip.swift"), "-o", str(STRIP)], check=True)

out = {}
for film in sorted(p for p in folder.iterdir() if p.is_dir()):
    frames = sorted(film.glob("*.png"))
    if not frames:
        continue
    if film.name.startswith("switch"):
        series = []
        for frame in frames:
            read = json.loads(subprocess.run([str(PIXEL), str(frame), "0.06", "0.62", "0.16", "0.7"], capture_output=True, text=True).stdout or "{}")
            series.append(read.get("mean"))
        distinct = []
        for value in series:
            if value and (not distinct or max(abs(a - b) for a, b in zip(value, distinct[-1])) > 2):
                distinct.append(value)
        spread = max((max(abs(a - b) for a, b in zip(v, series[0])) for v in series if v), default=0)
        out[film.name] = {"frames": len(series), "most from first frame": round(spread, 1),
                          "grounds seen": [[round(c) for c in v] for v in distinct]}
        print(f"{film.name}: {len(series)} frames, sidebar moved at most {spread:.1f} from frame 0, grounds {out[film.name]['grounds seen'][:6]}")
    else:
        subprocess.run([str(STRIP), str(film), str(folder / f"{film.name}-strip.png"), "", "8", "260"], capture_output=True)
        print(f"{film.name}: {len(frames)} frames, strip {film.name}-strip.png")
(folder / "read.json").write_text(json.dumps(out, indent=1))
