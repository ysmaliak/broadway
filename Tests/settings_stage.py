#!/usr/bin/env python3
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("set-stage")
ROOT = Path(__file__).resolve().parents[1]
TMP = Path(os.environ.get("TMPDIR", "/tmp"))
SHOT = TMP / f"settings-stage-shot-{os.getpid()}"
FILM = TMP / f"settings-stage-film-{os.getpid()}"
FILMS = os.environ.get("SETTINGS_STAGE_FILMS")
DETAILS = ["linkrule", "livefolder", "languages"]
PICTURED = ["appearance", "websites", "tabs", "agents", "passwords", "privacy"]


def stage():
    return sv.cmd({"do": "settings", "find": "", "stage": True})["stage"]


def ui(**what):
    sv.cmd({"do": "ui", **what})


def go(kind, name, wait=0.8):
    ui(settingsFind="")
    time.sleep(0.2)
    ui(**{"settingsPage" if kind == "page" else "settingsDetail": name})
    time.sleep(wait)


def middle(box):
    return box[0] + box[2] / 2


def inside(inner, outer, slack=1.0):
    return (inner[0] >= outer[0] - slack and inner[1] >= outer[1] - slack
            and inner[0] + inner[2] <= outer[0] + outer[2] + slack and inner[1] + inner[3] <= outer[1] + outer[3] + slack)


def landed(t, words, group, page, row, how):
    ui(settingsFind=words)
    time.sleep(0.8)
    ui(settingsPress="settings.result." + group)
    time.sleep(0.7)
    s = stage()
    lit = s.get("lit") or [0, 0, 0, 0]
    t.ok(f"“{words}” opens {page} with its band{how}", s["title"] == page and not s["folded"], s)
    t.ok(f"{row} is lit, wholly between the band and the foot of the pane{how}",
         lit[3] > 0 and lit[1] >= s["band"][1] + s["band"][3] - 0.5 and lit[1] + lit[3] <= s["pane"][1] + s["pane"][3] + 0.5,
         (lit, s["band"], s["pane"]))
    time.sleep(1.2)


def windows(pid):
    out = subprocess.run([str(SHOT), str(pid), "list"], capture_output=True, text=True).stdout
    return [line.split("\t") for line in out.splitlines() if line.count("\t") == 2]


def film(pid, number, name, seconds, act):
    if not FILMS or number is None:
        act()
        return
    path = Path(FILMS) / f"{name}.mp4"
    taking = subprocess.Popen([str(FILM), str(pid), number, str(path), str(seconds)], stdout=subprocess.PIPE, text=True)
    taking.stdout.readline()
    time.sleep(0.5)
    act()
    print(" ", (taking.communicate()[0] or "").strip())


def main():
    t = sv.T()
    number = None
    sv.setup(spaces=True, ai=True, **{"start.fresh": True})
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK): break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        if FILMS:
            Path(FILMS).mkdir(parents=True, exist_ok=True)
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/SettingsShot.swift"), "-o", str(SHOT)], check=True)
            subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/SettingsFilm.swift"), "-o", str(FILM)], check=True)
            mine = {w[0] for w in windows(pid)}
        ui(settings=True)
        time.sleep(1.5)
        if FILMS:
            fresh = [w for w in windows(pid) if w[0] not in mine]
            number = fresh[0][0] if fresh else None
            if number is None: print("no Settings window to film", windows(pid))
        for rule in (["pattern", "github.com/*/pull/*", "front"], ["add", "notion.so", "peek"]):
            sv.cmd({"do": "route", "args": rule})
        for live in (["on"], ["add", "Pull Requests", "https://github.com/pulls"]):
            sv.cmd({"do": "live", "args": live})
        ui(look="dark")
        ui(settingsSize=[860, 640])
        time.sleep(0.5)

        print("the six places whose settings change the picture have their band, the rest start with their heading")
        pages = sv.cmd({"do": "settings"}).get("pages", [])
        titles = {}
        for kind, name in [("page", p) for p in pages] + [("detail", d) for d in DETAILS]:
            go(kind, name)
            s = stage()
            titles[name] = s.get("title", "")
            if name not in PICTURED:
                t.ok(f"{name}: no band, and the rows start where the page does", s["folded"] and s["height"] == 0
                     and abs(s["offset"] + s["insetTop"]) < 0.5, s)
                t.ok(f"{name}: the page starts with its heading, and a detail says where it is",
                     bool(s["heading"]) and bool(s["headingCrumb"]) == (kind == "detail"), (s["heading"], s["headingCrumb"]))
                titles[name] = s["heading"]
                continue
            t.ok(f"{name}: no second heading under the band", s["heading"] == "", s["heading"])
            t.ok(f"{name}: the header is open at its full height", not s["folded"] and not s["compact"]
                 and s["height"] > 200 and s["well"][3] == s["height"] and not s["lined"], s)
            t.ok(f"{name}: the picture is large, and it and the title are one centred column",
                 s["picture"][2] >= 280 and all(abs(middle(s[k]) - middle(s["band"])) <= 1 for k in ("picture", "titleBox"))
                 and s["picture"][1] + s["picture"][3] <= s["titleBox"][1],
                 (s["band"], s["picture"], s["titleBox"]))
            t.ok(f"{name}: a title and no state", bool(s.get("title")) and "state" not in s and "stateBox" not in s, s)
            t.ok(f"{name}: every row has a name and a region or says it has none",
                 "" not in s["rows"] and s.get("unclaimed") == [], (s["rows"], s.get("unclaimed")))
            t.ok(f"{name}: the picture sits inside the band, and the band is all on show",
                 inside(s["picture"], s["band"]) and inside(s["band"], s["well"]), (s["picture"], s["band"], s["well"]))
            t.ok(f"{name}: the rows start under the band", abs(s["offset"] + s["insetTop"]) < 0.5 and s["insetTop"] >= s["height"], s)
            t.ok(f"{name}: a detail has its crumb, a page has none", bool(s["crumb"]) == (kind == "detail"), s["crumb"])
            if s.get("rest"):
                t.ok(f"{name}: the ring rests on {s['rest']}", s["marked"] == s["rest"] and inside(s["ring"], s["picture"], 3), s)
            else:
                t.ok(f"{name}: no ring when nothing is pointed at", s["marked"] == "" and "ring" not in s, s)
        t.ok("each page says its own name", titles.get("privacy") == "Privacy" and titles.get("agents") == "Agents"
             and titles.get("linkrule") == "Rule 1" and titles.get("livefolder") == "Pull Requests", titles)

        print("the header stays whole as the rows scroll under it, and a line comes at its foot")
        go("page", "privacy")
        rest = stage()
        t.ok("at rest no line", not rest["lined"], rest)
        sv.cmd({"do": "settings", "find": "", "scroll": 40.0})
        time.sleep(0.3)
        moved = stage()
        t.ok("the rows moved", moved["offset"] == rest["offset"] + 40, (rest["offset"], moved["offset"]))
        t.ok("the header did not move or shrink", all(moved[k] == rest[k] for k in ("well", "band", "picture", "titleBox")), moved)
        t.ok("the line is at the header's foot, the width of the page side", moved["lined"]
             and abs(moved["line"][1] + moved["line"][3] - (moved["well"][1] + moved["well"][3])) <= 0.5 and moved["line"][2] == moved["pane"][2], moved)
        t.ok("the scroll inset did not move", moved["insetTop"] == rest["insetTop"], (rest["insetTop"], moved["insetTop"]))
        sv.cmd({"do": "settings", "find": "", "scroll": 400.0})
        time.sleep(0.3)
        far = stage()
        t.ok("far down the header is still whole", all(far[k] == rest[k] for k in ("well", "band", "picture", "titleBox"))
             and far["picture"][2] >= 280 and far["lined"], far)
        t.ok("the ring is still on the picture", far["marked"] == far["rest"] and inside(far["ring"], far["picture"], 3), far)
        ui(settingsPoint="clear.history")
        time.sleep(0.4)
        low = stage()
        t.ok("and a row pointed at down there still moves it", low["marked"] == "field" and inside(low["ring"], low["picture"], 3)
             and low["row"][1] >= low["well"][1] + low["well"][3] - 0.5, low)
        ui(settingsPoint="")
        sv.cmd({"do": "settings", "find": "", "scroll": 0.0})
        time.sleep(0.3)
        back = stage()
        t.ok("back at the top it is as it was, with no line", back["well"] == rest["well"] and back["picture"] == rest["picture"] and not back["lined"], back)
        sv.cmd({"do": "settings", "find": "", "scroll": 0.0})
        band = rest["band"]
        sv.cmd({"do": "settings", "find": "", "wheel": [120.0, band[0] + band[2] / 2, band[1] + band[3] - 40]})
        time.sleep(0.5)
        t.ok("a wheel turned over the band moves the rows too", stage()["offset"] > rest["offset"] + 10, (rest["offset"], stage()["offset"]))
        sv.cmd({"do": "settings", "find": "", "scroll": 0.0})

        print("pointing at a row moves the ring")
        go("page", "appearance")
        s = stage()
        t.ok("it rests on the whole window", s["marked"] == "window", s["marked"])
        moves = s["moves"]

        def point_round():
            for row in ["sidebar.button", "newtab.floating", "look", "sidebar.button"]:
                ui(settingsPoint=row)
                time.sleep(0.7)
        film(pid, number, "ring-follows-the-pointer", 5.5, point_round)
        s = stage()
        t.ok("the sidebar button's row marks the top of the sidebar", s["marked"] == "top" and s["pointed"] == "sidebar.button", s)
        t.ok("the ring slid there", s["moves"] > moves, (moves, s["moves"]))
        ui(settingsPoint="app.icon")
        time.sleep(0.3)
        s = stage()
        t.ok("the icon has no place in the window, so no ring", s["marked"] == "" and s["pointed"] == "app.icon", s)
        ui(settingsPoint="")
        time.sleep(0.3)
        t.ok("off the rows it rests again", stage()["marked"] == "window")

        print("the keyboard moves it too")
        ui(settingsPoint="look")
        ui(settingsFocus="sidebar.button")
        time.sleep(0.3)
        s = stage()
        t.ok("focus on the sidebar button's switch marks the top of the sidebar", s["marked"] == "top", s)
        ui(settingsPoint="newtab.floating")
        time.sleep(0.3)
        t.ok("the pointer takes it back", stage()["marked"] == "page")
        ui(settingsPoint="")
        time.sleep(0.3)
        t.ok("and off the rows it returns to the focused row", stage()["marked"] == "top")
        ui(settingsFocus="")
        time.sleep(0.3)
        t.ok("with no focus it rests", stage()["marked"] == "window", stage()["marked"])
        sv.cmd({"do": "settings", "find": "", "scroll": 0.0})

        print("a setting changes the picture")
        s = stage()
        t.ok("the picture has the sidebar button", s["scene"]["sideButton"] is True, s["scene"])

        def flip_button():
            ui(settingsPoint="shield")
            time.sleep(0.7)
            sv.cmd({"do": "settings", "find": "", "set": "shield", "value": False})
            time.sleep(1.4)
            sv.cmd({"do": "settings", "find": "", "set": "shield", "value": True})
            time.sleep(1.2)
            ui(settingsPoint="")
            go("page", "appearance", 0.7)
            sv.cmd({"do": "settings", "find": "", "set": "newtab.floating", "value": True})
            time.sleep(1.2)
            sv.cmd({"do": "settings", "find": "", "set": "newtab.floating", "value": False})
            time.sleep(0.9)
            sv.cmd({"do": "settings", "find": "", "set": "sidebar.button", "value": False})
            time.sleep(0.8)
        go("page", "privacy")
        film(pid, number, "a-setting-changes-the-picture", 8.5, flip_button)
        t.ok("turned off, it leaves the picture", stage()["scene"]["sideButton"] is False, stage()["scene"])
        sv.cmd({"do": "settings", "find": "", "set": "sidebar.button", "value": True})
        ui(settingsPoint="")
        go("page", "privacy")
        s = stage()
        t.ok("Privacy pictures the ad blocked", s["scene"]["ads"] == "marked", s)
        sv.cmd({"do": "settings", "find": "", "set": "shield", "value": False})
        time.sleep(0.5)
        s = stage()
        t.ok("and the ad back on the page when it is not", s["scene"]["ads"] == "shown", s)
        sv.cmd({"do": "settings", "find": "", "set": "shield", "value": True})
        go("page", "websites")
        sv.cmd({"do": "settings", "find": "", "set": "pageZoom", "value": 1.25})
        time.sleep(0.5)
        s = stage()
        t.ok("Websites shows the zoom", abs(s["scene"]["zoom"] - 1.25) < 0.001, s)
        sv.cmd({"do": "settings", "find": "", "set": "pageZoom", "value": 1.0})
        sv.cmd({"do": "settings", "find": "", "set": "video.quality", "value": "1080"})
        time.sleep(0.5)
        s = stage()
        t.ok("and a video at the quality chosen", s["scene"]["video"] is True and s["scene"]["quality"] == "1080p", s["scene"])
        ui(settingsPoint="video.quality")
        time.sleep(0.3)
        t.ok("the video rows point at the page", stage()["marked"] == "page", stage()["marked"])
        ui(settingsPoint="")
        sv.cmd({"do": "settings", "find": "", "set": "video.quality", "value": "site"})

        print("a search folds the band away")
        go("page", "privacy")
        open_ = stage()
        chrome = sv.cmd({"do": "settings", "find": "", "chrome": True})["chrome"]
        folds = open_["folds"]

        def search():
            ui(settingsFind="dark")
            time.sleep(1.4)
        film(pid, number, "the-band-folds-for-a-search", 4.0, lambda: (search(), ui(settingsFind=""), time.sleep(1.2), search()))
        s = stage()
        t.ok("folded", s["folded"] and s["height"] == 0 and s["folds"] > folds, s)
        t.ok("the results start where they did before Stage", abs(s["insetTop"] - (open_["insetTop"] - open_["height"])) < 0.5
             and abs(s["offset"] + s["insetTop"]) < 0.5, (open_["insetTop"], s["insetTop"], s["offset"]))
        found = sv.cmd({"do": "settings", "find": "", "chrome": True})["chrome"]
        t.ok("and the window's bar is as it was", found.get("items") == chrome.get("items") and found.get("separator") == chrome.get("separator"),
             (chrome.get("items"), found.get("items")))
        ui(settingsFind="")
        time.sleep(0.8)
        s = stage()
        t.ok("it comes back with the page", not s["folded"] and s["height"] == open_["height"] and s["well"][3] == s["height"] and s["title"] == "Privacy"
             and abs(s["offset"] + s["insetTop"]) < 0.5, s)

        print("a result lands on its row, under the band")
        for words, group, page, row in [("cache", "clear", "Privacy", "clear.cache"), ("sidebar button", "sidebar", "Appearance", "sidebar.button")]:
            landed(t, words, group, page, row, "")

        print("a row with a chevron drills in, and the page says where it is")
        go("page", "general")

        def drill():
            time.sleep(0.4)
            ui(settingsPoint="languages")
            time.sleep(0.7)
            ui(settingsPress="detail.languages")
            time.sleep(1.3)
        film(pid, number, "a-drill-in", 4.5, drill)
        s = stage()
        t.ok("Languages under General", s["folded"] and s["heading"] == "Languages" and "General" in str(s["headingCrumb"]), s)
        ui(settingsPoint="")
        try:
            ui(settingsPress="settings.stage.crumb")
            pressed = True
        except RuntimeError:
            pressed = False
        t.ok("the crumb is words, not a way back: that is the toolbar's", not pressed and stage()["heading"] == "Languages")

        print("a short window gets the small band")
        go("page", "tabs")
        ui(settingsSize=[720, 480])
        time.sleep(0.6)
        s = stage()
        t.ok("small at the minimum size", s["compact"] and 100 < s["height"] < 200 and s["picture"][2] == 150 and inside(s["picture"], s["band"])
             and s["well"][3] == s["insetTop"], s)
        t.ok("the rows still start under it", abs(s["offset"] + s["insetTop"]) < 0.5, s)
        ui(settingsSize=[720, 640])
        time.sleep(0.6)
        s = stage()
        t.ok("full again when there is room, at the narrowest width", not s["compact"] and s["height"] > 250 and s["picture"][2] == 280
             and inside(s["picture"], s["band"]) and s["well"][3] == s["insetTop"], s)
        ui(settingsSize=[860, 640])
        time.sleep(0.5)

        print("with Reduce Motion nothing slides")
        subprocess.run(["defaults", "write", sv.SUITE, "motion.testReduced", "-bool", "true"], check=True)
        time.sleep(1.0)
        go("page", "appearance")
        moves = stage()["moves"]
        ui(settingsPoint="newtab.floating")
        time.sleep(0.2)
        s = stage()
        t.ok("the ring is on the page at once", s["marked"] == "page" and s["moves"] == moves, s)
        ui(settingsPoint="")
        ui(settingsFind="dark")
        time.sleep(0.2)
        t.ok("the band is gone at once", stage()["folded"])
        ui(settingsFind="")
        time.sleep(0.3)
        landed(t, "cache", "clear", "Privacy", "clear.cache", " with Reduce Motion")
        subprocess.run(["defaults", "delete", sv.SUITE, "motion.testReduced"], check=True)
    finally:
        try:
            ui(settingsFind="")
        except Exception:
            pass
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
