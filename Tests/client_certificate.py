#!/usr/bin/env python3
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("client-certificate")

HOST = "cert.localhost"
QUESTION = f"“{HOST}” asks for a certificate that identifies you"
PASSWORD = "probe-only"


def openssl(*args):
    subprocess.run(["openssl", *args], check=True, capture_output=True)


def make(folder):
    f = lambda name: str(Path(folder, name))
    openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", f"/CN={HOST}",
            "-keyout", f("server.key"), "-out", f("server.pem"))
    Path(f("client.ext")).write_text("keyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n")
    for kind in ("right", "wrong"):
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", f"/O=Example Labs/CN=Example {kind} CA",
                "-keyout", f(f"{kind}-ca.key"), "-out", f(f"{kind}-ca.pem"))
        openssl("req", "-newkey", "rsa:2048", "-nodes", "-subj", f"/CN=Pat Example Probe {kind}",
                "-keyout", f(f"{kind}.key"), "-out", f(f"{kind}.csr"))
        openssl("x509", "-req", "-in", f(f"{kind}.csr"), "-CA", f(f"{kind}-ca.pem"), "-CAkey", f(f"{kind}-ca.key"),
                "-set_serial", "7", "-days", "2", "-extfile", f("client.ext"), "-out", f(f"{kind}.pem"))
        openssl("pkcs12", "-export", "-in", f(f"{kind}.pem"), "-inkey", f(f"{kind}.key"), "-name", f"Pat Example Probe {kind}",
                "-passout", f"pass:{PASSWORD}", "-out", f(f"{kind}.p12"))
    for name in ("one", "two", "three", "four", "five"):
        Path(f(f"{name}.html")).write_text(f"<!doctype html><title>{name}</title><p>{name}")
    return f


class Server:
    def __init__(self, f):
        self.f = f
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.running = []

    def start(self):
        self.stop()
        for family, address in (("-4", f"127.0.0.1:{self.port}"), ("-6", f"[::1]:{self.port}")):
            self.running.append(subprocess.Popen(
                ["openssl", "s_server", family, "-accept", address, "-cert", self.f("server.pem"), "-key", self.f("server.key"),
                 "-Verify", "1", "-CAfile", self.f("right-ca.pem"), "-WWW", "-quiet"],
                cwd=str(Path(self.f("server.pem")).parent), stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            ))
        until = time.time() + 5
        while time.time() < until:
            with socket.socket() as knock:
                if knock.connect_ex(("127.0.0.1", self.port)) == 0:
                    return
            time.sleep(0.1)
        raise RuntimeError("the https server did not start")

    def stop(self):
        for process in self.running:
            process.terminate()
            process.wait(timeout=5)
        self.running = []

    def url(self, name):
        return f"https://{HOST}:{self.port}/{name}.html"


def client(action="state", values=None):
    return sv.cmd({"do": "clientcert", "action": action, "values": values or []})


def asked():
    return client()["dialogs"].count(QUESTION)


def load(tab, url, select=True, seconds=12):
    if tab is None:
        tab = sv.cmd({"do": "open", "url": url})["id"]
    else:
        sv.cmd({"do": "go", "id": tab, "url": url})
    if select:
        sv.cmd({"do": "select", "id": tab})
    waited = sv.cmd({"do": "wait", "id": tab, "seconds": seconds})
    time.sleep(0.5)
    return tab, sv.ev(tab, "document.title"), waited.get("failure") or ""


def hold_identities(f):
    return [client("load", [f(f"{kind}.p12"), PASSWORD]) for kind in ("wrong", "right")]


def keychain_holds(name):
    found = subprocess.run(["security", "find-certificate", "-c", name], capture_output=True, text=True)
    return found.returncode == 0


def main():
    t = sv.T()
    folder = tempfile.mkdtemp(prefix="client-certificate-")
    f = make(folder)
    server = Server(f)
    tab = None
    try:
        sv.setup(sidebar=True)
        sv.launch()
        sv.cmd({"do": "trust", "action": "continue"})
        loaded = hold_identities(f)
        t.ok("the probe's identities are held in memory", all("error" not in x for x in loaded), loaded)

        server.start()
        before = asked()
        tab, title, failure = load(None, server.url("one"))
        t.ok("a page that wants a certificate asks", asked() == before + 1, client())
        t.ok("Cancel leaves the page unloaded", title != "one", (title, failure))
        t.ok("and the tab shows why", bool(failure), failure)

        server.start()
        before = asked()
        tab, title, failure = load(tab, server.url("two"))
        t.ok("the refusal is kept: no question on the next load", asked() == before and title != "two", (client(), title))

        sv.cmd({"do": "close", "id": tab})
        sv.quit()
        sv.launch()
        sv.cmd({"do": "trust", "action": "continue"})
        hold_identities(f)
        client("first")

        server.start()
        tab, title, failure = load(None, server.url("three"), select=False)
        t.ok("a tab out of sight is not asked and gets no certificate", asked() == 0 and title != "three", (client(), title, failure))

        server.start()
        tab, title, failure = load(tab, server.url("four"))
        t.ok("after a restart the answer is gone and the tab in front is asked", asked() == 1, client())
        t.ok("Continue sends the certificate from the CA the server named, though another was held first", title == "four", (title, failure))

        server.start()
        tab, title, failure = load(tab, server.url("five"))
        t.ok("the kept choice answers the next load without a question", asked() == 1 and title == "five", (client(), title, failure))
        sv.cmd({"do": "close", "id": tab})

        t.ok("the probe's identities never reached a keychain",
             not keychain_holds("Pat Example Probe right") and not keychain_holds("Pat Example Probe wrong"))
    finally:
        server.stop()
        shutil.rmtree(folder, ignore_errors=True)
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
