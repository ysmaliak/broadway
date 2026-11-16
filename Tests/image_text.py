import json
import subprocess
import sys
import tempfile
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("image-text")
EXPECTED = "Ticket screenshot\nПроверка русского текста\nLast line here"
requests = []
fixtures = {}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.path, self.headers.get("Cookie", "")))
        if self.path.endswith(".png"):
            body = fixtures.get(self.path.split("?")[0].strip("/"), b"bad image")
            kind = "image/png"
        else:
            source = "/blank.png" if self.path == "/blank" else "/text.png"
            if self.path == "/cross":
                source = f"http://localhost:{self.server.server_port}/text.png"
            body = f"<!doctype html><title>Image text</title><a href='/next'><img id='picture' src='{source}'></a>".encode()
            kind = "text/html"
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def clipboard():
    return subprocess.run(["pbpaste"], capture_output=True, text=True).stdout


def copy(tab, **args):
    url = args.pop("url", None) or sv.ev(tab, "document.querySelector('img').currentSrc")
    request = {"do": "image-text", "id": tab, "url": url, **args}
    if args.get("close"):
        return sv.cmd(request)
    started = sv.cmd({**request, "start": True})
    until = time.time() + 90
    while time.time() < until:
        state = sv.cmd({"do": "image-text", "id": tab, "url": url, "state": True})
        if not state["running"]:
            return {**started, **state}
        time.sleep(0.1)
    raise RuntimeError("Image recognition did not finish within 90 seconds")


def ready(tab):
    for _ in range(50):
        if sv.ev(tab, "document.querySelector('img').complete && document.querySelector('img').naturalWidth > 0"):
            return
        time.sleep(0.1)
    raise RuntimeError("Fixture image did not load")


def main():
    t = sv.T()
    before = clipboard()
    with tempfile.TemporaryDirectory(prefix="broadway-image-text-") as folder:
        subprocess.run(["swift", str(sv.ROOT / "Tests/ImageTextFixture.swift"), folder], check=True)
        fixtures.update({name: Path(folder, name).read_bytes() for name in ["text.png", "blank.png"]})
        sv.setup(**{"tabs.groups": True})
        sv.launch()
        try:
            for pid in sv.pids():
                state = subprocess.run(["ps", "eww", "-p", pid, "-o", "command="], capture_output=True, text=True).stdout
                t.ok("test process has its own SEARCH_PROBE world", f"SEARCH_PROBE={sv.W}" in state)
            tab = sv.page("text")
            ready(tab)
            count = len(requests)
            state = copy(tab, clear=True)
            t.ok("menu contains Copy Text", "Copy Text" in state["menu"], state)
            t.ok("mixed English and Russian copied in reading order", state["text"] == EXPECTED, state)
            t.ok("existing confirmation reports the line count", state["announcement"] == "Copied 3 lines", state)
            t.ok("loaded image needs no new request", len(requests) == count, requests)
            blank = sv.page("blank")
            ready(blank)
            state = copy(blank)
            t.ok("blank image reports No text found", state["announcement"] == "No text found", state)
            t.ok("blank image preserves clipboard content", state["text"] == EXPECTED, state)
            for kind in ["data", "blob"]:
                script = """(function () { window.__fixtureReady = false; (async () => {
                    const image = document.querySelector('img');
                    const blob = await (await fetch('/text.png')).blob();
                    if (KIND === 'blob') image.src = URL.createObjectURL(blob);
                    else image.src = await new Promise(resolve => { const r = new FileReader(); r.onload = () => resolve(r.result); r.readAsDataURL(blob); });
                    window.__fixtureReady = true;
                })(); return true; })()""".replace("KIND", json.dumps(kind))
                sv.ev(tab, script)
                for _ in range(50):
                    if sv.ev(tab, "window.__fixtureReady === true"):
                        break
                    time.sleep(0.1)
                ready(tab)
                count = len(requests)
                state = copy(tab, clear=True)
                t.ok(kind + " image copies exact text without network", state["text"] == EXPECTED and len(requests) == count, state)
            cross = sv.page("cross")
            ready(cross)
            count = len(requests)
            state = copy(cross, clear=True)
            t.ok("tainted cross-origin canvas uses Copy Image fallback", state["text"] == EXPECTED and len(requests) == count + 1, state)
            t.ok("fallback carries no cookies, like Copy Image", requests[-1][1] == "", requests[-1])
            state = copy(tab, url=sv.BASE + "/invalid.png")
            t.ok("invalid image gives calm failure and keeps text", state["announcement"] == "Couldn't read text in that image" and state["text"] == EXPECTED, state)
            state = copy(tab, clear=True, close=True)
            t.ok("closing the tab cancels its menu action", state["cancelled"] and state["text"] == "", state)
            pinned = sv.page("pinned")
            ready(pinned)
            sv.cmd({"do": "pin", "id": pinned})
            state = copy(pinned, clear=True, close=True)
            t.ok("putting a pin away cancels its menu action", state["cancelled"] and state["text"] == "", state)
            grouped = sv.page("grouped")
            ready(grouped)
            sv.cmd({"do": "group", "id": grouped, "new": True, "name": "OCR"})
            sv.cmd({"do": "group", "name": "OCR", "pinned": True})
            state = copy(grouped, clear=True, close=True)
            t.ok("putting a grouped page away cancels its menu action", state["cancelled"] and state["text"] == "", state)
            t.ok("real clipboard text is unchanged", clipboard() == before)
        finally:
            sv.finish()
    t.done()
    sys.exit(1 if t.failed else 0)


main()
