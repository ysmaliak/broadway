#!/usr/bin/env python3
"""Link previews with the space's sign-in only, in a hidden probe against fixtures.

Build first (`./build.sh`), then `python3 Tests/integration_previews.py`.
`integrations.api` points the GitHub page read and the Linear session at a
server on 127.0.0.1; fake github.com and linear.app cookies are planted in
the probe's own space. No request may carry an Authorization header.
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "Tests/IntegrationFixtures"
sv.use("integration-preview-tests")
sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
seen = []
failures = []
GITHUB = "https://github.com/acme/rocket/pull/412"
LINEAR = "https://linear.app/acme/issue/ENG-231/small-export"


def check(name, condition, detail=""):
    print(("ok   " if condition else "FAIL ") + name, "" if condition else detail)
    if not condition:
        failures.append(name)


class Fixtures(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, data, kind="application/json", status=200):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        seen.append({"path": self.path, "auth": self.headers.get("Authorization"), "cookie": self.headers.get("Cookie")})
        if self.path == "/page":
            return self.reply(f"<!doctype html><title>Hover fixture</title><a id='pr' href='{GITHUB}'>Pull request</a><a id='issue' href='{LINEAR}'>Linear issue</a><p>Local fixture only</p>".encode(), "text/html")
        if self.path == "/github/page/acme/rocket/pull/412":
            return self.reply((FIXTURES / "github-preview.html").read_bytes(), "text/html")
        if self.path == "/github/page/redirect/rocket/pull/412":
            self.send_response(302)
            self.send_header("Location", f"http://127.0.0.1:{self.server.server_port}/trap")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        return self.reply(b"{}", status=404)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.loads(body)
        seen.append({"path": self.path, "auth": self.headers.get("Authorization"), "cookie": self.headers.get("Cookie"), "body": payload})
        query = payload.get("query", "")
        if self.path != "/linear-session/graphql" or "session=fixture" not in (self.headers.get("Cookie") or ""):
            return self.reply(b"{}", status=401)
        if "availableUsers" in query:
            return self.reply(json.dumps({"data": {"availableUsers": {"users": [{"id": "u-acme", "organization": {"id": "o-acme", "urlKey": "acme"}}]}}}).encode())
        if self.headers.get("user") != "u-acme" or self.headers.get("organization") != "o-acme" or "issue(id:" not in query:
            return self.reply(b"{}", status=401)
        return self.reply((FIXTURES / "linear-preview.json").read_bytes())


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def status():
    return sv.sp("state")


def wait_preview(reference):
    for _ in range(50):
        result = status().get("linkPreview", {})
        if result.get("reference") == reference:
            return result
        time.sleep(0.1)
    return result


def run(base):
    sv.setup(**{"links.show": True})
    subprocess.run(["defaults", "write", sv.SUITE, "integrations.api", "-string", base], check=True)
    sv.launch()
    live("github-cookie", "fixture")
    live("linear-cookie", "fixture")
    page = sv.sp("open", url=base + "/page")["resultID"]
    time.sleep(0.8)
    dimensions = "JSON.stringify([innerWidth,innerHeight,document.body.getBoundingClientRect().x,document.body.getBoundingClientRect().y])"
    before = sv.ev(page, dimensions)
    initial_count = len(seen)
    sv.cmd({"do": "eval", "id": page, "js": "document.querySelector('#pr').dispatchEvent(new MouseEvent('mouseover', {bubbles:true,composed:true}))"})
    preview = wait_preview("acme/rocket #412")
    check("the actual page hover relay presents a PR preview", preview.get("title") == "Keep the upload & retry alive", preview)
    check("state checks review author and update time survive", [preview.get(k) for k in ("state", "checks", "review", "author")] == ["Open", "failing", "Changes requested", "dana"] and preview.get("updated", 0) > 0, preview)
    check("hover leaves page viewport and document placement unchanged", before is not None and before == sv.ev(page, dimensions), before)
    first_count = len(seen)
    sv.cmd({"do": "ui", "link": "off"})
    time.sleep(0.4)
    check("leaving clears the preview", not status().get("linkPreview"), status().get("linkPreview"))
    sv.cmd({"do": "ui", "link": GITHUB + "#a-comment"})
    check("a repeated link uses the cached result", wait_preview("acme/rocket #412").get("state") == "Open")
    check("a fragment does not cause another request", len(seen) == first_count, seen[initial_count:])
    sv.cmd({"do": "ui", "link": LINEAR})
    check("switching to another link clears old data immediately", not status().get("linkPreview"))
    preview = wait_preview("ENG-231")
    check("a Linear issue has its workflow status and creator", preview.get("state") == "In Progress" and preview.get("author") == "Sam Octo", preview)
    sv.cmd({"do": "ui", "link": "https://example.com/acme/rocket/pull/412"})
    time.sleep(0.8)
    check("unrelated links have no integration preview", not status().get("linkPreview"))
    sv.cmd({"do": "ui", "link": "https://github.com/redirect/rocket/pull/412"})
    time.sleep(1.0)
    check("redirects are refused without forwarding the sign-in", not status().get("linkPreview") and not any(r["path"] == "/trap" for r in seen))
    github = [r for r in seen if r["path"].startswith("/github/page/")]
    linear = [r for r in seen if r["path"] == "/linear-session/graphql"]
    check("each sign-in goes only to its own service", github and linear and all(r["cookie"] == "user_session=fixture" for r in github) and all(r["cookie"] == "session=fixture" for r in linear), (github, [r["cookie"] for r in linear]))
    check("no request carried an Authorization header", all(not r["auth"] for r in seen), [r for r in seen if r["auth"]])
    live("github-cookie", "-")
    count = len(seen)
    sv.cmd({"do": "ui", "link": "https://github.com/acme/rocket/pull/413"})
    time.sleep(0.9)
    check("signed out of GitHub makes no request", len(seen) == count and not status().get("linkPreview"))
    check("all requests stayed on declared fixture paths", all(r["path"] in ("/page", "/linear-session/graphql", "/favicon.ico") or r["path"].startswith("/github/page/") for r in seen), [r["path"] for r in seen])


def main():
    if not os.path.exists(sv.APP):
        sys.exit("build first: ./build.sh")
    server = ThreadingHTTPServer(("127.0.0.1", 0), Fixtures)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        run(f"http://127.0.0.1:{server.server_port}")
    except Exception as error:
        check("probe runs to completion", False, repr(error))
    finally:
        sv.finish()
        server.shutdown()
        (Path.home() / f"Library/Preferences/{sv.SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
