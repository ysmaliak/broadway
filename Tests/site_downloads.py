#!/usr/bin/env python3
"""The question before a site's own download, checked in a probe.

Build first (`./build.sh`), then `python3 Tests/site_downloads.py`. The app
starts in a world of its own, and small servers in this script serve the
pages and their files: an http one, and an https one with a certificate made
for the run. Three cases:

- a page that starts a file from a timer puts the card, Allow lands the file,
  and the site's next file comes without a question
- with the kept answers forgotten, a click earns one file, and two more after
  it wait on one card that says "more files", Don't Allow drops them
- with 127.0.0.1 named public through the bench, a link on the https page to
  an http file puts the "not sent securely" card, Don't Download leaves no
  file, and the next click asks again

While each card is up, one picture of the probe's own window is taken by its
id. Pictures go to .context/site-downloads/.
"""
import os
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("site-downloads")

ROOT = Path(__file__).resolve().parents[1]
HOME = f"http://127.0.0.1:{sv.srv.server_port}"
OUT = ROOT / ".context" / "site-downloads"
TMP = Path(tempfile.mkdtemp(prefix="site-downloads-"))
SHOT = TMP / "shot"
COVER = 'style="position:fixed;inset:0;display:block;background:#f4f4f4;font:28px system-ui;padding:40px"'


def html(body):
    return f"<!doctype html><meta charset=utf-8><title>files</title>{body}".encode()


PAGES = {
    "/timer": html("<p style='font:28px system-ui;padding:40px'>A page that starts a file by itself</p>"
                   "<script>setTimeout(() => { location.href = '/file/timer.zip' }, 400)</script>"),
    "/timer-again": html("<script>setTimeout(() => { location.href = '/file/again.zip' }, 400)</script><p>again</p>"),
    "/more": html(f"""<a id=go href="/file/first.zip" download {COVER}>Download one file</a>
<script>
const fetchOne = name => {{ const a = document.createElement('a'); a.href = '/file/' + name; a.download = name; document.body.appendChild(a); a.click(); }};
document.getElementById('go').addEventListener('click', () => {{
  setTimeout(() => fetchOne('second.zip'), 500);
  setTimeout(() => fetchOne('third.zip'), 1200);
}});
</script>"""),
}


class H(BaseHTTPRequestHandler):
    def reply(self, data, kind, headers=()):
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path.startswith("/file/"):
            name = path.rsplit("/", 1)[1]
            return self.reply(f"file {name}\n".encode() * 64, "application/zip",
                              [("Content-Disposition", f'attachment; filename="{name}"')])
        return self.reply(PAGES.get(path, html("<p>plain</p>")), "text/html")

    def log_message(self, *a):
        pass


sv.srv.RequestHandlerClass = H


class Secure(BaseHTTPRequestHandler):
    def do_GET(self):
        page = html(f'<a id=go href="{HOME}/file/report.zip" {COVER}>Download the report</a>')
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def handle(self):
        try:
            super().handle()
        except Exception:
            pass

    def log_message(self, *a):
        pass


def secure_server():
    subprocess.run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", str(TMP / "key.pem"),
                    "-out", str(TMP / "cert.pem"), "-days", "1", "-subj", "/CN=localhost"], capture_output=True, check=True)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Secure)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(TMP / "cert.pem"), str(TMP / "key.pem"))
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def files(action="state", **more):
    return sv.cmd({"do": "sitefiles", "action": action, **more})


def trace():
    return sv.cmd({"do": "downloadtrace"})


def card(seconds=10, count=None):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        up = [c for c in files()["cards"] if c["front"] and (count is None or len(c["files"]) == count)]
        if up:
            return up[0]
        time.sleep(0.2)
    return None


def kept(name, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if any(k["name"] == name and Path(k["path"]).exists() for k in trace()["kept"]):
            return True
        time.sleep(0.2)
    return False


def tool():
    source = TMP / "WindowShot.swift"
    shutil.copy(ROOT / "Tests" / "WindowShot.swift", source)
    return subprocess.run(["swiftc", "-parse-as-library", str(source), "-o", str(SHOT)], cwd=str(TMP),
                          capture_output=True, text=True).returncode == 0


def shoot(pid, number, name, shots):
    if not SHOT.exists():
        return
    path = OUT / f"{name}.png"
    if path.exists():
        path.unlink()
    for _ in range(4):
        subprocess.run([str(SHOT), str(pid), str(number), str(path)], cwd=str(TMP), capture_output=True, text=True)
        if path.exists():
            shots.append(path)
            return
        time.sleep(0.8)
    print(f"  no picture {name}")


def case_timer(t, pid, number, shots):
    tab = sv.sp("open", url=f"{HOME}/timer")["resultID"]
    c = card()
    t.ok("a page's own file puts the card", c is not None, files())
    if not c:
        return
    t.ok("the card names the site", c["title"] == "“127.0.0.1” wants to download a file", c["title"])
    t.ok("and the file under it", c["text"] == "timer.zip", c["text"])
    t.ok("the buttons are Allow and Don't Allow", (c["allow"], c["deny"]) == ("Allow", "Don't Allow"), c)
    t.ok("the card is shown on the tab in front", c["title"] in files()["shown"], files()["shown"])
    t.ok("nothing is written before the answer", not (Path(trace()["folder"]) / "timer.zip").exists())
    time.sleep(0.6)
    shoot(pid, number, "timer-card", shots)
    files("allow")
    t.ok("Allow lands the file", kept("timer.zip"), trace()["kept"])
    sv.cmd({"do": "go", "id": tab, "url": f"{HOME}/timer-again"})
    t.ok("the site's next file comes without a question", kept("again.zip") and not files()["cards"], files())


def case_more(t, pid, number, shots):
    files("forget")
    tab = sv.sp("open", url=f"{HOME}/more")["resultID"]
    time.sleep(1.2)
    sv.cmd({"do": "tap", "id": tab, "selector": "#go"})
    t.ok("the clicked file goes ahead", kept("first.zip"), trace()["kept"])
    c = card(count=2)
    t.ok("the two files after the click wait on one card", c is not None and len(files()["cards"]) == 1, files())
    if not c:
        return
    t.ok("it asks about more files, with no text", c["title"] == "“127.0.0.1” wants to download more files" and not c["text"], c)
    time.sleep(0.6)
    shoot(pid, number, "more-files-card", shots)
    files("deny")
    time.sleep(1.5)
    folder = Path(trace()["folder"])
    got = trace()
    t.ok("Don't Allow leaves no file", not (folder / "second.zip").exists() and not (folder / "third.zip").exists())
    t.ok("and nothing in the list", not got["entries"] and not any(k["name"] in ("second.zip", "third.zip") for k in got["kept"]), got["entries"])
    t.ok("and nothing that reads as a failure", "didn't finish" not in got["announcement"], got["announcement"])


def case_insecure(t, pid, number, shots, secure):
    files("public", host="127.0.0.1")
    tab = sv.sp("open", url=f"https://127.0.0.1:{secure.server_port}/page")["resultID"]
    time.sleep(1.5)
    sv.cmd({"do": "tap", "id": tab, "selector": "#go"})
    c = card()
    t.ok("an http file from an https page puts the card, even after a click", c is not None and c["kind"] == "insecure", files())
    if not c:
        return
    t.ok("its title", c["title"] == "This file is not sent securely", c["title"])
    t.ok("its text", c["text"] == "“report.zip” from “127.0.0.1” could be read or changed on the way", c["text"])
    t.ok("its buttons", (c["deny"], c["allow"]) == ("Don't Download", "Download Anyway"), c)
    time.sleep(0.6)
    shoot(pid, number, "insecure-card", shots)
    files("deny")
    time.sleep(1.5)
    t.ok("Don't Download leaves no file", not (Path(trace()["folder"]) / "report.zip").exists())
    sv.cmd({"do": "tap", "id": tab, "selector": "#go"})
    again = card()
    t.ok("the next click asks again", again is not None and again["kind"] == "insecure", files())
    files("allow")
    t.ok("Download Anyway lands the file", kept("report.zip"), trace()["kept"])
    files("local")


def main():
    t = sv.T()
    shots = []
    OUT.mkdir(parents=True, exist_ok=True)
    have_tool = tool()
    secure = secure_server()
    try:
        sv.setup()
        sv.launch()
        pid = next(iter(sv.holding() & sv.running()))
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(0.8)
        t.ok("the picture tool builds", have_tool)
        case_timer(t, pid, number, shots)
        case_more(t, pid, number, shots)
        case_insecure(t, pid, number, shots, secure)
        sv.cmd({"do": "idle", "action": "hide"})
    finally:
        t.done()
        for path in shots:
            print("picture", path)
        sv.finish()
        secure.shutdown()
        shutil.rmtree(TMP, ignore_errors=True)
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(main())
