#!/usr/bin/env python3
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("cert-exception")

HOST = "cert.localhost"
QUESTION = "This connection isn't private"


class Page(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        name = self.path.strip("/") or "home"
        body = f"<!doctype html><title>{name}</title><p>{name}".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def log_message(self, *a):
        pass


class Six(ThreadingHTTPServer):
    address_family = socket.AF_INET6


def certificate(folder, name):
    key, cert = Path(folder, f"{name}.key"), Path(folder, f"{name}.pem")
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2",
         "-subj", f"/CN={HOST}", "-keyout", str(key), "-out", str(cert)],
        check=True, capture_output=True,
    )
    return key, cert


class Server:
    def __init__(self):
        self.port = None
        self.running = []

    def start(self, pair):
        self.stop()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(pair[1]), str(pair[0]))
        for _ in range(20):
            try:
                four = ThreadingHTTPServer(("127.0.0.1", self.port or 0), Page)
                six = Six(("::1", four.server_port), Page)
                break
            except OSError:
                if "four" in locals():
                    four.server_close()
                time.sleep(0.25)
        else:
            raise RuntimeError("no port for the https server")
        self.port = four.server_port
        for server in (four, six):
            server.socket = context.wrap_socket(server.socket, server_side=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            self.running.append(server)

    def stop(self):
        for server in self.running:
            server.shutdown()
            server.server_close()
        self.running = []

    def url(self, name):
        return f"https://{HOST}:{self.port}/{name}"


def trust(action="state"):
    return sv.cmd({"do": "trust", "action": action})


def asked():
    return trust()["dialogs"].count(QUESTION)


def load(tab, url, seconds=12):
    if tab is None:
        tab = sv.cmd({"do": "open", "url": url})["id"]
    else:
        sv.cmd({"do": "go", "id": tab, "url": url})
    sv.cmd({"do": "select", "id": tab})
    sv.cmd({"do": "wait", "id": tab, "seconds": seconds})
    time.sleep(0.5)
    title = sv.ev(tab, "document.title")
    return tab, title


def main():
    t = sv.T()
    folder = tempfile.mkdtemp(prefix="cert-exception-")
    first, second = certificate(folder, "first"), certificate(folder, "second")
    server = Server()
    kept = Path(sv.SUPPORT, "certificates.json")
    try:
        sv.setup(sidebar=True)
        sv.launch()

        server.start(first)
        before = asked()
        tab, title = load(None, server.url("one"))
        t.ok("the first load asks", asked() > before, trust())
        t.ok("Go Back leaves the page unloaded", title != "one", title)

        server.start(first)
        before = asked()
        tab, title = load(tab, server.url("two"))
        t.ok("a second load asks again: each load is a fresh connection", asked() > before, trust())
        t.ok("and is not loaded", title != "two", title)

        trust("continue")
        server.start(first)
        before = asked()
        tab, title = load(tab, server.url("three"))
        trust("back")
        t.ok("Continue Anyway is asked once", asked() == before + 1, trust())
        t.ok("and the page loads", title == "three", title)
        t.ok("the exception is written for the space", kept.exists(), str(kept))
        if kept.exists():
            saved = json.loads(kept.read_text())
            t.ok("it names the host, the port and the chain", any(
                e.get("host") == HOST and e.get("port") == server.port and len(e.get("chain", [])) == 1 for e in saved
            ), saved)

        server.start(first)
        before = asked()
        tab, title = load(tab, server.url("four"))
        t.ok("the same certificate loads without a question", asked() == before and title == "four", (trust(), title))

        server.start(second)
        before = asked()
        tab, title = load(tab, server.url("five"))
        t.ok("a new certificate asks again", asked() > before, trust())
        t.ok("and Go Back leaves it unloaded", title != "five", title)

        sv.cmd({"do": "close", "id": tab})
        sv.quit()
        sv.launch()
        server.start(first)
        tab, title = load(None, server.url("six"))
        t.ok("after a restart the first certificate still loads without a question", asked() == 0 and title == "six", (trust(), title))

        server.start(second)
        tab, title = load(tab, server.url("seven"))
        t.ok("and the second still asks", asked() > 0 and title != "seven", (trust(), title))
        sv.cmd({"do": "close", "id": tab})
    finally:
        server.stop()
        shutil.rmtree(folder, ignore_errors=True)
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
