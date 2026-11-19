#!/usr/bin/env python3
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("meeting-spaces")
ROOT = Path(__file__).resolve().parents[1]
HOST = "call.example.test"
CALENDARS = [
    {"id": "cal-work", "title": "Work", "account": "work@example.com", "source": "src-work"},
    {"id": "cal-team", "title": "Team", "account": "work@example.com", "source": "src-work"},
    {"id": "cal-launches", "title": "Launches", "account": "work@example.com", "source": "src-work"},
    {"id": "cal-home", "title": "Home", "account": "me@example.org", "source": "src-home"},
    {"id": "cal-family", "title": "Family", "account": "me@example.org", "source": "src-home"},
]


def space(**f): return sv.cmd({"do": "space", **f})
def alert(**f): return sv.cmd({"do": "meetalert", **f})
def settings(**f): return sv.cmd({"do": "settings", **f})
def ui(**f): return sv.cmd({"do": "ui", **f})


def event(key, calendar="cal-work"):
    return {"id": key, "title": "Standup " + key, "in": 1, "link": f"https://{HOST}/{key}", "calendar": calendar,
            "account": "work@example.com", "source": "src-work", "sourceTitle": "work@example.com"}


def join(t, key, accounts=None, calendars=None):
    said = alert(action="fixture", events=[event(key)], hosts={HOST: "meet"}, calendarList=CALENDARS,
                 accountSpaces=accounts or {}, calendarSpaces=calendars or {})
    t.ok(f"{key} is due", len(said.get("due", [])) == 1, said.get("due"))
    return alert(action="press", index=0, button="join")


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ROOT / ".context" / "meeting-spaces").resolve()
    out.mkdir(parents=True, exist_ok=True)
    shot_tool = out / "shot"
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests" / "WindowShot.swift"), "-o", str(shot_tool)], check=True)
    t = sv.T()
    try:
        sv.setup(spaces=True, **{"start.fresh": True})
        sv.launch()
        pid = next(iter(sv.holding() & sv.running()))
        space(action="rename", name="Personal")
        space(action="new", name="Work")
        here = space(action="go", index=1)
        t.ok("the person is in Personal", here.get("current") == "Personal", here.get("current"))

        landed = join(t, "abc-defg-hij")
        t.ok("a work call with nothing known stays in Personal", landed.get("space") == "Personal", landed.get("space"))
        t.ok("…as the fallback", landed.get("choice") == "current", landed.get("choice"))

        landed = join(t, "bcd-efgh-ijk")
        t.ok("the next call from that calendar is not pulled to Personal by the first", landed.get("choice") == "current",
             landed.get("choice"))

        landed = join(t, "cde-fghi-jkl", accounts={"src-work": "Work"})
        t.ok("with Work chosen for its account, a work call opens in Work", landed.get("space") == "Work", landed.get("space"))
        t.ok("…by the account's setting", landed.get("choice") == "chosenAccount", landed.get("choice"))
        space(action="go", index=1)

        landed = join(t, "def-ghij-klm", accounts={"src-work": "Work"}, calendars={"cal-work": "Personal"})
        t.ok("a calendar set to Personal wins over its account", landed.get("space") == "Personal", landed.get("space"))
        t.ok("…by the calendar's setting", landed.get("choice") == "chosenCalendar", landed.get("choice"))

        alert(action="fixture", events=[], hosts={HOST: "meet"}, calendarList=CALENDARS,
              accountSpaces={"src-work": "Work"}, calendarSpaces={"cal-work": "", "cal-team": "any"})
        sv.cmd({"do": "resize", "width": 1040, "height": 1300, "steps": 1})
        ui(settings=True)
        time.sleep(1.5)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(0.8)
        ui(settingsPage="general")
        time.sleep(1.5)
        before = [row["id"] for row in settings(shown=True).get("shown", [])]
        t.ok("the work account is listed folded", "meetings.space.fold.src-work" in before, before)
        ui(settingsPress="settings.meetings.space.fold.src-work")
        time.sleep(1.2)
        ui(settingsPoint="meetings.space.calendar.cal-launches")
        ui(settingsPoint="")
        shown = settings(shown=True)
        rows = {row["id"]: row for row in shown.get("shown", [])}
        t.ok("General has Spaces for calls", "meetings.spaces" in rows, sorted(rows))
        work = rows.get("meetings.space.account.src-work", {})
        home = rows.get("meetings.space.account.src-home", {})
        t.ok("the work account shows Work", work.get("picked") == "Work", work)
        t.ok("…offering Any Space and each space", work.get("items") == ["Any Space", "Personal", "Work"], work.get("items"))
        t.ok("the personal account shows Any Space", home.get("picked") == "Any Space", home)
        team = rows.get("meetings.space.calendar.cal-team", {})
        own = rows.get("meetings.space.calendar.cal-work", {})
        t.ok("an opened account lists its calendars", team.get("picked") == "Any Space" and own.get("picked") == "Same as Account",
             [team, own])
        fold = rows.get("meetings.space.fold.src-home", {})
        t.ok("a folded account names its calendars", fold.get("detail") == "Home, Family", fold)
        for look in ["light", "dark"]:
            ui(look=look)
            time.sleep(1.2)
            ui(settingsPoint="meetings.space.calendar.cal-launches")
            ui(settingsPoint="")
            time.sleep(0.6)
            path = out / f"settings-spaces-for-calls-{look}.png"
            said = subprocess.run([str(shot_tool), str(pid), str(number), str(path)], capture_output=True, text=True)
            t.ok(f"pictured Settings {look}", path.exists(), (said.stdout + said.stderr).strip()[-300:])
        ui(settings=False)
        time.sleep(0.6)
        alert(action="off")
    finally:
        sv.finish()
        shot_tool.unlink(missing_ok=True)
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
