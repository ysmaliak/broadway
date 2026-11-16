#!/usr/bin/env python3
"""The accounts under a sign-in box in an extension's popup window, in a
hidden probe.

Build first (`./build.sh`), then `python3 Tests/account_list_popup.py`. An
extension, written to a temporary folder, opens a sign-in page as a popup
window (`chrome.windows.create` with type "popup"), the way a sign-in through
an extension does. Broadway draws that window with PopupWindowView, which hangs the
list over the page as a SwiftUI overlay, the shape of the Split View bug where
a press on the list reached the page under it. What a press lands on is asked
of the popup window itself (`hit` with its window number), from the window's
top-left: the popup's 34-point bar is above the page, and the list hangs
6 points under the box, as it does in a pane. On the box, the page; on the list, something else. What it saves is this world's own and is
forgotten at the end; no window is shown.
"""
import json
import sys
import tempfile
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import account_list_split as als  # noqa: E402

sv.use("account-popup")


def files(base):
    return {
        "manifest.json": json.dumps({"manifest_version": 3, "name": "Popup sign-in", "description": "A test", "version": "1.0"}),
        "go.html": '<!doctype html><script src="go.js"></script>',
        "go.js": "chrome.windows.create({ type: 'popup', url: %s, width: 520, height: 560 });" % json.dumps(base + "/"),
    }


def keep(t, base):
    a = sv.sp("open", url=f"{base}/")["resultID"]
    sv.sp("select", id=a); time.sleep(1.5)
    sv.ev(a, """var set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
      var u = document.getElementById('u'), p = document.getElementById('p');
      set.call(u, %r); u.dispatchEvent(new Event('input', {bubbles: true}));
      p.focus(); set.call(p, 'pw-42'); p.dispatchEvent(new Event('input', {bubbles: true}));
      document.forms[0].requestSubmit(); true""" % als.USER)
    until = time.time() + 8
    while True:
        r = als.acc(keep=True)
        if r.get("kept") == 1 or time.time() > until: break
        time.sleep(0.5)
    t.ok("kept in this world's keychain", r.get("kept") == 1, r)
    sv.sp("close", id=a)


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), als.H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"
    folder = tempfile.TemporaryDirectory()
    for name, text in files(base).items():
        Path(folder.name, name).write_text(text)
    try:
        sv.setup(sidebar=True); sv.launch()
        als.acc(forget=True)
        keep(t, base)

        sv.cmd({"do": "ext-folder", "path": folder.name, "yes": True})
        end = time.time() + 30
        while time.time() < end:
            r = sv.cmd({"do": "extensions"})
            ext = next((e for e in r.get("extensions", []) if e.get("name") == "Popup sign-in" and e.get("loaded")), None)
            if not r.get("busy") and ext: break
            time.sleep(0.5)
        t.ok("the extension is in", ext is not None, r)
        if ext is None:
            return
        sv.cmd({"do": "ext-page", "id": ext["id"], "path": "go.html"})
        end = time.time() + 15
        n = 0
        while time.time() < end:
            listed = sv.cmd({"do": "windows", "action": "list"}).get("windows", [])
            n = len(listed)
            if n >= 2: break
            time.sleep(0.5)
        t.ok("the popup window opened", n >= 2, listed)
        if n < 2:
            return
        time.sleep(2)
        r = {}
        end = time.time() + 8
        while time.time() < end:
            r = sv.cmd({"do": "accounts", "window": n})
            if r.get("shown"): break
            time.sleep(0.5)
        t.ok("the list is up in the popup for the focused box", r.get("shown") is True, r)
        spot = r.get("spot")
        if r.get("shown") and spot:
            def hit(x, y): return sv.cmd({"do": "hit", "x": x, "y": y, "window": n}).get("view", "")
            x, y, w, h = spot
            top = 34
            on_box = hit(x + w / 2, top + y + h / 2)
            on_list = hit(x + 60, top + y + h + 6 + 18)
            beside = hit(x + w + 60, top + y + h / 2)
            t.ok("a press on the box is the page's", on_box == "PageView", on_box)
            t.ok("a press beside the box is the page's too", beside == on_box, (beside, on_box))
            t.ok("a press on the list is not the page's", on_list not in ("", on_box), (on_list, on_box))
    finally:
        try:
            r = als.acc(forget=True)
            t.ok("this world's logins forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok("this world's logins forgotten", False, e)
        srv.shutdown(); srv.server_close()
        folder.cleanup()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
