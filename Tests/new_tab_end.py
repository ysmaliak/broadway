"""New tab placement through the real browser in a hidden, isolated probe.

Build first (`./build.sh debug`), then `python3 Tests/new_tab_end.py`.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("new-tab-end")


def order(state=None):
    return [x["id"] for x in (state or sv.sp("state"))["tabs"]]


def loose(state, pins):
    return [tab for tab, group in zip(state["tabs"], state["groupIDs"])
            if not group and tab["id"] not in pins]


def cmd_click(source, name):
    sv.sp("select", id=source)
    sv.ev(source, f"document.body.innerHTML = `<a id='l' href='/{name}' style='font-size:40px'>link</a>`")
    sv.cmd({"do": "tap", "id": source, "selector": "#l", "mods": ["cmd"]})
    for _ in range(30):
        state = sv.sp("state")
        found = [tab["id"] for tab in state["tabs"] if tab["url"] == f"{sv.BASE}/{name}"]
        if found:
            return found[0]
        time.sleep(0.2)
    return None


def run(t, place, sidebar=True):
    sv.setup(sidebar=sidebar, **{"tabs.groups": True, "splitView": True})
    subprocess.run(["defaults", "write", sv.SUITE, "tabs.newPlace", place], check=True)
    sv.launch()
    try:
        a = sv.page("a")
        b = sv.page("b")
        c = sv.page("c")
        sv.sp("select", id=a)
        d = sv.page("d")
        now = order()
        target = {"next": now.index(a) + 1, "top": 0, "end": len(now) - 1}[place]
        t.ok(f"{place}: opened page has the chosen position", now[target] == d, now)

        # The initial blank is reused, then navigated so the next one is fresh.
        blank = sv.sp("newTab")["activeID"]
        now = order()
        # ⌘T's tab goes to the end unless Top is chosen: After current is for
        # links, as before the choice had a top.
        target = {"next": len(now) - 1, "top": 0, "end": len(now) - 1}[place]
        t.ok(f"{place}: reused blank has the chosen position", now[target] == blank, now)
        t.ok(f"{place}: repeated new tab reuses the same blank", sv.sp("newTab")["activeID"] == blank)
        sv.cmd({"do": "go", "id": blank, "url": f"{sv.BASE}/filled"})
        time.sleep(0.7)
        fresh = sv.sp("newTab")["activeID"]
        now = order()
        target = {"next": len(now) - 1, "top": 0, "end": len(now) - 1}[place]
        t.ok(f"{place}: fresh blank has the chosen position", fresh != blank and now[target] == fresh, now)

        if place != "top":
            # Reuse from either side of the current tab, not only the initial slot.
            for anchor in [a, c]:
                sv.sp("select", id=anchor)
                time.sleep(0.3)
                t.ok(f"{place}: a New Tab left untouched is closed", fresh not in order(), order())
                fresh = sv.sp("newTab")["activeID"]
                now = order()
                target = len(now) - 1
                t.ok(f"{place}: the next New Tab goes to the end", now[target] == fresh, now)
            sv.sp("select", id=a)
            before = order()
            quiet = sv.sp("private")
            private = quiet["activeID"]
            t.ok(f"{place}: a private tab opens in a private window, not this row",
                 private not in order() and order() == before and quiet["tabs"][-1]["shy"], (order(), quiet["tabs"]))
            again = sv.sp("private")
            t.ok(f"{place}: asked again, the private window's blank is reused", again["activeID"] == private and len(again["tabs"]) == 1, again["tabs"])
            sv.cmd({"do": "windows", "action": "close", "n": quiet["window"]})
            if place == "next":
                sv.sp("pair", id=b, **{"with": a, "side": "right"})
                fresh = sv.sp("newTab")["activeID"]
                for slot in [0, len(order()) - 1]:
                    sv.sp("move", id=fresh, to=slot)
                    reused = sv.sp("newTab")["activeID"]
                    now = order()
                    t.ok("next: the blank in front is reused and goes to the end", reused == fresh and now[-1] == fresh, now)
                sv.sp("select", id=a)
                time.sleep(0.3)
                t.ok("next: left for a split, the untouched New Tab is closed", fresh not in order(), order())
                fresh = sv.sp("newTab")["activeID"]
                t.ok("next: with a split on screen, the next New Tab goes to the end", order()[-1] == fresh, order())
            sv.sp("select", id=d)
            sv.ev(d, "document.body.innerHTML = `<button id='go' onclick=\"window.open('/popup')\">Open</button>`")
            for _ in range(15):
                if any(f.get("id") == d for f in sv.sp("state")["paneFrames"]):
                    break
                time.sleep(0.2)
            sv.cmd({"do": "tap", "id": d, "selector": "#go"})
            time.sleep(1)
            state = sv.sp("state")
            popup = next(tab["id"] for tab in state["tabs"] if tab["url"] == f"{sv.BASE}/popup")
            now = order(state)
            t.ok(f"{place}: foreground popup goes right after its page", now[now.index(d) + 1] == popup, now)
            linked = cmd_click(d, "cmd-link")
            now = order()
            if place == "next":
                t.ok("next: a ⌘-clicked link goes right after its tab", now.index(linked) == now.index(d) + 1, now)
            else:
                t.ok("end: a ⌘-clicked link goes to the bottom, as new tabs do", now[-1] == linked, now)
            return

        sv.cmd({"do": "pin", "id": a})
        sv.cmd({"do": "pin", "id": b})
        sv.sp("select", id=a)
        e = sv.page("after-pins")
        t.ok("top: pins stay before a new page", order()[:3] == [a, b, e], order())
        sv.sp("newTab")
        t.ok("top: reused blank stays after pins", order()[:3] == [a, b, fresh], order())

        # Explicit ordering is used by batches and extension API openings.
        first = sv.sp("open", url=f"{sv.BASE}/batch-1", atEnd=True)["resultID"]
        second = sv.sp("open", url=f"{sv.BASE}/batch-2", atEnd=True)["resultID"]
        t.ok("top: explicitly ordered openings still append", order()[-2:] == [first, second], order())
        sv.sp("select", id=c)
        background = sv.sp("open", url=f"{sv.BASE}/behind", foreground=False)["resultID"]
        t.ok("top: background link is first without taking focus", order()[2] == background and sv.sp("state")["activeID"] == c)
        linked = cmd_click(c, "cmd-link-top")
        t.ok("top: a ⌘-clicked link goes to the top under the pins, as new tabs do", order()[2] == linked, order())
        sv.sp("select", id=c)

        state = sv.sp("group", id=c)
        group = state["groups"][0]["id"]
        grouped = sv.sp("open", url=f"{sv.BASE}/grouped", **{"from": c})["resultID"]
        state = sv.sp("state")
        members = [tab["id"] for tab, gid in zip(state["tabs"], state["groupIDs"]) if gid == group]
        t.ok("top: a grouped link is first in its original group", members == [grouped, c], members)

        sv.cmd({"do": "peek", "url": f"{sv.BASE}/kept-peek"})
        sv.cmd({"do": "ui", "peeklink": "keep"})
        state = sv.sp("state")
        kept = next(tab for tab, gid in zip(state["tabs"], state["groupIDs"]) if gid == group)
        t.ok("top: a kept peek is first in its original group", kept["url"] == f"{sv.BASE}/kept-peek")

        sv.sp("pair", id=second, **{"with": first, "side": "right"})
        paired = sv.sp("state")["splits"]
        sv.page("after-pair")
        now = order()
        t.ok("top: opening a page preserves the existing split", sv.sp("state")["splits"] == paired and now.index(second) == now.index(first) + 1)

        # Trusted native input exercises WebKit's foreground window.open path.
        sv.sp("select", id=d)
        sv.ev(d, "document.body.innerHTML = `<button id='go' onclick=\"window.open('/popup')\">Open</button>`")
        sv.cmd({"do": "tap", "id": d, "selector": "#go"})
        time.sleep(1)
        state = sv.sp("state")
        t.ok("top: foreground popup is first below pins and groups",
             loose(state, [a, b])[0]["url"] == f"{sv.BASE}/popup"
             and loose(state, [a, b])[0]["id"] == state["activeID"], loose(state, [a, b])[0])
    finally:
        sv.finish()


def main():
    t = sv.T()
    try:
        for sidebar in (True, False):
            run(t, "next", sidebar=sidebar)
        print("  skip  end, top: tabs.newPlace is fixed at next since the Settings cut, so those placements are gone")
    finally:
        t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
