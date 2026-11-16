#!/usr/bin/env python3
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("menu-keys")


def main():
    t = sv.T()
    try:
        sv.setup(spaces=True, **{"pages.dusk": True})
        sv.launch()
        sv.page("a")
        sv.page("b")
        sv.sp("space", spaceAction="new", name="Two")
        time.sleep(0.5)
        reply = sv.cmd({"do": "menus"})
        keys = reply["keys"]
        seen = {}
        for item in keys:
            combo = (item["key"], item["command"], item["shift"], item["option"], item["control"])
            seen.setdefault(combo, []).append(item["path"])
        shared = {combo: paths for combo, paths in seen.items() if len(paths) > 1}
        t.ok("the menus have their keys", len(keys) > 40, len(keys))
        t.ok("no two menu items share a key", not shared, shared)
        paths = [item["path"] for item in keys]
        t.ok("Move Tab to Space lists ⌃⇧N per space", any(p.startswith("Tabs › Move Tab to Space › ") for p in paths), paths)
        t.ok("Close Tab keeps ⌘W", any(i["path"] == "File › Close Tab" and i["key"] == "w" and i["command"] and not i["shift"] and not i["option"] for i in keys), paths)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
