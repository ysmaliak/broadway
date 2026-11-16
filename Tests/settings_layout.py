#!/usr/bin/env python3
"""Settings after the cut: six pages (SettingsIndex.swift, SettingsCut.swift),
checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/settings_layout.py`. It uses
split_view.py's harness in a world of its own (bld-set2-<checkout>): started
hidden, driven through ./bench's socket, everything removed afterwards.
Nothing here makes, shows or brings forward a window.

- every setting that kept a row is found by words someone would type, and
  the always-there features say so;
- the fixed defaults the cut removed have no row;
- old addresses land on the six pages;
- the merged controls write the keys the two switches did;
- a test world keeps its keys: the cut's migration runs only for people.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-set2")

KEPT = {
    "quit.confirm": "quitting", "downloads": "save to", "downloads.ask": "ask where",
    "look": "dark mode", "pages.dusk": "darken", "sidebar.position": "right",
    "bookmarks.bar": "bookmarks bar", "tabs.close.after": "close tabs", "search.engine": "search with",
    "search.custom": "engine", "search.suggest": "suggestions", "search.keywords": "site shortcuts",
    "pageZoom": "zoom", "newtab.floating": "floating", "passwords.save": "save passwords",
    "passwords.fill": "fill", "passwords.apple": "apple passwords", "shield": "ads", "sites.keep": "tracking",
    "notifications.ask": "notifications", "bench": "script", "autocorrect": "spelling",
    "splitView": "split", "tabs.groups": "groups", "panel.sites": "side panel",
    "translate.pages": "translate", "tabs.keepAwake": "awake", "search.sites": "site from the address",
    "pins.shared": "every space", "pins.numberBack": "number again", "switcher.keys": "switcher",
    "links.show": "where links go", "float.flicks": "flick",
}
ALWAYS = {"splitView", "tabs.groups", "panel.sites", "translate.pages", "tabs.keepAwake", "search.sites",
          "pins.shared", "pins.numberBack", "switcher.keys", "links.show", "float.flicks"}
GONE = ["tabs.give", "downloads.button", "float.leave", "float.away", "pages.120.mode", "spaces", "tabs.newPlace",
        "glyph", "layout.cards", "sidebar.hides", "tabs.shortcuts", "tabs.address", "tabs.lazy", "tabs.sleep",
        "media.click", "pins.home", "pins.peek", "start.fresh", "links.peek", "swipe.history", "commandbar",
        "autoscroll", "fullscreen.escapeTwice", "passkeys", "sidebar.icons", "motion.light"]
PAGES = ["general", "field", "appearance", "websites", "links", "tabs", "shortcuts", "agents", "livefolders", "passwords", "privacy",
         "extensions"]


def settings(**f): return sv.cmd({"do": "settings", **f})
def read(key):
    out = subprocess.run(["defaults", "read", sv.SUITE, key], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def case_reachable(t):
    """what kept a row is found by its words; what the cut fixed has none"""
    sv.setup(); sv.launch()
    every = settings()
    items = every["items"]
    for key, words in KEPT.items():
        found = settings(find=words)["found"]
        hit = [i for i in found if key in i["keys"]]
        t.ok(f"“{words}” finds {key}", bool(hit), [i["id"] for i in found])
        if hit and key in ALWAYS:
            t.ok(f"…and says {key} is always there", hit[0]["note"] and hit[0]["findOnly"], hit[0])
    rows = [i for i in items if not i["findOnly"]]
    for key in GONE:
        t.ok(f"{key} has no row", not any(key in i["keys"] for i in rows), [i["id"] for i in rows if key in i["keys"]])
    found = settings(find="zoom")["found"]
    t.ok("results carry page and group", found and all(i["page"] and i["groupTitle"] for i in found), found)
    t.ok("…zoom on Websites", any(i["page"] == "websites" and i["id"] == "pageZoom" for i in found), found)
    t.ok("a page's worth of rows each, and no more", 30 <= len(rows) <= 75, len(rows))
    t.ok("the pages in rail order", every["pages"] == PAGES, every["pages"])
    for old, page in [("shortcuts", "shortcuts"), ("keyboard", "shortcuts"), ("downloads", "general"),
                      ("quickactions", "field"), ("permissions", "websites"), ("integrations", "livefolders"),
                      ("accounts", "livefolders"), ("github", "livefolders"), ("privacy", "privacy")]:
        sv.cmd({"do": "ui", "show": f"broadway://settings/{old}"}); time.sleep(0.6)
        t.ok(f"broadway://settings/{old} opens {page}", settings()["settingsPage"] == page, settings()["settingsPage"])


def case_test_world(t):
    """a test world keeps keys the cut removes for people"""
    sv.setup(**{"tabs.give": False, "tabs.address": True, "motion.light": True})
    sv.launch()
    t.ok("tabs.give kept", read("tabs.give") == "0", read("tabs.give"))
    t.ok("tabs.address kept", read("tabs.address") == "1", read("tabs.address"))
    t.ok("low power kept", read("motion.light") == "1", read("motion.light"))


def case_old_icons(t):
    """an icons-only column kept from an old run is ignored"""
    sv.setup(**{"sidebar.icons": True}); sv.launch()
    v = settings()["values"]
    t.ok("Tabs reads Left", v["tabs.layout"] == "left", v["tabs.layout"])
    s = sv.cmd({"do": "probe"})
    t.ok("the column is drawn at its own width", s.get("columnWidth") == s.get("sideWidth") and s.get("columnWidth", 0) > 100,
         (s.get("columnWidth"), s.get("sideWidth")))


def case_merged(t):
    """merged controls write the keys the two switches did"""
    sv.setup(); sv.launch()
    def put(id, value): return settings(set=id, value=value)["values"]
    put("tabs.layout", "right")
    t.ok("Tabs: Right writes its position", read("sidebar.position") == "right", read("sidebar.position"))
    try:
        settings(set="tabs.layout", value="icons")
        refused = False
    except RuntimeError:
        refused = True
    t.ok("Tabs: icons is no longer a layout", refused and read("sidebar.position") == "right", read("sidebar.position"))
    put("passwords.fill", False)
    t.ok("Fill and save off writes both keys", (read("passwords.fill"), read("passwords.save")) == ("0", "0"))
    put("downloads.ask", True)
    t.ok("Ask where writes its key", read("downloads.ask") == "1", read("downloads.ask"))
    sv.quit(); time.sleep(0.5); sv.launch()
    v = settings()["values"]
    t.ok("after a relaunch the merged values read back",
         v["tabs.layout"] == "right" and v["passwords.fill"] is False and v["downloads.ask"] is True, v)


def main():
    t = sv.T()
    cases = [case_reachable, case_test_world, case_old_icons, case_merged]
    try:
        for case in cases:
            print(case.__doc__)
            try:
                case(t)
            except Exception as error:  # noqa: BLE001
                t.ok(f"{case.__name__} ran", False, repr(error))
            sv.quit(); time.sleep(0.5)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
