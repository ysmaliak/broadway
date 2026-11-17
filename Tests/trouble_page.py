#!/usr/bin/env python3
import argparse
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

argparse.ArgumentParser(description="The page a tab shows when a load fails, read from its own views in a hidden probe: its "
                        "words, its buttons, and where its host is said with the column shown, folded away and in a split. "
                        "Build first. The world is its own and is removed afterwards.").parse_args()
sv.use("trouble-page")
ROOT = Path(__file__).resolve().parents[1]
TOOLS = ROOT / ".context" / "visual-tools"
VIVID = {"custom": "3139FB", "intensity": 1}
BLACK = {"colours": ["000000"], "intensity": 1}
TITLE = "The site refused the connection"
LINE = "It's there, but it isn't answering right now"
HOST = "127.0.0.1"


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def until(check, within=20):
    end = time.time() + within
    while time.time() < end:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.2)
    return False


def page():
    return sv.cmd({"do": "ownpage"})


def texts(seen, kind=None):
    return [v.get("text", "") for v in seen["views"] if "text" in v and (kind is None or v["kind"] == kind)]


def kinds(seen):
    return {v["kind"] for v in seen["views"]}


def tool(name, source):
    TOOLS.mkdir(parents=True, exist_ok=True)
    out = TOOLS / name
    src = ROOT / "Tests" / source
    if not out.exists() or out.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(src), "-o", str(out)], check=True)
    return out


def page_picture(name, look):
    sv.cmd({"do": "space", "action": "look", **look})
    time.sleep(0.9)
    x, y, wide, tall = sv.cmd({"do": "probe"})["activePageFrame"]
    whole = Path(sv.SUPPORT) / f"{name}-window.png"
    cut = Path(sv.SUPPORT) / f"{name}.png"
    sv.cmd({"do": "picture", "path": str(whole), "page": False})
    edge = 20
    subprocess.run(["sips", "-c", str(int(2 * (tall - 2 * edge))), str(int(2 * (wide - 2 * edge))),
                    "--cropOffset", str(int(2 * (y + edge))), str(int(2 * (x + edge))), str(whole), "--out", str(cut)],
                   capture_output=True)
    return cut


def same(a, b):
    if not (a.exists() and b.exists()):
        return {"error": "no picture"}
    ran = subprocess.run([str(tool("pixel-diff", "PixelDiff.swift")), str(a), str(b), str(a.with_name("diff.png")), "0", "0"],
                         capture_output=True, text=True)
    try:
        return json.loads(ran.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return {"error": ran.stdout.strip()[-200:]}


def says_host():
    return HOST in texts(page(), "KitLabel")


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        sv.cmd({"do": "ui", "folded": False})
        port = free_port()
        tid = sv.sp("open", url=f"http://{HOST}:{port}/page")["resultID"]
        failed = until(lambda: sv.cmd({"do": "trouble"}).get("trouble") == "refused")
        t.ok("a page nothing answers is read as refused", failed, sv.cmd({"do": "trouble"}))
        time.sleep(0.6)

        seen = page()
        t.ok("the page in front is the failed load's", seen.get("kind") == "TroubleView", seen.get("kind"))
        t.ok("it says its title, then its line", texts(seen, "KitParagraph") == [TITLE, LINE], texts(seen, "KitParagraph"))
        t.ok("Try Again is its only button", texts(seen, "KitBroadwayButton") == ["Try Again"], texts(seen, "KitBroadwayButton"))
        t.ok("it has one symbol", texts(seen, "KitSymbol") == ["hand.raised"], texts(seen, "KitSymbol"))
        t.ok("it has no glow and no ground of the space's",
             not kinds(seen) & {"TroubleGlow", "PageGroundView", "GroundPaintView", "TroublePill"}, sorted(kinds(seen)))
        t.ok("the host is left to the address field", HOST not in " ".join(texts(seen)), texts(seen))
        t.ok("the tab still says the address that failed", f"{HOST}:{port}" in next(
            (x.get("url", "") for x in sv.sp("state")["tabs"] if x["id"] == tid), ""), sv.sp("state")["tabs"])

        before = [v["frame"] for v in seen["views"]]
        time.sleep(1.0)
        t.ok("nothing on it moves", [v["frame"] for v in page()["views"]] == before)

        for look in ("light", "dark"):
            sv.cmd({"do": "ui", "look": look})
            said = same(page_picture(f"vivid-{look}", VIVID), page_picture(f"black-{look}", BLACK))
            t.ok(f"in {look} the page is the same in a vivid space and a black one",
                 said.get("touched") == 0 and said.get("width", 0) > 400, said)

        sv.cmd({"do": "ui", "folded": True})
        t.ok("with the column folded away the page says the host", until(says_host, 5), texts(page()))
        sv.cmd({"do": "ui", "folded": False})
        t.ok("with the column back the host is left to the field again", until(lambda: not says_host(), 5), texts(page()))

        other = sv.page("beside")
        sv.sp("pair", id=tid, **{"with": other})
        sv.sp("focus", id=other)
        t.ok("in a split the pane that is not focused says its host", until(says_host, 5), texts(page()))
        sv.sp("focus", id=tid)
        t.ok("the focused pane leaves its host to its bar", until(lambda: not says_host(), 5), texts(page()))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
