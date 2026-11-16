#!/usr/bin/env python3
"""Answers in the address field (FieldAnswers.swift), through the field itself.

Build first (`./build.sh`), then `python3 Tests/field_answers.py`. Uses the
split suite's harness in a world of its own: started hidden, no window shown,
everything removed afterwards. Copies go to a pasteboard of the probe's own
(AnswerBoard), and the run checks the real clipboard is left as it was.
"""
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-answers")

def rows(*args):
    return sv.cmd({"do": "fieldrows", "args": list(args)})


def typed(text):
    return sv.cmd({"do": "field", "text": text, "type": True})


def lead(state):
    return state["rows"][0] if state["rows"] else ["", "", "", ""]


def clipboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def main():
    t = sv.T()
    before = clipboard()
    try:
        sv.setup(**{"newtab.floating": True})
        sv.launch()
        sv.page("start")

        typed("20% of 80"); time.sleep(0.3)
        s = rows("answer")
        t.ok("typed into the field: 20% of 80 leads with 16", lead(s)[:1] == ["16"] and lead(s)[2] == "answer", s["rows"][:2])
        t.ok("the search for it is still in the list", any(r[2] == "search" for r in s["rows"]), s["rows"])
        t.ok("no grey ending over an answer", s["ending"] == "", s["ending"])
        s = rows("return")
        s = rows("answer")
        t.ok("Return copies 16 and keeps the field open", s["copied"] == "16" and s["editing"], s)
        t.ok("the question stays in the field", s["typed"] == "20% of 80" and lead(s)[:1] == ["16"], s)
        t.ok("a quiet Copied", s["announced"] == "Copied", s["announced"])
        t.ok("the page under the field is left alone", sv.sp("state")["tabs"][-1]["url"].endswith("/start"), sv.sp("state")["tabs"])

        typed("3*7"); time.sleep(0.3)
        sv.cmd({"do": "press", "code": 36, "chars": "\r", "mods": []}); time.sleep(0.4)
        s = rows("answer")
        t.ok("a pressed Return copies 21 and the field keeps the question", s["copied"] == "21" and s["editing"] and s["typed"] == "3*7", s)
        sv.cmd({"do": "press", "code": 53, "chars": "\x1b", "mods": []}); time.sleep(0.4)
        s = rows("answer")
        t.ok("Esc then closes the field", not s["editing"], s)

        typed("5 км в милях"); time.sleep(0.3)
        s = rows("answer")
        t.ok("5 км в милях answers in miles", lead(s)[0].startswith("3") and lead(s)[0].endswith("мили"), lead(s))
        tabs = len(sv.sp("state")["tabs"])
        s = rows("return-aside")
        t.ok("⌘↩ copies the question with the answer", s["copied"].startswith("5 км в милях = 3") and s["copied"].endswith("мили"), s["copied"])
        t.ok("⌘↩ over an answer opens no tab", s["tabs"] == tabs, s["tabs"])
        t.ok("⌘↩ keeps the field open too", s["editing"], s)
        rows("close")

        typed("15:00 warsaw to new york"); time.sleep(0.3)
        s = rows("answer")
        t.ok("15:00 warsaw to new york: a time with date and offset", lead(s)[2] == "answer" and "New York · UTC−" in lead(s)[1], lead(s))
        rows("close")

        typed("время в токио"); time.sleep(0.3)
        s = rows("answer")
        t.ok("время в токио answers with Tokyo's time", "Токио · UTC+9" in lead(s)[1], lead(s))
        rows("close")

        typed("0xff to dec"); time.sleep(0.3)
        s = rows("click", "0")
        t.ok("clicking the row copies it and keeps the field", s["copied"] == "255" and s["editing"], s)
        rows("close")

        for words in ["weather tomorrow", "iphone 15", "1.2.3.4", "2024-11-04", "london to new york"]:
            typed(words); time.sleep(0.3)
            s = rows("answer")
            t.ok(f"{words!r} stays a search or a place", all(r[2] != "answer" for r in s["rows"]), s["rows"][:2])
            rows("close")

        typed(f"{sv.BASE}/next"); time.sleep(0.3)
        s = rows("answer")
        t.ok("an address gets no answer", all(r[2] != "answer" for r in s["rows"]), s["rows"][:2])
        rows("return"); time.sleep(0.8)
        t.ok("and Return still goes there", sv.sp("state")["tabs"][-1]["url"].endswith("/next"), sv.sp("state")["tabs"])

        s = rows("launch")
        t.ok("⌘T's floating field opens", s["launching"], s)
        typed("2^10"); time.sleep(0.3)
        s = rows("answer")
        t.ok("the floating field answers 2^10", lead(s)[0] == "1,024" or lead(s)[0].replace(" ", " ") == "1 024", lead(s))
        s = rows("return")
        s = rows("answer")
        t.ok("Return there copies too and the field stays", s["copied"] in ("1024",) and s["editing"] and s["typed"] == "2^10", s)
        rows("close")

        t.ok("the real clipboard is untouched", clipboard() == before)
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
