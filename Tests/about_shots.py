#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

parser = argparse.ArgumentParser(description="The standard About panel opened twice, then pictured in dark and light by its window id "
                                 "into .context/LABEL/window-dark.png and window-light.png.")
parser.add_argument("label")
options = parser.parse_args()
OUT = ROOT / ".context" / options.label
failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name + (f"  {detail}" if detail else ""), flush=True)
    if not ok:
        failures.append(name)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sv.use("about-shots-" + uuid.uuid4().hex[:6])
    sv.setup(**{"start.fresh": False})
    sv.launch()
    try:
        first = sv.cmd({"do": "about"})
        again = sv.cmd({"do": "about"})
        print(json.dumps(first, indent=1), flush=True)
        check("the panel opens", first.get("window", 0) > 0 and (first.get("visible") is True or first.get("hidden") is True))
        check("opening it twice brings the same panel forward", again.get("window") == first.get("window") and again.get("panels", 0) <= 1)
        check("a standard titled window with a close button", first.get("titled") is True and first.get("closable") is True)
        texts = first.get("texts", [])
        check("the name is Broadway", "Broadway" in texts, str(texts))
        versions = [t for t in texts if t.startswith("Version ")]
        check("one version line", len(versions) == 1, str(versions))
        if versions:
            line = versions[0]
            short = line.split(" ")[1]
            check("the build is not the short version again", f"({short})" not in line, line)
            check("the build is written once", line.count("(") <= 1, line)
        check("the copyright line", "Open source under the MIT License. Based on Search © Office Commun" in texts, str(texts))
        check("the credits", "broadwaybrowser.com\nSource code on GitHub" in texts, str(texts))
        frame, middle = first.get("frame", []), first.get("screen", [])
        if len(frame) == 4 and len(middle) == 2:
            dx = abs(frame[0] + frame[2] / 2 - middle[0])
            check("centred across the screen", dx < 2, f"dx {dx:.1f}")
        for look in ["dark", "light"]:
            said = sv.cmd({"do": "about", "look": look})
            shot = OUT / f"window-{look}.png"
            subprocess.run(["screencapture", "-x", "-o", "-l", str(said.get("window", 0)), str(shot)],
                           stdin=subprocess.DEVNULL, capture_output=True, timeout=30)
            check(f"{look}: window picture by id", shot.exists() and shot.stat().st_size > 2000,
                  "no screen recording grant over ssh" if not shot.exists() else "")
    finally:
        sv.finish()
    print(f"{len(failures)} failed: {failures}" if failures else "all passed", flush=True)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
