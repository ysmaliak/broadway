import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

MARKS = [("Safari Fixture One", "https://one.safari-fixture.example/"),
         ("Safari Fixture Two", "https://two.safari-fixture.example/")]


def profiles():
    for folder in ("Google/Chrome/Default", "Arc/User Data/Default"):
        made = Path(sv.SUPPORT) / "Import" / folder
        made.mkdir(parents=True, exist_ok=True)
        (made / "Bookmarks").write_text('{"roots":{"bookmark_bar":{"children":[],"type":"folder"}}}')


def export(folder):
    inside = Path(folder) / "Safari Export"
    inside.mkdir()
    links = "".join(f'<DT><A HREF="{url}">{title}</A>' for title, url in MARKS)
    (inside / "Bookmarks.html").write_text(f"<DL>{links}</DL>")
    history = {"metadata": {"data_type": "history"},
               "history": [{"url": "https://history.safari-fixture.example/", "title": "History",
                            "time_usec": 1_700_000_000_000_000, "visits_count": 3}]}
    (inside / "History.json").write_text(json.dumps(history))
    archive = Path(folder) / "Safari Export.zip"
    subprocess.run(["ditto", "-c", "-k", "--sequesterRsrc", str(inside), str(archive)], check=True)
    return archive


def panel(**more):
    return sv.cmd({"do": "import-panel", **more})


def settled(within=10):
    seen = panel()
    for _ in range(int(within / 0.2)):
        if seen.get("open") and not seen.get("looking"):
            return seen
        time.sleep(0.2)
        seen = panel()
    return seen


def main():
    if not os.path.exists("/Applications/Safari.app"):
        sys.exit("Safari.app is not on this Mac, so the Bring step offers no Safari to probe")
    t = sv.T()
    scratch = tempfile.mkdtemp(prefix="bring-safari-")
    try:
        sv.setup()
        profiles()
        sv.launch()
        sv.cmd({"do": "onboarding", "action": "replay", "reduced": True})
        sv.cmd({"do": "onboarding", "action": "skip"})
        state = sv.cmd({"do": "onboarding", "action": "go:bring"})
        t.ok("the Bring step offers Safari, then Chrome and Arc", state.get("sources") == ["Safari", "Chrome", "Arc"], state)
        sv.cmd({"do": "onboarding", "action": "source:Safari"})
        state = sv.cmd({"do": "onboarding", "action": "primary"})
        t.ok("finishing with Safari picked opens Bring Things Over on Safari", state.get("bringing") == "Safari", state)
        time.sleep(1.2)

        seen = settled()
        t.ok("the panel is open", seen.get("open"), seen)
        t.ok("the panel opened on Safari", seen.get("onSafari") and seen.get("pick") == "Safari", seen)
        t.ok("Safari leads the list and is the one chosen",
             seen.get("rows", [])[:3] == ["Safari", "Chrome", "Arc"] and seen.get("chosen") == ["Safari"], seen)
        shown = set(seen.get("shown", []))
        t.ok("Safari's way in is shown: the export, the file and Open Safari",
             {"settings.row.import.safari.export", "settings.row.import.safari.file", "import.safari.open"} <= shown, sorted(shown))
        t.ok("no browser's switches are shown with Safari", "settings.row.import.passwords" not in shown and "import.bookmarks" not in shown,
             sorted(shown))
        t.ok("the panel's key reads Choose File…", seen.get("lead") == "Choose File…", seen)
        t.ok("the second file key is put away", "import.file" not in shown, sorted(shown))

        sv.cmd({"do": "axpress", "identifier": "import.safari.open"})
        t.ok("Open Safari answers its press", panel().get("openedSafari") == 1, panel())

        before = panel().get("total", 0)
        archive = export(scratch)
        panel(file=str(archive))
        sv.cmd({"do": "axpress", "identifier": "import.bring"})
        seen = panel()
        for _ in range(100):
            if seen.get("brought"):
                break
            time.sleep(0.2)
            seen = panel()
        said = " ".join(seen.get("brought", []))
        t.ok("Choose File… brings the export in and says so", "2 bookmarks" in said and "1 place" in said, seen)
        t.ok("its bookmarks are here", seen.get("total", 0) - before >= len(MARKS), (before, seen.get("total"), seen.get("top")))
        history = sv.cmd({"do": "history"}).get("history", [])
        t.ok("its history is here", "https://history.safari-fixture.example/" in history, history[:10])
        t.ok("Choose File… stays for another file", seen.get("lead") == "Choose File…", seen)

        broken = Path(scratch) / "Not an export.zip"
        broken.write_text("not a zip")
        panel(file=str(broken))
        sv.cmd({"do": "axpress", "identifier": "import.bring"})
        for _ in range(50):
            seen = panel()
            if not seen.get("busy") and seen.get("brought") and "2 bookmarks" not in " ".join(seen["brought"]):
                break
            time.sleep(0.2)
        t.ok("a file that isn't an export says so", "Nothing to bring in" in " ".join(seen.get("brought", [])), seen)
        t.ok("and Choose File… is still there to try again", seen.get("lead") == "Choose File…", seen)

        sv.cmd({"do": "ui", "import": "off"})
        time.sleep(0.5)
        sv.cmd({"do": "ui", "import": "on"})
        time.sleep(0.8)
        seen = settled()
        t.ok("from the menu the panel starts on Chrome", seen.get("pick") == "Chrome" and not seen.get("onSafari"), seen)
        t.ok("and a browser's switches are back", "settings.row.import.bookmarks" in set(seen.get("shown", [])), seen.get("shown"))
    finally:
        t.done()
        sv.finish()
        subprocess.run(["rm", "-rf", scratch])
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
