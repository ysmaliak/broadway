#!/usr/bin/env python3
"""Downloads of every common shape, checked in a hidden probe.

Build first (`./build.sh`), then `python3 Tests/download_matrix.py`. The app
starts hidden in a world of its own (see split_view.use), a small server in
this script serves the pages and files, each case is clicked with a trusted
click (`tap`) or started by the page itself, and the world is removed
afterwards with everything it downloaded. Local pages only.

Each case names a file of its own. A case passes when the file is in the
world's download folder with the bytes the server sent, and the list of
kept files has it (a private window's go to its own list instead). When one
fails, the stage it stopped at is printed from the app's download trace:
never a download, no destination, an error, or finished but not kept.
`python3 Tests/download_matrix.py name …` runs only the named cases.
"""
import json
import socket
import threading
import unicodedata
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("download-matrix")

LINK = 'style="display:block;font-size:40px;line-height:80px;padding:0 20px"'
PORT = sv.srv.server_port
HOME = f"http://127.0.0.1:{PORT}"
AWAY = f"http://localhost:{PORT}"



class Six(sv.ThreadingHTTPServer):
    address_family = socket.AF_INET6


six = Six(("::1", 0), sv.H)
threading.Thread(target=six.serve_forever, daemon=True).start()
THIRD = f"http://[::1]:{six.server_port}"


def body(case):
    return f"matrix file for {case}\n".encode() * 64


def page(html):
    return f"<!doctype html><meta charset=utf-8><title>matrix</title>{html}".encode()


def go(href, extra=""):
    return f'<a id="go" href="{href}" {extra} {LINK}>Download</a>'


def scripted(onclick, href, later="", blank=False):
    target = ' target="_blank"' if blank else ""
    handler = f"document.getElementById('go').addEventListener('click', function (e) {{ {onclick} }});" if onclick else ""
    return (f'<p id="ad" style="font-size:20px;margin:20px">Some words to read, not a link.</p>'
            f'<a id="go" href="#"{target} {LINK}>Download</a>'
            f'<script>var B = "{AWAY}", C = "{THIRD}"; document.getElementById("go").href = {href}; {handler} {later}</script>')


OVER_VIDEO = (f'<div style="position:relative;width:640px;height:360px"><video width="640" height="360" style="background:#111"></video>'
              f'<div id="go" style="position:absolute;inset:0;z-index:5"></div></div>'
              f'<script>document.getElementById("go").onclick = function () {{ window.open("{AWAY}/file/overvideo?name=matrix-overvideo.bin") }}</script>')

PAGES = {
    "main": lambda: go("/file/main?name=matrix-main.bin"),
    "blank": lambda: go("/file/blank?name=matrix-blank.bin", 'target="_blank"'),
    "blank-away": lambda: go(f"{AWAY}/file/blankaway?name=matrix-blankaway.bin", 'target="_blank"'),
    "open": lambda: f'<a id="go" href="#" onclick="window.open(\'/file/open?name=matrix-open.bin\'); return false" {LINK}>Download</a>',
    "open-blank-then": lambda: f'<a id="go" href="#" onclick="var w = window.open(\'about:blank\'); w.location = \'/file/openthen?name=matrix-openthen.bin\'; return false" {LINK}>Download</a>',
    "frame-src": lambda: f'<p {LINK}>A frame below</p><iframe src="/file/framesrc?name=matrix-framesrc.bin" width=10 height=10></iframe>',
    "frame-away": lambda: f'<p {LINK}>A frame below</p><iframe src="{AWAY}/file/frameaway?name=matrix-frameaway.bin" width=10 height=10></iframe>',
    "redirect": lambda: go("/hop/1/redirect?name=matrix-redirect.bin"),
    "redirects": lambda: go("/hop/4/redirects?name=matrix-redirects.bin"),
    "redirect-away": lambda: go(f"/hop/1/redirectaway?name=matrix-redirectaway.bin&to={quote(AWAY)}"),
    "redirect-blank": lambda: go(f"/hop/2/redirectblank?name=matrix-redirectblank.bin&to={quote(AWAY)}", 'target="_blank"'),
    "post": lambda: f'<form method="post" action="/file/post?name=matrix-post.bin"><input type=hidden name=a value=b><button id="go" {LINK}>Download</button></form>',
    "post-blank": lambda: f'<form method="post" target="_blank" action="/file/postblank?name=matrix-postblank.bin"><input type=hidden name=a value=b><button id="go" {LINK}>Download</button></form>',
    "cookie": lambda: go("/file/cookie?name=matrix-cookie.bin&needs=1"),
    "octet": lambda: go("/file/octet?name=matrix-octet.bin&plain=1"),
    "octet-blank": lambda: go("/file/octetblank?name=matrix-octetblank.bin&plain=1", 'target="_blank"'),
    "inline-zip": lambda: go("/file/inlinezip?name=matrix-inlinezip.zip&inline=1&type=application/zip"),
    "star-name": lambda: go("/file/starname?star=1"),
    "slash-name": lambda: go("/file/slashname?slash=1"),
    "no-name": lambda: go("/file/noname/?bare=1"),
    "pdf-attach": lambda: go("/file/pdfattach?name=matrix-pdfattach.pdf&type=application/pdf"),
    "a-download": lambda: go("/file/adownload?plain=1&type=text/plain", 'download="matrix-adownload.txt"'),
    "a-download-away": lambda: go(f"{AWAY}/file/adownloadaway?name=matrix-adownloadaway.bin", 'download="matrix-adownloadaway-asked.bin"'),
    "blob": lambda: f'<a id="go" {LINK}>Download</a><script>var a = document.getElementById("go"); a.download = "matrix-blob.txt"; a.href = URL.createObjectURL(new Blob(["matrix blob\\n"], {{type: "text/plain"}}))</script>',
    "data": lambda: go("data:text/plain;base64,bWF0cml4IGRhdGEK", 'download="matrix-data.txt"'),
    "data-octet": lambda: go("data:application/octet-stream;base64,bWF0cml4IGRhdGEK", 'download="matrix-dataoctet.bin"'),
    "script-blob": lambda: f'<a id="go" href="#" onclick="setTimeout(function () {{ var a = document.createElement(\'a\'); a.href = window.URL.createObjectURL(new Blob([\'matrix scriptblob\\n\'])); a.download = \'matrix-scriptblob.txt\'; document.body.appendChild(a); a.click() }}, 100); return false" {LINK}>Download</a>',
    "script-later": lambda: f'<p {LINK}>Your download starts in a moment</p><script>setTimeout(function () {{ location.href = "/file/scriptlater?name=matrix-scriptlater.bin" }}, 1200)</script>',
    "script-frame": lambda: f'<p {LINK}>Your download starts in a moment</p><script>setTimeout(function () {{ var f = document.createElement("iframe"); f.style.display = "none"; f.src = "/file/scriptframe?name=matrix-scriptframe.bin"; document.body.appendChild(f) }}, 800)</script>',
    "script-anchor": lambda: f'<p {LINK}>Your download starts in a moment</p><script>setTimeout(function () {{ var a = document.createElement("a"); a.href = "/file/scriptanchor?name=matrix-scriptanchor.bin"; document.body.appendChild(a); a.click() }}, 800)</script>',
    "script-blob-later": lambda: f'<p {LINK}>Your download starts in a moment</p><script>setTimeout(function () {{ var a = document.createElement("a"); a.href = URL.createObjectURL(new Blob(["matrix scriptbloblater\\n"])); a.download = "matrix-scriptbloblater.txt"; document.body.appendChild(a); a.click() }}, 800)</script>',
    "two": lambda: f'<a id="go" href="#" onclick="var a = document.createElement(\'a\'); a.href = \'/file/twoa?name=matrix-twoa.bin\'; a.download = \'\'; document.body.appendChild(a); a.click(); var b = document.createElement(\'a\'); b.href = \'/file/twob?name=matrix-twob.bin\'; b.download = \'\'; document.body.appendChild(b); b.click(); return false" {LINK}>Download</a>',
    "same-name": lambda: go("/file/samename?name=matrix-samename.bin"),
    "tu-now": lambda: scripted("e.preventDefault(); window.open(B + '/thanks'); location.href = C + '/file/tunow?name=matrix-tunow.bin'", "B + '/thanks'"),
    "tu-octet": lambda: scripted("e.preventDefault(); window.open(B + '/thanks'); location.href = C + '/file/tuoctet?plain=1'", "B + '/thanks'"),
    "tu-300": lambda: scripted("e.preventDefault(); window.open(B + '/thanks'); setTimeout(function () { location.href = C + '/file/tu300?name=matrix-tu300.bin' }, 300)", "B + '/thanks'"),
    "tu-1500": lambda: scripted("e.preventDefault(); window.open(B + '/thanks'); setTimeout(function () { location.href = C + '/file/tu1500?name=matrix-tu1500.bin' }, 1500)", "B + '/thanks'"),
    "tu-redirect": lambda: scripted("e.preventDefault(); window.open(B + '/thanks'); location.href = '/hop/1/turedirect?name=matrix-turedirect.bin&to=' + encodeURIComponent(C)", "B + '/thanks'"),
    "tu-reverse": lambda: scripted("e.preventDefault(); window.open(B + '/hop/1/tureverse?name=matrix-tureverse.bin&to=' + encodeURIComponent(C)); location.href = B + '/thanks'", "B + '/thanks'"),
    "astray": lambda: scripted("e.preventDefault(); window.open(B + '/file/astray?name=matrix-astray.bin')", "'/download-page'"),
    "countdown-open": lambda: scripted("", "'#'", "setTimeout(function () { window.open(B + '/file/countdownopen?name=matrix-countdownopen.bin') }, 800)"),
    "countdown-location": lambda: scripted("", "'#'", "setTimeout(function () { location.href = B + '/file/countdownlocation?name=matrix-countdownlocation.bin' }, 800)"),
    "open-await": lambda: scripted("e.preventDefault(); var w = window.open(''); fetch('/slow').then(function () { w.location = B + '/file/openawait?name=matrix-openawait.bin' })", "'#'"),
    "over-video": lambda: OVER_VIDEO,
    "spent": lambda: scripted("e.preventDefault(); window.open(B + '/thanks'); window.open(C + '/file/spent?name=matrix-spent.bin')", "B + '/thanks'"),
    "countdown-open-bare": lambda: scripted("", "'#'", "setTimeout(function () { window.open(B + '/file/countdownbare') }, 800)"),
    "tu-page": lambda: scripted("e.preventDefault(); window.open(B + '/thanks'); location.href = C + '/tupage-ad'", "B + '/thanks'"),
    "tu-reverse-page": lambda: scripted("e.preventDefault(); window.open(B + '/hop/1/tureversepage?page=1&to=' + encodeURIComponent(C)); location.href = B + '/thanks'", "B + '/thanks'"),
    "wary": lambda: scripted("", "B + '/file/wary?name=matrix-wary.bin'", "document.getElementById('ad').addEventListener('mousedown', function () { window.open(C + '/ad') })", blank=True),
    "private": lambda: go("/file/private?name=matrix-private.bin"),
    "private-blank": lambda: go("/file/privateblank?name=matrix-privateblank.bin", 'target="_blank"'),
}

CASES = list(PAGES) + ["same-name-again", "address"]


class H(BaseHTTPRequestHandler):
    def reply(self, data, kind="text/html", headers=()):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        self.rfile.read(length)
        self.do_GET()

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        parts = url.path.strip("/").split("/")
        if parts[0] == "page" and len(parts) > 1 and parts[1] in PAGES:
            headers = [("Set-Cookie", "matrix=yes; Path=/")] if parts[1] == "cookie" else []
            return self.reply(page(PAGES[parts[1]]()), headers=headers)
        if parts[0] == "slow":
            time.sleep(0.6)
            return self.reply(b"ok", "text/plain")
        if parts[0] == "hop":
            left = int(parts[1]) - 1
            rest = "/".join(parts[2:])
            to = q.pop("to", "") if left == 0 else q.get("to", "")
            query = "&".join(f"{k}={quote(v)}" for k, v in q.items())
            where = f"{to}/hop/{left}/{rest}?{query}" if left > 0 else f"{to}/{rest}" if q.get("page") else f"{to}/file/{rest}?{query}"
            self.send_response(302)
            self.send_header("Location", where)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if parts[0] == "file":
            case = parts[1] if len(parts) > 1 else "file"
            if q.get("needs") and "matrix=yes" not in (self.headers.get("Cookie") or ""):
                return self.reply(b"no cookie", "text/plain", ())
            kind = q.get("type", "application/octet-stream")
            headers = []
            if q.get("star"):
                headers.append(("Content-Disposition", "attachment; filename=\"matrix-star.bin\"; filename*=UTF-8''matrix-st%C3%A4r.bin"))
            elif q.get("slash"):
                headers.append(("Content-Disposition", 'attachment; filename="../up/matrix-slash.bin"'))
            elif q.get("bare"):
                headers.append(("Content-Disposition", "attachment"))
            elif q.get("plain"):
                pass
            elif q.get("inline"):
                headers.append(("Content-Disposition", f'inline; filename="{q["name"]}"'))
            else:
                headers.append(("Content-Disposition", f'attachment; filename="{q.get("name", case)}"'))
            return self.reply(body(case), kind, headers)
        return self.reply(page(f"<p {LINK}>{url.path}</p>"))

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H
six.RequestHandlerClass = H

EXPECT = {
    "main": "matrix-main.bin", "blank": "matrix-blank.bin", "blank-away": "matrix-blankaway.bin",
    "open": "matrix-open.bin", "open-blank-then": "matrix-openthen.bin",
    "frame-src": "matrix-framesrc.bin", "frame-away": "matrix-frameaway.bin",
    "redirect": "matrix-redirect.bin", "redirects": "matrix-redirects.bin",
    "redirect-away": "matrix-redirectaway.bin", "redirect-blank": "matrix-redirectblank.bin",
    "post": "matrix-post.bin", "post-blank": "matrix-postblank.bin", "cookie": "matrix-cookie.bin",
    "octet": "octet", "octet-blank": "octetblank", "inline-zip": "matrix-inlinezip.zip",
    "star-name": "matrix-stär.bin", "slash-name": None, "no-name": None,
    "pdf-attach": "matrix-pdfattach.pdf", "a-download": "matrix-adownload.txt",
    "a-download-away": None, "blob": "matrix-blob.txt", "data": "matrix-data.txt",
    "data-octet": "matrix-dataoctet.bin", "script-blob": "matrix-scriptblob.txt",
    "script-later": "matrix-scriptlater.bin", "script-frame": "matrix-scriptframe.bin",
    "script-anchor": "matrix-scriptanchor.bin", "script-blob-later": "matrix-scriptbloblater.txt",
    "same-name": "matrix-samename.bin", "same-name-again": "matrix-samename 2.bin",
    "tu-now": "matrix-tunow.bin", "tu-octet": "tuoctet", "tu-300": "matrix-tu300.bin", "tu-1500": "matrix-tu1500.bin",
    "tu-redirect": "matrix-turedirect.bin", "tu-reverse": "matrix-tureverse.bin", "astray": "matrix-astray.bin",
    "countdown-open": "matrix-countdownopen.bin", "countdown-location": "matrix-countdownlocation.bin",
    "open-await": "matrix-openawait.bin", "over-video": "matrix-overvideo.bin", "wary": "matrix-wary.bin",
    "spent": "matrix-spent.bin", "countdown-open-bare": "countdownbare",
    "address": "matrix-address.bin", "private": "matrix-private.bin", "private-blank": "matrix-privateblank.bin",
}
CLICKED = {"main", "blank", "blank-away", "open", "open-blank-then", "redirect", "redirects", "redirect-away",
           "redirect-blank", "post", "post-blank", "cookie", "octet", "octet-blank", "inline-zip", "star-name",
           "slash-name", "no-name", "pdf-attach", "a-download", "a-download-away", "blob", "data", "data-octet",
           "script-blob", "two", "same-name", "private", "private-blank",
           "tu-now", "tu-octet", "tu-300", "tu-1500", "tu-redirect", "tu-reverse", "astray", "open-await", "over-video", "wary"}
GUARDED = {"tu-now", "tu-octet", "tu-300", "tu-1500", "tu-redirect", "tu-reverse", "astray", "countdown-open",
           "countdown-location", "open-await", "over-video", "wary"}
BEFORE = {"wary": ["#ad", "#ad"]}
CLICKED |= {"spent", "tu-page", "tu-reverse-page"}
GUARDED |= {"spent", "countdown-open-bare", "tu-page", "tu-reverse-page"}
OUTCOME = {"over-video": "refused", "countdown-open-bare": "refused", "tu-page": "stays", "tu-reverse-page": "stays"}
MARKS = {"over-video": "/file/overvideo", "countdown-open-bare": "/file/countdownbare", "tu-page": "tupage-ad",
         "tu-reverse-page": "tureversepage"}


def trace(clear=False):
    return sv.cmd({"do": "downloadtrace", "clear": clear})


def folder():
    return Path(trace()["folder"])


def files():
    try:
        return {unicodedata.normalize("NFC", p.name): p for p in folder().iterdir() if p.is_file()}
    except FileNotFoundError:
        return {}


def stage(events, key):
    mine = [e for e in events if key in json.dumps(e)]
    kinds = [e["kind"] for e in mine]
    if "failed" in kinds:
        e = next(e for e in mine if e["kind"] == "failed")
        return f"failed with {e.get('domain')} {e.get('code')}: {e.get('error')}"
    if "finished" in kinds:
        return "finished but not kept or not where it says"
    if "placed" in kinds or "asked-destination" in kinds:
        return "has a destination but never finished"
    if "became" in kinds:
        return "became a download, no destination asked"
    return "never became a download"


def wait_for(names, seconds=6.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        have = files()
        if all(n in have for n in names):
            return have
        time.sleep(0.2)
    return files()


def sign(tab):
    try:
        return sv.cmd({"do": "popups", "id": tab})
    except RuntimeError:
        return {"blocked": [], "reasons": []}


def tab_of(tab):
    return next((x for x in sv.cmd({"do": "tabs"})["tabs"] if x["id"] == tab), None)


def check_files(case, wanted, have, new, got):
    kept = {unicodedata.normalize("NFC", Path(k["path"]).name) for k in got["kept"]}
    quiet = {unicodedata.normalize("NFC", Path(k["path"]).name) for k in got["private"]}
    if not wanted:
        if len(new) == 1 and new[0] in kept and "/" not in new[0] and new[0] not in ("", ".", ".."):
            return []
        return [f"not one kept file ({new})"]
    problems = []
    for w in wanted:
        if w not in new:
            problems.append(f"{w} not in the folder ({new})")
        elif not have[w].read_bytes().startswith(b"matrix"):
            problems.append(f"{w} has other bytes")
        elif case.startswith("private") and w not in quiet:
            problems.append(f"{w} not in the private list")
        elif not case.startswith("private") and w not in kept:
            problems.append(f"{w} not kept")
    return problems


def run(case, t, window=None):
    before = set(files())
    trace(clear=True)
    source = "same-name" if case == "same-name-again" else case
    tab = None
    at = {"window": window} if window else {}
    if case == "address":
        sv.cmd({"do": "split", "action": "open", "url": f"{HOME}/file/address?name=matrix-address.bin"})
        time.sleep(0.5)
    else:
        tab = sv.cmd({"do": "split", "action": "open", "url": f"{HOME}/page/{source}", **at})["resultID"]
        time.sleep(1.2)
        if source in GUARDED:
            sv.cmd({"do": "popups", "action": "forgive"})
        for first in BEFORE.get(source, []):
            sv.cmd({"do": "tap", "id": tab, "selector": first, **at})
            time.sleep(0.7)
        if source in CLICKED:
            sv.cmd({"do": "tap", "id": tab, "selector": "#go", **at})
    outcome = OUTCOME.get(case, "file")
    problems = []
    if outcome == "file":
        wanted = ["matrix-twob.bin"] if case == "two" else [EXPECT[case]] if EXPECT.get(case) else []
        have = wait_for(wanted) if wanted else (time.sleep(4) or files())
        new = sorted(set(have) - before)
        problems = check_files(case, wanted, have, new, trace())
        label = "only the second of two, WebKit drops the first" if case == "two" else ", ".join(wanted) or "one file"
    elif outcome == "refused":
        time.sleep(3)
        new = sorted(set(files()) - before)
        marker = MARKS[case]
        shown = sign(tab)
        if new:
            problems.append(f"a file arrived without asking ({new})")
        if not any(marker in u for u in shown["blocked"]):
            problems.append(f"the sign does not offer it ({shown['blocked']})")
        else:
            index = list(reversed(shown["blocked"])).index(next(u for u in shown["blocked"] if marker in u))
            sv.cmd({"do": "popups", "action": "open", "id": tab, "index": index})
            have = wait_for([EXPECT[case]])
            new = sorted(set(have) - before)
            problems += [f"opened from the sign: {p}" for p in check_files(case, [EXPECT[case]], have, new, trace())]
        label = "refused, offered in the sign, and the sign's Open downloads it"
    else:
        time.sleep(4)
        new = sorted(set(files()) - before)
        shown = sign(tab)
        here = tab_of(tab)
        if new:
            problems.append(f"a file arrived ({new})")
        if not here or urlparse(here["url"]).path != f"/page/{case}":
            problems.append(f"the page left ({here and here['url']})")
        elif here.get("loading"):
            problems.append("the page is still loading")
        if "tab-under" not in shown["reasons"]:
            problems.append(f"the sign does not say tab-under ({shown['reasons']})")
        strays = [x["url"] for x in sv.cmd({"do": "tabs"})["tabs"] if MARKS[case] in x["url"]]
        if strays:
            problems.append(f"the other tab stayed ({strays})")
        label = "the page stays, the other tab goes, the sign says tab-under"
    got = trace()
    events = got["events"]
    if tab and case in GUARDED:
        shown = sign(tab)
        events.append({"kind": "sign", "blocked": " ".join(shown["blocked"]), "reasons": " ".join(shown["reasons"])})
    good = not problems
    why = "" if good else "; ".join(problems) + " | " + stage(events, "/file/")
    t.ok(f"{case}: {label}", good, why)
    return (case, good, ", ".join(new) or "nothing", why, events)


def main():
    only = sys.argv[1:]
    t = sv.T()
    results = []
    try:
        sv.setup()
        sv.launch()
        for case in CASES:
            if only and case not in only:
                continue
            if case.startswith("private"):
                continue
            results.append(run(case, t))
        private = [c for c in CASES if c.startswith("private") and (not only or c in only)]
        if private:
            quiet = sv.sp("private")
            time.sleep(0.6)
            for case in private:
                results.append(run(case, t, window=quiet["window"]))
    finally:
        t.done()
        out = Path(sv.ROOT, ".context", "download_matrix.json")
        if out.parent.exists():
            out.write_text(json.dumps([{"case": c, "ok": ok, "got": got, "stage": why, "events": ev}
                                       for c, ok, got, why, ev in results], indent=1))
        sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/download_matrix.py requires macOS and a built Broadway.app")
    sys.exit(main())
