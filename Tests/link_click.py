#!/usr/bin/env python3
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("link-click")

PORT = sv.srv.server_port
A = f"http://127.0.0.1:{PORT}"
B = f"http://localhost:{PORT}"
HITS = []
STYLE = 'style="display:block;font-size:22px;line-height:40px;padding:0 20px"'
FRAME = 'style="display:block;width:420px;height:60px;border:1px solid #888;margin:4px 20px"'
REAL = "--no-real" not in sys.argv


def anchors(s):
    return [
        ("plain_same", f'href="/dest/plain-same-{s}"', "same"),
        ("plain_cross", f'href="{B}/dest/plain-cross-{s}"', "same"),
        ("redirect", f'href="/go?to={quote(B + "/dest/redirect-" + s)}"', "same"),
        ("redirect_js", f'href="/hop?to={quote(B + "/dest/hop-" + s)}"', "same"),
        ("clean", f'href="{B}/dest/clean-{s}?utm_source=x&amp;fbclid=abc&amp;gclid=def"', "same"),
        ("unwrap", f'href="https://www.google.com/url?q={quote(B + "/dest/unwrap-" + s)}"', "same"),
        ("open_tab", f'href="{B}/dest/already-{s}"', "same"),
        ("ruled", f'href="{B}/dest/ruled-{s}"', "same"),
        ("onclick_assign", f'href="#" data-to="{B}/dest/assign-{s}"', "same"),
        ("blank_same", f'target="_blank" href="/dest/blank-same-{s}"', "new"),
        ("blank_cross", f'target="_blank" href="{B}/dest/blank-cross-{s}"', "new"),
        ("window_open", f'href="#" data-open="{B}/dest/winopen-{s}"', "new"),
        ("blank_open_tab", f'target="_blank" href="{B}/dest/already-{s}"', "new"),
        ("blank_ruled", f'target="_blank" href="{B}/dest/ruled-blank-{s}"', "rule"),
    ]


FRAMES = [
    ("frame_plain_same", "A", "plain", "frame"),
    ("frame_top_same", "A", "top", "same"),
    ("frame_blank_same", "A", "blank", "new"),
    ("frame_plain_cross", "B", "plain", "frame"),
    ("frame_top_cross", "B", "top", "same"),
    ("frame_blank_cross", "B", "blank", "new"),
    ("frame_named_cross", "B", "named", "new"),
]


def links_page(s):
    rows = "".join(f'<a id="{name}" {attrs} {STYLE}>{name}</a>' for name, attrs, _ in anchors(s))
    frames = "".join(
        f'<iframe id="{name}" src="{A if host == "A" else B}/frame?kind={kind}&amp;s={s}&amp;n={name}" {FRAME}></iframe>'
        for name, host, kind, _ in FRAMES)
    script = """<script>
    document.querySelectorAll('[data-open]').forEach(a => a.addEventListener('click', e => { e.preventDefault(); window.open(a.dataset.open); }));
    document.querySelectorAll('[data-to]').forEach(a => a.addEventListener('click', e => { e.preventDefault(); location.href = a.dataset.to; }));
    </script>"""
    return f"<title>links {s}</title>{rows}{frames}{script}"


def frame_page(q):
    kind, s, n = q["kind"][0], q["s"][0], q["n"][0]
    target = {"plain": "", "top": ' target="_top"', "blank": ' target="_blank"', "named": ' target="elsewhere"'}[kind]
    return (f'<style>body{{margin:0}}a{{display:block;height:60px;font-size:20px;line-height:60px}}</style>'
            f'<a id="in" href="{B}/dest/{n.replace("_", "-")}-{s}"{target}>{n}</a>')


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = urlparse(self.path)
        path, q = parts.path, parse_qs(parts.query)
        HITS.append(path)
        if path == "/go":
            self.send_response(302)
            self.send_header("Location", q["to"][0])
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path == "/hop":
            body = f'<title>hop</title><script>location.replace({json.dumps(q["to"][0])})</script>'
        elif path == "/links":
            body = links_page(q["s"][0])
        elif path == "/based":
            s = q["s"][0]
            body = f'<title>based</title><base target="_blank"><a id="base_blank" href="{B}/dest/base-blank-{s}" {STYLE}>base</a>'
        elif path == "/frame":
            body = frame_page(q)
        else:
            body = f"<title>{path}</title>landed {path}"
        data = ("<!doctype html><meta charset=utf-8>" + body).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H


def windows(action="list", **f):
    return sv.cmd({"do": "windows", "action": action, **f})["windows"]


def snap():
    out = {}
    for w in windows():
        out[w["n"]] = [(x["id"], x["url"], x["active"]) for x in sv.cmd({"do": "tabs", "window": w["n"]})["tabs"]]
    return out


def trace(tab):
    try:
        return sv.cmd({"do": "popups", "action": "state", "id": tab})["trace"]
    except RuntimeError:
        return []


def settle(tab, wait=0.6):
    for _ in range(60):
        rows = [x for w in snap().values() for x in w if x[0] == tab]
        if rows and rows[0][1] and not any(x["id"] == tab and x["loading"] for x in sv.cmd({"do": "tabs", "id": tab})["tabs"]):
            break
        time.sleep(0.1)
    time.sleep(wait)


def opened(n, url):
    tab = sv.sp("open", url=url, window=n)["resultID"]
    sv.sp("select", id=tab, window=n)
    settle(tab)
    return tab


def land(before, after, src, tokens, frame_hit):
    known = {x[0] for w in before.values() for x in w}
    where = {x[0]: (n, x[1], x[2]) for n, w in after.items() for x in w}
    home = next(n for n, w in before.items() for x in w if x[0] == src)
    made = [(n, x) for n, w in after.items() for x in w if x[0] not in known]
    hit = lambda url: any(t in (url or "") for t in tokens)
    for n, x in made:
        if hit(x[1]):
            return "new tab" if n == home else f"new tab, window {n}"
    if src in where and hit(where[src][1]):
        return "same tab"
    for tab, (n, url, active) in where.items():
        if tab != src and tab not in {x[0] for _, x in made} and hit(url):
            return "open tab" if n == home else f"open tab, window {n}"
    if made:
        return "new tab, elsewhere: " + made[0][1][1]
    if frame_hit:
        return "frame"
    return "nothing"


def click(tab, selector, tokens, dest_path=None, wait=5.0):
    before = snap()
    seen = len(trace(tab))
    start = len(HITS)
    said = sv.cmd({"do": "tap", "id": tab, "selector": selector})
    until = time.time() + wait
    got = "nothing"
    while time.time() < until:
        time.sleep(0.4)
        frame_hit = dest_path is not None and any(h.startswith(dest_path) for h in HITS[start:])
        got = land(before, snap(), tab, tokens, frame_hit)
        if got not in ("nothing", "frame"):
            break
        if got == "frame" and time.time() > until - wait + 2:
            break
    asked = [x["verdict"] for x in trace(tab)[seen:]]
    return got, ",".join(asked) or "-", said


def cleanup(n, keep):
    for w, tabs in snap().items():
        for tab, url, _ in tabs:
            if tab not in keep and (urlparse(url).path.startswith("/dest/") or "google." in url):
                try:
                    sv.sp("close", id=tab, window=w)
                except RuntimeError:
                    pass


def expect(kind, window, setting):
    if kind == "same":
        return "same tab"
    if kind == "new":
        return "new tab"
    if kind == "frame":
        return "frame"
    if kind == "rule":
        return "new tab" if window == "private" else "rule"
    return kind


ROWS = []


def row(kind, window, setting, expected, got, asked, real=False):
    good = got == expected or (expected == "rule" and got not in ("new tab", "nothing", "same tab")) or (real and got.startswith(expected))
    ROWS.append((kind, window, setting, expected, got, asked, good, real))


def matrix(n, window, setting, other, keep):
    s = f"{window[0]}{setting[0]}{int(time.time() * 1000) % 100000}"
    keep.add(opened(other, f"{B}/dest/already-{s}"))
    for name, _, kind in anchors(s):
        src = opened(n, f"{A}/links?s={s}")
        tokens = {"unwrap": ["google.com/", f"/dest/unwrap-{s}"]}.get(name)
        dest = {
            "plain_same": "plain-same", "plain_cross": "plain-cross", "redirect": "redirect", "redirect_js": "hop",
            "clean": "clean", "unwrap": "unwrap", "open_tab": "already", "ruled": "ruled", "onclick_assign": "assign",
            "blank_same": "blank-same", "blank_cross": "blank-cross", "window_open": "winopen",
            "blank_open_tab": "already", "blank_ruled": "ruled-blank",
        }[name]
        tokens = tokens or [f"/dest/{dest}-{s}"]
        got, asked, _ = click(src, f"#{name}", tokens)
        row(name, window, setting, expect(kind, window, setting), got, asked)
        sv.sp("close", id=src, window=n)
        cleanup(n, keep)
    for name, _, _, kind in FRAMES:
        src = opened(n, f"{A}/links?s={s}")
        path = f"/dest/{name.replace('_', '-')}-{s}"
        got, asked, _ = click(src, f"#{name}", [path], dest_path=path)
        row(name, window, setting, expect(kind, window, setting), got, asked)
        sv.sp("close", id=src, window=n)
        cleanup(n, keep)
    src = opened(n, f"{A}/based?s={s}")
    got, asked, _ = click(src, "#base_blank", [f"/dest/base-blank-{s}"])
    row("base_target_blank", window, setting, "new tab", got, asked)
    sv.sp("close", id=src, window=n)
    cleanup(n, keep)
    return s


def first_tab(n, window, setting):
    s = f"f{window[0]}{setting[0]}"
    first = sv.cmd({"do": "tabs", "window": n})["tabs"][0]["id"]
    sv.cmd({"do": "go", "id": first, "url": f"{A}/links?s={s}"})
    settle(first)
    got, asked, _ = click(first, "#plain_cross", [f"/dest/plain-cross-{s}"])
    row("first_tab_plain_cross", window, setting, "same tab", got, asked)
    sv.cmd({"do": "go", "id": first, "url": f"{A}/links?s={s}2"})
    settle(first)
    got, asked, _ = click(first, "#plain_same", [f"/dest/plain-same-{s}2"])
    row("first_tab_plain_same", window, setting, "same tab", got, asked)


SITES = [
    ("example.com", "https://example.com/", "a[href]"),
    ("wikipedia article link", "https://en.wikipedia.org/wiki/Web_browser", "#mw-content-text a[href^='/wiki/']:not([href*=':'])"),
    ("hacker news story", "https://news.ycombinator.com/", ".titleline > a"),
    ("hacker news comments", "https://news.ycombinator.com/", ".subline a[href^='item']"),
    ("duckduckgo html result", "https://html.duckduckgo.com/html/?q=webkit", "a.result__a"),
    ("bing result", "https://www.bing.com/search?q=webkit", "#b_results h2 a"),
    ("google result", "https://www.google.com/search?q=webkit&hl=en", "#search a:has(h3)"),
    ("reddit signed out", "https://www.reddit.com/r/programming/", "a[slot='full-post-link'], a[data-click-id='body']"),
    ("github repo file", "https://github.com/WebKit/WebKit", "table a.Link--primary[href*='/tree/'], table a.Link--primary[href*='/blob/']"),
]


def real_sites(n, window, setting, keep):
    for name, url, selector in SITES:
        src = opened(n, url)
        time.sleep(1.2)
        js = f"""(() => {{ const a = document.querySelector({json.dumps(selector)});
          if (!a) return null;
          const base = document.querySelector('base[target]');
          return [a.href, a.getAttribute('target') || '', a.getAttribute('rel') || '', base ? base.getAttribute('target') : '']; }})()"""
        try:
            info = sv.ev(src, js)
        except RuntimeError:
            info = None
        if not info:
            row(name, window, setting, "-", "no link found", "-", real=True)
            sv.sp("close", id=src, window=n)
            continue
        href, target, rel, base = info
        asks = (target or base).lower() not in ("", "_self", "_top", "_parent")
        expected = "new tab" if asks else "same tab"
        tokens = [urlparse(href).netloc + urlparse(href).path] if urlparse(href).path not in ("", "/") else [urlparse(href).netloc]
        before = snap()
        try:
            got, asked, _ = click(src, selector, tokens, wait=7)
        except RuntimeError as e:
            got, asked = f"tap failed: {e}", "-"
        if got == "nothing":
            after = snap()
            moved = [x for w in after.values() for x in w if x[0] == src]
            known = {x[0] for w in before.values() for x in w}
            made = [x for w in after.values() for x in w if x[0] not in known]
            if made:
                got = "new tab: " + made[0][1][:60]
            elif moved and moved[0][1] != url:
                got = "same tab: " + moved[0][1][:60]
        detail = f"target={target or '-'} base={base or '-'} rel={rel or '-'}"
        row(f"{name} [{detail}]", window, setting, expected, got, asked, real=True)
        try:
            sv.sp("close", id=src, window=n)
        except RuntimeError:
            pass
        cleanup(n, keep)


def run(setting):
    sv.setup(sidebar=True)
    Path(sv.SUPPORT).mkdir(parents=True, exist_ok=True)
    if setting == "open tab on":
        (Path(sv.SUPPORT) / "links.json").write_text(json.dumps({"rules": [], "settings": {"goesToOpenTab": True}}))
    sv.launch()
    try:
        sv.cmd({"do": "route", "args": ["rule", "contains", "/dest/ruled", "anywhere", "window"]})
        ws = windows("private")
        private = next(w["n"] for w in ws if w["private"])
        first_tab(private, "private", setting)
        ws = windows("new")
        other = max(w["n"] for w in ws if not w["private"])
        ordinary = min(w["n"] for w in ws if not w["private"])
        keep = {x[0] for w in snap().values() for x in w}
        for window, n in (("ordinary", ordinary), ("private", private)):
            matrix(n, window, setting, other, keep)
        if setting == "open tab on":
            probe = f"{B}/dest/control-{int(time.time())}"
            held = opened(other, probe)
            keep.add(held)
            count = sum(len(w) for w in snap().values())
            windows("link", url=probe)
            time.sleep(1.5)
            after = snap()
            got = "open tab" if sum(len(w) for w in after.values()) == count else "new tab"
            row("control: link from another app to an open page", "ordinary", setting, "open tab", got, "-")
        if REAL and setting == "default":
            for window, n in (("ordinary", ordinary), ("private", private)):
                real_sites(n, window, setting, keep)
    finally:
        sv.finish()


def table():
    head = ("kind", "window", "setting", "expected", "got", "asked")
    rows = [r[:6] for r in ROWS]
    widths = [max(len(str(x[i])) for x in rows + [head]) for i in range(6)]
    line = lambda r: "  ".join(str(v).ljust(widths[i]) for i, v in enumerate(r))
    print(line(head))
    for r in ROWS:
        print(line(r[:6]) + ("" if r[6] else "   <-- differs") + ("   (real site)" if r[7] else ""))


def main():
    t = sv.T()
    try:
        for setting in ("default", "open tab on"):
            run(setting)
    finally:
        table()
        for kind, window, setting, expected, got, asked, good, real in ROWS:
            if real:
                continue
            t.ok(f"{window}, {setting}: {kind} lands as {expected}", good, got)
        plain = [r for r in ROWS if r[3] == "same tab" and not r[7]]
        t.ok("no plain click anywhere opened a new tab", not any(r[4].startswith("new tab") for r in plain),
             [r[:5] for r in plain if r[4].startswith("new tab")])
        t.done()
        out = os.environ.get("LINK_CLICK_JSON")
        if out:
            Path(out).write_text(json.dumps(ROWS, indent=1))
    return 1 if t.failed else 0


if __name__ == "__main__":
    if sys.platform != "darwin":
        sys.exit("Tests/link_click.py requires macOS and a built Broadway.app")
    sys.exit(main())
