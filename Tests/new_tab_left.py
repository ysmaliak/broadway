import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("new-tab-left")

ROOT = Path(__file__).resolve().parents[1]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "after"
OUT = ROOT / ".context" / LABEL
WINDOW = [0]
DARK = [False]
KEYS = {"d": 2, "e": 14, "f": 3, "h": 4, "l": 37, "o": 31, "r": 15, "t": 17, "w": 13}


def stage(dark):
    DARK[0] = dark
    WINDOW[0] = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": [1100, 720]})["window"]
    time.sleep(1.0)


def shoot(t, name):
    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / f"{name}.png"
    path.unlink(missing_ok=True)
    time.sleep(0.8)
    for _ in range(5):
        subprocess.run(["screencapture", "-x", "-o", "-l", str(WINDOW[0]), str(path)], capture_output=True)
        if path.exists():
            break
        stage(DARK[0])
    t.ok(f"pictured {name}", path.exists())


def welcome(action, **more):
    try:
        return sv.cmd({"do": "welcome", "action": action, **more})
    except RuntimeError:
        return None


def fresh_install(dark, **prefs):
    sv.setup(**{"onboarding.show": True, "delight.show": True, "spaces": True, **prefs})
    sv.launch()
    stage(dark)
    state = welcome("state")
    if state and state.get("shown"):
        welcome("press", key="return")
        welcome("look:noir")
        welcome("primary")
        welcome("go:bring")
        welcome("press", key="escape")
    time.sleep(1.0)


def state():
    return sv.sp("state")


def ids(st=None):
    return [tab["id"] for tab in (st or state())["tabs"]]


def blanks(st=None):
    return [tab["id"] for tab in (st or state())["tabs"] if not tab["url"].startswith("http")]


def type_text(text):
    for ch in text:
        sv.cmd({"do": "press", "code": KEYS[ch], "chars": ch, "mods": []})
    time.sleep(0.4)


def typed():
    return sv.cmd({"do": "sitesearch", "action": "state"})["typed"]


def settle():
    time.sleep(0.6)


def left_untouched(t, mode, pictures):
    a = sv.page("alpha")
    b = sv.page("bravo")
    gone = sv.page("closed-page")
    sv.sp("close", id=gone)
    for blank in blanks():
        if blank not in (a, b):
            sv.sp("close", id=blank)
    sv.sp("select", id=a)
    settle()
    before = state()
    ghosts = before["ghosts"]
    title = before["reopenTitle"]
    sv.sp("newTab")
    made = state()["activeID"]
    t.ok(f"{mode}: New Tab made a blank tab in front", made in blanks() and made not in (a, b), state()["tabs"])
    if pictures:
        shoot(t, f"{mode}-1-new-tab")
    sv.sp("select", id=b)
    settle()
    after = state()
    t.ok(f"{mode}: the tab chosen is the one selected", after["activeID"] == b, after["activeID"])
    t.ok(f"{mode}: the untouched New Tab is gone once left", made not in ids(after), ids(after))
    t.ok(f"{mode}: nothing was added to recently closed", after["ghosts"] == ghosts and after["reopenTitle"] == title,
         (ghosts, after["ghosts"], title, after["reopenTitle"]))
    if pictures:
        shoot(t, f"{mode}-2-left")
    sv.sp("reopen")
    settle()
    back = state()
    t.ok(f"{mode}: Reopen Closed Tab brings back the page, not the empty tab",
         back["activeID"] not in blanks(back) and made not in ids(back), back["tabs"])
    sv.sp("select", id=a)
    sv.sp("newTab")
    again = state()["activeID"]
    t.ok(f"{mode}: New Tab asked again makes a fresh one", again in blanks() and again != made, (again, made))
    type_text("hello")
    t.ok(f"{mode}: words are in the New Tab's field", typed() == "hello", typed())
    sv.sp("select", id=b)
    settle()
    kept = state()
    t.ok(f"{mode}: a New Tab with words typed stays when left", again in ids(kept) and kept["activeID"] == b, ids(kept))
    if pictures:
        shoot(t, f"{mode}-3-draft-kept")
    sv.sp("select", id=again)
    settle()
    t.ok(f"{mode}: its words are still there on coming back", typed() == "hello", typed())
    sv.sp("close", id=again)
    settle()
    return a, b


def split_and_space(t, a, b):
    sv.sp("select", id=a)
    sv.sp("newTab")
    blank = state()["activeID"]
    sv.sp("pair", id=blank, **{"with": b}, side="right")
    settle()
    sv.sp("focus", id=b)
    settle()
    st = state()
    t.ok("split: a New Tab in a pair stays when focus moves to the other pane", blank in ids(st) and blank in st["visibleIDs"], st["visibleIDs"])
    sv.sp("focus", id=blank)
    sv.sp("select", id=a)
    settle()
    st = state()
    t.ok("split: the empty half of a pair stays when the pair is left", blank in ids(st), ids(st))
    sv.sp("close", id=blank)
    settle()

    sv.sp("select", id=a)
    sv.sp("newTab")
    blank = state()["activeID"]
    first = state()["spaceID"]
    sv.cmd({"do": "space", "action": "new", "name": "Work"})
    settle()
    sv.cmd({"do": "space", "action": "go", "index": 2})
    settle()
    t.ok("space: another space is in front", state()["spaceID"] != first)
    sv.cmd({"do": "space", "action": "go", "index": 1})
    settle()
    st = state()
    t.ok("space: back in the first space, its New Tab is still its front tab", st["activeID"] == blank and blank in ids(st), (st["activeID"], blank))
    sv.sp("select", id=b)
    settle()
    t.ok("space: left within its own space, it closes", blank not in ids())


def stacked(t):
    a = sv.page("stack-alpha")
    sv.cmd({"do": "space", "action": "new", "name": "Work"})
    settle()
    sv.cmd({"do": "space", "action": "go", "index": 2})
    settle()
    w = sv.page("stack-work")
    sv.sp("newTab")
    blank = state()["activeID"]
    t.ok("stacked: a New Tab in front of the second space", blank in blanks())
    sv.cmd({"do": "space", "action": "go", "index": 1})
    settle()
    sv.cmd({"do": "stacked", "action": "load"})
    sv.cmd({"do": "stacked", "action": "select", "id": a})
    settle()
    sv.cmd({"do": "stacked", "action": "select", "id": w})
    settle()
    st = state()
    t.ok("stacked: a tab chosen in its space's section closes the New Tab it replaced",
         st["activeID"] == w and blank not in ids(st), (st["activeID"], ids(st)))


def main():
    t = sv.T()
    try:
        for dark in (False, True):
            mode = "dark" if dark else "light"
            fresh_install(dark)
            try:
                a, b = left_untouched(t, mode, pictures=True)
                if not dark:
                    split_and_space(t, a, b)
            finally:
                sv.finish()
        fresh_install(True, sidebar=False)
        try:
            left_untouched(t, "hidden-sidebar", pictures=False)
        finally:
            sv.finish()
        fresh_install(True, **{"spaces.stacked": True})
        try:
            stacked(t)
        finally:
            sv.finish()
    finally:
        t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
