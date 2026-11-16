#!/usr/bin/env python3
"""The host in the sidebar's address pill, drawn off screen (bench addresspill).

Build first (`./build.sh`), then `python3 Tests/address_pill_hosts.py [DIR]`.
The app starts hidden in a world of its own, draws the real address pill to
a bitmap for each case below on a light, a dark and a coloured sidebar, and
quits. Nothing is put on the screen. With DIR, each picture is saved there
at 2x with index.json beside it. With --shots-only, the checks on the drawn
runs are skipped, as for a build of main.
"""
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-pill")
ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
SHOTS = Path(ARGS[0]) if ARGS else None
CHECK = "--shots-only" not in sys.argv

LOOKS = {"light": {"look": "light"}, "dark": {"look": "dark"}, "blue": {"look": "light", "space": "3139FB"}}
CASES = [
    ("acme-okta", "https://acme.okta.com/app/home", 258, "acme.", "okta.com"),
    ("mail-google", "https://mail.google.com/mail/u/0/", 258, "mail.", "google.com"),
    ("docs-example-co-uk", "https://docs.example.co.uk/guide", 258, "docs.", "example.co.uk"),
    ("example", "https://www.example.com/", 258, "", "example.com"),
    ("acme-github-io", "https://acme.github.io/notes/", 258, "", "acme.github.io"),
    ("long-chain-narrow", "https://a.very.long.subdomain.chain.example.com/", 200, "a.very.long.subdomain.chain.", "example.com"),
    ("localhost", "http://localhost:3000/", 258, "", "localhost"),
    ("address", "http://192.168.1.20:8080/", 258, "", "192.168.1.20"),
    ("idn", "https://news.xn--wgv71a119e.jp/", 258, None, None),
]
FULL = ("acme-okta-full", "https://acme.okta.com/app/home", 258)


def draw(url, width, look, path=None, full=False):
    req = {"do": "addresspill", "url": url, "width": width, "scale": 2, **LOOKS[look]}
    if full:
        req["full"] = True
    if path:
        req["path"] = str(path)
    return sv.cmd(req)


def main():
    t = sv.T()
    index = []
    try:
        sv.setup(sidebar=True)
        sv.launch()
        if SHOTS:
            SHOTS.mkdir(parents=True, exist_ok=True)
        for name, url, width, lead, site in CASES:
            for look in LOOKS:
                file = f"{name}-{look}.png"
                r = draw(url, width, look, SHOTS / file if SHOTS else None)
                index.append({"file": file, "url": url, "host": r.get("host", r["text"]), "drawn": r["text"], "look": look, "width": width})
                if not CHECK or look != "light":
                    continue
                runs = [{"text": x["text"], "tone": x["tone"]} for x in r["runs"]]
                if lead is None:
                    t.ok(f"{name}: drawn as {[x['text'] for x in runs]}", r["text"].endswith(".jp"), r)
                elif lead:
                    first = runs[0] if runs else {}
                    kept = first.get("text", "")
                    t.ok(f"{name}: the subdomain is secondary", first.get("tone") == "muted"
                         and (kept == lead or (kept.startswith("…") and lead.endswith(kept[1:]) and not kept[1:].startswith("."))), runs)
                    t.ok(f"{name}: the site is in the title colour", runs[-1:] == [{"text": site, "tone": "title"}], runs)
                    alphas = [x["alpha"] for x in r["runs"]]
                    t.ok(f"{name}: the subdomain is drawn fainter than the site", alphas[0] < alphas[-1] - 0.2, alphas)
                else:
                    t.ok(f"{name}: one run in the title colour", runs == [{"text": site, "tone": "title"}], runs)
                if r["fadeAt"] is not None and lead:
                    end = r["labelX"] + r["labelWidth"]
                    t.ok(f"{name}: the words end before the buttons' fade", end <= r["fadeAt"] - r["pillFade"] + 0.5,
                         (end, r["fadeAt"]))
        name, url, width = FULL
        for look in ["light", "dark"]:
            file = f"{name}-{look}.png"
            r = draw(url, width, look, SHOTS / file if SHOTS else None, full=True)
            index.append({"file": file, "url": url, "host": r.get("host", r["text"]), "drawn": r["text"], "look": look, "width": width, "full": True})
            if CHECK and look == "light":
                t.ok("full address: one run in the title colour, as before",
                     [x["tone"] for x in r["runs"]] == ["title"] and r["text"].startswith("acme.okta.com/app"), r)
        if SHOTS:
            (SHOTS / "index.json").write_text(json.dumps(index, indent=2))
    finally:
        sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
