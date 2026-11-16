#!/usr/bin/env python3
"""A local stand-in for OpenRouter, so no test, probe or eval ever reaches openrouter.ai.

    python3 Tests/openrouter_stub.py [PORT] [LOG]

It answers GET /api/v1/key and POST /api/v1/chat/completions the way OpenRouter
does. A key starting sk-or-good is accepted, sk-or-broke is out of credit and
every other key is turned down, with the key echoed in the error the way a
careless server might, so a test can prove Broadway never repeats it. A name is
the word most of the titles share, and a current name is kept while its first
word is still in most titles. Every request is appended to LOG as one JSON line.
"""
import json
import re
import sys
import threading
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STOP = {"with", "from", "that", "this", "your", "what", "best", "guide", "review", "reviews", "page", "home", "about"}


def name_for(prompt):
    titles = re.findall(r'^- "(.*)" — ', prompt, flags=re.M)
    words = Counter()
    for title in titles:
        seen = {w.lower() for w in re.findall(r"[^\W\d_]{4,}", title)} - STOP
        words.update(seen)
    current = re.search(r"^Current name: (.+)$", prompt, flags=re.M)
    current = current.group(1).strip() if current else "none"
    if current != "none":
        head = re.findall(r"[^\W\d_]+", current.lower())
        if head and words.get(head[0], 0) * 2 >= max(len(titles), 1):
            return {"name": current, "emoji": "🗂️", "keep": True}
    top = words.most_common(1)
    name = top[0][0].capitalize() if top else "Folder"
    return {"name": name, "emoji": "🗂️", "keep": False}


class Stub(BaseHTTPRequestHandler):
    log = None

    def log_message(self, *args):
        pass

    def key(self):
        said = self.headers.get("Authorization", "")
        return said[7:] if said.startswith("Bearer ") else ""

    def record(self, body):
        if not Stub.log:
            return
        with open(Stub.log, "a") as out:
            out.write(json.dumps({"method": self.command, "path": self.path, "authorized": bool(self.key()), "body": body},
                                 ensure_ascii=False) + "\n")

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def refused(self):
        key = self.key()
        if key.startswith("sk-or-good"):
            return False
        if key.startswith("sk-or-broke"):
            self.reply(402, {"error": {"code": 402, "message": f"Insufficient credits for {key}"}})
        else:
            self.reply(401, {"error": {"code": 401, "message": f"No auth credentials found for {key}"}})
        return True

    def do_GET(self):
        self.record(None)
        if not self.path.rstrip("/").endswith("/key"):
            return self.reply(404, {"error": {"code": 404, "message": "Not found"}})
        if self.refused():
            return
        self.reply(200, {"data": {"label": "stub", "limit": None, "usage": 0, "is_free_tier": False}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            body = {}
        self.record(body)
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self.reply(404, {"error": {"code": 404, "message": "Not found"}})
        if self.refused():
            return
        prompt = next((m.get("content", "") for m in body.get("messages", []) if m.get("role") == "user"), "")
        answer = json.dumps(name_for(prompt), ensure_ascii=False)
        self.reply(200, {"id": "gen-stub", "model": body.get("model", ""),
                         "choices": [{"message": {"role": "assistant", "content": answer}}],
                         "usage": {"prompt_tokens": 100, "completion_tokens": 12, "total_tokens": 112, "cost": 0.00002}})


def start(port=0, log=None):
    Stub.log = log
    server = ThreadingHTTPServer(("127.0.0.1", port), Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, f"http://127.0.0.1:{server.server_address[1]}/api/v1"


if __name__ == "__main__":
    server, base = start(int(sys.argv[1]) if len(sys.argv) > 1 else 0, sys.argv[2] if len(sys.argv) > 2 else None)
    print(base, flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        server.shutdown()
