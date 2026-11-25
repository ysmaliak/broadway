#!/usr/bin/env python3
"""Looks the same: window-only shots of named surfaces, pixel-diffed.

    python3 Tests/visual_diff.py shoot DIR [--app PATH] [--only a,b]
    python3 Tests/visual_diff.py compare BEFORE AFTER [--channel 16] [--share 0.005]

`shoot` opens a test copy of the app (this build's, or --app, such as a build
of main) in a world of its own, puts each surface in SURFACES on the screen
in light and in dark, takes a window-only shot of it (Tests/WindowShot.swift)
and quits. `compare` diffs every shot in BEFORE against the one of the same
name in AFTER (Tests/PixelDiff.swift) and writes a diff picture beside each:
grey where equal, amber where anti-aliasing moved, red past the tolerance.
A shot fails when more than --share of its pixels differ by more than
--channel in any channel.

A surface is a bench `surface` (Sources/Search/BenchSurfaces.swift) or the
test window itself after a recipe of bench commands. A pass adds the
surfaces it converts, shoots them from main before it starts, and compares
against them before it lands.
"""
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TOOLS = Path(os.environ.get("BROADWAY_PROBE_TOOLS") or ROOT / ".context" / "visual-tools")
LOOKS = ["light", "dark"]
TWO = [["loom", "Loom", "is recording your screen"], ["tella", "Tella", "is using your camera and microphone"]]
PALE, VIVID, BLACK = "F2EEE6", "3139FB", "000000"
SURFACES = {
    "recording-pill": {"surface": {"name": "recording-pill"}},
    "recording-pill-two": {"surface": {"name": "recording-pill", "lines": TWO}},
    "recording-pill-frame": {"surface": {"name": "recording-pill", "ground": "frame"}},
    "shortcut-numbers": {"surface": {"name": "shortcut-numbers"}},
    "shortcut-numbers-lifted": {"surface": {"name": "shortcut-numbers", "lift": 0.8, "ground": "3139FB"}},
    "marks": {"surface": {"name": "marks"}},
    "marks-lifted": {"surface": {"name": "marks", "lift": 0.8, "ground": "3139FB"}},
    "marks-black": {"surface": {"name": "marks", "lift": 1.0, "ground": "000000"}},
    "marks-pale": {"surface": {"name": "marks", "ground": "F3EEE4"}},
    "hover-tab-card": {"surface": {"name": "hover-tab-card", "plain": True}},
    "hover-tab-card-glass": {"surface": {"name": "hover-tab-card", "ground": "F3EEE4"}},
    "hover-tab-card-vivid": {"surface": {"name": "hover-tab-card", "ground": "3139FB"}},
    "hover-tab-card-black": {"surface": {"name": "hover-tab-card", "ground": "000000"}},
    "account-list": {"surface": {"name": "account-list"}},
    "account-list-offer": {"surface": {"name": "account-list", "kind": "offer", "ground": "3139FB"}},
    "device-bar": {"surface": {"name": "device-bar"}},
    "hover-folder-list": {"surface": {"name": "hover-folder-list", "plain": True}},
    "hover-folder-list-vivid": {"surface": {"name": "hover-folder-list", "ground": "3139FB"}},
    "tab-offers": {"surface": {"name": "tab-offers", "picked": 1, "ground": "F3EEE4"}},
    "tab-offers-black": {"surface": {"name": "tab-offers", "ground": "000000"}},
    "popup-sign": {"surface": {"name": "popup-sign"}},
    "popup-sign-shown": {"surface": {"name": "popup-sign", "shown": True}},
    "popup-sign-vivid": {"surface": {"name": "popup-sign", "ground": "3139FB"}},
    "popup-sign-black": {"surface": {"name": "popup-sign", "ground": "000000"}},
    "translate-sign": {"surface": {"name": "translate-sign"}},
    "translate-sign-working": {"surface": {"name": "translate-sign", "working": True}},
    "translate-sign-shown": {"surface": {"name": "translate-sign", "shown": True, "ground": "F3EEE4"}},
    "translate-sign-vivid": {"surface": {"name": "translate-sign", "ground": "3139FB"}},
    "translate-sign-black": {"surface": {"name": "translate-sign", "ground": "000000"}},
    "blocked-popups-menu": {"surface": {"name": "blocked-popups-menu", "pad": 0}},
    "translate-menu": {"surface": {"name": "translate-menu", "pad": 0}},
    "translate-menu-failed": {"surface": {"name": "translate-menu", "failed": True, "pad": 0}},
    "capture-question": {"surface": {"name": "capture-question"}},
    "capture-question-location": {"surface": {"name": "capture-question", "wants": "location"}},
    "screen-question": {"surface": {"name": "screen-question", "sound": True}},
    "password-offer": {"surface": {"name": "password-offer"}},
    "password-offer-changed": {"surface": {"name": "password-offer", "changed": True}},
    "shield-offer": {"surface": {"name": "shield-offer"}},

    "trouble": {"surface": {"name": "trouble", "kind": "notFound"}},
    "trouble-waiting": {"surface": {"name": "trouble", "kind": "offline", "waiting": True}},
    "trouble-host": {"surface": {"name": "trouble", "kind": "refused", "host": "example.test"}},
    "trouble-narrow": {"surface": {"name": "trouble", "kind": "insecure", "width": 320}},
    "trouble-memory": {"surface": {"name": "trouble", "kind": "tooLarge"}},
    "developer-servers": {"surface": {"name": "developer-servers", "height": 160}},
    "developer-servers-some": {"surface": {"name": "developer-servers", "height": 220, "servers": {"localhost:3000": True, "app.test": False}}},
    "integration-preview": {"surface": {"name": "integration-preview"}},
    "integration-preview-sidebar": {"surface": {"name": "integration-preview", "width": 252}},
    "integration-preview-linear": {"surface": {"name": "integration-preview", "kind": "linear"}},
    "integration-hover": {"surface": {"name": "integration-hover"}},
    "developer-band": {"surface": {"name": "developer", "part": "band"}},
    "developer-band-clean": {"surface": {"name": "developer", "part": "band", "clean": True}},
    "developer-panel": {"surface": {"name": "developer", "part": "panel"}},
    "developer-panel-network": {"surface": {"name": "developer", "part": "panel", "network": True}},
    "developer-offer": {"surface": {"name": "developer", "part": "offer"}},
    "developer-offer-frame": {"surface": {"name": "developer", "part": "offer", "ground": "frame"}},
    "quick-actions": {"surface": {"name": "quick-actions"}},
    "quick-actions-changed": {"surface": {"name": "quick-actions", "changed": True}},
    "quick-action-sheet": {"surface": {"name": "quick-action-sheet"}},
    "quick-action-sheet-taken": {"surface": {"name": "quick-action-sheet", "taken": True}},
    "shortcuts": {"surface": {"name": "shortcuts"}},
    "extensions-page": {"surface": {"name": "extensions-page"}},
    "store-offer": {"surface": {"name": "store-offer"}},
    "store-offer-busy": {"surface": {"name": "store-offer", "busy": True}},
    "bookmarks-page": {"surface": {"name": "bookmarks-page"}},
    "bookmarks-page-empty": {"surface": {"name": "bookmarks-page", "empty": True}},
    "bookmark-outline": {"surface": {"name": "bookmark-outline"}},
    "bookmark-card": {"surface": {"name": "bookmark-card"}},
    "files-page": {"surface": {"name": "files-page"}},
    "files-page-empty": {"surface": {"name": "files-page", "empty": True}},
    "float-feedback": {"surface": {"name": "float-feedback", "ground": BLACK}},
    "float-controls-black": {"surface": {"name": "float-controls", "ground": BLACK, "feedback": "1.5×"}},
    "float-controls-vivid": {"surface": {"name": "float-controls", "ground": VIVID}},
    "float-controls-pale": {"surface": {"name": "float-controls", "ground": PALE}},
    "float-controls-paused": {"surface": {"name": "float-controls", "ground": VIVID, "playing": False}},
    "float-controls-live": {"surface": {"name": "float-controls", "ground": BLACK, "live": True, "waiting": True,
                                        "captions": False, "chapters": False}},
    "call-bar": {"surface": {"name": "call-bar", "ground": BLACK}},
    "call-bar-vivid": {"surface": {"name": "call-bar", "ground": VIVID, "mic": False, "camera": True, "leaves": False}},
    "escape-reminder": {"surface": {"name": "escape-reminder", "ground": BLACK}},
    "escape-reminder-pale": {"surface": {"name": "escape-reminder", "ground": PALE}},
    "reload-door": {"surface": {"name": "reload-door"}},
    "reload-door-frame": {"surface": {"name": "reload-door", "ground": "frame", "frame": True}},
    "reload-door-vivid": {"surface": {"name": "reload-door", "ground": VIVID, "lift": 0.8, "frame": True}},
    "agent-character": {"surface": {"name": "agent-character"}},
    "agent-character-vivid": {"surface": {"name": "agent-character", "ground": VIVID, "lift": 0.8}},
    "agent-faces": {"surface": {"name": "agent-character", "sheet": True}},
    "agent-pointer-type": {"surface": {"name": "agent-pointer", "ground": PALE, "kind": "type"}},
    "agent-pointer-click": {"surface": {"name": "agent-pointer", "ground": PALE, "kind": "click"}},
    "link-bubble": {"surface": {"name": "link-bubble"}},
    "link-bubble-vivid": {"surface": {"name": "link-bubble", "ground": VIVID}},
    "at-rest": {"surface": {"name": "at-rest"}},
    "at-rest-vivid": {"surface": {"name": "at-rest", "ground": VIVID, "lift": 0.8}},
    "driving-bar": {"surface": {"name": "driving-bar"}},
    "driving-bar-black": {"surface": {"name": "driving-bar", "ground": BLACK}},
    "passkey-switch-system": {"surface": {"name": "passkey-switch", "broadway": False}},
    "settings-switches": {"surface": {"name": "settings-switches"}},
    "settings-controls": {"surface": {"name": "settings-controls"}},
    "controls-gallery": {"surface": {"name": "controls-gallery"}},
    "settings-drill": {"surface": {"name": "settings-drill"}},
    "settings-danger": {"surface": {"name": "settings-danger"}},
    "settings-header": {"surface": {"name": "settings-header"}},
    "field-rows": {"surface": {"name": "field-rows"}},
    "now-rows": {"surface": {"name": "now-rows"}},
    "field-chips": {"surface": {"name": "field-chips"}},
    "field-slab": {"surface": {"name": "field-slab", "ground": "frame"}},
    "field-bar": {"surface": {"name": "field-bar"}},
    "field-menu": {"surface": {"name": "field-menu"}},
    "extension-icons": {"surface": {"name": "extension-icons"}},
    "extension-icons-lifted": {"surface": {"name": "extension-icons", "lift": 0.8, "ground": "3139FB"}},
    "fetch-doors": {"surface": {"name": "fetch-doors"}},
    "fetch-doors-lifted": {"surface": {"name": "fetch-doors", "lift": 0.8, "ground": "3139FB"}},
    "recent-downloads": {"surface": {"name": "recent-downloads"}},
    "agent-card": {"surface": {"name": "agent-card"}},
    "agent-badge": {"surface": {"name": "agent-badge"}},
    "find-bar": {"surface": {"name": "find-bar"}},
    "find-bar-empty": {"surface": {"name": "find-bar-empty"}},
    "find-bar-narrow": {"surface": {"name": "find-bar-narrow"}},
    "find-bar-vivid": {"surface": {"name": "find-bar", "ground": "3139FB"}},
    "find-bar-black": {"surface": {"name": "find-bar", "ground": "000000"}},
    "find-count": {"surface": {"name": "find-count"}},
    "form-fill-card": {"surface": {"name": "form-fill-card"}},
    "form-fill-card-vivid": {"surface": {"name": "form-fill-card", "ground": "3139FB"}},
    "form-fill-done": {"surface": {"name": "form-fill-done"}},
    "form-fill-offer": {"surface": {"name": "form-fill-offer"}},
    "form-fill-offer-black": {"surface": {"name": "form-fill-offer", "ground": "000000"}},
    "meeting-alert": {"surface": {"name": "meeting-alert"}},
    "hidden-panel": {"surface": {"name": "hidden-panel"}},
    "meeting-alert-vivid": {"surface": {"name": "meeting-alert", "ground": "3139FB"}},
    "meeting-alert-black": {"surface": {"name": "meeting-alert", "ground": "000000"}},
    "meeting-alert-two": {"surface": {"name": "meeting-alert-two"}},
    "meeting-alert-faces": {"surface": {"name": "meeting-alert-faces"}},
    "pin-meeting-badges": {"surface": {"name": "pin-meeting-badges"}},
    "history-panel": {"surface": {"name": "history-panel", "pad": 0}},

    "newtab": {"surface": {"name": "newtab"}},
    "newtab-pale": {"surface": {"name": "newtab", "space": "paper"}},
    "newtab-vivid": {"surface": {"name": "newtab", "space": "cobalt"}},
    "newtab-black": {"surface": {"name": "newtab", "space": "onyx"}},
    "newtab-small": {"surface": {"name": "newtab", "space": "sky", "width": 560, "height": 420}},
    "onboarding-1": {"surface": {"name": "onboarding", "step": 1}},
    "onboarding-2": {"surface": {"name": "onboarding", "step": 2}},
    "onboarding-3": {"surface": {"name": "onboarding", "step": 3}},
    "onboarding-4": {"surface": {"name": "onboarding", "step": 4}},
    "onboarding-5": {"surface": {"name": "onboarding", "step": 5}},
    "onboarding-6": {"surface": {"name": "onboarding", "step": 6}},
    "about": {"surface": {"name": "about"}},
    "window": {"window": [{"do": "resize", "width": 1000, "height": 700, "steps": 1}]},
    "column-pale": {"setup": "column", "window": [{"do": "space", "action": "look", "colour": "sky"}], "crop": "column"},
    "column-vivid": {"setup": "column", "window": [{"do": "space", "action": "look", "custom": "3139FB", "intensity": 1}], "crop": "column"},
    "column-black": {"setup": "column", "window": [{"do": "space", "action": "look", "custom": "000000", "intensity": 1}], "crop": "column"},
    "column-gray": {"setup": "column", "window": [{"do": "space", "action": "look", "colour": "gray"}], "crop": "column"},
    "column-hover": {"setup": "column", "window": [{"do": "space", "action": "look", "colour": "gray"}], "hover": 3, "crop": "column"},
    "window-spaces-vivid": {"window": [{"do": "resize", "width": 1000, "height": 700, "steps": 1},
                                       {"do": "ui", "cards": True},
                                       {"do": "space", "action": "look", "custom": "000000", "intensity": 2}]},
    "window-spaces-blend": {"window": [{"do": "space", "action": "look", "colours": ["8BE33A", "7CC4F2", "7B3FE4"], "intensity": 0.7}]},
    "window-spaces-pale": {"window": [{"do": "space", "action": "look", "colour": "sky", "intensity": 0.15}]},
    "window-stacked": {"window": [{"do": "ui", "spaces": True},
                                  {"do": "space", "action": "new", "name": "Work"},
                                  {"do": "space", "action": "go", "index": 1},
                                  {"do": "settings", "set": "spaces.stacked", "value": "stacked"}]},
    "space-ground-pale": {"surface": {"name": "space-ground", "style": "pale"}},
    "space-ground-vivid": {"surface": {"name": "space-ground", "style": "vivid"}},
    "space-ground-blend": {"surface": {"name": "space-ground", "style": "blend"}},
    "space-ground-grain": {"surface": {"name": "space-ground", "style": "grain"}},
    "stacked-headers": {"surface": {"name": "stacked-headers"}},
    "stacked-headers-vivid": {"surface": {"name": "stacked-headers", "style": "vivid"}},
    "stacked-headers-pale": {"surface": {"name": "stacked-headers", "style": "pale"}},
    "new-space-card": {"surface": {"name": "new-space-card"}},
    "live-folder-rows": {"surface": {"name": "live-folder-rows"}},
    "space-look-editor": {"surface": {"name": "space-look-editor"}},
    "space-look-editor-blend": {"surface": {"name": "space-look-editor", "style": "blend"}},
    "passwords-page": {"surface": {"name": "passwords-page"}},
    "passwords-empty": {"surface": {"name": "passwords-page", "style": "empty"}},
    "import-page": {"surface": {"name": "import-page"}},
    "pairing-card": {"surface": {"name": "pairing-card"}},
    "pairing-card-vivid": {"surface": {"name": "pairing-card", "ground": "3139FB"}},
    "pairing-card-pale": {"surface": {"name": "pairing-card", "ground": "DCEBFA"}},
    "pairing-card-black": {"surface": {"name": "pairing-card", "ground": "000000"}},
    "pairing-card-starting": {"surface": {"name": "pairing-card", "style": "starting"}},
    "pairing-card-idle": {"surface": {"name": "pairing-card", "style": "idle"}},
    "settings-routes": {"surface": {"name": "settings-routes"}},
}

PAGES = {}

OPENED = {}


def pages(sv):
    for name in ["shell-a", "shell-b"]:
        if name not in OPENED:
            OPENED[name] = sv.sp("open", url=f"{sv.BASE}/{name}")["resultID"]
            time.sleep(0.7)
    sv.sp("select", id=OPENED["shell-a"])
    return {"pause": 0.4}


def unsplit(sv):
    if "shell-b" in OPENED:
        sv.sp("detach", id=OPENED["shell-b"])
    return {"pause": 0.2}


def split(sv):
    sv.sp("pair", id=OPENED["shell-b"], **{"with": OPENED["shell-a"]}, side="right")
    return {"pause": 0.8}


def marks(sv):
    for name in ["Alpha", "Beta", "Gamma"]:
        sv.cmd({"do": "titles", "mark": f"{sv.BASE}/{name.lower()}", "named": name})
    return {"do": "ui", "bookmarksBar": True}


def shell(*steps, cards=False, side="left", folded=False, bar=False, look=None):
    reset = [{"do": "resize", "width": 1000, "height": 700, "steps": 1}, pages, unsplit,
             {"do": "peek", "url": "close"}, {"do": "press", "code": 53, "chars": "\u001b"},
             {"do": "ui", "cards": cards, "side": side, "folded": folded, "bookmarksBar": bar}]
    if bar:
        reset.append(marks)
    if look:
        reset.append({"do": "space", "action": "look", **look})
    return {"window": reset + list(steps)}


TIDY = [{"do": "find", "close": True}, {"do": "sidepanel", "action": "close"}, {"do": "ui", "glassBars": [], "plus": False, "link": "off"}]


def layer(*steps, **kwargs):
    spec = shell(*steps, **kwargs)
    return {"window": spec["window"][:1] + TIDY + spec["window"][1:]}


SURFACES.update({
    "shell": shell(),
    "shell-right": shell(side="right"),
    "shell-bar": shell(bar=True),
    "shell-folded": shell(folded=True),
    "shell-split": shell(split, {"pause": 0.6}),
    "shell-peek": shell({"do": "peek", "url": None}),
    "shell-switcher": shell({"do": "press", "code": 48, "chars": "\t", "mods": ["ctrl"]}, {"pause": 0.6}),
    "shell-cards": shell(cards=True),
    "field-live": shell({"do": "press", "code": 37, "chars": "l", "mods": ["cmd"]}, {"pause": 0.8},
                        {"do": "field", "text": "127.0.0.1", "type": True}, {"pause": 1.0}),
    "shell-cards-bar": shell(cards=True, bar=True),
    "shell-cards-pale": shell(cards=True, look={"colours": ["F3E6C8"]}),
    "shell-cards-vivid": shell(cards=True, look={"colours": ["3139FB"]}),
    "shell-cards-black": shell(cards=True, look={"colours": ["000000"]}),
    "shell-cards-split": layer(split, {"pause": 0.6}, cards=True),
    "shell-find": layer({"do": "find", "text": "shell"}, {"pause": 0.8}),
    "shell-cards-find": layer({"do": "find", "text": "shell"}, {"pause": 0.8}, cards=True),
    "shell-split-find": layer(split, {"pause": 0.6}, {"do": "find", "text": "shell"}, {"pause": 0.8}),
    "shell-panel": layer(lambda sv: {"do": "sidepanel", "action": "site", "url": f"{sv.BASE}/shell-b"}, {"pause": 1.2}),
    "shell-cards-panel": layer(lambda sv: {"do": "sidepanel", "action": "site", "url": f"{sv.BASE}/shell-b"}, {"pause": 1.2},
                               cards=True),
    "shell-bars": layer({"do": "ui", "glassBars": ["shield", "done"]}, {"pause": 0.9}),
    "shell-cards-bars": layer({"do": "ui", "glassBars": ["shield", "done"]}, {"pause": 0.9}, cards=True),
    "shell-announce": {**layer({"pause": 0.6}, {"do": "ui", "announce": "Copied the address"}), "settle": 0.5},
    "shell-split-developer": layer(split, {"pause": 0.6}, {"do": "ui", "glassBars": ["developer"]}, {"pause": 0.9}),
    "shell-split-developer-wide": layer({"do": "resize", "width": 1500, "height": 700, "steps": 1}, split, {"pause": 0.6},
                                        {"do": "ui", "glassBars": ["developer"]}, {"pause": 0.9}),
    "shell-link": layer(lambda sv: {"do": "ui", "link": f"{sv.BASE}/shell-b"}, {"pause": 0.6}),
    "shell-plus": layer({"do": "ui", "plus": True}, {"pause": 0.8}),
})


def step(sv, spec):
    while callable(spec):
        spec = spec(sv)
    if "pause" in spec:
        time.sleep(spec["pause"])
        return {}
    if spec.get("do") == "peek" and spec.get("url", "") is None:
        spec = {**spec, "url": f"{sv.BASE}/shell-peeked"}
    return sv.cmd(spec)


def serve_pages():
    import socket
    import threading
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    class Pages(BaseHTTPRequestHandler):
        def do_GET(self):
            name = self.path.strip("/").replace("-", " ").title() or "Page"
            body = f"<!doctype html><title>{name}</title><body style='margin:0;background:#fff'></body>".encode()
            self.send_response(200)
            self.send_header("content-type", "text/html")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *a):
            pass

    class Six(ThreadingHTTPServer):
        address_family = socket.AF_INET6

    srv = Six(("::1", 47311), Pages)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return "http://[::1]:47311"


def column_world(sv):
    if "column" in PAGES:
        return PAGES["column"]
    base = serve_pages()
    sv.cmd({"do": "ui", "sidebar": True})
    sv.cmd({"do": "resize", "width": 1000, "height": 700, "steps": 1})

    def open_(name):
        made = sv.sp("open", url=f"{base}/{name}")["resultID"]
        time.sleep(0.4)
        return made

    pins = [open_(n) for n in ("mail", "calendar", "notes")]
    for p in pins:
        sv.cmd({"do": "pin", "id": p})
    loose = [open_(n) for n in ("inbox-zero", "weekly-review", "a-very-long-title-that-will-not-fit-in-the-column", "pull-requests", "docs")]
    reading = [open_(n) for n in ("long-read-on-columns", "design-notes", "release-plan")]
    sv.cmd({"do": "group", "id": reading[0], "new": True, "name": "Reading"})
    for i in reading[1:]:
        sv.cmd({"do": "group", "id": i, "name": "Reading"})
    sv.sp("select", id=loose[1])
    time.sleep(2.5)
    PAGES["column"] = {"pins": pins, "reading": reading, "loose": loose}
    return PAGES["column"]


def crop_column(sv, path):
    rep = subprocess.run(["sips", "-g", "pixelWidth", str(path)], capture_output=True, text=True).stdout
    w = int(rep.split("pixelWidth:")[1].split()[0])
    scale = 2 if w >= 1900 else 1
    subprocess.run([str(tool("crop", "CropShot.swift")), str(path), str(256 * scale)], capture_output=True)


def tool(name, source):
    TOOLS.mkdir(parents=True, exist_ok=True)
    out = TOOLS / name
    src = ROOT / "Tests" / source
    if not out.exists() or out.stat().st_mtime < src.stat().st_mtime:
        subprocess.run(["swiftc", "-O", "-parse-as-library", str(src), "-o", str(out)], check=True)
    return out


def option(args, name, default=None):
    if name in args:
        i = args.index(name)
        return args[i + 1]
    return default


def shoot(out, app=None, only=None):
    if app:
        os.environ["BROADWAY_PROBE_APP"] = str(Path(app).resolve())
    sys.path.insert(0, str(ROOT / "Tests"))
    import split_view as sv

    shot = tool("shot", "WindowShot.swift")
    out = Path(out)
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    sv.use("visual-" + uuid.uuid4().hex[:6])
    sv.setup()
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    taken = []
    try:
        for name, spec in SURFACES.items():
            if only and name not in only:
                continue
            for look in LOOKS:
                made = None
                sv.cmd({"do": "ui", "look": look})
                if "window" in spec:
                    made = column_world(sv) if spec.get("setup") == "column" else None
                    for each in spec["window"]:
                        step(sv, each)
                    if made and "hover" in spec:
                        sv.cmd({"do": "rowhover", "id": made["loose"][spec["hover"]]})
                    number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
                    time.sleep(spec.get("settle", 1.5))
                else:
                    number = sv.cmd({"do": "surface", **spec["surface"], "look": look})["number"]
                    time.sleep(0.8)
                path = out / f"{name}-{look}.png"
                said = subprocess.run([str(shot), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
                print(f"  {name} {look}: {said}")
                if path.exists() and spec.get("crop") == "column":
                    crop_column(sv, path)
                if made and "hover" in spec:
                    sv.cmd({"do": "rowhover", "id": made["loose"][spec["hover"]], "on": False})
                if path.exists():
                    taken.append(path.name)
                if "surface" in spec:
                    sv.cmd({"do": "surface", "action": "close"})
        (out / "app.txt").write_text(sv.APP + "\n")
    finally:
        sv.finish()
    print(f"{len(taken)} shots in {out}")
    return 0 if taken else 1


def compare(before, after, channel, share):
    diff = tool("pixeldiff", "PixelDiff.swift")
    before, after = Path(before), Path(after)
    rows, failed = [], 0
    for shot in sorted(before.glob("*.png")):
        if shot.name.startswith("diff-"):
            continue
        other = after / shot.name
        if not other.exists():
            rows.append({"shot": shot.name, "pass": False, "error": "missing after"})
            failed += 1
            continue
        run = subprocess.run([str(diff), str(shot), str(other), str(after / f"diff-{shot.name}"), str(channel), str(share)],
                             capture_output=True, text=True)
        row = json.loads(run.stdout or '{"pass": false}')
        row["shot"] = shot.name
        rows.append(row)
        failed += 0 if row.get("pass") else 1
    for row in rows:
        mark = "ok  " if row.get("pass") else "FAIL"
        detail = row.get("error") or f"{row['differing']} of {row['width']}x{row['height']} past {row['channel']} ({row['share']:.4%}), max {row['max']}"
        print(f"  {mark} {row['shot']}: {detail}")
    (after / "compare.json").write_text(json.dumps(rows, indent=1))
    print(f"{len(rows) - failed} same, {failed} different")
    return 1 if failed or not rows else 0


def main():
    args = sys.argv[1:]
    if args[:1] == ["shoot"] and len(args) >= 2:
        only = option(args, "--only")
        return shoot(args[1], option(args, "--app"), set(only.split(",")) if only else None)
    if args[:1] == ["compare"] and len(args) >= 3:
        return compare(args[1], args[2], int(option(args, "--channel", 16)), float(option(args, "--share", 0.005)))
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
