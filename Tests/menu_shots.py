#!/usr/bin/env python3
import json
import os
import shutil
import tempfile
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Tests"))
import split_view as sv  # noqa: E402

label = sys.argv[1] if len(sys.argv) > 1 else "now"
theme = sys.argv[2] if len(sys.argv) > 2 else "dark"
only = set(sys.argv[3:])
sv.use("menu-shots-" + uuid.uuid4().hex[:6])
OUT = ROOT / ".context" / "menus" / f"{label}-{theme}"
SHOT = ROOT / ".context" / "menus" / "shot"


class Pages(BaseHTTPRequestHandler):
    def do_GET(self):
        name = self.path.strip("/") or "page"
        kind = "text/html"
        if name == "popups":
            body = (b"<!doctype html><title>Pop</title><body style='background:white'>"
                    b"<script>setTimeout(function(){ window.open('/news', '_blank', 'width=300,height=200') }, 300)</script>")
        elif name == "pic.svg":
            kind = "image/svg+xml"
            body = (b"<svg xmlns='http://www.w3.org/2000/svg' width='200' height='120'>"
                    b"<rect width='200' height='120' fill='#3a7bd5'/></svg>")
        else:
            body = (f"<!doctype html><title>{name.title()}</title><body style='font:15px system-ui;margin:0'>"
                    f"<h1 style='position:absolute;left:40px;top:20px;margin:0'>{name.title()}</h1>"
                    f"<p id=words style='position:absolute;left:40px;top:90px;margin:0;font-size:20px'>A page for the menu shots.</p>"
                    f"<a href='/linked?utm_source=menu' style='position:absolute;left:40px;top:150px;font-size:24px'>a link</a>"
                    f"<img src='/pic.svg' style='position:absolute;left:40px;top:220px;width:200px;height:120px'>").encode()
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Pages)
threading.Thread(target=server.serve_forever, daemon=True).start()
BASE = f"http://127.0.0.1:{server.server_port}"


def shoot(pid, number, name, least=2, menu=False):
    path = OUT / f"{name}.png"
    whole = False
    for _ in range(4):
        out = subprocess.run([str(SHOT), str(pid), str(number), str(path)], capture_output=True, text=True).stdout.strip()
        words = out.split()
        whole = out.startswith("shot") and int(words[words.index("windows") + 1]) >= least \
            and (not menu or int(words[words.index("menus") + 1]) >= 1)
        if whole:
            break
        time.sleep(0.5)
    print("   ", out)
    return whole


def outline(items, depth=0):
    lines = []
    for item in items:
        if item.get("separator"):
            lines.append("  " * depth + "---")
            continue
        mark = "◆ " if item.get("image") else "  "
        state = "" if item.get("enabled", True) else " (off)"
        lines.append("  " * depth + mark + item["title"] + (" ▸" if "submenu" in item else "") + state)
        if "submenu" in item:
            lines += outline(item["submenu"], depth + 1)
    return lines


def still_open():
    try:
        sv.cmd({"do": "ctxmenu", "action": "read"})
        return True
    except RuntimeError:
        return False


def ctx(pid, number, name, keys=(), **ask):
    if only and name not in only:
        return None
    reply, took = None, False
    for _ in range(4):
        try:
            reply = sv.cmd({"do": "ctxmenu", "hold": 3, **ask})
        except RuntimeError as error:
            print(f"  {name}: {error}")
            time.sleep(0.5)
            continue
        if keys:
            reply = sv.cmd({"do": "ctxmenu", "action": "keys", "keys": list(keys)})
        time.sleep(0.6)
        if not still_open():
            continue
        took = shoot(pid, number, name, menu=True)
        if took and still_open():
            break
        took = False
        try:
            sv.cmd({"do": "ctxmenu", "action": "close"})
        except RuntimeError:
            pass
        time.sleep(0.8)
    try:
        sv.cmd({"do": "ctxmenu", "action": "close"})
    except RuntimeError:
        pass
    time.sleep(0.5)
    if not reply:
        return None
    (OUT / f"{name}.json").write_text(json.dumps(reply["items"], indent=1))
    (OUT / f"{name}.txt").write_text("\n".join(outline(reply["items"])) + "\n")
    print(f"  {name}: {len(reply['items'])} rows, shot {took}")
    return reply["items"]


def seed():
    folder = Path(tempfile.mkdtemp(prefix="broadway-menu-ext-"))
    (folder / "manifest.json").write_text(json.dumps({
        "manifest_version": 3, "name": "Shots", "version": "1.0",
        "action": {"default_title": "Shots", "default_popup": "popup.html"},
    }))
    (folder / "popup.html").write_text("<!doctype html><title>Shots</title><p>Shots")
    sv.cmd({"do": "ext-folder", "path": str(folder), "yes": True})
    for _ in range(40):
        loaded = [e for e in sv.cmd({"do": "extensions"}).get("extensions", []) if e.get("name") == "Shots" and e.get("loaded")]
        if loaded:
            sv.cmd({"do": "ext-pin", "id": loaded[0]["id"], "on": True})
            break
        time.sleep(0.25)
    marks = Path(tempfile.mkdtemp(prefix="broadway-menu-marks-")) / "marks.html"
    marks.write_text("<!DOCTYPE NETSCAPE-Bookmark-file-1><TITLE>Bookmarks</TITLE><H1>Bookmarks</H1><DL><p>"
                     f"<DT><A HREF=\"{BASE}/news\">News</A><DT><A HREF=\"{BASE}/docs\">Docs</A>"
                     f"<DT><H3>Reading</H3><DL><p><DT><A HREF=\"{BASE}/mail\">Mail</A></DL><p></DL><p>")
    sv.cmd({"do": "import-file", "path": str(marks)})
    time.sleep(2)
    sv.cmd({"do": "ui", "extensions": False, "bookmarksList": False})
    time.sleep(1)


def frames():
    return sv.cmd({"do": "rowframes"})["rows"]


def main():
    t = sv.T()
    if not only:
        shutil.rmtree(OUT, ignore_errors=True)
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["swiftc", "-parse-as-library", str(ROOT / "Tests/MenuShot.swift"), "-o", str(SHOT)], check=True)
    sv.setup(spaces=True, **{"start.fresh": False})
    subprocess.run(["defaults", "write", sv.SUITE, "look", "-string", theme], check=True)
    subprocess.run(["defaults", "write", sv.SUITE, "sidebar.width", "-float", "260"], check=True)
    before = sv.running()
    subprocess.run(["open", "-n", "-g", "--env", f"SEARCH_PROBE={sv.W}", "--env", "SEARCH_SHOWN=1", sv.APP], check=True)
    for _ in range(200):
        if os.path.exists(sv.SOCK):
            break
        time.sleep(0.1)
    time.sleep(2)
    sv.started.update(sv.running() - before)
    pid = next(iter(sv.holding() & sv.running()))
    try:
        sv.cmd({"do": "resize", "width": 1000, "height": 720, "steps": 1})
        sv.sp("space", spaceAction="new", name="Work")
        ids = {}
        for name in ["google", "github", "news", "mail", "docs"]:
            ids[name] = sv.sp("open", url=f"{BASE}/{name}")["resultID"]
            time.sleep(0.5)
        blank = [x["id"] for x in sv.sp("state")["tabs"] if x["id"] not in ids.values()]
        for x in blank:
            sv.sp("close", id=x)
        sv.cmd({"do": "pin", "id": ids["mail"]})
        sv.cmd({"do": "group", "id": ids["docs"][:8].lower(), "new": True, "name": "Reading"})
        sv.sp("select", id=ids["github"])
        time.sleep(1.5)
        number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
        time.sleep(1)
        rows = frames()
        print("rows", rows)
        tab = ctx(pid, number, "tab", id=ids["news"][:8].lower())
        t.ok("tab menu opened", bool(tab) or (only and "tab" not in only))
        ctx(pid, number, "tab-active", id=ids["github"][:8].lower())
        ctx(pid, number, "tab-copy", keys=["c", "right"], id=ids["news"][:8].lower())
        ctx(pid, number, "tab-move", keys=["c", "down", "right"], id=ids["news"][:8].lower())
        ctx(pid, number, "tab-more", keys=["c", "down", "down", "right"], id=ids["news"][:8].lower())
        ctx(pid, number, "pin", at=[130, 142])
        news = rows.get(ids["news"][:8].lower())
        if news:
            ctx(pid, number, "folder", at=[news[0] + news[2] / 2, news[1] + news[3] / 2 + 40])
        page = ids["github"][:8].lower()
        ctx(pid, number, "page", kind="page", id=page, x=600, y=400)
        ctx(pid, number, "page-link", kind="page", id=page, x=60, y=165)
        ctx(pid, number, "page-image", kind="page", id=page, x=120, y=280)
        sv.cmd({"do": "eval", "id": ids["github"], "js": "getSelection().selectAllChildren(document.getElementById('words')); true"})
        ctx(pid, number, "page-selection", kind="page", id=page, x=100, y=100)
        ctx(pid, number, "space-menu", kind="space", at=[140, 140])
        ctx(pid, number, "plus-menu", kind="plus", at=[140, 140])
        ctx(pid, number, "column-menu", kind="column", at=[140, 140])
        if not only or {"extensions", "bookmarks"} & only:
            seed()
        ctx(pid, number, "extensions", kind="extensions")
        ctx(pid, number, "bookmarks", kind="bookmarks")
        ctx(pid, number, "plus", kind="pluslist")
        ctx(pid, number, "site", kind="site")
        ctx(pid, number, "site-connection", keys=["down", "right"], kind="site")
        ctx(pid, number, "site-more", kind="site", step="more")
        ctx(pid, number, "site-developer", kind="site", step="developer")
        if not only or "sign" in only:
            popped = sv.sp("open", url=f"{BASE.replace('127.0.0.1', 'localhost')}/popups")["resultID"]
            time.sleep(2)
            ctx(pid, number, "sign", kind="sign")
            sv.sp("close", id=popped)
            sv.sp("select", id=ids["github"])
            time.sleep(0.8)
        bar = sv.cmd({"do": "menus"})
        (OUT / "menubar.json").write_text(json.dumps(bar.get("menus", {}), indent=1))
        for title in ["File", "Edit", "View", "Tabs", "Window"]:
            ctx(pid, number, "bar-" + title.lower(), kind="bar:" + title, at=[300, 60])
    finally:
        sv.finish()
        t.done()
    return int(t.failed != 0)


if __name__ == "__main__":
    sys.exit(main())
