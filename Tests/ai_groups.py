#!/usr/bin/env python3
"""Grouping tabs with AI (AIGrouper.swift), in a probe of its own.

Build first, then `python3 Tests/ai_groups.py` from a worktree. Hidden, with
the fake engine (aigroups fake): pages open as a person opens them, related
ones land in one group with a name and an emoji, an unrelated one stays loose,
a page opened later joins, a tab dragged out stays out, a page opened from
inside the folder stays when it belongs and leaves for the row under the folder
when it does not, a renamed group keeps its name, and an ungrouped group doesn't
come back. A result ⌘-clicked from a
search page (the user's shot: "Runner смотреть онлайн на английском") goes into
one folder with that page, under a short name that is not the query. Nothing
calls a model.

`python3 Tests/ai_groups.py --film DIR` uses Apple's on-device model
(SEARCH_REAL_MODEL, engine pinned to This Mac, so no plan can be reached) and
draws the probe's own tab column, still hidden, into DIR again and again while tabs
group, while a group is renamed and while the shot's search is filed. Nothing
else on the screen is captured.
"""
import os
import subprocess
import urllib.parse
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("ai-groups")

TITLES = {
    "flights": "Flights from Berlin to Lisbon",
    "hotels": "Hotels in Lisbon, Alfama district",
    "swiftui": "NavigationSplitView | Apple Developer Documentation",
    "weather": "Weather in Berlin today",
    "swiftdata": "ModelContainer | SwiftData | Apple Developer Documentation",
    "porto": "Porto day trip from Lisbon by train",
    "sintra": "Things to do in Sintra, Portugal",
    "food": "Lisbon food: where to eat pastéis de nata",
    "museums": "Lisbon museums opening hours",
}
QUERY = "Runner смотреть онлайн на английском"
RESULT = "Бегущий в лабиринте (2014) бесплатно смотреть онлайн в хорошем качестве"
TITLES["kino"] = RESULT
FAKE = {
    "kino": RESULT,
    "flights": "Lisbon flights", "hotels": "Lisbon hotels", "swiftui": "Swift docs: NavigationSplitView",
    "weather": "Weather in Berlin", "food": "Lisbon food", "museums": "Lisbon museums", "porto": "Lisbon to Porto trains",
}


class Pages(BaseHTTPRequestHandler):
    titles = TITLES

    def do_GET(self):
        parts = urllib.parse.urlsplit(self.path)
        name = parts.path.strip("/").split("/")[-1]
        title = self.titles.get(name, name)
        if name == "search":
            title = urllib.parse.parse_qs(parts.query).get("q", [""])[0] + " - Поиск"
        body = f"<!doctype html><title>{title}</title><h1>{title}</h1>".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def serve(titles):
    handler = type("P", (Pages,), {"titles": titles})
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_port}"


def launch(*env):
    if os.path.exists(sv.SOCK):
        os.remove(sv.SOCK)
    before = sv.running()
    extra = [part for pair in env for part in ("--env", pair)]
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={sv.W}", *extra, sv.APP])
    for _ in range(150):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update((sv.running() - before) & sv.holding())


def ai(*args):
    return sv.cmd({"do": "aigroups", "args": list(args)})


def ai_groups():
    return [g for g in ai("state")["groups"] if g["ai"]]


ANCHOR = {}


def open_page(base, name):
    return sv.sp("open", url=f"{base}/{name}", **({"from": ANCHOR["id"]} if "id" in ANCHOR else {}))["resultID"]


def anchor():
    blank = next((x["id"] for x in sv.sp("state")["tabs"] if x["blank"]), None)
    if blank:
        ANCHOR["id"] = blank


def wait_for(test, within=10):
    until = time.time() + within
    while time.time() < until:
        value = test()
        if value:
            return value
        time.sleep(0.2)
    return test()


def searching(base):
    subprocess.run(["defaults", "write", sv.SUITE, "search.engine", "-string", "custom"])
    subprocess.run(["defaults", "write", sv.SUITE, "search.custom", "-string", f"{base}/search?q=%s"])


def search_and_click(base):
    page = open_page(base, "search?q=" + urllib.parse.quote(QUERY))
    wait_for(lambda: any(t.get("id") == page and "Поиск" in t.get("title", "") for t in sv.sp("state").get("tabs", [])), 5)
    time.sleep(0.5)
    sv.cmd({"do": "searchfolder", "args": ["click", page, f"{base}/kino"]})
    return page


def filed(page):
    return next((g for g in ai_groups() if page in g["tabs"] and len(g["tabs"]) == 2), None)


def hidden():
    t = sv.T()
    base = serve(FAKE)
    try:
        sv.setup(**{"tabs.groups": True, "ai": True, "ai.groups": True})
        searching(base)
        launch()
        ai("fake", "0.4", "1.0")
        anchor()
        flights, hotels, swift = (open_page(base, n) for n in ("flights", "hotels", "swiftui"))
        groups = wait_for(lambda: [g for g in ai_groups() if g["how"]], 8)
        t.ok("related tabs form one AI group", len(groups) == 1 and sorted(groups[0]["tabs"]) == sorted([flights, hotels]), groups)
        t.ok("it is named and has an emoji", groups and groups[0]["name"] == "Lisbon" and groups[0]["emoji"] == "✈️", groups)
        t.ok("the unrelated tab stays loose", all(swift not in g["tabs"] for g in ai("state")["groups"]), ai("state"))
        passes = ai("state")["passes"]
        t.ok("three tabs opened together took one decision", passes == 1, passes)

        food = open_page(base, "food")
        joined = wait_for(lambda: food in (ai_groups() or [{}])[0].get("tabs", []), 8)
        t.ok("a page opened later joins the group", joined, ai_groups())

        sv.cmd({"do": "group", "id": hotels, "name": "none"})
        museums = open_page(base, "museums")
        wait_for(lambda: museums in (ai_groups() or [{}])[0].get("tabs", []), 8)
        now = ai_groups()[0]
        t.ok("a tab taken out stays out", hotels not in now["tabs"] and museums in now["tabs"], now)
        t.ok("and is remembered as taken out", any("hotels" in key for key in now["refused"]), now)

        trams = sv.sp("open", url=f"{base}/lisbon-trams", **{"from": flights, "foreground": False})["resultID"]
        pasta = sv.sp("open", url=f"{base}/pasta", **{"from": flights, "foreground": False})["resultID"]
        left = wait_for(lambda: (lambda g: g if g and pasta not in g["tabs"] and trams in g["tabs"] else None)((ai_groups() or [None])[0]), 10)
        folder = ai_groups()[0]
        t.ok("a page opened from inside the folder that belongs stays in it", trams in folder["tabs"], folder)
        t.ok("a page opened from inside the folder about something else leaves it", left is not None and all(pasta not in g["tabs"] for g in ai("state")["groups"]), ai("state"))
        t.ok("and is not taken for one the person took out", not any("pasta" in key for key in folder["refused"]), folder)
        row = [x["id"] for x in sv.sp("state")["tabs"]]
        t.ok("it sits right under the folder", pasta in row and row.index(pasta) == max(row.index(x) for x in folder["tabs"]) + 1, (row, folder["tabs"]))
        now = folder

        ai("rename", now["name"], "December")
        weather = open_page(base, "weather")
        time.sleep(2.5)
        named = ai_groups()[0]
        t.ok("a renamed group keeps its name", named["name"] == "December" and named["userNamed"], named)
        t.ok("an unrelated page stays loose", all(weather not in g["tabs"] for g in ai("state")["groups"]), ai("state"))

        members = set(named["tabs"])
        ai("ungroup", "December")
        t.ok("ungrouped: no AI group left", not ai_groups(), ai("state"))
        again = open_page(base, "porto")
        time.sleep(2.5)
        t.ok("its tabs don't come back together", all(len(members & set(g["tabs"])) < 2 for g in ai_groups()), (members, ai_groups()))
        t.ok("a new page may still pair with one of them", any(again in g["tabs"] for g in ai_groups()), ai_groups())

        page = search_and_click(base)
        folder = wait_for(lambda: (lambda g: g if g and g["how"] else None)(filed(page)), 10)
        t.ok("the search page and its result share one folder", folder is not None, ai("state"))
        if folder:
            t.ok("the folder keeps the search for follow-ups", folder["query"] == QUERY, folder)
            t.ok("its name is short and not the query", folder["name"] != QUERY and 1 <= len(folder["name"].split()) <= 3, folder)
            t.ok("the namer gave the name", folder["how"].startswith("model"), folder)
    finally:
        sv.finish()
    t.done()
    return t.failed == 0


def film_column(path, seconds=12):
    taken = []
    until = time.time() + seconds
    while time.time() < until:
        file = f"{path}-{len(taken):03d}.png"
        sv.cmd({"do": "column", "path": file, "height": 640})
        taken.append(file)
    return taken


def film(folder):
    folder = os.path.abspath(folder)
    os.makedirs(folder, exist_ok=True)
    base = serve(TITLES)
    try:
        sv.setup(**{"tabs.groups": True, "ai": True, "ai.groups": True})
        searching(base)
        launch("SEARCH_REAL_MODEL=1")
        ai("mac")
        anchor()
        state = ai("state")
        print("engine", state["engine"], "namer", state["namer"])
        if state["engine"] != "thisMac":
            print("This Mac's model isn't available here: nothing filmed")
            return False
        for name in ("flights", "hotels", "swiftui", "weather", "swiftdata"):
            open_page(base, name)
            time.sleep(0.25)
        shots = film_column(f"{folder}/grouping")
        wait_for(lambda: not ai("state")["busy"], 30)
        print("after grouping", [(g["emoji"], g["name"], len(g["tabs"])) for g in ai_groups()], ai("state")["note"])
        sv.cmd({"do": "column", "path": f"{folder}/column-grouped.png", "height": 640})
        for name in ("porto", "sintra"):
            open_page(base, name)
            time.sleep(0.25)
        shots += film_column(f"{folder}/renaming")
        wait_for(lambda: not ai("state")["busy"], 30)
        print("after renaming", [(g["emoji"], g["name"], len(g["tabs"]), g["how"]) for g in ai_groups()], ai("state")["note"])
        sv.cmd({"do": "column", "path": f"{folder}/column-renamed.png", "height": 640})
        page = search_and_click(base)
        shots += film_column(f"{folder}/searching", 8)
        wait_for(lambda: filed(page) and not ai("state")["busy"], 60)
        print("after the search", [(g["emoji"], g["name"], g["tabs"], g["how"]) for g in ai_groups() if page in g["tabs"]])
        sv.cmd({"do": "column", "path": f"{folder}/column-searched.png", "height": 640})
        print("frames", len(shots))
        return True
    finally:
        sv.finish()


if __name__ == "__main__":
    if sys.argv[1:2] == ["--film"]:
        sys.exit(0 if film(sys.argv[2] if len(sys.argv) > 2 else "ai-groups-film") else 1)
    ok = hidden()
    print("all good" if ok else "FAILED")
    sys.exit(0 if ok else 1)
