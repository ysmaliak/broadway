#!/usr/bin/env python3
"""Text actions on selected words, in a hidden test world.

Build first (`./build.sh`), then `python3 Tests/text_actions.py`. A local page,
a fake plan that answers with set words and a This Mac that isn't there: the
right-click menu on a selection, the list of commands, Improve Writing, its
result and Replace, then the same with the switch off and in a private window.
No real model is reached.
"""
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("text-actions")

BEFORE = "Their is a mistake in this sentense."
AFTER = "There is a mistake in this sentence."
ROWS = ["Improve Writing", "Fix Spelling and Grammar", "Summarize", "More Commands…"]
PAGE = f"""<!doctype html><title>Words</title>
<body style="font:18px -apple-system;margin:40px;background:white">
<p id=words>{BEFORE}</p>
<textarea id=box style="display:block;width:520px;height:90px;font:18px -apple-system">{BEFORE}</textarea>
<p id=only>PAGE-ONLY-WORDS stay on the page.</p>
<input id=pass name=password value="Their secret words" style="display:block;width:320px;font:18px -apple-system">
<input id=card autocomplete=cc-number value="Their card words" style="display:block;width:320px;font:18px -apple-system;margin-top:12px">
</body>""".encode()


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(PAGE)))
        self.end_headers()
        self.wfile.write(PAGE)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def pick_field(name):
    return f"""(function () {{ var b = document.getElementById('{name}'); b.focus();
      b.setSelectionRange(0, b.value.length); var r = b.getBoundingClientRect();
      return [r.left + 60, r.top + Math.min(r.height / 2, 14)]; }})()"""


PICK_WORDS = """(function () { var p = document.getElementById('words'); var range = document.createRange();
  range.selectNodeContents(p); var s = getSelection(); s.removeAllRanges(); s.addRange(range);
  var r = range.getBoundingClientRect(); return [r.left + 40, r.top + r.height / 2]; })()"""


def menu(tab, js, pick="(nothing)"):
    at = sv.ev(tab, js)
    time.sleep(0.3)
    try:
        said = sv.cmd({"do": "linkmenu", "id": tab, "x": at[0], "y": at[1], "pick": pick})
    except RuntimeError as error:
        return None, str(error)
    time.sleep(0.4)
    return said.get("menu") or None, "" if said.get("menu") else "no menu came up"


def titles(items):
    return list(items or [])


def rows(items):
    return [t for t in titles(items) if t in ROWS]


def ai(**f):
    return sv.cmd({"do": "ai", **f})


def sent(tab=None):
    return ai(action="sent", **({"id": tab} if tab else {}))


def total(said):
    return sum(v["count"] for v in said["sent"].values())


def finished(within=10):
    state = ai(action="state")
    end = time.time() + within
    while time.time() < end and (state.get("resultRunning") or "result" not in state):
        time.sleep(0.2)
        state = ai(action="state")
    return state


def edit_menu():
    return sv.cmd({"do": "menus"})["enabled"].get("Edit", {})


def main():
    t = sv.T()
    try:
        sv.setup()
        sv.launch()
        ai(action="fake", plan="claude", answer=AFTER, mac=False)
        tab = sv.sp("open", url=f"{BASE}/words")["resultID"]
        sv.sp("select", id=tab)
        sv.cmd({"do": "wait", "id": tab, "seconds": 20})
        time.sleep(0.5)

        items, why = menu(tab, PICK_WORDS)
        shown = titles(items)
        t.ok("the right-click menu on selected words has the three actions and More Commands…", rows(items) == ROWS, why or shown)
        if rows(items) == ROWS:
            first = shown.index(ROWS[0])
            last = shown.index(ROWS[-1])
            t.ok("they sit together", last - first == len(ROWS) - 1, shown)
            t.ok("a separator on each side", shown[first - 1] == "---" and (last + 1 == len(shown) or shown[last + 1] == "---"), shown)
            t.ok("below Copy", "Copy" in shown and shown.index("Copy") < first, shown)
        t.ok("Translate is not one of ours: no row is named just Translate", "Translate" not in shown, shown)

        items, why = menu(tab, pick_field("box"))
        t.ok("the menu on words selected in a box has them too", rows(items) == ROWS, why or titles(items))

        for name in ["pass", "card"]:
            items, why = menu(tab, pick_field(name))
            t.ok(f"a selection in a secret field ({name}) is offered nothing", items is not None and not rows(items), why or titles(items))
            state = ai(action="select", id=tab, js=pick_field(name))
            t.ok(f"a selection in a secret field ({name}) is never read", "commands" not in state and "selection" not in state, state)

        menu(tab, pick_field("box"), pick="Improve Writing")
        state = finished()
        t.ok("Improve Writing from the right-click menu runs on that selection", state.get("result") == AFTER, state)
        sv.cmd({"do": "ai", "action": "primary"})
        time.sleep(0.6)
        t.ok("and its Replace changes the box", sv.ev(tab, "document.getElementById('box').value") == AFTER)
        sv.ev(tab, f"document.getElementById('box').value = {BEFORE!r}; true")
        ai(action="fake", plan="claude", answer=AFTER, mac=False)

        enabled = edit_menu()
        t.ok("Edit has the five commands and More Commands…, all on",
             all(enabled.get(name) for name in ["Improve Writing", "Fix Spelling and Grammar", "Translate", "Summarize", "Explain Simply",
                                                "More Commands…"]), enabled)

        state = ai(action="select", id=tab, js=pick_field("box"))
        listed = state.get("commands", [])
        t.ok("More Commands… opens the list for the selection", "Improve Writing" in listed and state.get("selection") == BEFORE, state)
        t.ok("the list still has Translate", "Translate" in listed, listed)
        t.ok("its foot says once what runs them", state.get("foot") == "Claude Code, leaves this Mac", state)
        t.ok("and no row repeats it", state.get("details") and all(d == "" for d in state["details"]), state)
        state = ai(action="take", index=listed.index("Improve Writing") if "Improve Writing" in listed else 0)
        state = finished()
        t.ok("Improve Writing answers with the fake plan's words", state.get("result") == AFTER, state)
        t.ok("the result can replace the words in the box", state.get("canReplace") is True, state)
        t.ok("the result names the agent as Settings does", str(state.get("place", "")).startswith("Claude Code · "), state)
        said = sent()
        claude = said["sent"].get("claude", {})
        t.ok("one request went to the picked plan, and nothing anywhere else",
             claude.get("count") == 1 and total(said) == 1, said)
        t.ok("the request can only answer", claude.get("tools") == ["none"], claude.get("tools"))
        prompt = (claude.get("prompts") or [""])[0]
        t.ok("it carries the selected words", BEFORE in prompt)
        t.ok("and not the rest of the page", "PAGE-ONLY-WORDS" not in prompt and "secret" not in prompt)
        ai(action="primary")
        time.sleep(0.6)
        value = sv.ev(tab, "document.getElementById('box').value")
        t.ok("Replace puts the new words in the box", value == AFTER, value)
        t.ok("and says so", sent()["announced"] == "Replaced", sent()["announced"])

        sv.ev(tab, f"document.getElementById('box').value = {BEFORE!r}; true")
        sv.cmd({"do": "settings", "set": "ai.actions", "value": False})
        before = total(sent())
        items, why = menu(tab, pick_field("box"))
        t.ok("switch off: the right-click menu has no actions", items is not None and not rows(items), why or titles(items))
        state = ai(action="select", id=tab, js=pick_field("box"))
        t.ok("switch off: More Commands… opens nothing", "commands" not in state and "result" not in state, state)
        enabled = edit_menu()
        t.ok("switch off: the commands in Edit are greyed",
             not any(enabled.get(name) for name in ["Improve Writing", "Translate", "More Commands…"]), enabled)
        t.ok("switch off: nothing was sent", total(sent()) == before, sent())
        sv.cmd({"do": "settings", "set": "ai.actions", "value": True})

        hidden = sv.cmd({"do": "split", "action": "open", "url": f"{BASE}/private", "window": sv.sp("private")["window"]})["resultID"]
        sv.cmd({"do": "wait", "id": hidden, "seconds": 20})
        time.sleep(0.5)
        items, why = menu(hidden, pick_field("box"))
        t.ok("a private window without This Mac: the menu has no actions", items is not None and not rows(items), why or titles(items))
        state = ai(action="select", id=hidden, js=pick_field("box"))
        t.ok("a private window without This Mac: no list", "commands" not in state and "result" not in state, state)
        t.ok("it says the page isn't sent", sent(hidden)["announced"] == "In a private window, the page isn't sent", sent(hidden)["announced"])
        t.ok("a private window: nothing was sent", total(sent()) == before, sent())
    finally:
        sv.finish()
    t.done()
    return 0 if t.failed == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
