#!/usr/bin/env python3
"""Meeting alerts from a fake calendar, in a hidden probe world.

Build first (`./build.sh`), then `python3 Tests/meeting_alerts.py`. The
calendar is the bench's fixed one, never the Mac's; the meeting is a local
page that starts WebKit's pretend camera. The alert panel sits off every
screen on a test run. The pictures are window-only captures of a copy of the
card in a window under the desktop, saved to .context/meeting-alerts: by
ScreenCaptureKit when this terminal may record the screen, otherwise by the
test copy capturing its own window, which needs no permission. The test copy
hands the picture back over the bench and never writes outside its world.
"""
import base64
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("meeting-alerts")
t = sv.T()
ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / ".context" / "meeting-alerts"
SHOT = WORK / "shot"

CALL = r"""<!doctype html><title>Design sync call</title><script>
window.state = 'starting';
navigator.mediaDevices.getUserMedia({video: true, audio: true}).then(s => { window.stream = s; window.state = 'started'; })
  .catch(e => { window.state = 'error ' + e.name; });
</script><p>fake meeting"""

PEOPLE = [
    {"name": "Dana Scully", "email": "dana@example.test"},
    {"name": "Fox Mulder", "email": "fox@example.test"},
    {"name": "", "email": "walter.skinner@example.test"},
    {"name": "Monica Reyes", "email": "monica@example.test"},
]


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/")
        html = CALL if name.count("-") == 2 else f"<!doctype html><title>{name}</title><p>{name}"
        body = html.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


def alert(action="state", **values):
    return sv.cmd({"do": "meetalert", "action": action, **values})


def until(check, within=8):
    end = time.time() + within
    while time.time() < end:
        if check():
            return True
        time.sleep(0.2)
    return check()


def shoot(name, dark):
    path = WORK / name
    path.unlink(missing_ok=True)
    path.with_name(name.replace(".png", "-drawn.png")).unlink(missing_ok=True)
    state = alert("shot-start", dark=dark)
    try:
        time.sleep(0.8)
        out = subprocess.run([str(SHOT), str(state["pid"]), str(state["window"]), str(path)],
                             capture_output=True, text=True).stdout.strip()
        if not path.exists():
            png = alert("shot-take")["png"]
            if png:
                path.write_bytes(base64.b64decode(png))
                out = f"{out}; the test copy captured its own window"
    finally:
        alert("shot-end")
    if path.exists():
        return True, out
    png = alert("render", dark=dark)["png"]
    if png:
        path.with_name(name.replace(".png", "-drawn.png")).write_bytes(base64.b64decode(png))
    return bool(png), f"{out}; drawn instead, glass as a flat stand-in"


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/WindowShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup()
    for kind in (0, 1, 2):
        subprocess.run(["defaults", "write", sv.SUITE, f"capture.{sv.BASE}|{kind}", "-bool", "true"])
    sv.launch()
    try:
        before = alert()
        t.ok("a test run reads no calendar of its own", not before["access"] and not before["running"], before)

        idle = sv.page("idle")
        link = f"{sv.BASE}/abc-defg-hij"
        began = time.time()
        state = alert("fixture", lead="1", hosts={"127.0.0.1": "meet"}, events=[
            {"title": "Design sync", "in": 0.5, "link": link, "people": PEOPLE},
            {"title": "Quarterly planning", "in": 1.25, "notes": f"Join: {sv.BASE}/qrt-plan-now", "people": PEOPLE[:2],
             "pending": True, "external": "quarterly-planning@example.test"},
            {"title": "Offsite", "in": 0.4, "allDay": True},
            {"title": "Declined review", "in": 0.3, "declined": True, "link": link},
            {"title": "Family dinner", "in": 0.2, "calendar": "home"},
        ], skip=["home"])
        due = [d["title"] for d in state["due"]]
        t.ok("alerts start with the fake calendar", state["running"] and state["access"], state)
        t.ok("the meeting a minute away alerts now", due == ["Design sync"], due)
        t.ok("all-day, declined and quiet calendars stay quiet", not {"Offsite", "Declined review", "Family dinner"} & set(due), due)
        first = state["due"][0] if state["due"] else {}
        t.ok("its Meet link is found", first.get("service") == "Google Meet" and first.get("link") == link, first)
        t.ok("faces are initials", first.get("people") == ["DS", "FM", "WS", "MR"], first)
        t.ok("one timer, to the next alert in about 15 s", 11 <= state["fireIn"] <= 18, state["fireIn"])
        t.ok("the panel is up", state["shown"], state)
        t.ok("off every screen on a test run", state["frame"][0] < -10000, state["frame"])

        t.ok("the second alerts on time, with no polling", until(lambda: len(alert()["due"]) == 2, within=25), alert())
        late = time.time() - began
        t.ok("about 15 s after the first", 13 <= late <= 19, round(late, 2))
        second = alert()["due"][1]
        t.ok("an unanswered invitation offers Respond", second["pending"] and second["respond"].startswith("ical://ekevent/"), second)
        t.ok("the panel grows for two cards", alert()["frame"][3] > state["frame"][3], alert()["frame"])

        for theme in ("light", "dark"):
            saved, out = shoot(f"alert-{theme}.png", theme == "dark")
            t.ok(f"a picture of the card, {theme}", saved, out)
            print("       ", out)
        t.ok("the probe window is gone again", alert()["shown"] and len(alert()["due"]) == 2)

        state = alert("press", index=1, button="respond")
        t.ok("Respond hands the invitation to Calendar", any(x.startswith("ical://") for x in state["opened"]), state["opened"])
        state = alert("press", index=1, button="snooze")
        t.ok("Snooze puts it away", [d["title"] for d in state["due"]] == ["Design sync"], state["due"])
        t.ok("…until it starts", 20 <= state["fireIn"] <= 60, state["fireIn"])

        state = alert("press", index=0, button="join")
        t.ok("Join opens the meeting's link", link in state["opened"], state["opened"])
        tabs = sv.cmd({"do": "tabs"})["tabs"]
        meet = next((x for x in tabs if x["url"] == link), None)
        t.ok("in a tab in front", meet is not None and meet.get("active"), tabs)
        t.ok("the alert goes", "Design sync" not in [d["title"] for d in state["due"]], state["due"])
        if meet:
            t.ok("the call starts", until(lambda: sv.ev(meet["id"], "window.state") == "started"), sv.ev(meet["id"], "window.state"))
            sv.cmd({"do": "select", "id": idle})
            call = lambda: sv.cmd({"do": "call", "action": "state", "values": []})
            t.ok("leaving it floats the call like any other", until(lambda: call()["showing"]), call())
            t.ok("the floating call is the meeting", call()["tab"].startswith(meet["id"].lower()[:8]), call())

            alert("fixture", lead="1", hosts={"127.0.0.1": "meet"}, events=[
                {"title": "Design sync", "id": "again", "in": 0.2, "link": link},
            ])
            alert("press", index=0, button="join")
            tabs = sv.cmd({"do": "tabs"})["tabs"]
            t.ok("joining again reuses the meeting's tab", sum(1 for x in tabs if x["url"] == link) == 1, [x["url"] for x in tabs])
            t.ok("…and brings the floating call back", until(lambda: not call()["showing"]), call())
            back = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x["url"] == link), {})
            t.ok("…in front", back.get("active"), back)

        state = alert("fixture", lead="1", hosts={"127.0.0.1": "meet"}, events=[
            {"title": "Retro", "in": 3, "link": f"{sv.BASE}/ret-roro-now"},
        ])
        t.ok("three minutes away waits with a minute's lead", state["due"] == [] and 100 <= state["fireIn"] <= 125, state)
        state = alert("set", lead="5")
        t.ok("five minutes' lead shows it now", [d["title"] for d in state["due"]] == ["Retro"], state["due"])
        reads = state["reads"]
        state = alert("press", index=0, button="dismiss")
        t.ok("Dismiss closes it", state["due"] == [] and not state["shown"], state)
        state = alert("changed")
        t.ok("a calendar change reads again", state["reads"] > reads, state)
        t.ok("…and a dismissed alert stays away", state["due"] == [], state["due"])
        t.ok("nothing left to wake for but the next read", state["fireIn"] > 3600, state["fireIn"])

        state = alert("set", on=False)
        t.ok("turned off, nothing runs", not state["running"] and state["fireIn"] == -1 and not state["shown"], state)
        alert("off")
    finally:
        sv.quit()
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()
