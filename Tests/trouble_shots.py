#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402
import world_out as wo  # noqa: E402

parser = argparse.ArgumentParser(description="The page a tab shows when a load fails, drawn by the bench itself at 2x into "
                                 ".context/failed-page/LABEL/: each kind in light and dark at 720 by 520 and at 320 wide, then "
                                 "the page that waits for the network, the page that says its host and a large one. Build "
                                 "first. The app starts hidden in a world of its own and is quit, and nothing is put on the "
                                 "screen.")
parser.add_argument("label")
parser.add_argument("--only", default="", help="kinds to draw, comma separated")
options = parser.parse_args()
OUT = ROOT / ".context" / "failed-page" / options.label
KINDS = ["notFound", "offline", "slow", "refused", "insecure", "tooLarge", "other"]
ONLY = set(filter(None, options.only.split(",")))
LONG_HOST = "accounts.long-subdomain.example-company-name.test"
t = sv.T()


def draw(name, **request):
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    spot = wo.spot(sv, path.name)
    made = sv.cmd({"do": "surface", "name": "trouble", "pad": 0, "path": str(spot), **request})
    sv.cmd({"do": "surface", "action": "close"})
    saved = spot.exists() and made.get("saved") == str(spot)
    if saved:
        wo.bring(spot, path)
    t.ok(f"{name}: drawn", saved and path.exists(), made)
    return path


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    sv.use("trouble-shots")
    sv.setup()
    sv.launch()
    try:
        for kind in KINDS:
            if ONLY and kind not in ONLY:
                continue
            for look in ("light", "dark"):
                draw(f"{kind}-{look}", kind=kind, look=look, width=720, height=520)
                draw(f"{kind}-320-{look}", kind=kind, look=look, width=320, height=520)
        for look in ("light", "dark"):
            draw(f"waiting-{look}", kind="offline", look=look, width=720, height=520, waiting=True)
            draw(f"waiting-320-{look}", kind="offline", look=look, width=320, height=520, waiting=True)
            draw(f"host-{look}", kind="refused", look=look, width=720, height=520, host="example.test")
            draw(f"host-long-320-{look}", kind="slow", look=look, width=320, height=520, host=LONG_HOST)
            draw(f"large-{look}", kind="slow", look=look, width=1600, height=1000)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
