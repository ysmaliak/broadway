#!/usr/bin/env python3
"""Places inside the floating field (FieldPlace.swift), driven by keys.

Build first (`./build.sh`), then `python3 Tests/field_places.py [picture-dir]`.
Uses the split suite's harness in a world of its own: started hidden, no
window shown, everything removed afterwards. Keys go through the app's own
event queue, as a hand's do. Copies go to the probe's own pasteboard
(AnswerBoard) and Finder is never asked to open or show anything
(PlaceFiles); the run checks the real clipboard is left as it was.
"""
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-places")

CODES = {"a": 0, "s": 1, "d": 2, "z": 6, "h": 4, "x": 7, "c": 8, "b": 11, "w": 13, "e": 14, "r": 15, "t": 17,
         "o": 31, "i": 34, "p": 35, "l": 37, "k": 40, "n": 45}
TAB, RETURN, ESCAPE, DELETE = (48, "\t"), (36, "\r"), (53, "\u001b"), (51, "\u007f")
DOWN = (125, "\uf701")


def press(key, mods=()):
    code, chars = key if isinstance(key, tuple) else (CODES[key], key)
    sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})
    time.sleep(0.15)


def type_in(text):
    for ch in text:
        press(ch)


def rows(*args):
    return sv.cmd({"do": "fieldrows", "args": list(args)})


def places():
    return rows("places")


def titles(state):
    return [r[0] for r in state["rows"]]


def in_field():
    return sv.cmd({"do": "probe"})["responderIsAddress"]


def clipboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def marks(path):
    rows_ = "\n".join(f'<DT><A HREF="{u}" ADD_DATE="1700000000">{n}</A>'
                      for n, u in [("Tracker board", f"{sv.BASE}/tracker"), ("Recipes", f"{sv.BASE}/recipes")])
    Path(path).write_text("<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>\n"
                          f"<DL><p>\n<DT><H3>Work</H3>\n<DL><p>\n{rows_}\n</DL><p>\n</DL><p>\n")


def open_field():
    press("t", ["cmd"])
    time.sleep(0.3)


def main():
    t = sv.T()
    pictures = sys.argv[1] if len(sys.argv) > 1 else None
    before = clipboard()
    folder = tempfile.mkdtemp()
    file = os.path.join(folder, "bookmarks.html")
    marks(file)
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        sv.page("start")
        rows("visit", f"{sv.BASE}/alpha", "30", "Alpha", "one")
        rows("visit", f"{sv.BASE}/beta", "5", "Beta", "news")
        rows("visit", f"{sv.BASE}/gamma", "60", "Gamma", "page")
        rows("keep", "report.pdf", "10", "bank.example")
        rows("keep", "photo.jpg", "2", "camera.example")
        sv.cmd({"do": "import-file", "path": file})

        open_field()
        type_in("hist")
        s = places()
        t.ok("typing hist offers History, a Tab away", s["placeOffer"] == "history" and s["place"] == "", s)
        t.ok("the field still has the keys", in_field())
        press(TAB)
        s = places()
        t.ok("Tab puts History in the field as a chip and lets go of the word",
             s["place"] == "history" and s["typed"] == "", s)
        t.ok("History is newest first, the page just visited on top",
             titles(s) == ["start", "Beta news", "Alpha one", "Gamma page"], titles(s))
        t.ok("its first row is lit", s["picked"] == 0, s["picked"])
        if pictures:
            rows("picture", os.path.join(pictures, "history-place.png"))

        type_in("alp")
        s = places()
        t.ok("typing filters the place", titles(s) == ["Alpha one"] and s["typed"] == "alp", s["rows"])
        type_in("xx")
        s = places()
        t.ok("a query nothing matches leaves no rows and Return idle", s["rows"] == [] and s["idle"], s)
        press(DELETE)
        press(DELETE)

        sv.cmd({"do": "fieldrows", "args": ["type", "2+2"]})
        s = places()
        t.ok("an answer never leads in a place", all(r[2] == "placed" for r in s["rows"]) and s["place"] == "history", s["rows"])

        press(ESCAPE)
        s = places()
        t.ok("Escape first clears the query", s["typed"] == "" and s["place"] == "history", s)
        press(ESCAPE)
        s = places()
        t.ok("then leaves the place, the field still up", s["place"] == "" and s["showing"], s)
        press(ESCAPE)
        s = places()
        t.ok("then closes the field", not s["showing"], s)

        open_field()
        type_in("hist")
        press(TAB)
        type_in("bet")
        press(RETURN)
        time.sleep(0.6)
        s = places()
        t.ok("Return opens the lit page", s["active"] == f"{sv.BASE}/beta" and s["place"] == "" and not s["showing"], s["active"])

        open_field()
        type_in("hist")
        press(TAB)
        tabs = len(places()["tabs"])
        press(RETURN, ["cmd"])
        time.sleep(0.6)
        s = places()
        t.ok("⌘↩ opens it in a new tab", len(s["tabs"]) == tabs + 1, s["tabs"])

        open_field()
        type_in("hist")
        press(TAB)
        press(DOWN)
        s = places()
        t.ok("↓ walks the place and keeps the field empty", s["picked"] == 1 and s["typed"] == "", s)
        lit, url = s["rows"][1][0], s["rows"][1][3]
        rest = [r[0] for i, r in enumerate(s["rows"]) if i != 1]
        press("x", ["ctrl"])
        s = places()
        t.ok("⌃X forgets the lit history row with an Undo on the toast",
             url not in s["history"] and s["undo"] and s["announced"] == f"Forgot {lit}", s)
        t.ok("and the list closes over it, the next row lit", titles(s) == rest and s["picked"] == 1, s["rows"])
        rows("undo")
        s = places()
        t.ok("Undo brings it back where it was", url in s["history"] and titles(s)[1] == lit, s["rows"])
        press(DELETE)
        s = places()
        t.ok("⌫ on an empty query leaves the place", s["place"] == "" and s["showing"], s)
        press(ESCAPE)

        open_field()
        type_in("book")
        press(TAB)
        s = places()
        t.ok("Bookmarks keep their order and say their folder",
             titles(s) == ["Tracker board", "Recipes"] and s["place"] == "bookmarks", s["rows"])
        press("c", ["cmd", "shift"])
        s = places()
        t.ok("⇧⌘C copies the bookmark's link", s["copied"] == f"{sv.BASE}/tracker" and s["announced"] == "Link copied", s)
        press("x", ["ctrl"])
        s = places()
        t.ok("⌃X removes the bookmark", f"{sv.BASE}/tracker" not in s["bookmarks"] and titles(s) == ["Recipes"], s)
        press("z", ["cmd"])
        s = places()
        t.ok("⌘Z undoes it, back first in its folder", titles(s) == ["Tracker board", "Recipes"] and not s["undo"], s["rows"])
        press(ESCAPE)
        press(ESCAPE)

        open_field()
        type_in("down")
        press(TAB)
        s = places()
        t.ok("Downloads are newest first", titles(s) == ["photo.jpg", "report.pdf"], s["rows"])
        if pictures:
            rows("picture", os.path.join(pictures, "downloads-place.png"))
        type_in("bank")
        s = places()
        t.ok("found by the site they came from", titles(s) == ["report.pdf"], s["rows"])
        press("c", ["cmd", "shift"])
        s = places()
        t.ok("⇧⌘C copies the file's path", s["copied"].endswith("/bench-downloads/report.pdf") and s["announced"] == "Path copied", s)
        press("x", ["ctrl"])
        s = places()
        t.ok("⌃X takes it off the list", "report.pdf" not in s["downloads"] and s["rows"] == [], s)
        rows("undo")
        press("r", ["cmd"])
        s = places()
        t.ok("⌘R shows it in Finder and puts the field away",
             any(f.startswith("reveal ") and f.endswith("/report.pdf") for f in s["files"]) and not s["showing"], s)
        t.ok("the file itself was never touched", os.path.exists(next(f for f in s["files"] if f.startswith("reveal "))[7:]), s["files"])

        open_field()
        type_in("down")
        press(TAB)
        press(RETURN)
        s = places()
        t.ok("Return opens the newest download with its app, not in a tab",
             any(f.startswith("open ") and f.endswith("/photo.jpg") for f in s["files"]) and not s["active"].startswith("file:"), s)

        t.ok("the real clipboard is unchanged", clipboard() == before)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
