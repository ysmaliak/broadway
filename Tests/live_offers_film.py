#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
label = sys.argv[1] if len(sys.argv) > 1 else "now"
theme = sys.argv[2] if len(sys.argv) > 2 else "dark"
SIDEBAR = int(sys.argv[3]) if len(sys.argv) > 3 else 260
sys.argv = sys.argv[:1]
sys.path.insert(0, str(ROOT / "Tests"))
import live_offers as lo  # noqa: E402

sv = lo.sv
OUT = ROOT / ".context" / "shots" / label
TOOLS = ROOT / ".context" / "shots" / "tools"
CAPTURE = TOOLS / "capture"
SHOT = TOOLS / "shot"
CLOCK = 7.0
TALL = 430


def tools():
    TOOLS.mkdir(parents=True, exist_ok=True)
    for tool, source in [(CAPTURE, "WindowCapture.swift"), (SHOT, "WindowShot.swift")]:
        if not tool.exists():
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests" / source), "-o", str(tool)], check=True)


def picture(pid, number, name, crop=True):
    whole = OUT / f"{name}-window.png"
    said = subprocess.run([str(SHOT), str(pid), str(number), str(whole)], capture_output=True, text=True).stdout.strip()
    print(" ", said, flush=True)
    if crop and whole.exists():
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", str(whole), "-vf", f"crop={(SIDEBAR + 24) * 2}:{TALL * 2}:0:0",
                        str(OUT / f"{name}.png")], check=True)


def film(pid, number, name, seconds, act):
    folder = OUT / "frames" / name
    shutil.rmtree(folder, ignore_errors=True)
    p = subprocess.Popen([str(CAPTURE), str(pid), str(folder), str(seconds), str(number), "2", "60"], stdout=subprocess.PIPE, text=True)
    for _ in range(200):
        if (folder / "ready").exists() or p.poll() is not None:
            break
        time.sleep(0.025)
    time.sleep(0.3)
    act()
    print(" ", name, p.communicate()[0].strip(), flush=True)
    if not (folder / "0000.png").exists():
        return
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "60", "-i", str(folder / "%04d.png"),
                    "-vf", f"crop={(SIDEBAR + 24) * 2}:{TALL * 2}:0:0", "-pix_fmt", "yuv420p", str(OUT / f"{name}.mp4")], check=True)
    shutil.rmtree(folder, ignore_errors=True)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    tools()
    api, hub = lo.serve(lo.Api), lo.serve(lo.Pages)
    GH = f"http://127.0.0.1:{hub.server_port}"
    sv.use("live-offers-film-" + uuid.uuid4().hex[:6])
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(spaces=True, **{"live.on": True, "live.suggest": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    write = lambda *words: subprocess.run(["defaults", "write", sv.SUITE, *words], check=True)
    write("integrations.api", "-string", f"http://127.0.0.1:{api.server_port}")
    write("live.suggest.hosts", "-string", f"{hub.server_port}=github.com")
    write("dev.servers", "-dict", f"127.0.0.1:{hub.server_port}", "-bool", "false", f"127.0.0.1:{sv.srv.server_port}", "-bool", "false")
    write("look", "-string", theme)
    write("sidebar.width", "-float", str(SIDEBAR))
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 700, "steps": 1})
        lo.offer("pace", str(CLOCK), "0.6", "2", "3")
        lo.offer("front", "on")
        lo.offer("sight", "on")
        for name in ("notes", "reading"):
            sv.sp("open", url=f"{sv.BASE}/{name}")
            time.sleep(0.5)
        for path in ("acme/rocket", "acme/rocket/pulls"):
            sv.cmd({"do": "knowing", "action": "visit", "text": f"{GH}/{path}"})
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(1)
        picture(pid, number, "0-before")

        def arrive():
            sv.sp("open", url=f"{GH}/acme/rocket/issues")

        film(pid, number, "appear-then-timer-out", CLOCK + 5, arrive)
        now = lo.offer()
        print("  after the clock:", [p for p in now["past"] if p["id"] == "github"], flush=True)
        picture(pid, number, "4-timed-out")

        def again_then_add():
            lo.offer("again")
            time.sleep(0.6 + CLOCK * 0.45)
            lo.offer("press", "add")

        film(pid, number, "appear-timer-add", CLOCK * 0.45 + 4.5, again_then_add)
        picture(pid, number, "3-added")
        lo.offer("undo")
        lo.offer("pace", "45", "0.6", "10", "3")
        lo.until(lambda s: lo.shown(s) and s.get("view"))
        time.sleep(1.2)
        picture(pid, number, "1-ghost-real-clock")
        lo.offer("hover", "on")
        time.sleep(0.5)
        picture(pid, number, "1-ghost-pointer-over")
        lo.offer("hover", "off")
        lo.offer("pace", str(CLOCK), "0.6", "2", "3")
        lo.offer("press", "decline")
        lo.offer("again")
        lo.until(lambda s: lo.shown(s) and s.get("view"))
        time.sleep(CLOCK * 0.55)
        lo.offer("front", "off")
        picture(pid, number, "2-ghost-half-way")
        lo.offer("press", "decline")
        lo.offer("pace", "45", "0.6", "10", "3")
        lo.offer("front", "on")
        lo.offer("again")
        lo.until(lambda s: lo.shown(s) and s.get("view"))
        sv.cmd({"do": "settings", "find": "", "set": "spaces.stacked", "value": "stacked"})
        time.sleep(1.5)
        picture(pid, number, "5-stacked-spaces")
        sv.cmd({"do": "settings", "find": "", "set": "spaces.stacked", "value": "side"})
        sv.cmd({"do": "space", "action": "new", "name": "Work"})
        sv.cmd({"do": "space", "action": "go", "index": 1})
        time.sleep(1.5)
        sv.cmd({"do": "space", "action": "hold", "dx": -110})
        time.sleep(0.6)
        picture(pid, number, "6-mid-swipe")
        sv.cmd({"do": "space", "action": "release"})
        time.sleep(1)
        print("  state at the end:", {k: lo.offer().get(k) for k in ("reason", "ghosts", "shown")}, flush=True)
    finally:
        sv.finish()


if __name__ == "__main__":
    main()
