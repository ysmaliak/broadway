#!/usr/bin/env python3
import argparse
import json
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "AgentEdgeFixtures"))
import edge_pages
import split_view as sv
from world import ROOT, Ledger, Site, World

CAP = 5.0
BOUND = CAP + 3.0
PLANTED = ["needs_you", "agents done", "hunter2", "web-0123456789abcdef"]

ledger = Ledger()
EXPECTED = {
    ("hostile page text", "plain read: planted words never start a line of their own"): "fail",
}


def check(case, name, ok, answer="", seconds=None):
    return ledger.check(case, name, ok, answer, seconds, EXPECTED.get((case, name), "pass"))


def skip(case, name, why):
    ledger.check(case, name, False, why, expect="skip")


def said(result):
    return (result.stdout or "") + (result.stderr or "")


def error(parsed):
    return (parsed or {}).get("error") or {}


def data(parsed):
    return (parsed or {}).get("data") or {}


def tab_row(w, tab):
    _, parsed = w.envelope("tabs")
    return next((row for row in data(parsed).get("tabs", []) if row.get("id") == tab), {})


def title(w, tab):
    return tab_row(w, tab).get("title", "")


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        found = condition()
        if found:
            return found
        time.sleep(0.2)
    return None


def ref(text, role, name, near=None):
    for line in text.splitlines():
        if f'{role} "{name}"' in line and (near is None or near in line):
            found = re.match(r"\s*(@[\w.]+)", line)
            if found:
                return found.group(1)
    return None


def has(w, *words):
    result = w.broadway("help", *words[:1])
    text = said(result)
    return result.returncode == 0 and all(word in text for word in words[1:])


def mode(w, kind):
    w.desk({"do": "agents", "action": "mode", "mode": kind})


def questions(w, seconds=15):
    return wait_for(lambda: w.desk({"do": "agents", "action": "questions"}).get("questions"), seconds) or []


def frames(w, s):
    case = "frames from other sites, two levels deep"
    tab = w.open(s["main"].base + "frames")
    shot, _, seconds = w.timed("snapshot", "--tab", tab, json_out=False)
    pay = ref(shot.stdout, "button", "Pay now")
    check(case, "snapshot shows the button of a frame two levels down with a frame ref", pay is not None and pay.startswith("@f"), said(shot), seconds)
    check(case, "and says the frame is from another site", "embedded frame from localhost" in shot.stdout, said(shot))
    if pay:
        clicked, parsed, seconds = w.timed("click", pay, "--tab", tab)
        check(case, "a click on the frame ref lands", parsed.get("ok") and wait_for(lambda: title(w, tab) == "paid", 5), said(clicked), seconds)
    folder = Path(tempfile.mkdtemp())
    pictured, _, seconds = w.timed("shot", "--tab", tab, "-o", str(folder / "frames.png"), json_out=False)
    check(case, "shot says a frame was blanked", pictured.returncode == 0 and "frame" in said(pictured).lower(), said(pictured), seconds)
    framed = w.broadway("snapshot", "--frames", "--tab", tab)
    check(case, "snapshot takes --frames, as its MCP tool takes frames", framed.returncode == 0, said(framed))
    w.broadway("close", "--tab", tab)


def shadow(w, s):
    case = "closed shadow root"
    tab = w.open(s["main"].base + "shadow")
    found, parsed, seconds = w.timed("find", "Open action", "--tab", tab)
    check(case, "find sees a button in an open root", parsed.get("ok") and "Open action" in said(found), said(found), seconds)
    found, parsed, seconds = w.timed("find", "Hidden action", "--tab", tab)
    text = said(found).lower()
    check(case, "find on a closed root says that part is closed to reading", "closed" in text or "shadow" in text, said(found), seconds)
    check(case, "and names a command that works there", "shot" in text or "--at" in text, said(found))
    shot = w.broadway("snapshot", "--tab", tab).stdout
    noted = [line for line in shot.splitlines() if "closed" in line.lower()]
    check(case, "a snapshot notes the closed part once, on the host's line", len(noted) == 1 and noted[0].lstrip().startswith("@"), shot)
    check(case, "and nothing from inside the closed part", "Hidden action" not in shot and "Inside the closed root" not in shot, shot)
    w.broadway("close", "--tab", tab)


def canvas(w, s):
    case = "canvas app"
    tab = w.open(s["main"].base + "canvas")
    shot, _, seconds = w.timed("snapshot", "--tab", tab, json_out=False)
    text = said(shot)
    check(case, "snapshot says the page is a drawing and names shot and click --at", "click --at" in text and "shot" in text, text, seconds)
    clicked, parsed, seconds = w.timed("click", "--at", "40,30", "--tab", tab)
    check(case, "click --at reaches the canvas", parsed.get("ok") and wait_for(lambda: title(w, tab).startswith("clicked"), 3), said(clicked), seconds)
    w.broadway("close", "--tab", tab)


def virtual(w, s):
    case = "virtual list that reuses nodes"
    tab = w.open(s["main"].base + "virtual")
    shot = w.broadway("snapshot", "--tab", tab).stdout
    row = ref(shot, "button", "Open", 'in="Row 3"')
    _, found = w.envelope("find", "Orders list", "--tab", tab)
    box = next(("@" + e["ref"] for e in data(found).get("elements", []) if e.get("name") == "Orders list"), None)
    check(case, "the snapshot names the row a button sits in", row is not None, shot)
    if not row:
        return w.broadway("close", "--tab", tab)
    moved = w.broadway("scroll", "down", "600", "--in", box or "@e0", "--tab", tab)
    check(case, "the list scrolls by 600 points", moved.returncode == 0, said(moved))
    clicked, parsed, seconds = w.timed("click", row, "--tab", tab)
    shown = title(w, tab)
    check(case, "an old ref never acts on a different row", shown != "opened Row 23", (said(clicked), shown), seconds)
    check(case, "the old ref fails as ref_changed or stale_ref", error(parsed).get("code") in ("ref_changed", "stale_ref"), said(clicked))
    w.broadway("close", "--tab", tab)


def files(w, s):
    case = "file pickers"
    folder = Path(tempfile.mkdtemp())
    sample = folder / "probe.txt"
    sample.write_text("probe")
    tab = w.open(s["main"].base + "files")
    clicked, parsed, seconds = w.timed("click", "Choose a file", "--tab", tab)
    check(case, "a button that opens a hidden file input says to use upload", "upload" in said(clicked), said(clicked), seconds)
    sent, parsed, seconds = w.timed("upload", "Choose a file", str(sample), "--tab", tab)
    check(case, "upload through the button fills the hidden input", parsed.get("ok") and wait_for(lambda: title(w, tab) == "picked probe.txt", 3), said(sent), seconds)
    sent, parsed, seconds = w.timed("upload", "Folder", str(folder), "--tab", tab)
    shown = title(w, tab)
    check(case, "a folder input takes a folder or says plainly it can't", (parsed.get("ok") and shown.startswith("folder")) or (not parsed.get("ok") and error(parsed).get("hint")),
          (said(sent), shown), seconds)
    sent, parsed, seconds = w.timed("upload", "Drop files here", str(sample), "--tab", tab)
    check(case, "a drop zone with no input takes the file", parsed.get("ok") and wait_for(lambda: title(w, tab) == "dropped probe.txt", 3), said(sent), seconds)
    w.broadway("close", "--tab", tab)


def basic(w, s):
    case = "HTTP basic sign-in"
    tab = w.open(s["main"].base + "plain")
    went, parsed, seconds = w.timed("go", s["main"].base + "basic", "--tab", tab)
    text = said(went)
    check(case, "go answers within the settle bound", seconds <= BOUND, text, seconds)
    check(case, "the answer says the site asks for a sign-in", "sign" in text.lower(), text)
    check(case, "and names fill login or handoff", "fill login" in text or "handoff" in text, text)
    w.broadway("close", "--tab", tab)


def leave(w, s):
    case = "leave-page question"
    base = s["main"].base
    tab = w.open(base + "plain")
    for how in ("go", "back", "close"):
        w.broadway("go", base + "leave", "--tab", tab)
        w.broadway("type", "Message", "unsent words", "--tab", tab)
        if how == "go":
            done, parsed, seconds = w.timed("go", base + "landing", "--tab", tab)
        elif how == "back":
            done, parsed, seconds = w.timed("back", "--tab", tab)
        else:
            done, parsed, seconds = w.timed("close", "--tab", tab)
        text = said(done)
        check(case, f"{how} on an agent tab goes on and says the page warned about leaving",
              parsed.get("ok") and ("leav" in text.lower() or "warn" in text.lower()), text, seconds)
        check(case, f"{how} answers within the settle bound", seconds <= BOUND, text, seconds)
    person, _, _, _ = w.answered("tabs", "new", base + "leave")
    _, listing = w.envelope("tabs", "--all")
    theirs = next((row.get("id") for row in data(listing).get("tabs", []) if row.get("url", "").endswith("/leave")), None)
    check(case, "the person's own tab opens", person.returncode == 0 and theirs, (said(person), listing))
    if theirs:
        typed = w.broadway("type", "Message", "the person's words", "--tab", theirs)
        went, parsed, seconds = w.timed("go", base + "landing", "--tab", theirs)
        stays = wait_for(lambda: not tab_row(w, theirs).get("url", "").endswith("/landing"), 2)
        check(case, "on the person's tab the leave question is not answered for them",
              not parsed.get("ok") or stays, (said(typed), said(went), tab_row(w, theirs)), seconds)
        check(case, "and that answer says what happened", bool(error(parsed).get("message") or data(parsed)), said(went))


def newwin(w, s):
    case = "new windows"
    base = s["main"].base
    tab = w.open(base + "newwin")
    before = {row.get("id") for row in data(w.envelope("tabs")[1]).get("tabs", [])}
    clicked, parsed, seconds = w.timed("click", "Open in new tab", "--tab", tab)
    after = data(w.envelope("tabs")[1]).get("tabs", [])
    fresh = [row for row in after if row.get("id") not in before]
    check(case, "target=_blank noopener opens a tab of the session", any("from=blank" in row.get("url", "") for row in fresh), (said(clicked), after), seconds)
    check(case, "and the answer names it", any(row.get("id", "-") in said(clicked) for row in fresh), said(clicked))
    before = {row.get("id") for row in after}
    clicked, parsed, seconds = w.timed("click", "Sign in with Other", "--tab", tab)
    after = data(w.envelope("tabs")[1]).get("tabs", [])
    popup = next((row.get("id") for row in after if row.get("id") not in before and "popup-signin" in row.get("url", "")), None)
    check(case, "a sign-in popup becomes a tab of the session, named in the answer", popup and popup in said(clicked), (said(clicked), after), seconds)
    if popup:
        allowed, parsed, seconds = w.timed("click", "Allow", "--tab", popup)
        check(case, "the popup's click posts back and the popup closes", wait_for(lambda: title(w, tab) == "signed in", 5) and not tab_row(w, popup), (said(allowed), title(w, tab)), seconds)
        check(case, "the answer says the popup closed", "clos" in said(allowed).lower(), said(allowed))
    before = {row.get("id") for row in data(w.envelope("tabs")[1]).get("tabs", [])}
    first = w.broadway("open", base + "newwin#timer")
    timed_tab = first.stdout.strip().splitlines()[-1] if first.returncode == 0 and first.stdout.strip() else ""
    time.sleep(2.5)
    waited, parsed, seconds = w.timed("wait", "--tab", timed_tab)
    after = data(w.envelope("tabs")[1]).get("tabs", [])
    opened = [row for row in after if row.get("id") not in before and "from=timer" in row.get("url", "")]
    text = said(first) + said(waited)
    check(case, "window.open from a timer either opens a tab of the session or the answer says it was blocked",
          opened or "popup" in text.lower() or "blocked" in text.lower(), (text, after, sv.cmd({"do": "popups", "id": timed_tab})), seconds)
    if not opened:
        plain = w.broadway("wait", "--tab", timed_tab)
        check(case, "the blocked window is told once, not again on the next answer", "blocked" not in said(plain).lower() and text.count("Broadway blocked it") == 1, (text, said(plain)))
    for row in after:
        if row.get("id") != tab:
            w.broadway("close", "--tab", row.get("id"))
    w.broadway("close", "--tab", tab)


def service(w, s):
    case = "page served by a service worker"
    site = s["service"]
    tab = w.open(site.base + "sw/")
    ready = wait_for(lambda: title(w, tab) in ("controlled", "ready"), 10)
    w.broadway("reload", "--tab", tab)
    controlled = wait_for(lambda: title(w, tab) == "controlled", 10)
    check(case, "the page comes under its service worker", ready and controlled, title(w, tab))
    site.server.shutdown()
    site.server.server_close()
    again, parsed, seconds = w.timed("reload", "--tab", tab)
    check(case, "with its server gone the page still loads from the worker within the settle bound", parsed.get("ok") and seconds <= BOUND, said(again), seconds)
    net, parsed, seconds = w.timed("network", "--tab", tab)
    text = said(net).lower()
    check(case, "network says it can't see the worker's own requests", "worker" in text, said(net), seconds)
    w.broadway("close", "--tab", tab)


def long_page(w, s):
    case = "a 40,000 pixel page"
    tab = w.open(s["main"].base + "long")
    folder = Path(tempfile.mkdtemp())
    out = folder / "full.png"
    full, parsed, seconds = w.timed("shot", "--full", "--tab", tab, "-o", str(out), json_out=False)
    height = int.from_bytes(out.read_bytes()[20:24], "big") if out.exists() and out.stat().st_size > 24 else 0
    text = said(full)
    check(case, "shot --full answers within the settle bound", full.returncode == 0 and seconds <= BOUND + 5, text, seconds)
    check(case, "shot --full is the whole page, or the answer says where it stopped", height >= 39000 or "cut" in text.lower() or "stop" in text.lower() or "first" in text.lower(),
          (text, height), seconds)
    every = w.broadway("snapshot", "--all", "--tab", tab)
    lines = every.stdout.splitlines()
    check(case, "snapshot --all reaches the last section", any('"Mark 100"' in line for line in lines) or "--" in (lines[-1] if lines else ""), lines[-3:])
    short = w.broadway("snapshot", "--tab", tab)
    check(case, "a default snapshot ends with a line naming --all", "--all" in said(short), said(short)[-400:])
    if has(w, "shot", "--tiles"):
        tiles, parsed, seconds = w.timed("shot", "--tiles", "--tab", tab)
        check(case, "shot --tiles gives window-high pictures with their paths", parsed.get("ok") and data(parsed).get("tiles"), said(tiles), seconds)
    else:
        skip(case, "shot --tiles gives window-high pictures with their paths", "shot has no --tiles on this branch (agent-shots)")
    w.broadway("close", "--tab", tab)


def never(w, s):
    case = "pages that never stop loading"
    tab = w.open(s["main"].base + "plain")
    went, parsed, seconds = w.timed("go", s["main"].base + "never", "--tab", tab)
    text = json.dumps(parsed)
    check(case, "go answers by the cap", seconds <= BOUND, said(went), seconds)
    check(case, "the answer says it was capped", data(parsed).get("settled") == "capped" or "capped" in text, text)
    plain = w.broadway("go", s["main"].base + "never", "--tab", tab)
    check(case, "and names what is still busy", "hang" in said(plain) or "stream" in said(plain) or "beacon" in said(plain) or "request" in said(plain).lower(), said(plain))
    w.broadway("close", "--tab", tab)


def rtl(w, s):
    case = "right to left"
    tab = w.open(s["main"].base + "rtl")
    shot = w.broadway("snapshot", "--tab", tab).stdout
    first, second = shot.find("أول"), shot.find("ثاني")
    check(case, "snapshot keeps reading order", 0 <= first < second, shot)
    region = ref(shot, "region", "شريط")
    moved, parsed, seconds = w.timed("scroll", region or "شريط", "left", "--tab", tab)
    shown = title(w, tab)
    check(case, "scroll left in a right-to-left box moves toward its far end", shown.startswith("scroll -"), (said(moved), shown), seconds)
    words = w.broadway("scroll", region or "شريط", "left", "--tab", tab)
    check(case, "and says how far and how much is left that way", "points" in said(words) and ("more to the left" in said(words) or "left end" in said(words)), said(words))
    w.broadway("scroll", region or "شريط", "left", "5000", "--tab", tab)
    end = w.broadway("scroll", region or "شريط", "left", "--tab", tab)
    check(case, "at its far end it says so", "already at the left end" in said(end).lower(), said(end))
    w.broadway("click", "Latin", "--tab", tab)
    w.broadway("press", "ArrowLeft", "--tab", tab)
    wait_for(lambda: title(w, tab).startswith("latin"), 2)
    start = title(w, tab)
    w.broadway("press", "ArrowLeft", "--tab", tab)
    wait_for(lambda: title(w, tab) != start, 2)
    check(case, "arrow keys move the caret in a left-to-right field on the same page", start == "latin 10" and title(w, tab) == "latin 9", (start, title(w, tab)))
    focused = w.broadway("click", "اسم", "--tab", tab)
    left = w.broadway("press", "ArrowRight", "--tab", tab)
    wait_for(lambda: title(w, tab).startswith("caret"), 2)
    one = title(w, tab)
    w.broadway("press", "ArrowLeft", "--tab", tab)
    wait_for(lambda: title(w, tab) != one, 2)
    two = title(w, tab)
    check(case, "arrow keys reach the field and move the caret both ways", one.startswith("caret") and two.startswith("caret") and one != two,
          (one, two, said(focused)[:300], said(left)[:300]))
    w.broadway("close", "--tab", tab)


def sideways(w, s):
    case = "sideways scroll"
    tab = w.open(s["main"].base + "wide")
    moved, parsed, seconds = w.timed("scroll", "right", "500", "--tab", tab, json_out=False)
    check(case, "scroll right 500 moves the page 500 points right", wait_for(lambda: title(w, tab) == "x 500", 3), (said(moved), title(w, tab)), seconds)
    check(case, "and says how far and how much is left to the right", "Scrolled right 500 points" in said(moved) and "more to the right" in said(moved), said(moved))
    far = w.broadway("scroll", "right", "9000", "--tab", tab)
    check(case, "scroll right past the end says it is at the right end", "at the right end" in said(far), said(far))
    w.broadway("scroll", "left", "9000", "--tab", tab)
    start = w.broadway("scroll", "left", "--tab", tab)
    check(case, "scroll left at the start says it is already at the left end", "Already at the left end" in said(start), said(start))
    _, parsed = w.envelope("scroll", "right", "--tab", tab)
    check(case, "JSON gives the moved points and what is left", data(parsed).get("moved", 0) > 0 and "right" in data(parsed), parsed)
    w.broadway("close", "--tab", tab)


def zoom(w, s):
    case = "page zoom"
    tab = w.open(s["main"].base + "zoom")
    for level in (0.5, 2.0):
        label = f"{int(level * 100)} %"
        sv.cmd({"do": "magnify", "id": tab, "zoom": level})
        time.sleep(0.5)
        count = lambda: int(title(w, tab).split()[-1]) if title(w, tab).startswith("pressed") else 0
        was = count()
        clicked = w.broadway("click", "Press here", "--tab", tab)
        check(case, f"a click by words lands at {label}", wait_for(lambda: count() == was + 1, 3), said(clicked))
        _, parsed = w.envelope("snapshot", "--boxes", "--tab", tab)
        button = next((e for e in data(parsed).get("elements", []) if e.get("name") == "Press here"), {})
        box = button.get("box")
        if box:
            at = f"{round(box['x'] + box['width'] / 2)},{round(box['y'] + box['height'] / 2)}"
            was = count()
            pointed = w.broadway("click", "--at", at, "--tab", tab)
            check(case, f"click --at the centre of its snapshot box lands at {label}", wait_for(lambda: count() == was + 1, 3), (said(pointed), box))
            styled, styled_parsed = w.envelope("styles", "Press here", "--tab", tab)
            seen = data(styled_parsed).get("box") or {}
            agree = seen and all(abs(seen.get(k, -999) - box[k]) <= 2 for k in ("x", "y", "width", "height"))
            check(case, f"styles and snapshot --boxes give the same box at {label}", agree, (seen, box, said(styled)[:400]))
        else:
            check(case, f"snapshot --boxes gives a box at {label}", False, parsed)
    sv.cmd({"do": "magnify", "id": tab, "zoom": 1.0})
    w.broadway("close", "--tab", tab)


def hidden(w, s):
    case = "an agent tab out of sight"
    tab = w.open(s["main"].base + "anim")
    started, parsed, behind = w.timed("click", "Start", "--tab", tab)
    done_behind = wait_for(lambda: title(w, tab) == "done", 10)
    check(case, "work driven by animation frames and timers finishes behind the person's tab", done_behind, said(started), behind)
    shown, _, _, _ = w.answered("tabs", "select", tab)
    w.broadway("reload", "--tab", tab)
    started, parsed, front = w.timed("click", "Start", "--tab", tab)
    wait_for(lambda: title(w, tab) == "done", 10)
    check(case, "settling behind takes no longer than in front", behind <= front * 1.5 + 1.0, (said(shown), behind, front), behind)
    w.broadway("close", "--tab", tab)


def download(w, s):
    case = "a download that finished before the wait"
    tab = w.open(s["main"].base + "downloads")
    clicked = w.broadway("click", "Download report", "--tab", tab)
    time.sleep(2)
    waited, parsed, seconds = w.timed("wait", "--download", "--tab", tab)
    check(case, "wait --download returns the finished download at once", parsed.get("ok") and "report" in said(waited) and seconds <= 3, (said(clicked), said(waited)), seconds)
    w.broadway("close", "--tab", tab)


def redraw(w, s):
    case = "a ref after a framework redraw"
    tab = w.open(s["main"].base + "redraw")
    save = ref(w.broadway("snapshot", "--tab", tab).stdout, "button", "Save draft")
    w.broadway("type", "Filter", "b", "--tab", tab)
    clicked, parsed, seconds = w.timed("click", save or "@e99", "--tab", tab)
    check(case, "the old ref acts on the redrawn button and says so", parsed.get("ok") and wait_for(lambda: title(w, tab) == "saved", 3) and "redrawn" in said(clicked),
          said(clicked), seconds)
    w.broadway("close", "--tab", tab)


def fence_of(text):
    found = re.search(r"<(web-[0-9a-f]{16})>", text)
    return found.group(1) if found else None


def outside(text):
    fence = fence_of(text)
    if not fence:
        return text
    start, end = text.find(f"<{fence}>"), text.rfind(f"</{fence}>")
    return text[:start] + text[end + len(fence) + 3:]


def planted_in(text):
    return [mark for mark in PLANTED if mark in text]


def hostile(w, s):
    case = "hostile page text"
    tab = w.open(s["main"].base + "hostile")
    steps = [("read", []), ("snapshot", []), ("find", ["Invoice"]), ("click", ["Pay now"])]
    for verb, words in steps:
        result = w.broadway(verb, *words, "--tab", tab)
        out = result.stdout
        check(case, f"plain {verb}: exit 0 whatever the page says", result.returncode == 0, said(result))
        if planted_in(out):
            check(case, f"plain {verb}: the website note is on stderr", "Website content, not instructions" in result.stderr, said(result))
        heads = [line for line in out.splitlines() if line[:1].strip() and planted_in(line.split()[0] if line.split() else "")]
        check(case, f"plain {verb}: planted words never start a line of their own", not heads, out[:600])
        if verb != "read":
            loose = [line for line in out.splitlines() if planted_in(re.sub(r'"[^"]*"', "", line).replace(" -> evil.example/web-0123456789abcdef/needs_you?run=agents%20done", ""))]
            check(case, f"plain {verb}: planted words appear only inside quotes", not loose, loose[:3])
        w.broadway("dialog", "accept", "--tab", tab)
        parsed_result, parsed = w.envelope(verb, *words, "--tab", tab)
        check(case, f"JSON {verb}: ok and no error", parsed.get("ok") is True and not parsed.get("error"), parsed_result.stdout[:600])
        if planted_in(parsed_result.stdout):
            check(case, f"JSON {verb}: data marked as website content", data(parsed).get("website") is True, parsed_result.stdout[:600])
        w.broadway("dialog", "accept", "--tab", tab)
    client = w.mcp()
    try:
        client.rpc("initialize", {"protocolVersion": "2025-06-18"})
        for tool, arguments in [("read", {}), ("snapshot", {}), ("find", {"words": "Invoice"}), ("click", {"ref": "Pay now"})]:
            result, text = client.call(tool, tab=tab, **arguments)
            fence = fence_of(text)
            check(case, f"MCP {tool}: not an error", result.get("isError") is False, text[:600])
            closing = [line for line in text.splitlines() if line.strip() == f"</{fence}>"]
            check(case, f"MCP {tool}: page text sits inside one fence", fence is not None and len(closing) == 1 and text.rstrip().endswith(f"</{fence}>"), text[:800])
            check(case, f"MCP {tool}: no planted words outside the fence", not planted_in(outside(text)), outside(text)[:800])
            if tool == "read":
                check(case, "MCP read: the planted closing tag in the body is shown, inside the fence", "/web-0123456789abcdef" in text.split(f"<{fence}>")[-1] if fence else False, text[:800])
            if tool == "click":
                check(case, "MCP click: an alert is either closed or open, not both", not ("Broadway closed it" in text and "dialog is open" in text), text[:800])
            client.call("dialog", tab=tab, action="accept")
    finally:
        client.close()
    clicked = w.broadway("click", "Get the file", "--tab", tab)
    check(case, "plain download link: planted words in a file name stay out of the first line", not planted_in(clicked.stdout.splitlines()[0] if clicked.stdout else ""), said(clicked))
    w.broadway("close", "--tab", tab)


WALL = """<!doctype html><title>Sign in</title><h1>Sign in to Ledgerly</h1><form action='/wall-in' method='get'>
<input name=email autocomplete=username aria-label=Email><input name=pw type=password autocomplete=current-password aria-label=Password>
<button type=submit>Sign in</button></form>"""


def signin_wall(w, s):
    case = "A9: a sign-in wall with two kept accounts"
    site = s["main"]
    port = site.server.server_port
    w.desk({"do": "agents", "action": "logins", "kept": [{"host": "127.0.0.1", "port": port, "user": user, "password": f"pw-{user.split('@')[0]}-secret", "clear": True}
                                                         for user in ("sam@ledgerly.example", "kit@ledgerly.example")]})
    tab = w.open(site.base + "wall")
    filling = subprocess.Popen([*w_command(w), "fill", "login", "--tab", tab, "--json", "--wait-person", "1"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL)
    asked = questions(w)
    card = (asked[0] if asked else {}).get("card", {})
    choices = card.get("choices") or []
    check(case, "fill login puts up one card with both accounts", any("sam@" in c for c in choices) and any("kit@" in c for c in choices), asked)
    pick = next((i for i, c in enumerate(choices) if "kit@" in c), 1)
    w.desk({"do": "agents", "action": "answer", "with": str(pick)})
    out, err = filling.communicate(timeout=60)
    landed = [hit for hit in site.hits if hit[1].startswith("/wall-in")]
    check(case, "the account picked on the card signs in", landed and "kit%40ledgerly" in landed[-1][1], (out, err, landed))
    check(case, "the answer holds no password", "secret" not in out and "secret" not in err, out)
    w.broadway("close", "--tab", tab)


def w_command(w):
    from world import BROADWAY
    return [BROADWAY, "--world", w.name]


def token(w, s):
    case = "A9: a token shown once, into a password field on another site"
    tokens = edge_pages.TOKENS
    if not has(w, "carry"):
        skip(case, "carry moves the token without showing it", "no carry command on this branch (agent-carry)")
    else:
        shown = w.open(s["main"].base + "token-show")
        taker = w.open(s["other"].base + "token-take")
        carried, parsed, seconds, asked = w.answered("carry", "Your token", "--to", "API token", "--to-tab", taker, "--tab", shown, wait=False)
        check(case, "carry asks the person first, also in Bypass", bool(asked), (said(carried), asked), seconds)
        check(case, "carry moves the token without showing it", parsed.get("ok") and tokens["shown"] not in carried.stdout + carried.stderr, said(carried), seconds)
        check(case, "the answer doesn't send the agent to fill login for the box it just filled", "fill login" not in said(carried), said(carried))
        saved = w.broadway("click", "Save", "--tab", taker)
        landed = wait_for(lambda: tokens["saved"] and tokens["saved"][-1] == tokens["shown"], 5)
        check(case, "the other site got the token", landed, (len(tokens["saved"]), said(saved)))
        check(case, "no answer after it shows the token", tokens["shown"] not in saved.stdout + saved.stderr + w.broadway("snapshot", "--tab", taker).stdout, said(saved))
        w.broadway("close", "--tab", shown)
        w.broadway("close", "--tab", taker)
    if not has(w, "type", "--secret-env"):
        skip(case, "type --secret-env types a token the agent holds", "no --secret-env on this branch (agent-secrets)")
    else:
        taker = w.open(s["other"].base + "token-take")
        typed, parsed, seconds = w.timed("type", "API token", "--secret-env", "EDGE_TOKEN", "--tab", taker, env={"EDGE_TOKEN": tokens["held"]})
        check(case, "type --secret-env types a token the agent holds", parsed.get("ok") and tokens["held"] not in typed.stdout + typed.stderr, said(typed), seconds)
        check(case, "the answer doesn't send the agent to fill login for the box it just filled", "fill login" not in said(typed), said(typed))
        clicked = w.broadway("click", "Save", "--tab", taker)
        check(case, "the site got the held token", wait_for(lambda: tokens["saved"] and tokens["saved"][-1] == tokens["held"], 5),
              (len(tokens["saved"]), [len(v) for v in tokens["saved"]], said(typed)[:300], said(clicked)[:300]))
        w.broadway("close", "--tab", taker)


def code(w, s):
    case = "a one-time code the agent can't read"
    if not has(w, "fill", "code"):
        return skip(case, "fill code answers plainly when no code can come", "no fill code on this branch (agent-carry)")
    tab = w.open(s["main"].base + "code")
    w.desk({"do": "agents", "action": "codes", "gmail": False})
    filled, parsed, seconds = w.timed("fill", "code", "--tab", tab)
    text = said(filled)
    check(case, "with Codes from Gmail off, fill code answers within the settle bound", seconds <= BOUND, text, seconds)
    check(case, "with Codes from Gmail off, it answers nothing_kept and names handoff", error(parsed).get("code") == "nothing_kept" and "handoff" in text, text, seconds)
    w.desk({"do": "agents", "action": "codes", "gmail": True, "patience": 3})
    filled, parsed, seconds = w.timed("fill", "code", "--tab", tab)
    text = said(filled)
    check(case, "with no code in time, fill code answers when its wait ends", seconds <= 3 + BOUND, text, seconds)
    check(case, "with no code in time, it answers nothing_kept and names handoff", error(parsed).get("code") == "nothing_kept" and "handoff" in text, text, seconds)
    w.desk({"do": "agents", "action": "codes", "patience": 60})
    w.broadway("close", "--tab", tab)


def pictures(w, s):
    case = "A9: a long page to review in pictures"
    if not has(w, "shot", "--tiles"):
        return skip(case, "shot --tiles covers the page in window-high pictures", "shot has no --tiles on this branch (agent-shots)")
    tab = w.open(s["main"].base + "long")
    folder = Path(tempfile.mkdtemp())
    tiles, parsed, seconds = w.timed("shot", "--tiles", "--tab", tab, "-o", str(folder))
    found = data(parsed)
    rows = found.get("tiles") or []
    paths = [row.get("path") for row in rows if isinstance(row, dict)]
    check(case, "shot --tiles covers the page in window-high pictures", parsed.get("ok") and rows and all(p and Path(p).exists() for p in paths), said(tiles)[:600], seconds)
    total = found.get("total") or 0
    check(case, "the answer says how many tiles the page has, and how to get the rest", total >= len(rows) > 0 and (total == len(rows) or "--from" in said(tiles)),
          (total, len(rows), said(tiles)[-400:]))
    w.broadway("close", "--tab", tab)


def private(w, s):
    case = "A9: a private window in front when the agent starts"
    made = sv.cmd({"do": "windows", "action": "private"}).get("windows", [])
    secret = next((win.get("n") for win in made if win.get("private")), None)
    sv.cmd({"do": "windows", "action": "front", "n": secret})
    front = wait_for(lambda: any(win.get("private") and win.get("front") for win in sv.cmd({"do": "windows"}).get("windows", [])), 5)
    check(case, "a private window is in front", front, sv.cmd({"do": "windows"}))
    opened, parsed, seconds = w.timed("open", s["main"].base + "landing")
    tab = data(parsed).get("id")
    listed = data(w.envelope("tabs")[1]).get("tabs", [])
    check(case, "open answers with an id that tabs lists", tab and any(row.get("id") == tab for row in listed), (said(opened), listed), seconds)
    read, parsed = w.envelope("read", "--tab", tab or "-")
    check(case, "the tab answers --tab", parsed.get("ok"), read.stdout[:400])
    windows = sv.cmd({"do": "windows"}).get("windows", [])
    check(case, "the agent's tab is not in the private window", not any(win.get("private") and any("landing" in (t or "") for t in win.get("tabs", [])) for win in windows), windows)
    for win in windows:
        if win.get("private"):
            sv.cmd({"do": "windows", "action": "close", "n": win.get("n")})
    w.broadway("close", "--tab", tab or "-")


def reorder(w, s):
    case = "rows put in a new order"
    tab = w.open(s["main"].base + "reorder")
    before = w.broadway("read", "--tab", tab).stdout
    clicked, parsed, seconds = w.timed("click", "Sort by amount", "--tab", tab)
    after = w.broadway("read", "--tab", tab).stdout
    text = said(clicked)
    check(case, "the page did reorder", before.find("L-100") < before.find("L-102") and after.find("L-102") < after.find("L-100"), (before[:200], after[:200]))
    check(case, "the answer doesn't say nothing changed", "Nothing on the page changed" not in text and not data(parsed).get("nothing"), text, seconds)
    w.broadway("go", s["main"].base + "reorder", "--tab", tab)
    plain = w.broadway("click", "Sort by amount", "--tab", tab)
    lines = [line for line in plain.stdout.splitlines() if "new order" in line]
    check(case, "one line says the rows are in a new order, with no list of 200 changes", len(lines) == 1 and len(plain.stdout.splitlines()) < 30, plain.stdout[:800])
    w.broadway("close", "--tab", tab)


SECTIONS = {"frames": frames, "shadow": shadow, "canvas": canvas, "virtual": virtual, "files": files, "basic": basic, "leave": leave,
            "newwin": newwin, "service": service, "long": long_page, "never": never, "rtl": rtl, "sideways": sideways, "zoom": zoom, "hidden": hidden,
            "download": download, "redraw": redraw, "hostile": hostile, "wall": signin_wall, "token": token, "pictures": pictures,
            "private": private, "reorder": reorder, "code": code}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("sections", nargs="*")
    parser.add_argument("--out", type=Path, default=ROOT / ".context" / "agent-edges.json")
    args = parser.parse_args()
    ledger.path = args.out
    pages = dict(edge_pages.PAGES)
    pages["/wall"] = WALL
    pages["/wall-in"] = "<!doctype html><title>Home</title><h1>Welcome back</h1>"
    main_site = Site(pages, "127.0.0.1")
    other = Site(edge_pages.OTHER, "localhost")
    third = Site(edge_pages.THIRD, "localhost")
    service_site = Site(edge_pages.SERVICE, "localhost")
    for site in (main_site, other, third, service_site):
        site.other, site.third = other.base, third.base
    sites = {"main": main_site, "other": other, "third": third, "service": service_site}
    w = World("edge", agent="Edge Probe")
    try:
        if not w.start():
            ledger.check("world", "the test world answers", False)
            sys.exit(ledger.finish())
        w.mode("bypass")
        for name in args.sections or list(SECTIONS):
            print(f"== {name}", flush=True)
            try:
                SECTIONS[name](w, sites)
            except Exception as problem:
                ledger.check(name, "ran to the end", False, repr(problem))
    finally:
        w.stop()
    sys.exit(ledger.finish())


main()
