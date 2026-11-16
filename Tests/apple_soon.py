#!/usr/bin/env python3
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("apple-soon")
ROOT = Path(__file__).resolve().parents[1]
LABEL = sys.argv[1] if len(sys.argv) > 1 else "after"
OUT = ROOT / ".context" / "apple-soon" / LABEL
SHOT = ROOT / ".context" / "apple-soon" / "shot"
PAGE = "https://example.com/"
FORM = """document.body.innerHTML = '<form method="post" action="/" style="margin:120px 60px">'
  + '<input name="email" id="u" type="email" autocomplete="username" style="display:block;width:270px;height:40px">'
  + '<input name="password" id="p" type="password" autocomplete="current-password" style="display:block;width:270px;height:40px">'
  + '<button type="submit">Sign in</button></form>';
document.getElementById('p').focus(); location.protocol"""
BLUR = "document.activeElement && document.activeElement.blur(); true"
FOCUS = "document.getElementById('p').focus(); true"


def settings(**f): return sv.cmd({"do": "settings", **f})
def accounts(): return sv.cmd({"do": "accounts"})
def offer(**f): return sv.cmd({"do": "appleoffer", **f})


def saved(key):
    out = subprocess.run(["defaults", "read", sv.SUITE, key], capture_output=True, text=True)
    return out.stdout.strip() if out.returncode == 0 else None


def shot(t, name):
    if not SHOT.exists():
        subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests" / "WindowShot.swift"), "-o", str(SHOT)], check=True)
    number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
    time.sleep(0.8)
    pid = next(iter(sv.holding() & sv.running()))
    path = OUT / f"{name}.png"
    said = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
    t.ok(f"pictured {name}", path.exists(), said)


def case_settings(t):
    found = settings(find="apple passwords")["found"]
    hit = [i for i in found if i["id"] == "passwords.apple"]
    t.ok("“apple passwords” finds the row", bool(hit), [i["id"] for i in found])
    t.ok("…on Passwords", bool(hit) and hit[0]["page"] == "passwords", hit)
    t.ok("…and it says Coming soon, not Unofficial",
         bool(hit) and "Coming soon" in hit[0]["detail"] and "Unofficial" not in hit[0]["detail"], hit)
    t.ok("the switch saved on stays saved", saved("passwords.apple") == "1", saved("passwords.apple"))
    sv.cmd({"do": "ui", "settings": True})
    time.sleep(1.2)
    sv.cmd({"do": "ui", "settingsPage": "passwords"})
    time.sleep(1.2)
    shown = settings(row="passwords.apple")
    row = shown.get("row") or {}
    t.ok("the row is there", bool(row), shown.get("rows"))
    t.ok("…switched off whatever was saved", row.get("on") is False, row)
    t.ok("…and cannot be switched", row.get("enabled") is False, row)
    t.ok("…dimmed as a row that doesn't apply", row.get("alpha") == 0.5, row)
    t.ok("…with the note", "Coming soon" in row.get("detail", ""), row)
    t.ok("…and no ⓘ", row.get("more") is False, row)
    t.ok("no pairing row under it", "apple.pairing" not in shown.get("rows", ["apple.pairing"]), shown.get("rows"))
    for theme in ["dark", "light"]:
        sv.cmd({"do": "ui", "look": theme})
        time.sleep(1.0)
        shot(t, f"settings-passwords-{theme}")
    sv.cmd({"do": "ui", "settingsFind": "apple passwords"})
    time.sleep(1.2)
    shot(t, "settings-find-light")
    sv.cmd({"do": "ui", "settingsFind": ""})
    sv.cmd({"do": "ui", "look": "dark"})
    sv.cmd({"do": "ui", "settings": False})
    time.sleep(0.6)


def case_sign_in(t):
    tab = sv.sp("open", url=PAGE)["resultID"]
    sv.sp("select", id=tab)
    time.sleep(4)
    if sv.ev(tab, "location.protocol") != "https:":
        print("  SKIP: example.com did not load, so there is no https sign-in box to look under")
        return
    state = offer(asks=True, helper=True)
    t.ok("nothing is on", state["on"] is False and state["pairing"] is False and state["state"] == "idle", state)
    sv.ev(tab, FORM)
    time.sleep(2)
    up = accounts()
    t.ok("a sign-in box with the old switch saved on: nothing under it", up.get("shown") is False, up)
    shot(t, "sign-in-saved-on")
    sv.ev(tab, BLUR)
    time.sleep(0.8)
    offer(forget=True)
    sv.ev(tab, FOCUS)
    time.sleep(2)
    up = accounts()
    state = offer()
    t.ok("the same box with the switch off: no offer either", up.get("shown") is False and state["row"] == "", (up, state))
    t.ok("…and none counted", state["offered"] == [] and state["unanswered"] == 0, state)
    shot(t, "sign-in-never-on")
    state = offer(use=True)
    t.ok("its click would do nothing", state["on"] is False and state["pairing"] is False and state["standInStarts"] == 0, state)


def main():
    t = sv.T()
    OUT.mkdir(parents=True, exist_ok=True)
    try:
        sv.setup(**{"passwords.apple": True, "start.fresh": True})
        sv.launch()
        found = settings(find="apple passwords")["found"]
        if LABEL != "before" and not any(i["id"] == "passwords.apple" and "Coming soon" in i["detail"] for i in found):
            print("SKIP: Apple Passwords is on in this build (AppleHelper.available), so there is no off state to check")
            return 0
        case_settings(t)
        case_sign_in(t)
    finally:
        sv.finish()
    t.done()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
