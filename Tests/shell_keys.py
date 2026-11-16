#!/usr/bin/env python3
"""The shell's everyday keys, and Escape in every surface, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/shell_keys.py`. It uses the
split suite's harness in a world of its own: started hidden, no window made
or shown, everything removed afterwards. Keys are pressed through the app's
event queue (bench `press`), so the window's key monitor sees them as it sees
a hand's.

- ⌘T opens a tab with the caret in the field, ⌘L opens the field over the
  page, ⌘W closes the tab in front, ⌘Z brings it back (Undo Close Tab);
- ⌃Tab raises the switcher, Escape puts it away on the same tab;
- Escape closes, one press each and nothing else: the field, the find bar,
  the peek, the look editor, the downloads list, the bookmarks list, a tab's
  address being edited, a new space's card, and a Settings drill-in.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("shell-keys")

ESC, T, L, W, Z, F, TAB = 53, 17, 37, 13, 6, 3, 48


def press(code, chars, *mods, wait=0.5, **extra):
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods), **extra}); time.sleep(wait)


def probe(): return sv.cmd({"do": "probe"})
def state(): return sv.sp("state")
def urls(): return [x["url"].rsplit("/", 1)[-1] for x in state()["tabs"]]


def escape_closes(t, name, flag, opened_by, esc_extra=None):
    opened_by()
    time.sleep(0.6)
    before = probe()
    if not before.get(flag):
        t.ok(f"{name}: opens for the check", False, {k: before.get(k) for k in [flag, "field", "key"]})
        return
    tabs = sv.order(state())
    active = state()["activeID"]
    press(ESC, "\x1b", **(esc_extra or {}))
    after = probe()
    st = state()
    t.ok(f"Esc closes {name}", not after.get(flag), {flag: after.get(flag)})
    t.ok(f"Esc on {name}: the tabs and the tab in front are as they were",
         sv.order(st) == tabs and st["activeID"] == active, (urls(), st["activeID"], active))


def case_tab_keys(t):
    """⌘T, ⌘L, ⌘W and ⌘Z"""
    sv.setup(sidebar=True); sv.launch()
    a = sv.page("a"); b = sv.page("b")
    for x in [x["id"] for x in state()["tabs"] if x["id"] not in (a, b)]: sv.sp("close", id=x)
    sv.sp("select", id=b); time.sleep(0.4)

    count = len(state()["tabs"])
    press(T, "t", "cmd", wait=0.8)
    p = probe(); st = state()
    t.ok("⌘T: one more tab, in front", len(st["tabs"]) == count + 1 and st["activeID"] not in (a, b), (urls(), st["activeID"]))
    t.ok("⌘T: the caret is in the address field", p.get("responderIsAddress") is True or p.get("field") is True, {k: p.get(k) for k in ["field", "responderIsAddress"]})
    press(ESC, "\x1b", wait=0.6)
    st = state()
    t.ok("Esc on an untouched new tab: it closes, b is back", len(st["tabs"]) == count and st["activeID"] == b, (urls(), st["activeID"]))

    press(L, "l", "cmd", wait=0.6)
    p = probe()
    t.ok("⌘L: the field opens over b", p.get("field") is True, p.get("field"))
    press(ESC, "\x1b", wait=0.6)
    p = probe(); st = state()
    t.ok("Esc: the field goes, b stays", p.get("field") is False and st["activeID"] == b and len(st["tabs"]) == count, (p.get("field"), urls()))

    press(W, "w", "cmd", wait=0.8)
    st = state()
    t.ok("⌘W: b closes", b not in sv.order(st) and len(st["tabs"]) == count - 1, urls())
    press(Z, "z", "cmd", wait=0.8)
    pressed = "b" in urls()
    if not pressed:
        r = sv.cmd({"do": "undoclose"}); time.sleep(0.8)
        t.ok("Undo, sent up the page's responder chain: the menu reads Undo Close Tab",
             r.get("menuTitle") == "Undo Close Tab" and r.get("sent") is True, r)
    st = state()
    t.ok("⌘Z: b is back, in front", "b" in urls() and len(st["tabs"]) == count and urls()[sv.order(st).index(st["activeID"])] == "b", (urls(), st["activeID"]))
    print(f"  note  ⌘Z as a key {'reopened it' if pressed else 'needs a key window, which a hidden copy never has'}")
    r = sv.cmd({"do": "undoclose"}); time.sleep(0.6)
    t.ok("Undo again: nothing else comes back", len(state()["tabs"]) == count, (urls(), r))


def case_switcher(t):
    """⌃Tab and Escape"""
    sv.setup(sidebar=True); sv.launch()
    a = sv.page("a"); b = sv.page("b"); c = sv.page("c")
    sv.sp("select", id=c); time.sleep(0.4)
    press(TAB, "\t", "ctrl", wait=0.8)
    s = sv.cmd({"do": "switcher"})
    t.ok("⌃Tab: the switcher is up", s["visible"], s)
    press(ESC, "\x1b", "ctrl", wait=0.6)
    s = sv.cmd({"do": "switcher"})
    t.ok("Esc: the switcher goes, still on c", not s["visible"] and s["active"] == c, s)
    press(TAB, "\t", "ctrl", wait=0.8)
    press(TAB, "\t", "ctrl", wait=0.4, letgo=True)
    time.sleep(0.4)
    s = sv.cmd({"do": "switcher"})
    t.ok("⌃Tab ⌃Tab, let go: another tab, the switcher gone", not s["visible"] and s["active"] != c, s)


def case_escapes(t):
    """Escape in every surface"""
    sv.setup(sidebar=True, spaces=True); sv.launch()
    a = sv.page("a"); b = sv.page("long")
    sv.sp("select", id=b); time.sleep(0.4)
    escape_closes(t, "the field", "field", lambda: press(L, "l", "cmd"))
    escape_closes(t, "the find bar", "finding", lambda: press(F, "f", "cmd"))
    escape_closes(t, "the peek", "peekOpen", lambda: sv.cmd({"do": "peek", "url": f"{sv.BASE}/peeked"}))
    escape_closes(t, "the look editor", "editingLook", lambda: sv.cmd({"do": "ui", "editlook": True}))
    escape_closes(t, "the downloads list", "downloadsOpen", lambda: sv.cmd({"do": "ui", "recentdownloads": True}))
    escape_closes(t, "the bookmarks list", "bookmarksOpen", lambda: sv.cmd({"do": "ui", "bookmarksList": True}))
    escape_closes(t, "a tab's address being edited", "editingTab", lambda: sv.cmd({"do": "ui", "edittab": "typed"}))


def shown_launch():
    import os, subprocess
    if os.path.exists(sv.SOCK): os.remove(sv.SOCK)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)


def case_settings(t):
    """Escape in a Settings drill-in goes up one level"""
    sv.setup(sidebar=True); shown_launch()
    sv.cmd({"do": "ui", "settings": True}); time.sleep(1.2)
    sv.cmd({"do": "ui", "settingsDetail": "memory"}); time.sleep(0.6)
    drill = sv.cmd({"do": "probe"}).get("settingsDrill", "?")
    t.ok("the drill-in is open for the check", drill == "memory", drill)
    r = sv.cmd({"do": "press", "code": ESC, "chars": "\x1b", "mods": [], "toSettings": True})
    t.ok("Esc in a drill-in: taken by Settings", r.get("taken") is True, r)
    drill = sv.cmd({"do": "probe"}).get("settingsDrill", "?")
    t.ok("Esc in a drill-in: back on its page", drill in ("", None), drill)


def main():
    t = sv.T()
    cases = [case_tab_keys, case_switcher, case_escapes, case_settings]
    only = sys.argv[1:]
    for case in cases:
        if only and case.__name__ not in only: continue
        print(f"— {case.__doc__}")
        try:
            case(t)
        except Exception as error:
            t.ok(f"{case.__name__} ran to the end", False, error)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
