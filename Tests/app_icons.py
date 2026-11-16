#!/usr/bin/env python3
import os
import plistlib
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("BROADWAY_PROBE_APP") or ROOT / "build" / "Broadway.app")
COLOURS = ["ink", "night", "day", "volt", "citrus"]
failed = 0


def ok(name, passed, detail=""):
    global failed
    print(("PASS " if passed else "FAIL ") + name + ("" if passed else f": {detail}"))
    failed += 0 if passed else 1


def png_size(path):
    with open(path, "rb") as file:
        head = file.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", head[16:24])


for colour in COLOURS:
    picture = APP / "Contents" / "Resources" / "Icons" / f"{colour}.png"
    ok(f"{colour}.png is in the bundle", picture.is_file(), picture)
    if picture.is_file():
        ok(f"{colour}.png is 512 points at 2x", png_size(picture) == (1024, 1024), png_size(picture))

with open(APP / "Contents" / "Info.plist", "rb") as file:
    info = plistlib.load(file)
baked = info.get("BroadwayAppIcon")
ok("the baked colour is named in Info.plist", baked in COLOURS, baked)
ok("the bundle's root has no Finder icon", not (APP / "Icon\r").exists())
signed = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(APP)], capture_output=True, text=True)
ok("the signature holds under --strict", signed.returncode == 0, signed.stderr.strip())
print(f"baked: {baked}")
sys.exit(1 if failed else 0)
