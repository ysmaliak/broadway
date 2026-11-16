#!/usr/bin/env python3
import argparse
import shutil
import tempfile
import sys
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

parser = argparse.ArgumentParser(description="The About window drawn off screen at 2x by the app itself into "
                                 ".context/LABEL/about-dark.png and about-light.png, then shown behind every window once.")
parser.add_argument("label")
options = parser.parse_args()
OUT = ROOT / ".context" / options.label


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sv.use("about-shots-" + uuid.uuid4().hex[:6])
    sv.setup(**{"start.fresh": False})
    sv.launch()
    try:
        drawn = Path(tempfile.mkdtemp(prefix="about-shots-", dir="/private/tmp"))
        said = sv.cmd({"do": "about", "path": str(drawn)})
        for path in said.get("saved", []):
            kept = OUT / Path(path).name
            shutil.move(path, kept)
            print(kept, flush=True)
        shutil.rmtree(drawn, ignore_errors=True)
        surface = sv.cmd({"do": "surface", "name": "about", "look": "dark"})
        print("about surface:", surface.get("number"), surface.get("size"), flush=True)
        sv.cmd({"do": "surface", "action": "close"})
        window = sv.cmd({"do": "about"})
        print("about window:", window.get("window"), window.get("title"), flush=True)
    finally:
        sv.finish()


if __name__ == "__main__":
    main()
