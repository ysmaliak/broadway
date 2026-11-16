#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "build/Broadway.app"
BROADWAY = str(APP / "Contents/Helpers/broadway")
BENCH = str(ROOT / "bench")
sv.use(f"reach-{os.getpid()}")
WORLD = sv.W
FOLDER = Path(sv.SUPPORT)
SUITE = sv.SUITE
SCRATCH = Path(tempfile.mkdtemp(prefix="broadway-reach-"))

LIST = "[...this.files].map(f => f.name + ':' + f.size).join(',')"

PAGE = """<!doctype html><title>Reach</title>
<style>.sr{position:absolute;opacity:0;width:0;height:0;margin:0}.track{display:inline-block;width:40px;height:20px;background:#ccc;cursor:pointer}
.btn{display:inline-block;padding:4px 8px;border:1px solid #888;cursor:pointer}#zone{width:220px;height:90px;border:1px dashed #888}</style>
<div role="main">
<h1>Edge Certificates</h1>
<div class="row"><span>Always Use HTTPS</span>
<label class="toggle"><input id="https" class="sr" type="checkbox" onchange="document.title='https ' + this.checked"><span class="track"></span></label></div>
<button role="switch" aria-checked="false" id="dark" onclick="this.setAttribute('aria-checked', this.getAttribute('aria-checked') === 'true' ? 'false' : 'true')">Dark mode</button>
<p><label for="csr" class="btn">Choose File</label><input id="csr" type="file" accept=".certSigningRequest" style="display:none" onchange="document.title='csr ' + LIST"></p>
<p><input id="plain" type="file" multiple aria-label="Attachments" onchange="document.title='plain ' + LIST"></p>
<div><input id="hiddenfile" type="file" hidden onchange="document.title='hidden ' + LIST"><button type="button" onclick="document.getElementById('hiddenfile').click()">Upload photo</button></div>
<div id="zone" ondragover="event.preventDefault()" ondrop="event.preventDefault(); document.title = 'dropped ' + [...event.dataTransfer.files].map(f => f.name + ':' + f.size).join(',')">Drop files here</div>
<div contenteditable="true" aria-label="Editor">Hello editor</div>
<div role="combobox" aria-expanded="false" aria-haspopup="listbox" tabindex="0">Pick a colour</div>
<div style="cursor:pointer" onclick="document.title='card'">Open settings</div>
<shadow-host></shadow-host>
<iframe src="/inner" width="300" height="80"></iframe>
<iframe src="http://localhost:PORT/inner?far" width="300" height="80"></iframe>
<textarea id="notes" required aria-label="Notes"></textarea>
<select aria-label="Size"><option>Small</option><option>Large</option></select>
<p><a href="/report.bin">Get report</a></p>
</div>
<script>
document.cookie = 'sess=yes; path=/';
customElements.define('shadow-host', class extends HTMLElement { connectedCallback() {
  const root = this.attachShadow({ mode: 'open' });
  root.innerHTML = '<button onclick="document.title=\\'shadow\\'">Shadow button</button>';
} });
</script>""".replace("LIST", LIST)

MORE = """<!doctype html><title>More</title>
<form onsubmit="event.preventDefault()">
<label>Full name <input id="name" value="Old Name"></label>
<label>Email <input id="email" type="email"></label>
<label>Country <select id="country"><option value="">Pick</option><option value="es">Spain</option><option value="fr">France</option></select></label>
<label><input id="agree" type="checkbox"> I agree</label>
<label>PIN <input id="pin" autocomplete="one-time-code"></label>
<button type="button" id="report" onclick="document.title = ['name', 'email', 'country'].map(id => document.getElementById(id).value).concat([document.getElementById('agree').checked]).join('|')">Report</button>
</form>
<div id="card" draggable="true" ondragstart="event.dataTransfer.setData('text/plain', 'card')" style="width:80px;height:30px;background:#ddd">Card</div>
<div id="bin" ondragover="event.preventDefault()" ondrop="event.preventDefault(); document.title = 'dropped ' + event.dataTransfer.getData('text/plain')" style="width:120px;height:60px;border:1px solid">Done column</div>
<p id="words">The order number is 4471 today.</p>
<input id="keys" aria-label="Keys" onkeydown="if (event.shiftKey && event.key === 'Tab') { event.preventDefault(); document.title = 'shift tab'; }">
<button type="button" onclick="fetch('/api/save?x=1').then(() => document.title = 'saved')">Save remotely</button>
<div style="height:3000px"></div><p>Bottom of the page</p>
"""

ANSWERS = """<!doctype html><title>Answers</title>
<nav aria-label="Shop"><a href="/answers?two">Teas</a></nav>
<main>
<h1>Basket</h1>
<p id="count">Your basket is empty</p>
<button onclick="setTimeout(() => { document.getElementById('count').textContent = 'One tea in your basket'; const s = document.createElement('p'); s.setAttribute('role', 'status'); s.textContent = 'Added to basket'; document.body.appendChild(s); }, 300)">Add to basket</button>
<button style="position:absolute;top:400px;left:20px" onclick="document.title = 'bought'">Buy now</button>
<section aria-label="Many">BUTTONS</section>
</main>
<div id="pop" role="dialog" aria-label="Newsletter" style="display:none;position:fixed;inset:0;background:#fff"><button onclick="document.getElementById('pop').style.display='none'">Close</button></div>
"""

MODAL = """<!doctype html><title>Modal</title><button>Behind it</button>
<dialog id="d"><h2>Cookies</h2><button onclick="document.getElementById('d').close()">Accept all</button></dialog>
<script>document.getElementById('d').showModal()</script>"""

INNER = """<!doctype html><title>Inner</title><button onclick="parent.postMessage('inner', '*'); document.title='inner clicked'">Inner button</button>
<label><input type="checkbox"> Inner box</label>"""

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail, flush=True)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        port = self.server.server_port
        if self.path.endswith(".bin"):
            if "signed" in self.path and "sess=yes" not in (self.headers.get("cookie") or ""):
                self.send_response(403)
                self.send_header("content-length", "0")
                self.end_headers()
                return
            data = b"y" * 4321
            self.send_response(200)
            self.send_header("content-type", "application/octet-stream")
            self.send_header("content-disposition", f'attachment; filename="{self.path.rsplit("/", 1)[1]}"')
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        if self.path.startswith("/inner"):
            body = INNER
        elif self.path.startswith("/more"):
            body = MORE
        elif self.path.startswith("/answers"):
            body = ANSWERS.replace("BUTTONS", "".join(f"<button>Item {n}</button>" for n in range(1, 201)))
            if "covered" in self.path:
                body = body.replace("display:none;position:fixed", "display:block;position:fixed")
        elif self.path.startswith("/modal"):
            body = MODAL
        elif self.path.startswith("/api/"):
            time.sleep(0.4)
            body = "{}"
        else:
            body = PAGE.replace("PORT", str(port))
        data = body.encode()
        self.send_response(200)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def bench(*words):
    return subprocess.run([BENCH, "--world", WORLD, *words], capture_output=True, text=True, timeout=30).stdout


def broadway(*words, timeout=60, env=None):
    environment = dict(os.environ, **(env or {}))
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=timeout, env=environment)


def envelope(*words, **options):
    result = broadway(*words, "--json", **options)
    try:
        return result, json.loads(result.stdout)
    except ValueError:
        return result, {"ok": False, "error": {"code": "unparsed", "message": result.stdout + result.stderr}, "data": None}


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


def answered(answer, *words, cwd=None):
    running = subprocess.Popen([BROADWAY, "--world", WORLD, *words, "--json"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=cwd)
    asked = wait_for(desk, 15)
    question = desk()
    if asked:
        bench("knowing", "desk", answer)
    output, errors = running.communicate(timeout=60)
    try:
        parsed = json.loads(output)
    except ValueError:
        parsed = {"ok": False, "error": {"code": "unparsed", "message": output + errors}, "data": None}
    return running.returncode, parsed, question


def title(tab):
    rows = envelope("tabs")[1]["data"]["tabs"]
    return next((row["title"] for row in rows if row["id"] == tab), "")


def snapshot(tab):
    return envelope("snapshot", "--tab", tab)[1]["data"]["elements"]


def ref(elements, role, name):
    found = next((e for e in elements if e["role"] == role and name in e["name"]), None)
    return "@" + found["ref"] if found else None


def snapshot_sees(tab):
    plain = broadway("snapshot", "--tab", tab).stdout
    elements = snapshot(tab)
    roles = {(e["role"], e["name"]) for e in elements}
    check("a landmark role no longer hides what is inside it", any(e["role"] == "heading" and "Edge Certificates" in e["name"] for e in elements), plain)
    https = next((e for e in elements if e["role"] == "checkbox" and "Always Use HTTPS" in e["name"]), None)
    check("a checkbox hidden behind a styled label is listed, named by its row", https is not None, plain)
    check("with its state", https is not None and https.get("checked") is False, https)
    dark = next((e for e in elements if e["role"] == "switch"), None)
    check("an ARIA switch is listed off", dark is not None and dark.get("checked") is False and " off" in plain, dark)
    csr = next((e for e in elements if e["name"] == "Choose File"), None)
    check("a hidden file field is given to its visible label", csr is not None and csr["role"] == "button" and csr["upload"]["accept"] == ".certSigningRequest", csr)
    plain_file = next((e for e in elements if e["role"] == "file" and e["name"] == "Attachments"), None)
    check("a plain file field says it takes several", plain_file is not None and plain_file["upload"]["multiple"] is True, plain_file)
    check("the plain line says what a file field takes", 'takes a file accept=".certSigningRequest"' in plain and "takes files" in plain, plain)
    check("an upload button over a hidden field is listed", ("button", "Upload photo") in roles, roles)
    editor = next((e for e in elements if e["role"] == "textbox" and e["name"] == "Editor"), None)
    check("a contenteditable editor with its words", editor is not None and editor.get("value") == "Hello editor", editor)
    combo = next((e for e in elements if e["role"] == "combobox" and "Pick a colour" in e["name"]), None)
    check("a select look-alike, collapsed", combo is not None and combo.get("expanded") is False, combo)
    check("a clickable div", ("clickable", "Open settings") in roles, roles)
    check("a drop zone", ("dropzone", "Drop files here") in roles, roles)
    check("a button in an open shadow root", ("button", "Shadow button") in roles, roles)
    notes = next((e for e in elements if e["name"] == "Notes"), None)
    check("a required box says so", notes is not None and notes.get("required") is True, notes)
    framed = [e for e in elements if e["ref"].startswith("f")]
    hosts = {e.get("frame") for e in framed}
    check("same-origin and cross-origin frames get their own refs", {"127.0.0.1", "localhost"} <= hosts, framed)
    inner = next((e for e in framed if e.get("frame") == "localhost" and e["name"] == "Inner button"), None)
    clicked = broadway("click", "@" + inner["ref"], "--tab", tab) if inner else None
    check("a cross-origin frame's button can be clicked", clicked is not None and clicked.returncode == 0, clicked and clicked.stderr)

    flip = broadway("click", ref(elements, "checkbox", "Always Use HTTPS"), "--tab", tab)
    check("the hidden switch flips by its ref", flip.returncode == 0 and wait_for(lambda: title(tab) == "https true", 3), flip.stderr + title(tab))
    again = snapshot(tab)
    https = next((e for e in again if e["role"] == "checkbox" and "Always Use HTTPS" in e["name"]), None)
    check("and the snapshot sees it on, keeping its ref", https is not None and https["checked"] is True and "@" + https["ref"] == ref(elements, "checkbox", "Always Use HTTPS"), https)
    toggled = broadway("click", "@" + dark["ref"], "--tab", tab)
    after = next((e for e in snapshot(tab) if e["role"] == "switch"), None)
    check("an ARIA switch flips and keeps its ref", toggled.returncode == 0 and after and after["checked"] is True and after["ref"] == dark["ref"], (toggled.stderr, after))


def write(name, data=b"x" * 1234):
    path = SCRATCH / name
    path.write_bytes(data)
    return str(path)


def uploads(tab):
    elements = snapshot(tab)
    csr = write("request.certSigningRequest", b"-----BEGIN CERTIFICATE REQUEST-----\n")
    code, parsed, asked = answered("yes", "upload", ref(elements, "button", "Choose File"), csr, "--tab", tab)
    check("an upload asks the person in the default mode", bool(asked) and "Upload" in asked[0]["title"] and "request.certSigningRequest" in asked[0]["quote"], asked)
    check("a hidden field behind a label takes the file", code == 0 and wait_for(lambda: title(tab).startswith("csr request.certSigningRequest:"), 3), (parsed, title(tab)))
    check("the answer says what was attached", code == 0 and parsed["data"]["attached"][0]["name"] == "request.certSigningRequest" and parsed["data"]["site"] == "127.0.0.1", parsed)
    check("through the page's own chooser, with no panel", code == 0 and parsed["data"]["how"] == "chooser", parsed)

    listed = envelope("files", "list")[1]
    check("files list has what was given", any(row.get("path", "").endswith("request.certSigningRequest") for row in (listed.get("data") or {}).get("files", [])), listed)

    a, b = write("one.txt", b"a" * 10), write("two.txt", b"b" * 20)
    code, parsed, _ = answered("yes", "upload", ref(elements, "file", "Attachments"), a, b, "--tab", tab)
    check("several files to a plain field", code == 0 and wait_for(lambda: title(tab) == "plain one.txt:10,two.txt:20", 3), (parsed, title(tab)))
    code, parsed, _ = answered("yes", "upload", ref(elements, "button", "Upload photo"), a, "--tab", tab)
    check("an upload button over a hidden field", code == 0 and wait_for(lambda: title(tab) == "hidden one.txt:10", 3), (parsed, title(tab)))
    code, parsed, _ = answered("yes", "upload", ref(elements, "dropzone", "Drop files here") or "@e999", b, "--tab", tab)
    zone = next((e for e in elements if "Drop files here" in e["name"]), None)
    if zone is None:
        check("a drop zone is listed", False, [e["name"] for e in elements])
    else:
        check("a drop zone takes a drop", code == 0 and parsed["data"]["how"] == "drop" and wait_for(lambda: title(tab) == "dropped two.txt:20", 3), (parsed, title(tab)))

    hidden_file = write(".secret-token", b"nope")
    result, parsed = envelope("upload", ref(elements, "file", "Attachments"), hidden_file, "--tab", tab)
    check("a dotfile is refused before anyone is asked", result.returncode == 1 and parsed["error"]["code"] == "refused" and not desk(), parsed)
    result, parsed = envelope("upload", ref(elements, "file", "Attachments"), str(Path.home() / ".ssh/id_ed25519"), "--tab", tab)
    check("~/.ssh is refused", result.returncode == 1 and parsed["error"]["code"] == "refused", parsed)
    result, parsed = envelope("upload", ref(elements, "file", "Attachments"), str(Path.home() / "Library/Preferences/x.plist"), "--tab", tab)
    check("~/Library is refused", result.returncode == 1 and parsed["error"]["code"] == "refused", parsed)
    result, parsed = envelope("upload", ref(elements, "file", "Attachments"), "/etc/hosts", "--tab", tab)
    check("a file outside home and temporary folders is refused", result.returncode == 1 and parsed["error"]["code"] == "refused", parsed)
    result, parsed = envelope("upload", ref(elements, "button", "Upload photo"), a, b, "--tab", tab)
    check("two files to a one-file field are refused", result.returncode == 1 and parsed["error"]["code"] == "refused" and "one file" in parsed["error"]["message"], parsed)
    wrong = write("photo.png", b"png")
    result, parsed = envelope("upload", ref(elements, "button", "Choose File"), wrong, "--tab", tab)
    check("a file the field doesn't accept is refused", result.returncode == 1 and "isn't one" in parsed["error"]["message"], parsed)
    code, parsed, _ = answered("no", "upload", ref(elements, "file", "Attachments"), a, "--tab", tab)
    check("a no stops the upload", code == 1 and parsed["error"]["code"] == "said_no", parsed)
    code, parsed, _ = answered("yes", "upload", ref(elements, "file", "Attachments"), "two.txt", "--tab", tab, cwd=SCRATCH)
    check("a relative path is the caller's, not the app's", code == 0 and parsed["data"]["attached"][0]["path"].endswith("/two.txt") and wait_for(lambda: title(tab) == "plain two.txt:20", 3), parsed)


def stalled_folder(tab):
    elements = snapshot(tab)
    stall = SCRATCH / "stall"
    stall.mkdir(exist_ok=True)
    held = stall / "held.txt"
    held.write_bytes(b"x")
    began = time.time()
    running = subprocess.Popen([BROADWAY, "--world", WORLD, "upload", ref(elements, "file", "Attachments"), str(held), "--tab", tab, "--json"],
                               stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(1.5)
    quick = time.time()
    status = broadway("tabs", timeout=10)
    check("the app answers while a folder waits on macOS", status.returncode == 0 and time.time() - quick < 3, status.stderr)
    output, _ = running.communicate(timeout=40)
    parsed = json.loads(output)
    check("the upload gives up with needs_you, in time", parsed["error"]["code"] == "needs_you" and time.time() - began < 20, parsed)


def downloads(tab, base):
    elements = snapshot(tab)
    result, parsed = envelope("download", ref(elements, "link", "Get report"), "--tab", tab)
    data = parsed.get("data") or {}
    check("download by ref saves into Broadway's folder for agents", result.returncode == 0 and data.get("bytes") == 4321
          and "/Agent Downloads/Reach Probe/report" in data.get("path", ""), parsed)
    check("and says what it is", data.get("name", "").startswith("report") and data.get("site") == "127.0.0.1", data)
    check("the file is there", Path(data.get("path", "/nonexistent")).is_file())
    result, parsed = envelope("download", "--url", base + "signed.bin", "--tab", tab)
    data = parsed.get("data") or {}
    check("download by url carries the tab's sign-in", result.returncode == 0 and data.get("bytes") == 4321, parsed)
    listed = envelope("downloads", "list")[1]
    rows = (listed.get("data") or {}).get("downloads", [])
    check("downloads list has them", any("signed" in row.get("name", "") for row in rows), listed)
    result, parsed = envelope("download", "--url", "file:///etc/hosts", "--tab", tab)
    check("only web addresses", result.returncode == 1 and parsed["error"]["code"] == "refused", parsed)
    result, parsed = envelope("download", ref(elements, "heading", "Edge"), "--tab", tab, "--seconds", "2")
    check("a click that starts nothing times out", result.returncode == 1 and parsed["error"]["code"] == "timeout", parsed)
    result, parsed = envelope("download", "--tab", tab)
    check("download needs a ref or a url", result.returncode == 1, parsed)


def frozen_downloads(tab, base):
    began = time.time()
    person = broadway(base + "person.bin")
    check("a person's download starts", person.returncode == 0, person.stderr)
    time.sleep(1)
    quick = time.time()
    answered_tabs = broadway("tabs", timeout=10)
    check("the app answers while the Downloads folder waits on macOS", answered_tabs.returncode == 0 and time.time() - quick < 3, answered_tabs.stderr)
    held_file = FOLDER / "Held Downloads" / "person.bin"
    check("the file goes to Broadway's own folder instead of freezing", wait_for(held_file.is_file, 20) and time.time() - began < 25, list((FOLDER / "Held Downloads").glob("*")) if (FOLDER / "Held Downloads").exists() else "none")


def deadline(tab):
    began = time.time()
    result, parsed = envelope("--timeout", "2", "wait", "Never on the page", "--seconds", "20", "--tab", tab)
    took = time.time() - began
    check("--timeout ends a call in time with exit 4", result.returncode == 4 and parsed["error"]["code"] == "deadline" and took < 6, (took, parsed))
    pids = held()
    for pid in pids:
        os.kill(int(pid), signal.SIGSTOP)
    try:
        began = time.time()
        result, parsed = envelope("tabs", timeout=60)
        took = time.time() - began
        check("an app that doesn't answer ends the call with exit 4", result.returncode == 4 and parsed["error"]["code"] == "not_answering" and took < 20, (took, parsed))
        check("and says why", "system prompt" in parsed["error"]["message"], parsed)
        plain = broadway("snapshot", "--tab", tab, timeout=60)
        check("the plain words say it too", plain.returncode == 4 and "isn't answering" in plain.stderr, plain.stderr)
    finally:
        for pid in pids:
            os.kill(int(pid), signal.SIGCONT)
    check("it answers again once it can", wait_for(lambda: broadway("tabs").returncode == 0, 10))


def more(tab, base):
    broadway("go", base + "more", "--tab", tab)
    broadway("wait", "--tab", tab, "Bottom of the page")
    found = envelope("locate", "agree", "--tab", tab)[1]
    rows = (found.get("data") or {}).get("elements", [])
    check("locate by words gives refs", len(rows) == 1 and rows[0]["role"] == "checkbox", found)
    buttons = envelope("locate", "--role", "button", "--tab", tab)[1]["data"]["elements"]
    check("locate by role", {"Report", "Save remotely"} <= {e["name"] for e in buttons}, buttons)
    elements = snapshot(tab)
    name = ref(elements, "textbox", "Full name")
    fields = json.dumps({name: "Sam Lee", "Email": "sam@example.com", "Country": "Spain", "I agree": True})
    result, parsed = envelope("fill", fields, "--tab", tab)
    broadway("click", ref(elements, "button", "Report"), "--tab", tab)
    check("fill sets a whole form in one call, replacing what was there", result.returncode == 0 and wait_for(lambda: title(tab) == "Sam Lee|sam@example.com|es|true", 3), (parsed, title(tab)))
    result, parsed = envelope("fill", json.dumps({"PIN": "1234"}), "--tab", tab)
    check("fill refuses a code field", result.returncode == 1 and parsed["error"]["code"] == "refused" and "never type" in parsed["error"]["message"], parsed)
    result, parsed = envelope("fill", json.dumps({"Nowhere": "x"}), "--tab", tab)
    check("fill names a label it can't find", result.returncode == 1 and "No field" in parsed["error"]["message"], parsed)

    result = broadway("drag", ref(elements, "draggable", "Card") or "@e0", ref(elements, "dropzone", "Done column") or "@e0", "--tab", tab)
    check("drag drops one element on another", result.returncode == 0 and wait_for(lambda: title(tab) == "dropped card", 3), (result.stderr, title(tab)))

    keys = ref(elements, "textbox", "Keys")
    broadway("click", keys, "--tab", tab)
    result = broadway("press", "Shift+Tab", "--tab", tab)
    check("press takes a key with modifiers", result.returncode == 0 and wait_for(lambda: title(tab) == "shift tab", 3), (result.stderr, title(tab)))
    result, parsed = envelope("press", "Meta+v", "--tab", tab)
    check("paste is refused", result.returncode == 1 and parsed["error"]["code"] == "refused", parsed)
    result, parsed = envelope("press", "Hyper+q", "--tab", tab)
    check("a made-up modifier is bad input", parsed["error"]["code"] == "bad_input", parsed)
    result, parsed = envelope("select", name, "Lee", "--tab", tab)
    check("select picks text inside a box", result.returncode == 0 and parsed["data"]["selected"] == "Lee", parsed)

    broadway("click", ref(elements, "button", "Save remotely"), "--tab", tab)
    result, parsed = envelope("wait", "--request", "/api/save", "--seconds", "5", "--tab", tab)
    check("wait for a request", result.returncode == 0 and "/api/save" in parsed["data"]["url"], parsed)
    result = broadway("wait", "--idle", "--seconds", "5", "--tab", tab)
    check("wait for the network to settle", result.returncode == 0, result.stderr)

    folder = SCRATCH / "shots"
    folder.mkdir(exist_ok=True)
    whole = broadway("shot", "--full", "-o", str(folder / "full.png"), "--tab", tab)
    part = broadway("shot", ref(elements, "button", "Report"), "-o", str(folder / "button.png"), "--tab", tab)
    plain = broadway("shot", "-o", str(folder / "view.png"), "--tab", tab)
    def size(path):
        data = path.read_bytes()
        return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    ok = whole.returncode == 0 and part.returncode == 0 and plain.returncode == 0
    check("a full-page shot is taller than the window", ok and size(folder / "full.png")[1] > size(folder / "view.png")[1] * 2, (whole.stderr, part.stderr))
    check("a shot of one element is that element", ok and size(folder / "button.png")[0] < size(folder / "view.png")[0] / 3, ok and size(folder / "button.png"))
    result, parsed = envelope("resize", "390", "844", "--tab", tab)
    check("resize sets the page's size", result.returncode == 0 and parsed["data"]["width"] == 390, parsed)
    broadway("resize", "1280", "800", "--tab", tab)


def answers(tab, base):
    broadway("go", base + "answers", "--tab", tab)
    broadway("wait", "--tab", tab, "Basket")
    first = envelope("snapshot", "--tab", tab)[1]["data"]
    again = envelope("snapshot", "--tab", tab)[1]["data"]
    refs = [e["ref"] for e in first["elements"]]
    given = sorted(int(r[1:]) for r in refs + [r["ref"] for r in first.get("regions", [])])
    check("refs start at e1 on a page", given[:1] == [1], given[:3])
    check("and stay the same between looks", refs == [e["ref"] for e in again["elements"]], (refs[:5], [e["ref"] for e in again["elements"]][:5]))
    check("a long page shows 120 and counts the rest", first.get("shown") == 120 and first.get("total", 0) > 200, (first.get("shown"), first.get("total")))
    many = next((r for r in first.get("regions", []) if r.get("name") == "Many"), None)
    inside = envelope("snapshot", "--tab", tab, "--in", "@" + many["ref"])[1]["data"] if many else {}
    check("--in shows only what is inside a part", many is not None and inside.get("total") == 200 and all(e["name"].startswith("Item") for e in inside.get("elements", [])), inside.get("total"))
    links = envelope("snapshot", "--tab", tab, "--role", "link")[1]["data"]["elements"]
    check("--role keeps only those roles", [e["name"] for e in links] == ["Teas"], links)
    found = envelope("snapshot", "--tab", tab, "--find", "Item 199")[1]["data"]["elements"]
    check("--find keeps only elements with the words", [e["name"] for e in found] == ["Item 199"], found)
    result, parsed = envelope("click", "Add to basket", "--tab", tab, "--expect", "one tea in your basket")
    data = parsed.get("data") or {}
    check("a click by words lands", result.returncode == 0 and data.get("did") == "click", parsed)
    check("its answer waits for what the page says", any("Added to basket" in (e.get("name") or "") for e in data.get("appeared", [])) or "Added to basket" in result.stdout, {k: v for k, v in data.items() if k != "look"})
    check("and says the expected words came", (data.get("expect") or {}).get("met") is True, data.get("expect"))
    check("the first line ends with the tab", (data.get("message") or "").endswith(" in " + tab), data.get("message"))
    since = envelope("snapshot", "--tab", tab, "--since")[1]["data"]
    check("--since after an answer has nothing new", not since.get("appeared"), since)
    broadway("go", base + "answers?covered", "--tab", tab)
    broadway("wait", "--tab", tab, "Basket")
    covered = envelope("click", "Buy now", "--tab", tab)[1]
    error = covered.get("error") or {}
    check("a covered target names what covers it", error.get("code") == "not_actionable" and "Newsletter" in error.get("message", ""), covered)
    check("and how to close it", "broadway click @e" in (error.get("hint") or ""), error)
    check("and nothing was bought", title(tab) != "bought", title(tab))
    stale = envelope("click", "@e900", "--tab", tab)[1]
    check("a ref never given is stale", (stale.get("error") or {}).get("code") == "stale_ref", stale)
    missing = envelope("click", "Checkout please", "--tab", tab)[1]
    check("words that fit nothing say not_found", (missing.get("error") or {}).get("code") == "not_found", missing)
    twice = envelope("click", "Item", "--tab", tab)[1]
    check("words that fit many say ambiguous with candidates", (twice.get("error") or {}).get("code") == "ambiguous" and "fits 200" in (twice.get("error") or {}).get("message", "") and "--nth" in (twice.get("error") or {}).get("hint", ""), twice)
    check("with the first candidates as data", len((twice.get("data") or {}).get("candidates", [])) == 5, twice.get("data"))
    broadway("go", base + "modal", "--tab", tab)
    broadway("wait", "--tab", tab, "Cookies")
    modal = envelope("snapshot", "--tab", tab)[1]["data"]
    names = [e["name"] for e in modal["elements"]]
    check("a blocking dialog is shown alone", "Accept all" in names and "Behind it" not in names and modal.get("scope") == "dialog", names)
    whole = [e["name"] for e in envelope("snapshot", "--tab", tab, "--all")[1]["data"]["elements"]]
    check("--all shows the page behind it", "Behind it" in whole, whole)


def start():
    subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", "true"], check=True)
    env = ["--env", f"SEARCH_PROBE={WORLD}", "--env", f"SEARCH_FILE_STALL={SCRATCH / 'stall'}:{FOLDER / 'Downloads'}"]
    subprocess.run(["open", "-n", "-g", "-j", *env, str(APP)], check=True)
    check("the app is up", wait_for(lambda: broadway("status").returncode == 0, 40))
    broadway("agents", "connect")


def held():
    return subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    os.environ["BROADWAY_AGENT"] = WORLD
    os.environ["BROADWAY_AGENT_NAME"] = "Reach Probe"
    os.environ.pop("BROADWAY_TAB", None)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    wanted = set(sys.argv[1:])
    sv.wipe()
    try:
        start()
        tab = broadway("open", base).stdout.strip()
        broadway("wait", "--tab", tab, "--selector", "iframe")
        time.sleep(1.5)
        sections = [("snapshot", snapshot_sees), ("upload", uploads), ("stall", stalled_folder),
                    ("download", lambda tab: downloads(tab, base)), ("frozen", lambda tab: frozen_downloads(tab, base)), ("more", lambda tab: more(tab, base)), ("answers", lambda tab: answers(tab, base)), ("deadline", deadline)]
        for name, run in sections:
            if wanted and name not in wanted:
                continue
            broadway("go", base, "--tab", tab)
            broadway("wait", "--tab", tab, "--selector", "iframe")
            time.sleep(1.5)
            run(tab)
    finally:
        subprocess.run([BENCH, "--world", WORLD, "quit"], capture_output=True)
        for _ in range(40):
            if not held():
                break
            time.sleep(0.25)
        for pid in held():
            os.kill(int(pid), signal.SIGKILL)
        sv.wipe()
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
        subprocess.run(["rm", "-rf", str(SCRATCH)])
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
