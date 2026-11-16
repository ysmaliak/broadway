#!/usr/bin/env python3
import json
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv

sv.use("field-extras")
requests = []
mode = "rates"
xml = b"<Envelope><Cube><Cube time='2026-11-03'><Cube currency='USD' rate='1.25'/><Cube currency='PLN' rate='4'/></Cube></Cube></Envelope>"


class Rates(BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append((self.path, {k.lower(): v for k, v in self.headers.items()}))
        if self.path == "/rates" and mode == "rates":
            self.send_response(200)
            self.send_header("Content-Type", "text/xml")
            self.send_header("Set-Cookie", "rates=private; Path=/")
            body = xml
        elif self.path == "/rates" and mode == "published":
            self.send_response(200)
            body = (sv.ROOT / "Tests/IntegrationFixtures/ecb-daily-2026-11-03.xml").read_bytes()
        elif self.path == "/rates" and mode == "redirect":
            self.send_response(302)
            self.send_header("Location", "/elsewhere")
            body = b""
        elif self.path.startswith("/sug"):
            self.send_response(200)
            body = b'["q",[]]'
        else:
            self.send_response(503)
            body = b"unavailable"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Rates)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = f"http://127.0.0.1:{server.server_port}"


def rows(*args):
    return sv.cmd({"do": "fieldrows", "args": list(args)})


def typed(text):
    sv.cmd({"do": "field", "text": text, "type": True})
    time.sleep(0.5)
    return rows("answer")


def lead(state):
    return state["rows"][0] if state["rows"] else []


def expire():
    cache = Path(sv.SUPPORT) / "currency-rates.json"
    saved = json.loads(cache.read_text())
    saved["attemptedAt"] = 0
    cache.write_text(json.dumps(saved))


def main():
    global mode
    t = sv.T()
    before = subprocess.run(["pbpaste"], capture_output=True).stdout
    try:
        sv.setup(**{"search.suggest": True})
        for key, value in [("currency.testURL", base + "/rates"), ("suggest.testURL", base + "/sug?q=%s")]:
            subprocess.run(["defaults", "write", sv.SUITE, key, "-string", value], check=True)
        sv.launch()
        sv.page("start")
        t.ok("startup makes no currency request", not requests, requests)
        typed("2+2")
        t.ok("a local sum makes no rates request", not requests, requests)
        state = typed("100 usd in eur")
        t.ok("currency leads with the conversion and ECB date", lead(state)[:3] == ["80 EUR", "ECB rate of 2026-11-03", "answer"], state)
        t.ok("the explicit search row remains", any(r[2] == "search" for r in state["rows"]), state)
        rows("return")
        t.ok("Return copies currency and keeps the field open", rows("answer")["copied"] == "80 EUR" and rows("answer")["editing"])
        state = typed("€50 to zł")
        t.ok("currency symbols work", lead(state)[0] == "200 PLN", state)
        rows("return-aside")
        t.ok("Command Return copies expression and conversion", rows("answer")["copied"] == "€50 to zł = 200 PLN")
        state = typed("100 долларов в евро")
        t.ok("Russian currency words work", lead(state)[0] == "80 EUR", state)
        state = typed("1000 руб в usd")
        t.ok("missing RUB rate is never invented", all(r[2] != "answer" for r in state["rows"]), state)
        t.ok("all currency queries shared one fixed request", [p for p, _ in requests] == ["/rates"], requests)
        t.ok("the request contains no cookie, credentials, page or expression", all(not any(k in h for k in ["cookie", "authorization", "referer"]) for _, h in requests), requests)
        cache = Path(sv.SUPPORT) / "currency-rates.json"
        t.ok("rates and source date are saved on disk", json.loads(cache.read_text())["rates"]["date"] == "2026-11-03")

        for text in ["days until christmas", "days until 2026-12-31", "2 weeks from today", "через 10 дней", "сколько дней до нового года", "weekday of 2026-12-31", "какой день недели 2026-12-31"]:
            state = typed(text)
            t.ok(f"date answer through field: {text}", bool(lead(state)) and lead(state)[2] == "answer", state)
        t.ok("date questions do not reach the engine", not any(p.startswith("/sug") for p, _ in requests), requests)
        for text in ["2026-12-31", "days until 2026-02-30", "через дней", "100 usd in"]:
            state = typed(text)
            t.ok(f"unfinished or bare text stays search: {text}", all(r[2] != "answer" for r in state["rows"]), state)
        rows("close")
        sv.quit()
        sv.launch()
        sv.page("restart")
        state = typed("100 usd in eur")
        t.ok("restart uses the dated disk cache within six hours", lead(state)[0] == "80 EUR" and sum(p == "/rates" for p, _ in requests) == 1, requests)
        rows("close")
        sv.quit()
        expire()
        mode = "offline"
        sv.launch()
        sv.page("offline")
        state = typed("100 usd in eur")
        t.ok("offline keeps the last conversion and source date", lead(state)[:2] == ["80 EUR", "ECB rate of 2026-11-03"], state)
        typed("€50 to zł")
        t.ok("failed fetch is also limited to once in six hours", sum(p == "/rates" for p, _ in requests) == 2, requests)
        rows("close")
        sv.quit()
        expire()
        mode = "redirect"
        sv.launch()
        sv.page("redirect")
        state = typed("100 usd in eur")
        t.ok("redirects keep the cache without contacting a second endpoint", lead(state)[0] == "80 EUR" and [p for p, _ in requests if p == "/rates" or p == "/elsewhere"] == ["/rates"] * 3, requests)
        rows("close")
        sv.quit()
        expire()
        mode = "published"
        sv.launch()
        sv.page("published")
        state = typed("100 usd in eur")
        published = json.loads(cache.read_text())["rates"]
        t.ok("the published ECB namespace XML parses through the field", published["values"]["USD"] == 1.1179 and len(published["values"]) == 30 and lead(state)[1] == "ECB rate of 2026-11-03", state)
        t.ok("real clipboard is untouched", subprocess.run(["pbpaste"], capture_output=True).stdout == before)
    finally:
        sv.finish()
        server.shutdown()
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
