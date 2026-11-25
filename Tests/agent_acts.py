#!/usr/bin/env python3
import json
import os
import signal
import statistics
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
APP = Path(os.environ.get("ACTS_APP") or ROOT / "build/Broadway.app")
BROADWAY = str(APP / "Contents/Helpers/broadway")
BENCH = str(ROOT / "bench")
sv.use(f"acts-{os.getpid()}")
WORLD = sv.W
FOLDER = Path(sv.SUPPORT)
SUITE = sv.SUITE

COUNT = b"""<!doctype html><title>Count 0</title><h1>Counter</h1>
<button id="count" type="button" onclick="document.title = 'Count ' + (++n)">Count</button>
<p>Press the button.</p><script>var n = 0;</script>"""

READY = b"""<!doctype html><title>Ready</title><h1>Ready</h1>
<button type="button" onclick="setTimeout(function () { document.getElementById('coupon').disabled = false; }, 1200)">Arm coupon</button>
<button id="coupon" type="button" disabled onclick="document.title = 'applied'">Use the code</button>
<button id="stuck" type="button" disabled onclick="document.title = 'stuck'">Stays off</button>
<button type="button" onclick="veil(); setTimeout(function () { document.getElementById('veil').remove(); }, 1200)">Show veil</button>
<button id="under" type="button" onclick="document.title = 'under'">Under the veil</button>
<button type="button" onclick="var p = document.getElementById('peek'); p.style.visibility = 'hidden'; setTimeout(function () { p.style.visibility = 'visible'; }, 1200)">Blink</button>
<button id="peek" type="button" onclick="document.title = 'peeked'">Peek</button>
<button type="button" onclick="document.getElementById('slide').style.left = '320px'">Move</button>
<div style="position:relative;height:40px"><button id="slide" type="button" style="position:absolute;left:0;transition:left 1s linear" onclick="document.title = 'slid'">Slide</button></div>
<button id="kept" type="button" onclick="document.title = 'kept'">Behind the notice</button>
<script>
function veil() {
  var v = document.createElement('div');
  v.id = 'veil';
  v.style.cssText = 'position:fixed;left:0;top:0;right:0;bottom:0;background:rgba(0,0,0,0.3)';
  document.body.appendChild(v);
}
</script>"""

NOTICE = b"""<!doctype html><title>Notice</title><h1>Notice</h1>
<button id="kept" type="button" onclick="document.title = 'kept'">Behind the notice</button>
<div id="onetrust-banner-sdk" style="position:fixed;left:0;right:0;top:0;bottom:0;background:#fff">
<p>We use cookies to make this site work</p><button type="button">Accept all</button><button type="button">Reject all</button></div>"""

REDRAW = b"""<!doctype html><title>Redraw</title><h1>Shop</h1>
<input id="filter" aria-label="Filter">
<div id="app"></div>
<script>
var items = ['Blue mug', 'Red cup', 'Green bowl'], saved = 0;
function draw() {
  var q = document.getElementById('filter').value.toLowerCase();
  var html = '<button type="button" onclick="saved++; document.title = \\'saved \\' + saved">Save</button>';
  if (q.indexOf('zz') >= 0) html += '<button type="button">Save</button>';
  html += '<ul>' + items.filter(function (i) { return i.toLowerCase().indexOf(q.replace(/z/g, '')) >= 0; }).map(function (i) {
    return '<li><span>' + i + '</span> <button type="button" onclick="document.title = \\'added ' + i + '\\'">Add</button></li>';
  }).join('') + '</ul>';
  var pick = items.filter(function (i) { return q && i.toLowerCase().indexOf(q.replace(/z/g, '')) === 0; })[0] || items[0];
  html += '<section><h2>' + pick + '</h2><button type="button" onclick="document.title = \\'deleted ' + pick + '\\'">Delete</button></section>';
  document.getElementById('app').innerHTML = html;
}
document.getElementById('filter').addEventListener('input', draw);
draw();
</script>"""

REUSE = b"""<!doctype html><title>Reuse</title><h1>Pages</h1>
<ul id="rows"><li><span class="name">Blue mug</span> <button type="button" class="open">Open</button></li>
<li><span class="name">Red cup</span> <button type="button" class="open">Open</button></li>
<li><span class="name">Green bowl</span> <button type="button" class="open">Open</button></li></ul>
<button type="button" onclick="var next = ['Teal plate', 'Grey jug', 'Pink vase']; document.querySelectorAll('#rows .name').forEach(function (s, i) { s.textContent = next[i]; })">Next page</button>
<script>
document.querySelectorAll('#rows .open').forEach(function (b) {
  b.addEventListener('click', function () { document.title = 'opened ' + b.parentElement.querySelector('.name').textContent; });
});
</script>"""

ICONS = b"""<!doctype html><title>Icons</title><h1>Basket</h1>
<svg style="display:none"><symbol id="icon-trash" viewBox="0 0 10 10"><rect width="10" height="10"/></symbol></svg>
<ul>
<li><span>Blue mug</span> <button type="button" onclick="document.title = 'bin Blue mug'"><svg width="16" height="16"><use href="#icon-trash"></use></svg></button> <button type="button">Remove</button></li>
<li><span>Red cup</span> <button type="button" onclick="document.title = 'bin Red cup'"><svg width="16" height="16"><use href="#icon-trash"></use></svg></button> <button type="button">Remove</button></li>
</ul>
<footer>
<button type="button" data-icon="star" style="width:24px;height:24px"></button>
<button type="button" style="width:24px;height:24px"><i class="fa fa-heart" aria-hidden="true"></i></button>
<button type="button" style="width:24px;height:24px"><span class="icon icon-settings" aria-hidden="true"></span></button>
</footer>"""

LINKS = b"""<!doctype html><title>Links</title><h1>Links</h1>
<a href="/inside">Inside</a>
<a href="https://docs.example.org/guide?id=3">Guide</a>
<a href="https://example.com/reset?token=abc123secret">Reset</a>
<a href="https://sam:hunter2@evil.example/x">Login</a>
<a href="https://shop.127.0.0.1.example/y">Shop</a>"""

ALERTS = b"""<!doctype html><title>Alerts</title><h1>Alerts</h1>
<button type="button" onclick="alert('Done now')">Alert now</button>
<button type="button" onclick="setTimeout(function () { alert('Saved'); }, 300)">Save soon</button>
<button type="button" onclick="setTimeout(function () { document.title = confirm('Sure?') ? 'yes' : 'no'; }, 300)">Ask soon</button>
<button type="button" onclick="window.onbeforeunload = function (e) { e.preventDefault(); e.returnValue = ''; return ''; }; document.title = 'armed'">Arm leave</button>
<button type="button" onclick="window.onbeforeunload = function () { return 'Leave?'; }; document.title = 'armed'">Arm return</button>
<button type="button" onclick="window.addEventListener('beforeunload', function (e) { e.returnValue = 'Leave?'; }); document.title = 'armed'">Arm value</button>
<p>Alert page text</p>"""

ERRORS = b"""<!doctype html><title>Errors</title><h1>Errors</h1>
<button type="button" onclick="console.error('Bad thing'); null.x;">Break</button>
<button type="button" onclick="console.warn('Just a warning'); document.title = 'warned'">Warn</button>
<button type="button" onclick="for (var i = 0; i < 5; i++) console.error('Error ' + i);">Many</button>
<button type="button" onclick="document.title = 'fine'">Fine</button>"""

CANVAS = b"""<!doctype html><title>Canvas</title><style>html,body{margin:0;overflow:hidden}canvas{display:block}</style>
<canvas id="c" width="800" height="600" style="width:100vw;height:100vh"></canvas>
<script>
var c = document.getElementById('c'), seen = [];
['mousedown', 'mouseup', 'click', 'mousemove'].forEach(function (kind) {
  c.addEventListener(kind, function (e) { seen.push(kind + ' ' + Math.round(e.clientX) + ',' + Math.round(e.clientY)); document.title = seen.slice(-6).join(' | '); });
});
document.title = 'wide ' + innerWidth;
</script>"""

REACH = b"""<!doctype html><title>Reach</title><style>body{margin:0;height:4000px}button{position:absolute;left:20px;width:300px}</style>
<button id="low" type="button" style="height:60px" onclick="document.title = 'low'">Low</button>
<button id="trap" type="button" onclick="document.title = 'trap'">Trap</button>
<script>
var h = innerHeight, low = document.getElementById('low'), trap = document.getElementById('trap');
low.style.top = (h - 20) + 'px'; trap.style.top = (h + 50) + 'px'; trap.style.height = h + 'px';
document.title = 'reach ' + h;
</script>"""

PAINT = b"""<!doctype html><title>Paint</title><style>html,body{margin:0}</style>
<canvas id="c" width="400" height="300" style="position:absolute;left:0;top:0;width:400px;height:300px"></canvas>
<input id="pw" type="password" aria-label="Password" style="position:absolute;left:450px;top:20px;width:160px;height:30px">
<button type="button" style="position:absolute;left:450px;top:80px;width:100px;height:30px" onclick="document.title = 'pressed'">Press</button>
<script>
var c = document.getElementById('c'), seen = [];
['mousedown', 'mouseup', 'click', 'mousemove'].forEach(function (kind) {
  c.addEventListener(kind, function (e) { seen.push(kind + ' ' + Math.round(e.clientX) + ',' + Math.round(e.clientY)); document.title = seen.slice(-6).join(' | '); });
});
</script>"""

PLAIN = b"<!doctype html><title>Plain</title><h1>Plain</h1><p>Plain page text</p>"

PAGES = {"/count": COUNT, "/ready": READY, "/notice": NOTICE, "/redraw": REDRAW, "/reuse": REUSE, "/icons": ICONS,
         "/links": LINKS, "/alerts": ALERTS, "/errors": ERRORS, "/canvas": CANVAS, "/paint": PAINT, "/reach": REACH}

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else str(detail)[:1500], flush=True)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGES.get(self.path.split("?")[0], PLAIN)
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def bench(*words):
    return subprocess.run([BENCH, "--world", WORLD, *words], capture_output=True, text=True, timeout=30).stdout


def broadway(*words, timeout=60):
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout)


def envelope(*words, **options):
    result = broadway(*words, "--json", **options)
    try:
        return result, json.loads(result.stdout)
    except ValueError:
        return result, {"ok": False, "data": None, "error": {"code": "unparsed", "message": result.stdout + result.stderr}}


def timed(*words):
    began = time.perf_counter()
    result, parsed = envelope(*words)
    return result, parsed, time.perf_counter() - began


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def gone():
    for _ in range(60):
        if not held():
            return True
        time.sleep(0.25)
    return False


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        if condition():
            return True
        time.sleep(0.1)
    return False


def desk():
    try:
        return json.loads(bench("knowing", "desk", "list"))["pending"]
    except ValueError:
        return []


def title(tab):
    rows = envelope("tabs")[1]["data"]["tabs"]
    return next((row["title"] for row in rows if row["id"] == tab), "")


def ref_of(tab, name, role="button", nth=0):
    _, parsed = envelope("snapshot", "--tab", tab)
    found = [e for e in parsed["data"]["elements"] if e["name"] == name and e["role"] == role]
    return "@" + found[nth]["ref"] if len(found) > nth else "@e0"


def error(parsed):
    return parsed.get("error") or {}


def code(parsed):
    return error(parsed).get("code")


def said(result):
    return result.stdout + result.stderr


def opened(base, path):
    tab = broadway("open", base + path).stdout.strip()
    broadway("wait", "--tab", tab, "--idle")
    return tab


def timing(base):
    tab = opened(base, "count")
    ref = ref_of(tab, "Count")
    broadway("click", ref, "--tab", tab)
    rounds = []
    for _ in range(3):
        times = []
        for _ in range(50):
            began = time.perf_counter()
            broadway("click", ref, "--tab", tab)
            times.append((time.perf_counter() - began) * 1000)
        times.sort()
        load = os.getloadavg()[0]
        rounds.append((statistics.median(times), times[int(len(times) * 0.95)], statistics.mean(times), load))
        print(f"     50 clicks on a ready button: median {rounds[-1][0]:.0f} ms, p95 {rounds[-1][1]:.0f} ms, mean {rounds[-1][2]:.0f} ms, load {load:.1f}", flush=True)
    check("the clicks all landed", title(tab) == f"Count {50 * 3 + 1}", title(tab))
    broadway("close", "--tab", tab)


def ready(base):
    tab = opened(base, "ready")
    coupon = ref_of(tab, "Use the code")
    broadway("click", "Arm coupon", "--tab", tab, "--settle", "0")
    result, parsed, took = timed("click", coupon, "--tab", tab)
    check("a click on a button the page enables a moment later waits for it and lands", result.returncode == 0 and wait_for(lambda: title(tab) == "applied", 3), (took, parsed))

    stuck = ref_of(tab, "Stays off")
    result, parsed, took = timed("click", stuck, "--tab", tab)
    message = error(parsed).get("message", "")
    check("a button that stays disabled fails after about 3 s", code(parsed) == "not_actionable" and 2.6 <= took <= 6, (took, parsed))
    check("and says what it waited for", "Waited 3 s" in message and "stayed disabled" in message, message)
    result, parsed, took = timed("click", stuck, "--tab", tab, "--settle", "5")
    check("--settle raises the bound", code(parsed) == "not_actionable" and 4.6 <= took <= 8 and "Waited 5 s" in error(parsed).get("message", ""), (took, parsed))

    under = ref_of(tab, "Under the veil")
    broadway("click", "Show veil", "--tab", tab, "--settle", "0")
    result, parsed, took = timed("click", under, "--tab", tab)
    check("a cover that goes away is waited out", result.returncode == 0 and wait_for(lambda: title(tab) == "under", 3), (took, parsed))
    time.sleep(1.5)

    peek = ref_of(tab, "Peek")
    broadway("click", "Blink", "--tab", tab, "--settle", "0")
    result, parsed, took = timed("click", peek, "--tab", tab)
    check("a button hidden for a moment is waited for", result.returncode == 0 and wait_for(lambda: title(tab) == "peeked", 3), (took, parsed))

    slide = ref_of(tab, "Slide")
    broadway("click", "Move", "--tab", tab, "--settle", "0")
    result, parsed, took = timed("click", slide, "--tab", tab)
    check("a moving button is clicked where it stops", result.returncode == 0 and wait_for(lambda: title(tab) == "slid", 3), (took, parsed))

    result, parsed, took = timed("click", "Nowhere at all", "--tab", tab)
    check("a target that is not there fails at once", code(parsed) == "not_found" and took < 2, (took, parsed))

    broadway("go", base + "notice", "--tab", tab)
    broadway("wait", "--tab", tab, "--idle")
    kept = ref_of(tab, "Behind the notice")
    result, parsed, took = timed("click", kept, "--tab", tab)
    check("a cookie notice that stays fails at once with its buttons", code(parsed) == "not_actionable" and took < 2 and "Accept all" in json.dumps(parsed), (took, parsed))
    broadway("close", "--tab", tab)


def redraw(base):
    tab = opened(base, "redraw")
    save = ref_of(tab, "Save")
    broadway("type", "Filter", "u", "--tab", tab)
    result, parsed = envelope("click", save, "--tab", tab)
    first = (parsed.get("data") or {}).get("message", "") if parsed.get("ok") else error(parsed).get("message", "")
    check("a redrawn button with a short name keeps its ref", result.returncode == 0 and wait_for(lambda: title(tab) == "saved 1", 3), parsed)
    plain = broadway("click", "Save", "--tab", tab).stdout
    check("and the first line says so", first.startswith(save + " was redrawn. Acted on the same button, now @"), first)

    add = ref_of(tab, "Add")
    broadway("type", "Filter", "e", "--tab", tab, "--replace")
    result, parsed = envelope("click", add, "--tab", tab)
    check("a ref whose name was not unique when given is never rebound", code(parsed) == "stale_ref" and "added" not in title(tab), parsed)

    broadway("type", "Filter", "", "--tab", tab, "--replace")
    save = ref_of(tab, "Save")
    broadway("type", "Filter", "zz", "--tab", tab, "--replace")
    result, parsed = envelope("click", save, "--tab", tab)
    check("two candidates after a redraw fail as before", code(parsed) == "stale_ref", parsed)

    broadway("type", "Filter", "", "--tab", tab, "--replace")
    delete = ref_of(tab, "Delete")
    broadway("type", "Filter", "red", "--tab", tab, "--replace")
    result, parsed = envelope("click", delete, "--tab", tab)
    check("a delete whose heading changed is never rebound", code(parsed) == "stale_ref" and "deleted" not in title(tab), parsed)

    broadway("type", "Filter", "", "--tab", tab, "--replace")
    save = ref_of(tab, "Save")
    broadway("go", base + "redraw?again", "--tab", tab)
    broadway("wait", "--tab", tab, "--idle")
    result, parsed = envelope("click", save, "--tab", tab)
    check("a navigation in between still fails", code(parsed) == "stale_ref", parsed)

    broadway("go", base + "reuse", "--tab", tab)
    broadway("wait", "--tab", tab, "--idle")
    first_open = ref_of(tab, "Open")
    broadway("click", "Next page", "--tab", tab)
    result, parsed = envelope("click", first_open, "--tab", tab)
    check("a row node reused for another row never acts on the new row", result.returncode != 0 and "opened" not in title(tab), (parsed, title(tab)))
    broadway("close", "--tab", tab)


def names(base):
    tab = opened(base, "icons")
    _, parsed = envelope("snapshot", "--tab", tab)
    lines = parsed["data"].get("lines") or []
    text = broadway("snapshot", "--tab", tab).stdout
    bins = [line for line in text.splitlines() if 'icon="trash"' in line]
    check("an icon button gains the icon's name from an svg sprite", len(bins) == 2, text)
    check("and the row it sits in", any('in="Blue mug"' in line for line in bins) and any('in="Red cup"' in line for line in bins), bins)
    removes = [line for line in text.splitlines() if '"Remove"' in line]
    check("a repeated name gains its row", len(removes) == 2 and 'in="Blue mug"' in removes[0] and 'in="Red cup"' in removes[1], removes)
    check("data-icon names an icon", 'icon="star"' in text, text)
    check("an aria-hidden icon's class names it", 'icon="heart"' in text and 'icon="settings"' in text, text)
    elements = parsed["data"]["elements"]
    check("the json carries icon and in", any(e.get("icon") == "trash" and e.get("in") == "Blue mug" for e in elements), elements)
    found, parsed = envelope("find", "trash", "--tab", tab)
    check("find matches the icon word", found.returncode == 0 and parsed["data"]["count"] == 2, parsed)
    hit = broadway("click", "trash", "--in", "Red cup", "--tab", tab)
    check("an act's words match the icon word", hit.returncode == 0 and wait_for(lambda: title(tab) == "bin Red cup", 3), said(hit))
    check("the hints are page text inside the fence", "Website content" in broadway("snapshot", "--tab", tab).stderr)
    broadway("close", "--tab", tab)


def links(base):
    tab = opened(base, "links")
    text = broadway("snapshot", "--tab", tab).stdout
    line = lambda name: next((l for l in text.splitlines() if f'"{name}"' in l), "")
    check("a link on the same site shows its path", line("Inside").endswith("-> /inside"), line("Inside"))
    check("a link to another site shows where", line("Guide").endswith("-> docs.example.org/guide?id=3"), line("Guide"))
    check("its address is scrubbed", line("Reset").endswith("-> example.com/reset?token=hidden") and "abc123" not in text, line("Reset"))
    check("a user and password never show", line("Login").endswith("-> evil.example/x") and "hunter2" not in text, line("Login"))
    broadway("close", "--tab", tab)


def alerts(base):
    tab = opened(base, "alerts")
    now = broadway("click", "Alert now", "--tab", tab)
    check("an alert during an act is closed and said", now.returncode == 0 and 'The page showed an alert: "Done now". Broadway closed it' in now.stdout, said(now))
    broadway("click", "Save soon", "--tab", tab, "--settle", "0")
    time.sleep(1.2)
    later = broadway("read", "--tab", tab)
    check("an alert between commands no longer blocks the next one", later.returncode == 0 and "Alert page text" in later.stdout, said(later))
    check("and the next answer says it", 'The page showed an alert: "Saved". Broadway closed it' in said(later), said(later))
    broadway("click", "Ask soon", "--tab", tab, "--settle", "0")
    time.sleep(1.2)
    asked, parsed = envelope("read", "--tab", tab)
    check("a confirm still waits for the agent", code(parsed) == "dialog_open", parsed)
    broadway("dialog", "dismiss", "--tab", tab)

    broadway("click", "Arm leave", "--tab", tab)
    went = broadway("go", base + "plain", "--tab", tab)
    check("a leave-page question on go is accepted", went.returncode == 0 and wait_for(lambda: title(tab) == "Plain", 5), said(went))
    check("and the answer says the page had warned", "warned" in said(went), said(went))
    broadway("go", base + "alerts", "--tab", tab)
    broadway("wait", "--tab", tab, "--idle")
    broadway("go", base + "plain", "--tab", tab)
    broadway("wait", "--tab", tab, "--idle")
    broadway("back", "--tab", tab)
    broadway("wait", "--tab", tab, "--idle")
    broadway("click", "Arm leave", "--tab", tab)
    went = broadway("forward", "--tab", tab)
    check("and on a history step", went.returncode == 0 and "warned" in said(went), said(went))
    broadway("go", base + "alerts", "--tab", tab)
    broadway("wait", "--tab", tab, "--idle")
    broadway("click", "Arm leave", "--tab", tab)
    shut = broadway("close", "--tab", tab)
    check("and on close", shut.returncode == 0 and "warned" in said(shut) and wait_for(lambda: tab not in broadway("tabs").stdout, 5), said(shut))
    for button in ["Arm return", "Arm value"]:
        tab = opened(base, "alerts")
        broadway("click", button, "--tab", tab)
        shut = broadway("close", "--tab", tab)
        check(f"a page that warns with {button.split()[-1]} is caught on close", shut.returncode == 0 and "warned" in said(shut), said(shut))


def names_of_tabs(base):
    first = broadway("open", base + "one", "--name", "cafe")
    tab = first.stdout.strip().split()[0] if first.stdout.strip() else ""
    check("open takes a name", first.returncode == 0 and len(tab) == 8, said(first))
    read = broadway("read", "--tab", "cafe")
    check("--tab takes the name", read.returncode == 0 and "Plain page text" in read.stdout, said(read))
    rows = envelope("tabs")[1]["data"]["tabs"]
    check("tabs shows the name", any(row["id"] == tab and row.get("name") == "cafe" for row in rows), rows)
    check("and so does the plain list", any(line.startswith(tab) and "cafe" in line for line in broadway("tabs").stdout.splitlines()), broadway("tabs").stdout)
    again, parsed = envelope("open", base + "two", "--name", "cafe")
    check("a second tab with the name is refused with the first one's id", again.returncode != 0 and bool(tab) and tab in error(parsed).get("message", ""), parsed)
    broadway("go", base + "three", "--tab", "cafe")
    broadway("wait", "--tab", "cafe", "--idle")
    rows = envelope("tabs")[1]["data"]["tabs"]
    check("the name survives a navigation", any(row["id"] == tab and row.get("name") == "cafe" and "three" in row["url"] for row in rows), rows)
    broadway("close", "--tab", "cafe")
    fresh = broadway("open", base + "four", "--name", "cafe")
    check("the name ends with the tab", fresh.returncode == 0 and fresh.stdout.strip() != tab, said(fresh))
    broadway("close", "--tab", "cafe")


def errors(base):
    tab = opened(base, "errors")
    broke, parsed = envelope("click", "Break", "--tab", tab)
    text = broadway("click", "Break", "--tab", tab).stdout
    data = parsed.get("data") or {}
    check("an act's answer carries its page errors", "! 2 page errors" in text and "TypeError" in text and "broadway console --since" in text, text)
    check("in json with the cursor", len(data.get("errors", {}).get("list", [])) == 2 and data.get("errors", {}).get("cursor"), data.get("errors"))
    warned = broadway("click", "Warn", "--tab", tab).stdout
    check("warnings stay out", "page error" not in warned, warned)
    many = broadway("click", "Many", "--tab", tab).stdout
    shown = [l for l in many.splitlines() if l.startswith('  "Error')]
    check("at most three are listed", "! 5 page errors" in many and len(shown) <= 3, many)
    quiet = broadway("-q", "click", "Break", "--tab", tab).stdout
    check("--quiet leaves them out", "page error" not in quiet, quiet)
    fine = broadway("click", "Fine", "--tab", tab).stdout
    check("a clean act has no error line", "page error" not in fine, fine)
    broadway("close", "--tab", tab)


def point(base):
    tab = opened(base, "canvas")
    inner = int(title(tab).split()[-1]) if title(tab).startswith("wide ") else 0
    look = broadway("snapshot", "--tab", tab)
    check("a page that is one canvas says so", "canvas" in look.stdout.lower() and "broadway shot" in look.stdout and "click --at" in look.stdout, said(look))
    folder = Path(sv.SUPPORT) / "shots"
    folder.mkdir(parents=True, exist_ok=True)
    broadway("shot", "--tab", tab, "-o", str(folder / "canvas.png"))
    png = (folder / "canvas.png").read_bytes()
    wide = int.from_bytes(png[16:20], "big")
    scale = wide / inner if inner else 1.0
    print(f"     shot is {wide} px wide, the page {inner} points, so {scale:.2f} picture pixels a point", flush=True)
    clicked = broadway("click", "--at", "100,50", "--tab", tab)
    shown = title(tab)
    want = f"click {round(100 / scale)},{round(50 / scale)}"
    check("click --at lands at the point of the picture", clicked.returncode == 0 and want in shown, (said(clicked), shown, want))
    check("the answer names what is under the point", "canvas" in clicked.stdout.lower(), clicked.stdout)
    moved = broadway("hover", "--at", "200,100", "--tab", tab)
    check("hover --at moves there", moved.returncode == 0 and f"mousemove {round(200 / scale)},{round(100 / scale)}" in title(tab), (said(moved), title(tab)))
    dragged = broadway("drag", "--at", "40,40", "--to", "160,120", "--tab", tab)
    shown = title(tab)
    check("drag --at goes from one point to the other", dragged.returncode == 0 and f"mousedown {round(40 / scale)},{round(40 / scale)}" in shown
          and f"mouseup {round(160 / scale)},{round(120 / scale)}" in shown, (said(dragged), shown))
    sv.cmd({"do": "magnify", "id": tab, "zoom": 1.5})
    broadway("shot", "--tab", tab, "-o", str(folder / "zoomed.png"))
    zoomed = broadway("click", "--at", f"{round(300 * scale)},{round(150 * scale)}", "--tab", tab)
    check("at page zoom 150 % the point still lands", zoomed.returncode == 0 and "click 200,100" in title(tab), (said(zoomed), title(tab)))
    sv.cmd({"do": "magnify", "id": tab, "zoom": 1.0})
    broadway("go", base + "reach", "--tab", tab)
    broadway("wait", "--tab", tab, "--idle")
    high = int(title(tab).split()[-1]) if title(tab).startswith("reach ") else 0
    low = broadway("click", "--at", f"{round(100 * scale)},{round((high - 10) * scale)}", "--tab", tab)
    check("a point on a button the click scrolls to still lands on it", low.returncode == 0 and wait_for(lambda: title(tab) == "low", 3), (said(low), title(tab)))
    broadway("go", base + "paint", "--tab", tab)
    broadway("wait", "--tab", tab, "--idle")
    _, parsed = envelope("snapshot", "--tab", tab, "--boxes")
    elements = (parsed.get("data") or {}).get("elements") or []
    password = next((e for e in elements if e.get("hidden")), None)
    check("snapshot --boxes adds each ref's box", password is not None and "box" in password and all("box" in e for e in elements), elements)
    boxes = broadway("snapshot", "--tab", tab, "--boxes").stdout
    check("and the lines show it", "box=" in boxes, boxes)
    if password and "box" in password:
        box = password["box"]
        at = f"{round(box['x'] + box['width'] / 2)},{round(box['y'] + box['height'] / 2)}"
        refused, parsed = envelope("click", "--at", at, "--tab", tab)
        check("a point inside a secret field is refused", refused.returncode != 0 and code(parsed) == "secret_field", parsed)
    pressed = broadway("click", "--at", f"{round(500 * scale)},{round(95 * scale)}", "--tab", tab)
    check("a point on a button clicks it and names it", pressed.returncode == 0 and wait_for(lambda: title(tab) == "pressed", 3) and '"Press"' in pressed.stdout, said(pressed))
    broadway("close", "--tab", tab)


SECTIONS = {"timing": timing, "ready": ready, "redraw": redraw, "names": names, "links": links, "alerts": alerts,
            "tabnames": names_of_tabs, "errors": errors, "point": point}


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    wanted = sys.argv[1:] or list(SECTIONS)
    os.environ["BROADWAY_AGENT"] = WORLD
    os.environ["BROADWAY_AGENT_NAME"] = "Acts Probe"
    os.environ.pop("BROADWAY_TAB", None)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sv.wipe()
    try:
        subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
        subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
        broadway("tabs")
        for name in wanted:
            print(f"== {name}", flush=True)
            try:
                SECTIONS[name](base)
            except Exception as problem:
                check(f"{name} ran to the end", False, repr(problem))
    finally:
        subprocess.run([BENCH, "--world", WORLD, "quit"], capture_output=True)
        if not gone():
            for pid in held():
                os.kill(int(pid), signal.SIGKILL)
        sv.wipe()
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
