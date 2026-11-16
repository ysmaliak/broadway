#!/usr/bin/env python3
import json
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("field-leave")

ROOT = Path(__file__).resolve().parents[1]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "after"
HOLD = LABEL != "before"
OUT = ROOT / ".context" / LABEL
ONLY = set(sys.argv[2].split(",")) if len(sys.argv) > 2 else None
SIZE = [1100, 720]
PID = [0]


def press(code, chars, *mods):
    return sv.cmd({"do": "press", "code": code, "chars": chars, "mods": list(mods)})


def escape():
    press(53, "\u001b")


def ret():
    press(36, "\r")


def cmd_l():
    press(37, "l", "cmd")


def cmd_t():
    press(17, "t", "cmd")


def down():
    press(125, "")


def field(*args):
    return sv.cmd({"do": "fieldrows", "args": list(args)})


def drawn():
    try:
        return field("drawn").get("drawn")
    except RuntimeError:
        return None


def stage(dark):
    answer = sv.cmd({"do": "agents", "action": "stage", "dark": dark, "size": SIZE})
    PID[0] = answer["pid"]
    time.sleep(1.0)


def welcome(action, **more):
    try:
        return sv.cmd({"do": "welcome", "action": action, **more})
    except RuntimeError:
        return None


def fresh_install(dark):
    sv.setup(**{"onboarding.show": True, "delight.show": True, "spaces": True, "sidebar": True,
                "newtab.floating": True, "search.suggest": False})
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


def line(name):
    field("line", str(OUT / "lines" / f"{name}.png"))


def same(a, b):
    keys = ("text", "placeholder", "heads", "rows", "lit", "bar", "selection", "menu", "chips")
    if not a or not b:
        return False, "no reading"
    off = {k: (a.get(k), b.get(k)) for k in keys if a.get(k) != b.get(k)}
    return not off, off


class Run:
    def __init__(self):
        self.t = sv.T()
        self.report = {}
        self.home = None

    def ready(self):
        if self.home:
            sv.sp("select", id=self.home)
            time.sleep(0.5)
        seen = drawn() or {}
        if seen.get("visible"):
            escape()
            time.sleep(0.6)

    def way(self, name, opened, out, keep=None):
        if ONLY and name not in ONLY:
            return
        self.ready()
        opened()
        time.sleep(0.7)
        before = drawn()
        line(f"{name}-1-open")
        during = {}
        out()
        time.sleep(0.03)
        during["a"] = drawn()
        line(f"{name}-2-leaving")
        time.sleep(0.07)
        during["b"] = drawn()
        time.sleep(0.6)
        after = drawn()
        shown = [d for d in (during.get("a"), during.get("b")) if d and d.get("leaving")]
        holds = [same(before, d) for d in shown]
        self.report[name] = {"before": before, "during": [during.get("a"), during.get("b")], "after": after}
        self.t.ok(f"{name}: the panel was open before leaving", bool(before and before.get("visible") and not before.get("leaving")), before)
        if keep is not None:
            self.t.ok(f"{name}: {keep}", bool(after and after.get("visible") and not after.get("leaving")), after)
            return
        self.t.ok(f"{name}: the panel was leaving when read", len(shown) >= 1, during)
        self.t.ok(f"{name}: what it draws while leaving is what it drew before", bool(holds) and all(ok for ok, _ in holds),
                  [off for _, off in holds])
        self.t.ok(f"{name}: gone afterwards", not (after or {}).get("visible"), after)

    def done(self):
        OUT.mkdir(parents=True, exist_ok=True)
        (OUT / "field_leave.json").write_text(json.dumps(self.report, indent=1))
        self.t.done()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    run = Run()
    try:
        for dark in (True, False):
            look = "dark" if dark else "light"
            fresh_install(dark)
            field("hold", "on" if HOLD else "off")
            pages = [sv.page(name) for name in ("alpha", "bravo", "charlie")]
            run.home = pages[0]
            sv.sp("select", id=pages[0])
            time.sleep(0.8)
            cmd_l()
            time.sleep(0.7)
            escape()
            time.sleep(0.6)

            def typed(words):
                def act():
                    cmd_l()
                    time.sleep(0.4)
                    field("type", words)
                return act

            def recent_row():
                cmd_t()
                time.sleep(0.5)
                rows = field("state").get("rows", [])
                index = next((i for i, r in enumerate(rows) if r[3].endswith("/bravo")), None)
                if index is not None:
                    field("pick", str(index))

            run.way(f"{look}-escape", cmd_l, escape)
            if not dark:
                sv.finish()
                continue
            run.way(f"{look}-click-outside", cmd_l, lambda: field("clickout"))
            run.way(f"{look}-typed-escape", typed("cha"), escape)
            run.way(f"{look}-return-address", typed(f"{sv.BASE}/delta"), ret)
            run.way(f"{look}-return-row", recent_row, lambda: field("return"))

            def copy_row():
                cmd_l()
                time.sleep(0.4)
                field("pick", "0")

            run.way(f"{look}-copy-address", copy_row, ret)

            def actions_menu():
                cmd_l()
                time.sleep(0.4)
                press(40, "k", "cmd")

            run.way(f"{look}-actions-click-outside", actions_menu, lambda: field("clickout"))
            run.way(f"{look}-switch-tab", cmd_l, lambda: press(19, "2", "cmd"))
            run.way(f"{look}-lose-key", cmd_l, lambda: sv.cmd({"do": "pageclick", "action": "otherkey"}),
                    keep="the panel stays up when another window takes the keys")
            sv.cmd({"do": "pageclick", "action": "otherkey", "close": True})
            run.way(f"{look}-cmd-t-escape", cmd_t, escape)

            def cmd_t_typed():
                cmd_t()
                time.sleep(0.4)
                field("type", "cha")

            run.way(f"{look}-cmd-t-typed-escape", cmd_t_typed, escape)
            def cmd_t_address():
                cmd_t()
                time.sleep(0.4)
                field("type", f"{sv.BASE}/echo")

            run.way(f"{look}-cmd-t-return", cmd_t_address, lambda: field("return"))

            if not ONLY or "reopen" in ONLY:
                run.ready()
                typed("cha")()
                time.sleep(0.6)
                escape()
                time.sleep(0.03)
                cmd_l()
                time.sleep(0.05)
                again = drawn()
                time.sleep(0.6)
                settled = drawn()
                run.report["reopen"] = {"again": again, "settled": settled}
                run.t.ok("reopen: ⌘L during the leave shows the page's address at once",
                         bool(again) and not again.get("leaving") and (again.get("text") or "").startswith("http")
                         and again.get("text") == settled.get("text") and not again.get("still"), (again, settled))
                run.t.ok("reopen: and the page's rows, not the held ones",
                         bool(again) and again.get("heads") == ["This Page"] and again.get("rows") == settled.get("rows")
                         and not again.get("still"), (again, settled))
                run.ready()
                typed("cha")()
                time.sleep(0.6)
                escape()
                time.sleep(0.03)
                cmd_t()
                time.sleep(0.05)
                again = drawn()
                time.sleep(0.6)
                settled = drawn()
                run.report["reopen-new-tab"] = {"again": again, "settled": settled}
                run.t.ok("reopen: ⌘T during the leave shows an empty field and the resting list at once",
                         bool(again) and not again.get("leaving") and again.get("text") == ""
                         and again.get("rows") == settled.get("rows") and bool(again.get("rows")) and not again.get("still"),
                         (again, settled))
            sv.finish()
    finally:
        run.done()
        sv.finish()
    sys.exit(1 if run.t.failed else 0)


if __name__ == "__main__":
    main()
