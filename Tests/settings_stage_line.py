#!/usr/bin/env python3
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("set-line")
ROOT = Path(__file__).resolve().parents[1]
EDGE = ROOT / ".build" / "settings-bar" / "edge-pixels"
HEADER = ("well", "band", "picture", "titleBox")
t = sv.T()


def edge(*args):
    return subprocess.run([str(EDGE), *map(str, args)], capture_output=True, text=True).stdout.strip()


def ui(**f): return sv.cmd({"do": "ui", **f})
def stage(): return sv.cmd({"do": "settings", "find": "", "stage": True})["stage"]


def scroll(y):
    sv.cmd({"do": "settings", "find": "", "scroll": float(y)})
    time.sleep(0.4)
    return stage()


def go(page):
    ui(settingsFind="")
    time.sleep(0.2)
    ui(settingsPage=page)
    time.sleep(1.0)


def shoot(out, name):
    path = out / f"{name}.png"
    path.unlink(missing_ok=True)
    took = sv.cmd({"do": "picture", "path": str(path), "page": False})
    t.ok(f"{name}: pictured", path.exists(), took)
    return path


def same(a, b):
    return all(a[k] == b[k] for k in HEADER)


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "stage-line").resolve()
    out.mkdir(parents=True, exist_ok=True)
    EDGE.parent.mkdir(parents=True, exist_ok=True)
    if not EDGE.exists() or EDGE.stat().st_mtime < (ROOT / "Tests/EdgePixels.swift").stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(ROOT / "Tests/EdgePixels.swift"), "-o", str(EDGE)], check=True)
    sv.setup(spaces=True, ai=True, **{"start.fresh": True})
    sv.launch()
    measures = {}
    try:
        sv.cmd({"do": "resize", "width": 1130.0, "height": 700.0, "steps": 1})
        for index in range(26):
            sv.page(f"Loose tab {index:02d}")
        ui(settings=True)
        time.sleep(1.5)
        for theme in ("dark", "light"):
            ui(look=theme)
            time.sleep(0.8)
            go("appearance")
            rest = scroll(0)
            shoot(out, f"appearance-rest-{theme}")
            t.ok(f"{theme}: at rest no line, the whole header", not rest["lined"] and not rest["folded"] and rest["picture"][2] == 280, rest)
            for depth, name in ((40, "40"), (400, "deep")):
                s = scroll(depth)
                shoot(out, f"appearance-{name}-{theme}")
                foot = s["well"][1] + s["well"][3]
                t.ok(f"{theme} {name}: the header is as at rest", same(s, rest), {k: (rest[k], s[k]) for k in HEADER})
                t.ok(f"{theme} {name}: the line is shown at the header's foot", s["lined"] and abs(s["line"][1] + s["line"][3] - foot) <= 0.5, (s["line"], foot))
                measures[f"appearance-{name}-{theme}"] = {"line": s["line"], "well": s["well"], "offset": s["offset"]}
            scroll(0)
        ui(look="dark")
        time.sleep(0.8)
        go("general")
        s = scroll(80)
        shoot(out, "general-scrolled-dark")
        t.ok("general: no header, the line at the top of the rows", s["folded"] and s["lined"] and s["line"][1] < 120, s["line"])
        measures["general"] = {"line": s["line"]}
        scroll(0)

        go("appearance")
        column = sv.cmd({"do": "columnscroll", "wheel": 160.0})
        time.sleep(0.6)
        s = scroll(40)
        both = shoot(out, "appearance-40-dark-sidebar-scrolled")
        runs = [r.split(":") for r in edge("column", both, 20, 160, 600).split()]
        side = next((int(runs[i][0]) / 2 for i in range(1, len(runs) - 1)
                     if runs[i][1].endswith("x1") and runs[i - 1][1].split("x")[0] == runs[i + 1][1].split("x")[0]), 0)
        t.ok("the browser sidebar shows its line", side > 0 and column.get("edges", {}).get("top") == 1, runs[:4])
        line = s["line"][1]
        left = s["pane"][0]
        edge("crop", both, int(left * 2), int((line - 12) * 2), 400, 48, 2, out / "line-settings-2x.png")
        edge("crop", both, 0, int((side - 12) * 2), int(min(200, left) * 2), 48, 2, out / "line-sidebar-2x.png")
        measures["pixels"] = {
            "settings": edge("column", both, int(left * 2 + 60), int((line - 3) * 2), int((line + 3) * 2)),
            "sidebar": edge("column", both, 20, int((side - 3) * 2), int((side + 3) * 2)),
            "settingsLine": line, "sidebarLine": side, "sidebarEdges": column.get("edges", {}),
        }
        print("  pixels", json.dumps(measures["pixels"]))
        sv.cmd({"do": "columnscroll", "wheel": -600.0})
        scroll(0)

        sv.cmd({"do": "resize", "width": 1130.0, "height": 480.0, "steps": 1})
        time.sleep(0.8)
        go("appearance")
        rest = scroll(0)
        s = scroll(60)
        shoot(out, "appearance-short-60-dark")
        room = s["pane"][1] + s["pane"][3] - (s["well"][1] + s["well"][3])
        t.ok("short: the small header, whole, with the line at its foot", s["compact"] and same(s, rest) and s["lined"], s)
        measures["short"] = {"pane": s["pane"], "well": s["well"], "rows": room}
        print("  short", json.dumps(measures["short"]))
        (out / "measures.json").write_text(json.dumps(measures, indent=1))
    finally:
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
