#!/usr/bin/env python3
"""The address at rest on the tab you're on (AtRest.swift), in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/address_at_rest.py`. The app
starts hidden in a world of its own (bld-addr-<checkout>, see
split_view.use), is driven through ./bench's socket, and is quit; its world
is removed afterwards. Nothing here makes, shows or brings forward a window:
the column and the strip are pictured off screen (bench column/strip) into
the folder given as the first argument, if any.

What is said is read from the bench's tab list: `atRest`, the line the tab
would show, and `atRestShown`, whether it shows it now. The look-alike and
http pages are only addressed, never needed: what the tab says comes from
the address, loaded or not. Timings: the address field typed into a key at
a time with the setting off and on, interleaved (bench field).
"""
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-addr")
PORT = sv.BASE.rsplit(":", 1)[1]
SHOTS = sys.argv[1] if len(sys.argv) > 1 else None


def tabs(window=None):
    return {t["id"]: t for t in sv.cmd({"do": "tabs", **({"window": window} if window else {})})["tabs"]}


def shown(window=None):
    return sorted(id for id, t in tabs(window).items() if t["atRestShown"])


def ui(**f):
    return sv.cmd({"do": "ui", **f})


def picture(tag):
    if not SHOTS:
        return
    for look in ["light", "dark"]:
        ui(look=look)
        time.sleep(0.4)
        sv.cmd({"do": "column", "path": f"{SHOTS}/{tag}-column-{look}.png", "height": 330})
    ui(look="light")


def typing(times=3):
    """Milliseconds from a key into the field to the run loop resting, per key."""
    out = []
    for _ in range(times):
        r = sv.cmd({"do": "field", "text": "github.com/samrowe", "type": True})
        out += [rested for _, rested in r["ms"]]
        sv.cmd({"do": "suggest", "action": "esc"})
        time.sleep(0.3)
    return out


def main():
    t = sv.T()
    try:
        sv.setup(sidebar=True, splitView=True)
        sv.launch()
        first = next(iter(tabs()))
        sv.cmd({"do": "go", "id": first, "url": f"http://localhost:{PORT}/one"})
        time.sleep(1)

        key = subprocess.run(["defaults", "read", sv.SUITE, "tabs.address"], capture_output=True, text=True)
        t.ok("off by default: no setting written", key.returncode != 0, key.stdout)
        t.ok("off by default: the front tab keeps its title", shown() == [], shown())
        t.ok("off: no tab says its address", shown() == [], shown())
        t.ok("off: the line is still worked out for the bench", tabs()[first]["atRest"] == f"localhost:{PORT}", tabs()[first])

        # Off, the front tab still warns: plain http and look-alike names.
        warn_http = sv.sp("open", url="http://example.com/off")["resultID"]
        until = time.time() + 10
        while not tabs()[warn_http]["atRest"] and time.time() < until: time.sleep(0.3)
        t.ok("off: plain http is still said on the front tab", shown() == [warn_http]
             and tabs()[warn_http]["atRest"].startswith("Not secure, "), (shown(), tabs()[warn_http]["atRest"]))
        warn_fake = sv.sp("open", url="https://xn--80ak6aa92e.com/off")["resultID"]
        # Said once the page arrives (Tab.restAddress): a real site, so give
        # the network its time.
        until = time.time() + 10
        while not tabs()[warn_fake]["atRest"] and time.time() < until: time.sleep(0.3)
        t.ok("off: a look-alike name is still said, as punycode", shown() == [warn_fake]
             and tabs()[warn_fake]["atRest"] == "xn--80ak6aa92e.com", (shown(), tabs()[warn_fake]["atRest"]))
        plain_https = sv.sp("open", url="https://docs.github.com/off")["resultID"]
        time.sleep(0.6)
        t.ok("off: an ordinary https page keeps its title", shown() == [], shown())
        safe_idn = sv.sp("open", url="https://xn--wgv71a119e.jp/")["resultID"]  # 日本語.jp
        time.sleep(0.6)
        t.ok("off: a name safe in its own alphabet keeps its title", shown() == [], (shown(), tabs()[safe_idn]["atRest"]))
        sv.sp("select", id=first)
        time.sleep(0.4)
        t.ok("off: localhost over http is this Mac, not a warning", shown() == [], shown())

    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
