#!/usr/bin/env python3
"""An extension's side panel in a private window (issue 662), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/panel_private.py [PICTURES]`.
It runs in a world of its own with split_view.py's harness: started hidden,
everything removed afterwards. The extension is a folder made here, with a
panel of its own.

What it checks: a private window opening leaves an ordinary window's panel
as it was; sidePanel.open, asked for over a private window by an extension
not let in, opens nothing there, a tab included; let in (ext-private), it
opens beside the private page, and shut out again it is held back where it
stands, the ordinary window's panel through all along; and a panel closed
while it waits is closed for good. Given a folder, a
picture of the panel beside an ordinary tab goes there, light and dark;
nothing is shown on any screen to take it.
"""
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("panel-private")
PICTURES = sys.argv[1] if len(sys.argv) > 1 else None
work = Path(tempfile.mkdtemp(prefix="search-panelprivate-"))

PANEL = """<!doctype html><title>The panel</title>
<p>Panel</p>
"""


def make():
    folder = work / "PanelPrivate"
    folder.mkdir()
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Panel Private", "version": "1.0",
        "permissions": ["sidePanel", "tabs"],
        "action": {"default_title": "Panel Private"},
        "side_panel": {"default_path": "panel.html"},
    }))
    (folder / "panel.html").write_text(PANEL)
    (folder / "page.html").write_text("<!doctype html><title>own</title>")
    return str(folder)


def installed(): return sv.cmd({"do": "extensions"})["extensions"]


def add(path, name):
    sv.cmd({"do": "ext-folder", "path": path, "yes": True})
    for _ in range(50):
        found = [x for x in installed() if x["name"] == name and x["loaded"]]
        if found: return found[0]
        time.sleep(0.2)
    raise RuntimeError(f"{name} didn't load")


def panel(action="state", window=None, **f):
    return sv.cmd({"do": "sidepanel", "action": action, **f, **({"window": window} if window else {})})


def peval(js): return panel("eval", js=js).get("value")


def pages(window=None):
    """How far the widest page on screen reaches, from the window's left."""
    return max((f[0] + f[2] for f in panel(window=window)["pages"] if f), default=0)


def urls(window=None): return [x["url"] for x in sv.cmd({"do": "tabs", **({"window": window} if window else {})})["tabs"]]


def opened(path, window=None): return sum(1 for u in urls(window) if u.rstrip("/").endswith(path))


def letIn(ext, on): sv.cmd({"do": "ext-private", "id": ext["id"], "on": on}); time.sleep(0.8)


def ui(**f): sv.cmd({"do": "ui", **f}); time.sleep(0.9)


def picture(name):
    if not PICTURES: return
    for look in ("light", "dark"):
        ui(look=look)
        sv.cmd({"do": "picture", "path": f"{PICTURES}/private-panel-{name}-{look}.png", "page": False})
    ui(look="system")


def main():
    t = sv.T()
    if PICTURES: os.makedirs(PICTURES, exist_ok=True)
    folder = make()
    try:
        sv.setup(sidebar=True); sv.launch()
        plain = sv.page("a")
        ext = add(folder, "Panel Private")
        page = sv.cmd({"do": "ext-page", "id": ext["id"], "path": "page.html"})["id"]
        time.sleep(1.0)

        # The window's panel, asked for by the extension itself.
        sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.open({windowId: 1}); 1"})
        time.sleep(1.2)
        st = panel()
        t.ok("the panel is up beside an ordinary tab", st["shown"] and not st["held"]
             and st["content"]["kind"] == "page", st)
        beside = pages()
        picture("beside-a-tab")
        peval("window.__kept = 'yes'; 1")

        quiet = sv.cmd({"do": "open", "url": f"{sv.BASE}/b", "private": True})["id"]
        n = next(w["n"] for w in sv.cmd({"do": "windows", "action": "list"})["windows"] if w["private"])
        sv.cmd({"do": "windows", "action": "front", "n": n})
        time.sleep(1.0)
        st = panel()
        t.ok("a private window opening changes nothing here", st["shown"] and not st["held"], st)
        t.ok("and the private window has no panel of its own", not panel(window=n)["shown"], panel(window=n))

        sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.open({windowId: 1}); 1"})
        time.sleep(1.2)
        st = panel(window=n)
        t.ok("sidePanel.open over a private window, not let in: nothing opens", not st["shown"] and st["content"]["kind"] == "none", st)
        t.ok("and no tab either, there or here", opened("/panel.html", n) == 0 and opened("/panel.html") == 0, (urls(n), urls()))
        t.ok("the ordinary window's panel still through", panel()["shown"] and not panel()["held"], panel())

        letIn(ext, True)
        sv.cmd({"do": "eval", "id": page, "js": "chrome.sidePanel.open({windowId: 1}); 1"})
        time.sleep(1.2)
        st = panel(window=n)
        t.ok("let into private windows: the panel opens there", st["shown"] and not st["held"] and st["content"]["kind"] == "page", st)

        letIn(ext, False)
        st = panel(window=n)
        t.ok("shut out again: held back where it stands", st["held"], st)
        t.ok("the ordinary window's panel through, whatever the switch says", panel()["shown"] and not panel()["held"], panel())
        t.ok("and its page kept", peval("window.__kept") == "yes", peval("window.__kept"))

        # Closed by hand while it waits: closed for good, room and all.
        panel("close", window=n); time.sleep(0.6)
        st = panel(window=n)
        t.ok("closed while held back: it is closed, not waiting", not st["shown"] and not st["held"]
             and st["content"]["kind"] == "none", st)
        t.ok("the private tab is still the window's", any(x["id"] == quiet for x in sv.cmd({"do": "tabs", "window": n})["tabs"]))
        sv.quit()
    finally:
        t.done(); sv.finish(); shutil.rmtree(work, ignore_errors=True)
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
