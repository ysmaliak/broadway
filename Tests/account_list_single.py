#!/usr/bin/env python3
"""The accounts under a sign-in box with Split View off, in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/account_list_single.py`. With
Split View off the stage is a single page, and the list under a sign-in box
hung on that page as an overlay. What a press lands on is asked of the window
itself (`hit`): on the list, the list's host; on the box, and off the list,
the page. Split View is always on for people (Prefs.splitView is never
written): the bench's `split enabled` turns it off, the only way to reach the
single-page stage. The Split View probe asks for the list's own host
(AccountHost); here the list is SwiftUI's, so a press on it must reach
something other than the page under it. What it saves is this world's own and
is forgotten at the end; no window is shown.
"""
import sys
import threading
import time
from http.server import ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402
import account_list_split as als  # noqa: E402

sv.use("account-single")


def main():
    t = sv.T()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), als.H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_port}"
    try:
        sv.setup(sidebar=True, **{"layout.cards": True}); sv.launch()
        sv.sp("enabled", on=False)
        als.acc(forget=True)

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

        b = sv.sp("open", url=f"{base}/")["resultID"]
        sv.sp("select", id=b); time.sleep(1.5)
        r = als.acc()
        t.ok("Split View off: the list is up for the focused box", r.get("shown") is True, r)
        page = sv.cmd({"do": "probe"}).get("activePageFrame")
        t.ok("the page's place in the window is known", bool(page), page)
        if r.get("shown") and page:
            x, y, w, h = r["spot"]
            px, py = page[0], page[1]
            on_box = als.hit(px + x + w / 2, py + y + h / 2)
            on_list = als.hit(px + x + 60, py + y + h + 6 + 18)
            off = als.hit(px + x + w + 300, py + y + h + 200)
            t.ok("a press on the box is the page's", on_box == "PageView", on_box)
            t.ok("a press off the list is the page's", off == on_box, (off, on_box))
            t.ok("a press on the list is not the page's", on_list != on_box and on_list != "", (on_list, on_box))
        sv.sp("close", id=b)
    finally:
        try:
            r = als.acc(forget=True)
            t.ok("this world's logins forgotten", r.get("kept") == 0, r)
        except Exception as e:
            t.ok("this world's logins forgotten", False, e)
        srv.shutdown(); srv.server_close()
        t.done(); sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
