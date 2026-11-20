#!/usr/bin/env python3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import fullscreen_tab as ft  # noqa: E402

sv.use("fullscreen-side")
ESC = "\x1b"


def side(action, **f):
    return sv.cmd({"do": "fullscreenside", "action": action, **f})


def esc(number):
    sv.cmd({"do": "press", "code": 53, "chars": ESC, "number": number})
    time.sleep(0.6)


def run(t, twice):
    name = f"Esc twice {'on' if twice else 'off'}"
    sv.setup(**{"sidebar": True, "splitView": False, "fullscreen.escapeTwice": twice})
    ft.launch()
    b = sv.page("b")
    a = sv.page("a")
    time.sleep(0.8)
    p = ft.go_full(a)
    entered = ft.full(a)(p)
    t.ok(f"{name}: the video goes full screen for real", entered, p.get("fullscreenStates"))
    if not entered:
        sv.quit()
        return
    time.sleep(1.0)
    s = side("state")
    t.ok(f"{name}: the full screen is WebKit's own window", s["host"] != 0 and "FullScreen" in s["hostKind"], s)
    t.ok(f"{name}: its window hears the pointer move", s["hearsMoves"], s)
    t.ok(f"{name}: nothing out at first", not s["out"], s)

    s = side("pass")
    t.ok(f"{name}: a pointer only passing the edge brings nothing out", not s["out"], s)

    s = side("edge")
    t.ok(f"{name}: resting at the edge brings the sidebar out", s["out"], s)
    t.ok(f"{name}: it is a child of WebKit's full-screen window, on screen", s["parentIsHost"] and s["panelVisible"], s)
    t.ok(f"{name}: it shows the tabs", s["rows"] >= 2, s)
    p = ft.probe()
    t.ok(f"{name}: the video is still full screen under it", ft.full(a)(p), p.get("fullscreenStates"))
    ft.shoot(f"side-{'twice' if twice else 'once'}-out")

    s = side("inside")
    t.ok(f"{name}: the pointer in the sidebar keeps it out", s["out"], s)

    esc(s["host"])
    s = side("state")
    p = ft.probe()
    t.ok(f"{name}: Escape sends the sidebar back", not s["out"], s)
    t.ok(f"{name}: and leaves the video full screen", ft.full(a)(p), p.get("fullscreenStates"))
    t.ok(f"{name}: and brings no reminder up", not s["reminder"], s)

    s = side("edge")
    t.ok(f"{name}: after Escape the pointer still at the edge brings nothing back", not s["out"], s)
    side("away")
    s = side("edge")
    t.ok(f"{name}: away and back to the edge brings it out again", s["out"], s)

    s = side("away")
    t.ok(f"{name}: the pointer leaving sends it back", not s["out"], s)

    s = side("edge")
    s = side("click", id=b)
    p = ft.wait(ft.home(a))
    t.ok(f"{name}: a click on another tab's row leaves the full screen", ft.home(a)(p), p.get("fullscreenStates"))
    time.sleep(0.6)
    p = ft.probe()
    t.ok(f"{name}: and shows that tab", ft.stage_of(p, b) is not None, p.get("stages"))
    t.ok(f"{name}: the sidebar is gone with the full screen", not side("state")["out"])
    sv.quit()


def main():
    t = sv.T()
    try:
        run(t, False)
        run(t, True)
    finally:
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
