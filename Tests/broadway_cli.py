#!/usr/bin/env python3
import json
import os
import pty
import re
import shutil
import signal
import stat
import statistics
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
sv.use(f"avecli-{os.getpid()}")
WORLD = sv.W
FOLDER = Path(sv.SUPPORT)
SUITE = sv.SUITE
SAM = f"sam-{os.getpid()}@example.com"
AGENT_NAME = "CLI Probe"

FORM = b"""<!doctype html><title>Form</title><h1>Sign up</h1><form>
<input id="pass" type="password" value="hunter2-secret">
<input id="card" autocomplete="cc-number" value="4242424242424242">
<input id="plain" placeholder="plain" value="">
<button id="inside" type="button" onclick="document.title='leaked'">Inside</button>
</form>
<button id="go" type="button" onclick="document.title='clicked'">Go</button>
<button id="rename" type="button" onclick="document.getElementById('victim').textContent='Delete everything'">Rename</button>
<button id="victim" type="button" onclick="document.title='hit'">Harmless</button>
<button id="later" type="button" onclick="setTimeout(function () { document.getElementById('quiet').textContent = 'Remove all' }, 1500)">Later</button>
<button id="quiet" type="button" onclick="document.title='struck'">Fine</button>
<button id="note" type="button" onclick="document.title='sent'">Send note</button>
<button id="draft" type="button" onclick="document.title='erased'">Delete draft</button>
<button id="mark" type="button" onclick="document.title='marked'">Mark seen</button>
<p>the price is 12 dollars</p>"""

SECOND = b"""<!doctype html><title>Second</title><h1>Other</h1>
<button type="button" onclick="document.title='wrong'">Wrong</button>
<button type="button">Also wrong</button><button type="button">Third</button>
<button type="button">Fourth</button><button type="button">Fifth</button>
<button type="button">Sixth</button><button type="button">Seventh</button>"""

DETAILS = b"""<!doctype html><title>Details</title><form>
<input name="name" autocomplete="name"><input name="email" type="email" autocomplete="email">
<input name="address" autocomplete="address-line1"><input name="city" autocomplete="address-level2">
</form>"""

SECTIONS = b"""<!doctype html><title>Sections</title><h2>Billing address</h2><p>12 Oak Road</p>
<button type="button" onclick="document.title='billing'">Edit</button>
<h2>Shipping address</h2><p>4 Elm Street</p>
<button type="button" onclick="document.title='shipping'">Edit</button>
<p aria-hidden="true">zebra hidden words</p><p style="opacity:0">zebra faint words</p>"""

COOKIE = b"""<!doctype html><title>Cookie</title><div style="height:1500px"></div>
<button type="button" onclick="document.title='shown'">Show more</button><div style="height:1500px"></div>
<div id="onetrust-banner-sdk" style="position:fixed;top:30vh;bottom:0;left:0;right:0;background:#fff">
<p>We use cookies to make this site work</p><button>Accept all</button><button>Reject all</button><button aria-label="Close">x</button>
</div>"""

SIZES = b"<!doctype html><title>Sizes</title><select aria-label=\"Size\">" + b"".join(b"<option>Size %d</option>" % n for n in range(1, 26)) + b"</select>"

BLANK = b"<!doctype html><title>Blank</title><body></body>"

SIGNIN = b"""<!doctype html><title>Sign in</title><h1>Sign in</h1>
<form onsubmit="event.preventDefault(); document.title = 'sent'"><input id="user" name="username" autocomplete="username">
<input id="pass" name="password" type="password" autocomplete="current-password"><button>Sign in</button></form>"""

PAGES = {"/sections": SECTIONS, "/cookie": COOKIE, "/sizes": SIZES, "/blank": BLANK, "/signin": SIGNIN}

FEED = b"""<?xml version="1.0"?><rss version="2.0"><channel><title>Feed</title>
<item><title>Item one</title><link>https://example.com/one</link><guid>one</guid></item>
<item><title>Item two</title><link>https://example.com/two</link><guid>two</guid></item>
</channel></rss>"""

SILENCE = b"RIFF" + (36 + 8000 * 2 * 60).to_bytes(4, "little") + b"WAVEfmt " + (16).to_bytes(4, "little") + (1).to_bytes(2, "little") \
    + (1).to_bytes(2, "little") + (8000).to_bytes(4, "little") + (16000).to_bytes(4, "little") + (2).to_bytes(2, "little") \
    + (16).to_bytes(2, "little") + b"data" + (8000 * 2 * 60).to_bytes(4, "little") + bytes(8000 * 2 * 60)

SONG = b"""<!doctype html><title>Song</title><audio id=a src="/silence.wav"></audio><script>
var a = document.getElementById('a'); a.volume = 0.01;
navigator.mediaSession.metadata = new MediaMetadata({ title: 'A Quiet Song', artist: 'Nobody' });
</script>"""

failures = []


def check(name, ok, detail=""):
    print(("ok   " if ok else "FAIL ") + name, "" if ok else detail)
    if not ok:
        failures.append(name)


class Page(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.endswith(".bin"):
            return self.attachment()
        if self.path.startswith("/silence.wav"):
            return self.media(SILENCE, "audio/wav")
        body = PAGES.get(self.path.split("?")[0]) or (SONG if self.path.startswith("/song") else FEED if self.path.startswith("/feed") else DETAILS if self.path.startswith("/details") else SECOND if self.path.startswith("/second") else FORM)
        self.send_response(200)
        self.send_header("content-type", "text/html")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def media(self, body, kind):
        total = len(body)
        wanted = self.headers.get("range")
        if wanted and wanted.startswith("bytes="):
            first, _, last = wanted[6:].partition("-")
            start = int(first or 0)
            end = min(int(last) if last else total - 1, total - 1)
            self.send_response(206)
            self.send_header("content-range", f"bytes {start}-{end}/{total}")
            body = body[start:end + 1]
        else:
            self.send_response(200)
        self.send_header("content-type", kind)
        self.send_header("accept-ranges", "bytes")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def attachment(self):
        whole = 8_000_000 if "slow" in self.path or "drop" in self.path else 2000
        name = self.path.rsplit("/", 1)[1]
        self.send_response_only(206 if self.headers.get("range") else 200)
        self.send_header("content-type", "application/octet-stream")
        self.send_header("content-disposition", f'attachment; filename="{name}"')
        self.send_header("accept-ranges", "bytes")
        self.send_header("etag", '"same"')
        self.send_header("last-modified", "Mon, 02 Nov 2026 10:00:00 GMT")
        ranged = self.headers.get("range")
        if ranged:
            start = int(ranged.split("=")[1].split("-")[0])
            self.send_header("content-range", f"bytes {start}-{whole - 1}/{whole}")
            whole -= start
        self.send_header("content-length", str(whole))
        self.end_headers()
        try:
            if "slow" in self.path:
                for _ in range(600):
                    self.wfile.write(b"x" * 1000)
                    self.wfile.flush()
                    time.sleep(0.1)
            elif "drop" in self.path:
                self.wfile.write(b"x" * 1000)
                self.wfile.flush()
                time.sleep(0.2)
            else:
                self.wfile.write(b"x" * whole)
        except OSError:
            pass
        self.close_connection = True

    def log_message(self, *_):
        pass


def bench(*words):
    return subprocess.run([BENCH, "--world", WORLD, *words], capture_output=True, text=True, timeout=30).stdout


def broadway(*words, stdin=subprocess.DEVNULL, env=None, text=True, timeout=40):
    environment = dict(os.environ, **(env or {}))
    return subprocess.run([BROADWAY, "--world", WORLD, *words], capture_output=True, text=text, stdin=stdin, env=environment, timeout=timeout)


def in_terminal(environment):
    master, slave = pty.openpty()
    process = subprocess.Popen([BROADWAY, "--world", WORLD, "tabs"], stdin=slave, stdout=slave, stderr=slave, env=environment)
    os.close(slave)
    output = b""
    while True:
        try:
            chunk = os.read(master, 4096)
        except OSError:
            break
        if not chunk:
            break
        output += chunk
    process.wait()
    os.close(master)
    return output.decode(errors="replace")


def envelope(*words, **options):
    result = broadway(*words, "--json", **options)
    return result, json.loads(result.stdout)


def spawn(*words):
    return subprocess.Popen([BROADWAY, "--world", WORLD, *words], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def held():
    found = subprocess.run(["lsof", "-t", "--", str(FOLDER / "broadway.sock")], capture_output=True, text=True).stdout.split()
    return found


def gone():
    for _ in range(60):
        if not held():
            return True
        time.sleep(0.25)
    return False


def check_quit(name, *words):
    quit = broadway(*words)
    check(name, quit.returncode == 0 and gone(), f"{quit.returncode} {quit.stdout} {quit.stderr} held {held()}")


def forget_logins():
    label = f"Broadway ({WORLD})"
    while subprocess.run(["security", "delete-internet-password", "-l", label], capture_output=True, timeout=10).returncode == 0:
        pass


def write_settings(agents):
    subprocess.run(["defaults", "write", SUITE, "bench", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", SUITE, "agents.on", "-bool", agents], check=True)


def wait_for(condition, seconds=10):
    until = time.time() + seconds
    while time.time() < until:
        if condition():
            return True
        time.sleep(0.1)
    return False


def wake_and_quit():
    check("nothing is running first", not held())
    status = broadway("status")
    check("status never wakes it", status.returncode == 1 and not held(), status.stderr)
    check("help never wakes it", broadway("help", "click").returncode == 0 and not held())
    listed, parsed = envelope("tabs")
    check("a browser command wakes it", listed.returncode == 0 and parsed["ok"], listed.stderr)
    check("it woke hidden", envelope("status")[1]["data"]["hidden"] is True)
    mode = os.stat(FOLDER / "broadway.sock").st_mode
    check("socket is user only", stat.S_IMODE(mode) == 0o600 and stat.S_ISSOCK(mode), oct(mode))


def latency():
    def run(*words):
        times = []
        for _ in range(30):
            began = time.perf_counter()
            broadway(*words)
            times.append((time.perf_counter() - began) * 1000)
        times.sort()
        return statistics.median(times), times[int(len(times) * 0.95)]
    for words in (["tabs"], ["tabs", "--json"], ["status"]):
        middle, slow = run(*words)
        print(f"     latency {' '.join(words)}: median {middle:.1f} ms, p95 {slow:.1f} ms")
        check(f"{' '.join(words)} is fast", middle < 100, middle)
    return True


def help_and_mistakes():
    check("broadway alone is help", broadway().returncode == 0 and "Browser" in broadway().stdout)
    page = broadway("help", "click")
    check("help for a command", page.returncode == 0 and "broadway click WORDS|@ref" in page.stdout and "[--role ROLE] [--name NAME]" in page.stdout and "broadway click @e3" in page.stdout, page.stdout)
    check("help leaves out the app's unlisted flags", all(flag not in page.stdout for flag in ("--expect_gone", "--settle", "--target", "--words")) and "--expect TEXT" in page.stdout, page.stdout)
    check("--help after a command", broadway("click", "--help").stdout == page.stdout)
    check("help is generated for aliases", "broadway go <url>" in broadway("help", "navigate").stdout)
    check("guide", "Broadway for agents" in broadway("guide").stdout and "broadway wait" in broadway("guide").stdout)
    check("guide mcp", "mcpServers" in broadway("guide", "mcp").stdout)
    typo = broadway("clikc")
    check("a typo suggests a command", typo.returncode == 2 and "Did you mean click" in typo.stderr, typo.stderr)
    typo, parsed = envelope("clikc", "Save")
    check("a typo keeps the envelope", typo.returncode == 2 and parsed["error"]["code"] == "usage" and parsed["ok"] is False, typo.stdout)
    check("envelope keys", set(parsed) == {"ok", "command", "data", "error"}, parsed)
    check("error keys", set(parsed["error"]) == {"code", "message", "hint", "retry_safe"}, parsed)
    check("a bad option", broadway("--cli", "nope", "do it").returncode == 2)
    check("a click with no target is a mistake", broadway("click").returncode == 2 and "needs a target" in broadway("click").stderr)
    formless = broadway("choose", "Colour")
    check("a choose with no value says the form", formless.returncode == 2 and "broadway choose TARGET VALUE" in formless.stderr, formless.stderr)
    check("words are a target, not a mistake", broadway("click", "button").returncode != 2)
    check("an unknown flag", "Did you mean --seconds" in broadway("wait", "--second", "3").stderr)
    check("a bad number", broadway("wait", "--seconds", "lots").returncode == 2)
    check("--tab on a tabless command", broadway("history", "--tab", "abc").returncode == 2)
    completed = broadway("__complete", "--", "sn")
    check("completion", "snapshot" in completed.stdout, completed.stdout)
    check("completion of flags", "--selector" in broadway("__complete", "wait", "--", "--s").stdout)


def browsing(base):
    opened = broadway("open", base)
    tab = opened.stdout.strip()
    check("open prints the id when piped", opened.returncode == 0 and len(tab) == 8, opened.stdout + opened.stderr)
    tabs, parsed = envelope("tabs")
    mine = next(row for row in parsed["data"]["tabs"] if row["id"] == tab)
    check("an agent tab stays behind", mine["agent"] and not mine["front"])
    plain = broadway("tabs").stdout.splitlines()
    check("tabs piped is tab separated", any(line.startswith(tab + "\t") for line in plain), plain)
    check("wait", broadway("wait", "--selector", "#go").returncode == 0)
    check("wait for text", broadway("wait", "the price").returncode == 0)
    missed, parsed = envelope("wait", "Never Here", "--seconds", "1")
    check("a wait times out", missed.returncode == 1 and parsed["error"]["code"] == "timeout", parsed)

    refused, parsed = envelope("wait", "--selector", 'input[value^="h"]', "--seconds", "1")
    check("wait can't read a field", refused.returncode == 1 and parsed["error"]["code"] == "refused", parsed)
    refused, parsed = envelope("wait", "--selector=input[v\\61lue^=h]", "--seconds", "1")
    check("nor through an escape or = form", refused.returncode == 1 and parsed["error"]["code"] == "refused", parsed)

    snapshot = broadway("snapshot")
    check("snapshot", snapshot.returncode == 0 and "@e" in snapshot.stdout, snapshot.stdout)
    check("values stay on the page", "hunter2" not in snapshot.stdout and "4242" not in snapshot.stdout)
    check("page text is marked on stderr", "Website content" in snapshot.stderr and "Website content" not in snapshot.stdout)
    hidden = [line.split()[0] for line in snapshot.stdout.splitlines() if "value hidden" in line]
    check("secret boxes are hidden", len(hidden) == 2, snapshot.stdout)
    asking = spawn("click", hidden[0], "--json")
    if wait_for(desk, 8):
        shown = json.dumps(desk()) + broadway("approvals", "list", "--json").stdout
        check("the person's question never quotes a secret box", "hunter2" not in shown and "4242" not in shown, shown)
        bench("knowing", "desk", "no")
    asking.communicate(timeout=15)
    for ref in hidden:
        typed, parsed = envelope("type", ref, "x")
        check("secret boxes refuse typing", typed.returncode == 1 and parsed["error"]["code"] == "secret_field", parsed)
    _, parsed = envelope("snapshot")
    elements = parsed["data"]["elements"]
    check("snapshot json", parsed["data"]["website"] and parsed["data"]["tab"] == tab, parsed["data"].keys())
    check("the same element keeps its ref", next(line for line in snapshot.stdout.splitlines() if line.startswith("@")).split()[0] == "@" + elements[0]["ref"], elements[0])
    ref = lambda name: pick(elements, name)
    typed = broadway("type", ref("plain"), "hello")
    check("type", typed.returncode == 0 and "hello" in typed.stdout, typed.stdout + typed.stderr)
    check("the typed text shows", 'value="hello"' in broadway("snapshot").stdout)
    asking = spawn("click", ref("Inside"), "--json")
    check("a click in a card form asks for approval", wait_for(desk), desk())
    check("the click waits without landing", asking.poll() is None and "leaked" not in broadway("tabs").stdout)
    bench("knowing", "desk", "no")
    output, errors = asking.communicate(timeout=15)
    parsed = json.loads(output)
    check("a refused card-form click stays refused", asking.returncode == 1 and parsed["error"]["code"] in ("refused", "said_no"), output + errors)
    check("and nothing landed", "leaked" not in broadway("tabs").stdout)
    check("click", broadway("click", ref("Go")).returncode == 0)
    check("the click landed", wait_for(lambda: "clicked" in broadway("tabs").stdout, 3))
    check("a ref with no @", broadway("scroll", "--ref", ref("Go")[1:]).returncode == 0)
    check("press", broadway("press", "Tab").returncode == 0)
    check("an unknown key", envelope("press", "Nope")[1]["error"]["code"] == "bad_input")
    check("scroll by", broadway("scroll", "20").returncode == 0)
    check("scroll back", broadway("scroll", "-20").returncode == 0)
    down = broadway("scroll", "down", "300")
    check("scroll down N is one scroll and says where it ended", down.returncode == 0 and ("points" in down.stdout or "Already at the bottom" in down.stdout), down.stdout + down.stderr)
    _, parsed = envelope("scroll", "down", "300")
    check("a scroll's data says whether the page has ended", parsed["data"].get("bottom") is True and "below" in parsed["data"], parsed)

    renamed = broadway("click", ref("Rename"))
    check("an action's answer says what it changed", "Delete everything" in renamed.stdout, renamed.stdout)
    asking = spawn("click", ref("Harmless"), "--json")
    check("a ref the answer renamed acts on what it says now, so a delete asks", wait_for(desk, 8), desk())
    bench("knowing", "desk", "no")
    output, errors = asking.communicate(timeout=15)
    parsed = json.loads(output)
    check("and a no stays a no", asking.returncode == 1 and parsed["error"]["code"] == "said_no", output + errors)
    check("and hit nothing", "hit" not in broadway("tabs").stdout)
    broadway("click", ref("Later"))
    wait_for(lambda: "Remove all" in broadway("read").stdout, 5)
    changed, parsed = envelope("click", ref("Fine"))
    check("a ref whose element changed unseen is ref_changed", changed.returncode == 1 and parsed["error"]["code"] == "ref_changed" and "Remove all" in json.dumps(parsed), parsed)
    check("and struck nothing", "struck" not in broadway("tabs").stdout)

    read = broadway("read")
    check("read has only the page on stdout", read.stdout.lstrip().startswith("Sign up") and "Website content" in read.stderr, read.stdout[:80])
    check("read leaves secrets out", "hunter2" not in read.stdout and "4242" not in read.stdout)
    grep = subprocess.run(f"'{BROADWAY}' --world {WORLD} read 2>/dev/null | grep -c price", shell=True, capture_output=True, text=True)
    check("read pipes", grep.stdout.strip() == "1", grep.stdout)
    found = broadway("read", "--find", "price")
    check("read --find gives the lines holding the words", found.returncode == 0 and "price" in found.stdout.lower() and "Sign up" not in found.stdout, found.stdout + found.stderr)
    close = broadway("read", "--find", "the prise is")
    check("read --find with no line gives the closest lines", close.returncode == 1 and "Closest lines" in close.stderr and "the price is 12 dollars" in close.stderr, close.stderr)
    check("the website note is said once", read.stderr.count("Website content") == 1 and found.stderr.count("Website content") <= 1, read.stderr + found.stderr)
    both = broadway("batch", "read", "snapshot")
    check("and once for a batch", both.stderr.count("Website content") == 1, both.stderr)
    aimed = broadway("click", "Mark seen", "--role", "button")
    check("words and --role aim together", aimed.returncode == 0 and wait_for(lambda: "marked" in broadway("tabs").stdout, 5), aimed.stdout + aimed.stderr)

    folder = Path(tempfile.mkdtemp())
    shot = broadway("shot", "-o", str(folder / "page.png"))
    png = (folder / "page.png").read_bytes()
    check("shot -o", shot.returncode == 0 and png[:4] == b"\x89PNG", shot.stderr)
    raw = broadway("shot", text=False)
    named = Path(raw.stdout.decode(errors="replace").strip().splitlines()[0]) if raw.stdout.strip() else Path("-")
    check("shot on a pipe names its file and writes no picture there", raw.returncode == 0 and raw.stdout[:4] != b"\x89PNG" and named.name.startswith("broadway-shot-") and named.exists(), raw.stdout[:200])
    if named.name.startswith("broadway-shot-"):
        named.unlink(missing_ok=True)
    raw = broadway("shot", "--out", "-", text=False)
    check("shot --out - is the picture", raw.stdout[:4] == b"\x89PNG")
    _, parsed = envelope("shot", "-o", str(folder / "json.png"))
    check("shot --json has the path, no pixels", parsed["data"]["path"].endswith("json.png") and "image" not in parsed["data"], parsed)
    output = broadway("read", "-o", str(folder / "page.txt"))
    check("-o writes data", "price" in (folder / "page.txt").read_text() and output.stdout == "")
    shutil.rmtree(folder)

    old = [e["ref"] for e in elements]
    check("go", broadway("go", base + "second").returncode == 0)
    check("wait after go", broadway("wait", "Other").returncode == 0)
    gone_ref, parsed = envelope("click", "@" + old[-1])
    check("an old page's ref is stale and names the move", gone_ref.returncode == 1 and (parsed["error"] or {}).get("code") == "stale_ref"
          and "this tab is now on Second" in (parsed["error"] or {}).get("message", ""), parsed)
    check("the hint says what to do", "broadway snapshot" in ((parsed["error"] or {}).get("hint") or ""), parsed)
    _, parsed = envelope("snapshot")
    fresh = [e["ref"] for e in parsed["data"]["elements"]]
    check("refs start again on a new page", fresh[0] == "e1" and old[-1] not in fresh, (old, fresh))
    gone_ref, parsed = envelope("click", "@" + old[-1])
    check("not even after a new snapshot", gone_ref.returncode == 1 and (parsed["error"] or {}).get("code") == "stale_ref", parsed)
    check("and nothing was clicked", "wrong" not in broadway("tabs").stdout)
    check("back is a command", broadway("back").returncode == 0 and broadway("wait", "Sign up").returncode == 0)
    check("forward is a command", broadway("forward").returncode == 0 and broadway("wait", "Other").returncode == 0)
    check("reload is a command", broadway("reload").returncode == 0 and broadway("wait", "Other").returncode == 0)

    missing, parsed = envelope("read", "--tab", "zzzzzzzz")
    check("no such tab", missing.returncode == 1 and parsed["error"]["code"] == "no_tab" and "broadway tabs" in parsed["error"]["hint"], parsed)
    check("a named tab becomes current", broadway("read", "--tab", tab).returncode == 0)
    front = next(row for row in envelope("tabs", "--all")[1]["data"]["tabs"] if row["front"])
    refused, parsed = envelope("go", base, "--tab", front["id"])
    check("the front tab can't be sent elsewhere", refused.returncode == 1 and parsed["error"]["code"] == "refused", parsed)
    refused, parsed = envelope("close", "--tab", front["id"])
    check("the front tab can't be closed", refused.returncode == 1 and parsed["error"]["code"] == "not_yours", parsed)
    check("addresses only", (envelope("go", "file:///etc/passwd", "--tab", tab)[1]["error"] or {}).get("code") in ("refused", "usage"))
    check("close", broadway("close", "--tab", tab).returncode == 0)
    check("it's gone", tab not in broadway("tabs").stdout)
    tabless = broadway("read")
    check("a read with no tab of its own says whose tab it read", "Reading the person's tab" in tabless.stderr or tabless.returncode != 0, tabless.stderr)

    check("history", broadway("history", "--limit", "3").returncode == 0)
    check("skills is a command, and notes and routines no longer are", broadway("skills").returncode == 0
          and all(broadway(word).returncode == 2 for word in ("notes", "every", "memory", "routines", "eye")))
    other = broadway("open", base + "agentonly").stdout.strip()
    broadway("wait", "--tab", other)
    check("an agent's visit stays out of history", "agentonly" not in broadway("history", "agentonly").stdout)
    broadway("close", "--tab", other)

    check("a person's page", broadway(base + "first").returncode == 0)
    time.sleep(0.5)
    first = next(row["id"] for row in envelope("tabs", "--all")[1]["data"]["tabs"] if row["front"])
    broadway(base + "last")
    time.sleep(0.8)
    check("a person's page is in history", "first" in broadway("history", "first").stdout)
    steered = broadway("go", base + "steered", "--tab", first)
    check("go on a person's other tab", steered.returncode == 0, steered.stderr)
    broadway("wait", "--tab", first)
    time.sleep(0.5)
    check("a steered visit stays out of history", "steered" not in broadway("history", "steered").stdout)

    private = bench("open", base + "secretpage", "private").strip()
    time.sleep(1)
    check("a private tab isn't listed", "secretpage" not in broadway("tabs").stdout and private[:8] not in broadway("tabs").stdout)
    hidden_tab, parsed = envelope("read", "--tab", private[:8])
    check("a private tab can't be reached", hidden_tab.returncode == 1 and parsed["error"]["code"] == "no_tab", parsed)
    bench("close", private)

    terminal = dict(os.environ, TERM="xterm-256color")
    terminal.pop("NO_COLOR", None)
    check("a terminal gets colour", "\x1b[" in in_terminal(terminal))
    terminal["NO_COLOR"] = "1"
    plain = in_terminal(terminal)
    check("NO_COLOR is respected", "\x1b[" not in plain, plain)
    check("a pipe gets no colour", "\x1b[" not in broadway("tabs").stdout)


def looking(base):
    tab = broadway("open", base + "cookie").stdout.strip()
    broadway("wait", "--tab", tab)
    covered = broadway("click", "Show more", "--tab", tab)
    check("a covered click names the cookie notice and its buttons", covered.returncode == 1 and "cookie notice" in covered.stderr and "Reject all" in covered.stderr and "broadway click @e" in covered.stderr, covered.stderr)
    check("and nothing was clicked or dismissed", "shown" not in broadway("tabs").stdout and "Accept all" in broadway("read", "--tab", tab).stdout)
    broadway("go", base + "sizes", "--tab", tab)
    broadway("wait", "--tab", tab)
    missed = broadway("choose", "Size", "Huge", "--tab", tab)
    check("choose with no such option lists twenty and counts the rest", missed.returncode == 1 and '"Size 20"' in missed.stderr and '"Size 21"' not in missed.stderr and "5 more" in missed.stderr, missed.stderr)
    broadway("go", base + "blank", "--tab", tab)
    broadway("wait", "--tab", tab)
    empty, parsed = envelope("read", "--tab", tab)
    check("read on an empty page says so and names wait", empty.returncode == 1 and parsed["error"]["code"] == "no_answer" and "broadway wait" in json.dumps(parsed), parsed)
    broadway("go", base + "sections", "--tab", tab)
    broadway("wait", "--tab", tab)
    found, parsed = envelope("find", "Edit", "--in", "Shipping address", "--tab", tab)
    check("--in words narrow find to one section", found.returncode == 0 and parsed["data"]["count"] == 1, parsed)
    both, parsed = envelope("click", "Edit", "--tab", tab)
    hint = (parsed.get("error") or {}).get("hint") or ""
    check("several fits say the heading each sits under", both.returncode == 1 and parsed["error"]["code"] == "ambiguous" and 'under "Billing address"' in hint and 'under "Shipping address"' in hint, parsed)
    clicked = broadway("click", "Edit", "--in", "Shipping address", "--tab", tab)
    check("--in words act inside that section only", clicked.returncode == 0 and wait_for(lambda: "shipping" in broadway("tabs").stdout, 3), clicked.stdout + clicked.stderr)
    broadway("close", "--tab", tab)


def batching(base):
    tab = broadway("open", base + "batchform").stdout.strip()
    broadway("wait", "--tab", tab)
    _, parsed = envelope("snapshot", "--tab", tab)
    elements = parsed["data"]["elements"]
    ref = lambda name: pick(elements, name)
    secret = "@" + next(e["ref"] for e in elements if e.get("hidden"))

    done = broadway("batch", f"type {ref('plain')} from-batch", f"click {ref('Go')}")
    check("a batch runs each step", done.returncode == 0 and done.stdout.startswith("1 ok"), done.stdout + done.stderr)
    check("and both landed", wait_for(lambda: "clicked" in broadway("tabs").stdout, 3) and 'value="from-batch"' in broadway("snapshot").stdout)

    stopped, parsed = envelope("batch", f"type {ref('plain')} x", "click @e999999999", f"click {ref('Rename')}")
    data = parsed["data"] or {}
    check("a batch stops at the first failure", stopped.returncode == 1 and parsed["error"]["code"] == "stale_ref", parsed)
    check("and says what landed", data.get("landed") == [1] and data["steps"][2].get("ran") is False, data)
    check("a batch that landed is not safe to repeat", parsed["error"]["retry_safe"] is False, parsed)
    check("the step after the failure never ran", "Delete everything" not in broadway("read").stdout)
    text = broadway("batch", f"type {ref('plain')} y", "click @e999999999")
    check("the text answer lists the steps and how to go on", "2 FAIL" in text.stdout and "Landed 1. Nothing from 2 on was done" in text.stdout, text.stdout)

    piped = subprocess.run(
        [BROADWAY, "--world", WORLD, "batch", "--from", "2"], input=f"# steps\nclick @e999999999\n\ntype {ref('plain')} piped\n", capture_output=True, text=True, timeout=40)
    check("steps come from stdin and --from skips the first", piped.returncode == 0 and piped.stdout.startswith("2 ok"), piped.stdout + piped.stderr)

    for words, what in ((["bookmarks list"], "a noun"), (["agents done"], "agents"), (["batch 'click x'"], "a batch"), (['"buy some tea"'], "a task")):
        refused, parsed = envelope("batch", f"click {ref('Go')}", *words)
        check(f"{what} is refused before anything runs", refused.returncode == 2 and parsed["error"]["code"] == "usage" and parsed["data"]["step"] == 2, parsed)
    many, parsed = envelope("batch", *([f"click {ref('Go')}"] * 26))
    check("26 steps are too many", many.returncode == 2 and "25 steps at most" in parsed["error"]["message"], parsed)

    secret_box, parsed = envelope("batch", f"type {secret} x")
    check("a secret box still refuses typing in a batch", secret_box.returncode == 1 and parsed["error"]["code"] == "secret_field" and parsed["data"]["landed"] == [], parsed)
    check("and its value stayed out", "hunter2" not in json.dumps(parsed))

    broadway("go", base + "batchform", "--tab", tab)
    broadway("wait", "--tab", tab)
    _, parsed = envelope("snapshot", "--tab", tab)
    elements = parsed["data"]["elements"]
    asking = spawn("batch", f"click {ref('Delete draft')}", f"click {ref('Go')}", "--json")
    check("a gated step in a batch asks the person", wait_for(desk), desk())
    bench("knowing", "desk", "no")
    output, errors = asking.communicate(timeout=20)
    parsed = json.loads(output)
    check("a no stops the batch", asking.returncode == 1 and parsed["data"]["landed"] == [] and parsed["data"]["steps"][1].get("ran") is False, output + errors)
    check("and the gated click never landed", "erased" not in broadway("tabs").stdout)

    broadway("go", base + "batchform", "--tab", tab)
    broadway("wait", "--tab", tab)
    _, parsed = envelope("snapshot", "--tab", tab)
    elements = parsed["data"]["elements"]
    script = f'type("{ref('plain')[1:]}", "from-run")\nconst hit = find("Go")\nif (hit.count) click(hit.elements[0].ref)\nprint("found", hit.count)'
    ran = broadway("run", "--tab", tab, script)
    check("a script runs commands and branches on their answers", ran.returncode == 0 and "found 1" in ran.stdout and "(3 steps)" in ran.stdout, ran.stdout + ran.stderr)
    _, parsed = envelope("snapshot", "--tab", tab)
    elements = parsed["data"]["elements"]
    secret = "@" + next(e["ref"] for e in elements if e.get("hidden"))
    ran, parsed = envelope("run", "--tab", tab, f'try {{ type("{secret[1:]}", "x") }} catch (e) {{}}\nprint("went on")')
    check("a secret box ends a script whatever it catches", ran.returncode == 1 and parsed["error"]["code"] == "secret_field" and "went on" not in json.dumps(parsed), parsed)
    asking = spawn("run", "--tab", tab, f'try {{ click("{ref('Send note')[1:]}") }} catch (e) {{}}\nclick("{ref('Go')[1:]}")', "--json")
    check("a gated step in a script asks the person", wait_for(desk), desk())
    bench("knowing", "desk", "no")
    output, errors = asking.communicate(timeout=20)
    parsed = json.loads(output)
    check("a no ends the script", asking.returncode == 1 and parsed["data"]["steps"] == 1 and parsed["data"]["landed"] == [], output + errors)
    check("and the gated click never landed", "sent" not in broadway("tabs").stdout)
    looping = broadway("run", "--timeout", "1", "while (true) {}")
    check("a script that never ends stops at its timeout", looping.returncode == 4 and "deadline" in looping.stdout, looping.stdout + looping.stderr)

    old, parsed = envelope("locate", "Go", "--tab", tab)
    check("the old locate still answers", old.returncode == 0 and any(e["name"] == "Go" for e in parsed["data"]["elements"]), parsed)
    found = broadway("find", "Go", "--tab", tab)
    check("find gives the same refs", found.returncode == 0 and "@e" in found.stdout and '"Go"' in found.stdout, found.stdout + found.stderr)
    shot = broadway("shot", "--ref", ref("Go"), "-o", "/dev/null", "--tab", tab)
    check("shot --ref still works", shot.returncode == 0, shot.stderr)
    scrolled = broadway("scroll", "0", "--tab", tab)
    check("a scroll answer prints numbers as numbers", "y: no" not in scrolled.stdout and scrolled.returncode == 0, scrolled.stdout)
    chose = broadway("choose", ref("plain"), "x", "--tab", tab)
    check("choose prints something either way", chose.stdout.strip() != "" or chose.stderr.strip() != "", chose.stdout + chose.stderr)
    broadway("close", "--tab", tab)


def old_task_words():
    for words in (["task", "say hello"], ["session", "list"], ["plans", "list"], ["tasks", "list"], ["helpers", "list"], ["say hello"], ["mcp", "--task", "6f1c2d3e-0000-4000-8000-000000000001"]):
        said = broadway(*words)
        lines = said.stderr.strip().splitlines()
        check(f"{' '.join(words)} says Broadway no longer runs tasks", said.returncode == 2 and said.stdout == "" and len(lines) == 1
              and "Broadway no longer runs tasks" in lines[0], said.stdout + said.stderr)
    typo = broadway("buy", "some", "tea")
    check("buy some tea is an unknown command, not a task", typo.returncode == 2 and "Unknown command buy" in typo.stderr and "no longer runs tasks" not in typo.stderr, typo.stderr)
    memory = broadway("memory")
    check("memory is simply an unknown command", memory.returncode == 2 and memory.stdout == ""
          and memory.stderr.startswith("broadway: Unknown command memory") and "notes" not in memory.stderr, memory.stderr)
    refused, parsed = envelope("say hello")
    check("its envelope", refused.returncode == 2 and parsed["error"]["code"] == "no_tasks" and parsed["ok"] is False, refused.stdout)
    shown = broadway("help").stdout
    check("help names no task", "what to do" not in shown and "Tasks" not in shown, shown)
    status = broadway("status").stdout
    check("status names no plan and no task", all(word not in status for word in ("Claude:", "ChatGPT:", "Tasks running")), status)


def setup():
    home = Path(tempfile.mkdtemp())
    real = Path.home()
    before = sorted(str(path) for path in [real / ".local/bin/broadway", real / ".config/fish/completions/broadway.fish", real / ".claude/skills/broadway", real / ".codex/skills/broadway"] if path.exists() or path.is_symlink())
    (home / ".claude").mkdir()
    (home / ".codex").mkdir()
    (home / ".zshrc").write_text("export KEEP=1\n")
    env = {"BROADWAY_HOME": str(home), "PATH": f"{home}/.local/bin:{os.environ['PATH']}"}
    broken = broadway("doctor", env=env)
    check("doctor finds nothing set up", broken.returncode == 1 and "broadway setup" in broken.stdout, broken.stdout)
    done, parsed = envelope("setup", env=env)
    check("setup", done.returncode == 0 and parsed["ok"], done.stdout + done.stderr)
    link = home / ".local/bin/broadway"
    check("the command is linked", link.is_symlink() and os.readlink(link) == os.path.realpath(BROADWAY), link)
    check("fish completions", (home / ".config/fish/completions/broadway.fish").exists())
    check("claude skill", "name: broadway" in (home / ".claude/skills/broadway/SKILL.md").read_text())
    codex = (home / ".codex/skills/broadway/SKILL.md").read_text()
    check("codex skill is a stub that sends agents to the guide", "broadway-guide: " in codex and "Run `broadway guide`" in codex and len(codex) < 1200, codex)
    stale = home / ".claude/skills/broadway/SKILL.md"
    stale.write_text("---\nname: broadway\nmanaged-by: written by broadway setup\n---\n\ntab=$(broadway open https://example.com)\n")
    refreshed = broadway("setup", "claude", "--refresh", env={"BROADWAY_HOME": str(home)})
    check("--refresh rewrites an old skill broadway wrote", refreshed.returncode == 0 and "broadway-guide: " in stale.read_text(), refreshed.stdout + refreshed.stderr)
    check("zshrc gets a block", ">>> broadway >>>" in (home / ".zshrc").read_text() and "KEEP" in (home / ".zshrc").read_text())
    for shell, script in [("fish", ".config/fish/completions/broadway.fish"), ("zsh", ".local/share/broadway/broadway.zsh"), ("bash", ".local/share/bash-completion/completions/broadway")]:
        path = shutil.which(shell)
        if path:
            flag = "--no-execute" if shell == "fish" else "-n"
            parsed_script = subprocess.run([path, flag, str(home / script)], capture_output=True, text=True)
            check(f"{shell} takes the completions", parsed_script.returncode == 0, parsed_script.stderr)
    doctor, parsed = envelope("doctor", env=env)
    bad = [row for row in parsed["data"]["checks"] if not row["ok"] and row["required"]]
    check("doctor is happy", doctor.returncode == 0 and not bad, bad)
    check("setup twice is fine", broadway("setup", env=env).returncode == 0)
    check("no second block", (home / ".zshrc").read_text().count(">>> broadway >>>") == 1)
    (home / ".codex/skills/broadway/SKILL.md").write_text("mine\n")
    check("remove", broadway("remove", env=env).returncode == 0)
    check("everything's gone", not link.is_symlink() and not (home / ".config/fish/completions/broadway.fish").exists() and not (home / ".claude/skills/broadway").exists())
    check("zshrc is as it was", (home / ".zshrc").read_text() == "export KEEP=1\n", (home / ".zshrc").read_text())
    check("someone else's file stays", (home / ".codex/skills/broadway/SKILL.md").read_text() == "mine\n")
    link.parent.mkdir(parents=True, exist_ok=True)
    link.write_text("mine\n")
    check("setup leaves a stranger's file", '"done":false' in broadway("setup", "command", "--json", env=env).stdout and link.read_text() == "mine\n")
    shutil.rmtree(home)
    after = sorted(str(path) for path in [real / ".local/bin/broadway", real / ".config/fish/completions/broadway.fish", real / ".claude/skills/broadway", real / ".codex/skills/broadway"] if path.exists() or path.is_symlink())
    check("the real home is untouched", before == after, after)


def serving():
    running = spawn("serve")
    check("serve holds", wait_for(lambda: (envelope("status")[1]["data"] or {}).get("serving") is True, 20), "")
    check_quit("serve --stop quits", "serve", "--stop")
    running.wait(timeout=10)
    check("serve returns when Broadway goes", running.returncode == 0, running.returncode)


def switched_off(base):
    write_settings("false")
    check("tabs wakes it, and is refused", envelope("tabs")[1]["error"]["code"] == "agents_off")
    status = broadway("status")
    check("status works off", status.returncode == 0 and "Agents: off" in status.stdout, status.stdout)
    check("help works off", broadway("help", "click").returncode == 0)
    check("doctor works off", "agents are off" in broadway("doctor").stdout)
    for words in (["read"], ["snapshot"], ["click", "@e1"], ["shot", "-o", "/dev/null"], ["history", "x"], ["wait"], ["go", base]):
        refused, parsed = envelope(*words)
        check(f"{words[0]} is refused off", refused.returncode == 1 and parsed["error"]["code"] == "agents_off" and "Settings" in parsed["error"]["hint"], parsed)
    task = broadway("do a thing")
    check("a sentence says Broadway no longer runs tasks", task.returncode == 2 and "Broadway no longer runs tasks" in task.stderr, task.stderr)
    opened, parsed = envelope("open", base + "byhand")
    check("open still works, as your own tab", opened.returncode == 0 and parsed["data"]["agent"] is False, opened.stdout + opened.stderr)
    check("and a bare address", broadway(base).returncode == 0)


SETTINGS_REFUSED = [
    ("ai.agents", "true"), ("ai.agents", "false"), ("agents.mode", "bypass"), ("agents.sites", "x"),
    ("agents.mode", "ask"), ("passwords.fill", "false"), ("passwords.open", "x"), ("autofill.cards", "x"),
    ("codes.gmail", "false"), ("history.pageText", "true"),
    ("downloads.folder", "/tmp"),
    ("shield", "false"), ("sites.keep", "false"),
    ("notifications.ask", "true"), ("search.suggest", "true"),
]

covered = set()


def run(*words, **options):
    covered.add(" ".join(words[:2]))
    return envelope(*words, **options)


def good(name, *words, **options):
    result, parsed = run(*words, **options)
    check(name, result.returncode == 0 and parsed["ok"], result.stdout + result.stderr)
    return parsed["data"] or {}


def no(name, code, *words, **options):
    result, parsed = run(*words, **options)
    exits = {"usage": 2, "needs_you": 3}.get(code, 1)
    check(name, result.returncode == exits and (parsed["error"] or {}).get("code") == code, result.stdout + result.stderr)
    return parsed


def pick(elements, name):
    named = [e for e in elements if e["name"] == name]
    chosen = next((e for e in named if e.get("role") == "button"), named[0])
    return "@" + chosen["ref"]


def desk():
    return json.loads(bench("knowing", "desk", "list"))["pending"]


def with_person(name, answer, *words):
    covered.add(" ".join(words[:2]))
    running = subprocess.Popen([BROADWAY, "--world", WORLD, *words, "--wait-person", "1", "--json"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    check(f"{name} waits for the person", wait_for(desk, 10), words)
    asked = desk()
    bench("knowing", "desk", answer)
    output, errors = running.communicate(timeout=20)
    return running.returncode, json.loads(output), asked, errors


def yes(name, *words):
    code, parsed, asked, errors = with_person(name, "yes", *words)
    check(name, code == 0 and parsed["ok"], f"{parsed} {errors}")
    check(f"{name} shows the command and agent", asked and re.fullmatch(f"From {AGENT_NAME}( \\d+)?", asked[0]["label"]) and words[1] in asked[0]["quote"], asked)
    return parsed["data"] or {}


def player_field(base):
    song = good("a tab that plays", "tabs", "new", base + "song", "--front")["id"]
    wait_for(lambda: bench("eval", song, "document.readyState").strip() == "complete", 10)
    bench("eval", song, "document.getElementById('a').play(), 1")
    shown = {}

    def heard():
        nonlocal shown
        shown = good("tabs show while it plays", "tabs", "show", song)
        return isinstance(shown.get("player"), dict) and shown["player"].get("playing") is True and shown["player"].get("duration") == 60

    check("tabs show has the mini player's state", wait_for(heard, 15) and shown["player"].get("title") == "A Quiet Song"
          and shown["player"].get("detail") == "Nobody" and shown["player"].get("duration") == 60 and "rate" in shown["player"], shown)
    raw = shown.get("player") or {}
    check("and its raw readings", str(raw.get("reading", "")).startswith("audio, ") and "playing" in str(raw.get("reading"))
          and raw.get("refused") == "no" and "chosen" in str(raw.get("media1", "")) and raw.get("frames", 0) >= 1, raw)
    plain = broadway("tabs", "show", song)
    check("and says it in words", "player: " in plain.stdout and "title=A Quiet Song" in plain.stdout and "playing=yes" in plain.stdout, plain.stdout)
    bench("eval", song, "document.getElementById('a').pause(), 1")
    yes("close the playing tab", "tabs", "close", song)
    quiet = good("tabs show of a quiet tab", "tabs", "show", good("a quiet tab", "tabs", "new", base + "tabquiet")["id"])
    check("a quiet tab has no player", quiet.get("player") is None, quiet)


def spaces_and_tabs(base):
    listed = good("spaces list", "spaces", "list")
    first = next(row for row in listed["spaces"] if row["current"])["name"]
    no("spaces new needs a name", "usage", "spaces", "new")
    made = good("spaces new", "spaces", "new", "Work")
    other = good("spaces new --fresh", "spaces", "new", "Temp", "--fresh")
    again = good("spaces list again", "spaces", "list")["spaces"]
    check("a new space stays behind", next(row for row in again if row["current"])["name"] == first)
    check("each space says which accounts it uses", {row["name"]: row["accounts"] for row in again if row["name"] in ("Work", "Temp")} == {"Work": "shared", "Temp": "separate"}, again)
    good("spaces rename", "spaces", "rename", "Temp", "Scratch")
    good("spaces move", "spaces", "move", "Scratch", "2")
    check("it moved", good("spaces order", "spaces", "list")["spaces"][1]["name"] == "Scratch")
    no("spaces move out of range", "usage", "spaces", "move", "Scratch", "99")
    wrong = no("a bad icon", "usage", "spaces", "icon", "Scratch", "nope")
    icon = wrong["error"]["hint"].split(": ")[1].split(",")[0].rstrip(".")
    good("spaces icon", "spaces", "icon", "Scratch", icon)
    no("a space that isn't", "not_found", "spaces", "switch", "Nowhere")
    good("spaces switch", "spaces", "switch", "Work")
    check("space says", good("space show", "space", "show")["space"] == "Work")
    good("broadway space NAME", "space", "show", first)
    check("space came back", broadway("space").stdout.strip().endswith(first) or first in broadway("space").stdout, broadway("space").stdout)
    no("the erase needs a person", "needs_you", "spaces", "delete", "Scratch", "--no-person")
    yes("spaces delete", "spaces", "delete", "Scratch")
    check("it's gone", not any(row["name"] == "Scratch" for row in good("spaces gone", "spaces", "list")["spaces"]))

    tab = good("tabs new", "tabs", "new", base + "tabone")["id"]
    rows = good("tabs list", "tabs", "list")["tabs"]
    mine = next(row for row in rows if row["id"] == tab)
    check("a person's tab, behind", mine["agent"] is False and mine["front"] is False, mine)
    other_tab = good("tabs new front", "tabs", "new", base + "tabtwo", "--front")["id"]
    check("--front", next(row for row in good("tabs list", "tabs", "list")["tabs"] if row["id"] == other_tab)["front"])
    good("tabs select", "tabs", "select", tab)
    shown = good("tabs show", "tabs", "show", tab)
    check("tabs show fields", shown["id"] == tab and shown["space"] == first and "zoom" in shown and "folder" in shown, shown)
    no("tabs show needs one", "usage", "tabs", "show")
    good("tabs rename", "tabs", "rename", other_tab, "Named")
    check("the name stays", good("named", "tabs", "show", other_tab)["name"] == "Named")
    good("tabs rename clears", "tabs", "rename", other_tab)
    good("tabs pin", "tabs", "pin", other_tab)
    check("pinned", any(row["id"] == other_tab for row in good("tabs list --pinned", "tabs", "list", "--pinned")["tabs"]))
    good("tabs unpin", "tabs", "unpin", other_tab)
    good("tabs mute", "tabs", "mute", tab, other_tab)
    check("muted", good("muted", "tabs", "show", tab)["muted"])
    good("tabs unmute", "tabs", "unmute", tab, other_tab)
    slept = good("tabs sleep", "tabs", "sleep", other_tab)
    check("sleep answers", slept["tabs"][0]["id"] == other_tab, slept)
    check("wake answers", good("tabs wake", "tabs", "wake", other_tab)["tabs"][0]["state"] == "awake")
    good("tabs move --to", "tabs", "move", other_tab, "--to", "1")
    no("tabs move says where", "usage", "tabs", "move", other_tab)
    good("tabs move --space", "tabs", "move", other_tab, "--space", "Work")
    check("not on screen", not any(row["id"] == other_tab for row in good("list", "tabs", "list")["tabs"]))
    everything = good("tabs list --all", "tabs", "list", "--all")["tabs"]
    check("--all reaches it", next(row for row in everything if row["id"] == other_tab)["space"] == "Work", everything)
    check("--space too", any(row["id"] == other_tab for row in good("tabs list --space", "tabs", "list", "--space", "Work")["tabs"]))
    no("a tab elsewhere can't be pinned", "refused", "tabs", "pin", other_tab)
    in_space = good("broadway open --space", "open", "--space", "Work", base + "agentwork")
    check("an agent tab in a space", in_space["agent"] and next(row for row in good("all", "tabs", "list", "--all")["tabs"] if row["id"] == in_space["id"])["space"] == "Work", in_space)
    covered.add("tabs open")
    yes("tabs keep", "tabs", "keep", in_space["id"])
    check("now the person's", good("kept", "tabs", "show", in_space["id"])["agent"] is False)
    good("tabs list --pinned empty", "tabs", "list", "--pinned")
    yes("tabs close another space", "tabs", "close", other_tab)
    check("gone from the other space", other_tab not in str(good("all", "tabs", "list", "--all")))
    yes("tabs close", "tabs", "close", tab)
    check("in closed", any("tabone" in row["url"] for row in good("tabs closed", "tabs", "closed")["closed"]), good("tabs closed", "tabs", "closed"))
    reopened = good("tabs reopen", "tabs", "reopen")
    check("reopen answers", reopened["id"], reopened)
    agent = broadway("open", base + "byagent").stdout.strip()
    good("an agent tab closes at once", "tabs", "close", agent)

    private = bench("open", base + "secretspace", "private").strip()
    time.sleep(0.6)
    check("private tabs stay out of --all", private[:8] not in str(good("all", "tabs", "list", "--all")) and "secretspace" not in str(good("all", "tabs", "list", "--all")))
    no("a private tab can't be shown", "no_tab", "tabs", "show", private[:8])
    no("nor closed", "no_tab", "tabs", "close", private[:8])
    no("nor selected", "no_tab", "tabs", "select", private[:8])
    no("nor read as a page", "no_tab", "page", "info", "--tab", private[:8])
    bench("close", private)

    folder = good("folders new", "folders", "new", "Reading")["id"]
    first_tab = good("tabs new", "tabs", "new", base + "foldered")["id"]
    second_tab = good("tabs new", "tabs", "new", base + "foldered2")["id"]
    good("folders add", "folders", "add", "Reading", first_tab, second_tab)
    row = next(row for row in good("folders list", "folders", "list")["folders"] if row["id"] == folder)
    check("two tabs in it", row["tabs"] == 2, row)
    good("folders rename", "folders", "rename", "Reading", "Later")
    good("folders fold", "folders", "fold", "Later")
    check("folded", next(row for row in good("folders list", "folders", "list")["folders"] if row["id"] == folder)["folded"])
    good("folders unfold", "folders", "unfold", "Later")
    check("a new folder is in the list, not pinned", not next(row for row in good("folders list", "folders", "list")["folders"] if row["id"] == folder)["pinned"])
    good("folders pin", "folders", "pin", "Later")
    check("pinned", next(row for row in good("folders list", "folders", "list")["folders"] if row["id"] == folder)["pinned"])
    good("folders unpin", "folders", "unpin", "Later")
    check("unpinned again", not next(row for row in good("folders list", "folders", "list")["folders"] if row["id"] == folder)["pinned"])
    good("folders remove", "folders", "remove", first_tab)
    good("tabs move --folder", "tabs", "move", first_tab, "--folder", "Later")
    good("tabs move --no-folder", "tabs", "move", first_tab, "--no-folder")
    good("tabs new in a folder", "tabs", "new", base + "folderthree", "--folder", "Later")
    with_tabs = good("folders new with tabs", "folders", "new", "Trip", "--tabs", first_tab)["id"]
    good("folders delete", "folders", "delete", "Trip")
    check("the tab stayed", first_tab in str(good("list", "tabs", "list")))
    check("the folder went", with_tabs not in str(good("folders list", "folders", "list")))
    yes("folders close", "folders", "close", "Later")
    check("its tabs went", second_tab not in str(good("list", "tabs", "list")))

    bench("aigroups", "off")
    no("groups regroup while grouping is off", "refused", "groups", "regroup")
    bench("aigroups", "on")
    bench("aigroups", "fake", "30", "30")
    good("tabs new", "tabs", "new", base + "grouped-one")
    good("tabs new", "tabs", "new", base + "grouped-two")
    regrouped = good("groups regroup", "groups", "regroup")
    listed = good("groups list", "groups", "list")
    check("regroup made the groups list shows", regrouped["formed"] >= 1 and len(listed["groups"]) == regrouped["formed"], (regrouped, listed))
    check("each AI group has a name and tabs", all(row["name"] and row["tabs"] >= 2 for row in listed["groups"]), listed)
    for row in listed["groups"]:
        good("an AI group can be ungrouped", "folders", "delete", row["id"])
    check("none left", not good("groups list", "groups", "list")["groups"])
    bench("aigroups", "off")

    left = good("tabs new", "tabs", "new", base + "left")["id"]
    right = good("tabs new", "tabs", "new", base + "right", "--front")["id"]
    good("split start", "split", "start", right, left)
    pairs = good("split list", "split", "list")["pairs"]
    check("a pair", len(pairs) == 1 and pairs[0]["front"], pairs)
    good("split swap", "split", "swap")
    good("split even", "split", "even")
    good("split detach", "split", "detach", left)
    check("no pair", not good("split list", "split", "list")["pairs"])
    no("nothing to swap", "refused", "split", "swap")

    count = len(good("windows list", "windows", "list")["windows"])
    good("windows new", "windows", "new")
    check("a window more", len(good("windows list", "windows", "list")["windows"]) == count + 1)
    probe = subprocess.run([BENCH, "--world", WORLD, "tabs"], capture_output=True, text=True, timeout=30)
    check("no window on a screen", probe.returncode == 0, probe.stderr)


def your_stuff(base):
    made = good("bookmarks add", "bookmarks", "add", base + "marked", "--title", "Marked page")["id"]
    no("bookmarked twice", "refused", "bookmarks", "add", base + "marked")
    no("bookmarks are web pages", "refused", "bookmarks", "add", "file:///etc/passwd")
    folder = good("bookmarks folder", "bookmarks", "folder", "Keepers")["id"]
    check("bookmarks list", any(row["id"] == made and row["url"].endswith("marked") for row in good("bookmarks list", "bookmarks", "list")["bookmarks"]))
    check("a query narrows", len(good("bookmarks find", "bookmarks", "list", "Marked")["bookmarks"]) == 1)
    good("bookmarks rename", "bookmarks", "rename", made, "Renamed page")
    good("bookmarks move", "bookmarks", "move", made, "--folder", "Keepers")
    check("in the folder", [row["id"] for row in good("--folder", "bookmarks", "list", "--folder", "Keepers")["bookmarks"]] == [made])
    no("a folder can't go in itself", "refused", "bookmarks", "move", folder, "--folder", "Keepers")
    opened = good("bookmarks open", "bookmarks", "open", made)
    check("as the person's tab", good("tab", "tabs", "show", opened["id"])["agent"] is False)
    no("a folder doesn't open", "refused", "bookmarks", "open", folder)
    no("no erase without a person", "needs_you", "bookmarks", "delete", made, "--no-person")
    with_person("bookmarks delete refused", "no", "bookmarks", "delete", made)
    check("no is no", any(row["id"] == made for row in good("still", "bookmarks", "list")["bookmarks"]))
    yes("bookmarks delete", "bookmarks", "delete", made)
    check("gone", not any(row["id"] == made for row in good("gone", "bookmarks", "list")["bookmarks"]))
    no("a bad id", "not_found", "bookmarks", "delete", "zzzzzzzz")

    held_tab = good("a slow file", "tabs", "new", base + "slow.bin")["id"]
    check("it starts", wait_for(lambda: any(row["state"] == "downloading" for row in good("downloads list", "downloads", "list")["downloads"]), 8))
    row = next(row for row in good("downloads list", "downloads", "list")["downloads"] if row["state"] == "downloading")
    good("downloads pause", "downloads", "pause", row["id"])
    check("paused", wait_for(lambda: any(item["state"] == "paused" for item in good("list", "downloads", "list")["downloads"])))
    good("downloads resume", "downloads", "resume", row["id"])
    check("going again", wait_for(lambda: any(item["state"] == "downloading" for item in good("list", "downloads", "list")["downloads"])))
    yes("downloads cancel", "downloads", "cancel", row["id"])
    good("a broken file", "tabs", "new", base + "drop.bin")
    check("it fails", wait_for(lambda: any(item["state"] == "failed" for item in good("list", "downloads", "list")["downloads"]), 8))
    broken = next(item for item in good("list", "downloads", "list")["downloads"] if item["state"] == "failed")
    good("downloads retry", "downloads", "retry", broken["id"])
    no("no such download", "not_found", "downloads", "pause", "zzzzzzzz")
    good("a whole file", "tabs", "new", base + "file.bin")
    check("it lands", wait_for(lambda: any(item["state"] == "done" and item["name"] == "file.bin" for item in good("list", "downloads", "list")["downloads"]), 8))
    done = next(item for item in good("list", "downloads", "list")["downloads"] if item["name"] == "file.bin")
    check("it landed in the test world", str(FOLDER) in done["path"], done)
    check("files list", any(row["name"] == "file.bin" for row in good("files list", "files", "list")["files"]))
    check("files query", not good("files find", "files", "list", "nothing such")["files"])
    given = good("downloads get", "downloads", "get", done["id"])
    check("downloads get gives the path", given.get("path") == done["path"], given)
    raw = broadway("downloads", "get", done["id"], "--out", "-", text=False)
    check("downloads get --out - gives the bytes", raw.stdout == Path(done["path"]).read_bytes(), len(raw.stdout))
    yes("downloads forget", "downloads", "forget", done["id"])
    check("the file stays", Path(done["path"]).exists())
    yes("downloads clear", "downloads", "clear")
    secret_download = bench("open", base + "shy.bin", "private").strip()
    check("a private download happens", wait_for(lambda: list(FOLDER.rglob("shy.bin")), 8))
    check("a private download isn't listed", "shy.bin" not in str(good("list", "downloads", "list")) and "shy.bin" not in str(good("files", "files", "list")))
    bench("close", secret_download)
    watching = subprocess.Popen([BROADWAY, "--world", WORLD, "watch", "--json", "--only", "downloads", "--seconds", "4"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(0.6)
    slow_secret = bench("open", base + "slow-shy.bin", "private").strip()
    check("a private download is under way", wait_for(lambda: list(FOLDER.rglob("slow-shy.bin*")), 8))
    check("and not listed while it runs", "slow-shy" not in str(good("list", "downloads", "list")))
    check("nor in the files", "slow-shy" not in str(good("files", "files", "list")))
    streamed = watching.communicate(timeout=10)[0]
    check("nor in watch", "slow-shy" not in streamed, streamed)
    bench("close", slow_secret)

    visited = base + "visited-page"
    broadway(visited)
    check("history list", wait_for(lambda: any("visited-page" in row["url"] for row in good("history list", "history", "list", "visited")["visits"]), 5), "")
    no("delete says what", "usage", "history", "delete")
    no("one way at a time", "usage", "history", "delete", visited, "--since", "1h")
    no("--since is a time", "usage", "history", "delete", "--since", "soon")
    yes("history delete", "history", "delete", visited)
    check("it went", not good("history list", "history", "list", "visited-page")["visits"])
    broadway(base + "site-page")
    wait_for(lambda: good("history list", "history", "list", "site-page")["visits"], 5)
    yes("history delete --site", "history", "delete", "--site", "127.0.0.1")
    check("the site went", not good("history list", "history", "list", "site-page")["visits"])
    broadway(base + "since-page")
    wait_for(lambda: good("history list", "history", "list", "since-page")["visits"], 5)
    yes("history delete --since", "history", "delete", "--since", "1h")
    check("the hour went", not good("history list", "history", "list", "since-page")["visits"])
    broadway(base + "clear-page")
    wait_for(lambda: good("history list", "history", "list", "clear-page")["visits"], 5)
    yes("history clear", "history", "clear")
    check("nothing left", not good("history list", "history", "list")["visits"])

    no("a source that isn't", "refused", "live", "add", "Bad", "not an address at all")
    folder = good("live add", "live", "add", "News", base + "feed.xml")["id"]
    good("live update one", "live", "update", folder)
    check("it reads the feed", wait_for(lambda: any(row["id"] == folder and row["items"] == 2 for row in good("live list", "live", "list")["folders"]), 10), good("live list", "live", "list"))
    shown = good("live show", "live", "show", folder)
    check("website content is marked", shown["website"] is True and shown["items"][0]["title"].startswith("Item"), shown)
    no("a feed has no statuses to choose", "refused", "live", "statuses", folder, "todo")
    no("a feed has no lists to choose", "refused", "live", "lists", folder, "changed")
    no("a feed has no range to choose", "refused", "live", "range", folder, "week")
    no("a feed has no review requests to hide", "refused", "live", "drafts", folder, "hide")
    said = good("live unhide", "live", "unhide", folder)
    check("nothing was removed from it", said.get("shown") == 0, said)
    prs = good("live add prs", "live", "add", "PRs", "https://github.com/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")["id"]
    no("an unknown list is refused", "refused", "live", "lists", prs, "later")
    said = good("live lists", "live", "lists", prs, "changed", "Created by You")
    check("the lists are taken", said.get("lists") == ["Changed Since Your Review", "Created by You"], said)
    check("live show says them", good("live show prs", "live", "show", prs).get("lists") == ["Changed Since Your Review", "Created by You"])
    yes("live delete prs", "live", "delete", prs)
    rocket = good("live add repository", "live", "add", "Rocket", "acme/rocket")["id"]
    no("a range that isn't one is refused", "usage", "live", "range", rocket, "year")
    said = good("live range", "live", "range", rocket, "week")
    check("the range is taken", said.get("range") == "week", said)
    yes("live delete repository", "live", "delete", rocket)
    good("live rename", "live", "rename", folder, "Headlines")
    good("live pause", "live", "pause", folder)
    good("live resume", "live", "resume", folder)
    good("live update", "live", "update")
    yes("live delete", "live", "delete", folder)
    check("live gone", not good("live list", "live", "list")["folders"])


def filling(base):
    csv = Path(tempfile.mkdtemp()) / "passwords.csv"
    csv.write_text(f"url,username,password\nhttp://127.0.0.1/,{SAM},s3cret-pass-word\n")
    bench("import-file", str(csv))
    shutil.rmtree(csv.parent)
    kept = no("logins list is the person's", "person_only", "logins", "list")
    check("no site or user named", SAM not in str(kept) and "127.0.0.1" not in str(kept) and "fill login" in kept["error"].get("hint", ""), kept)
    given = no("logins give is off until the person turns it on", "person_only", "logins", "give", "127.0.0.1")
    check("and its hint names the switch", "Let agents ask for a saved password" in given["error"].get("hint", ""), given)
    port = int(base.rstrip("/").rsplit(":", 1)[1])
    sv.cmd({"do": "agents", "action": "logins", "kept": [{"host": "127.0.0.1", "port": port, "user": SAM, "password": "s3cret-pass-word", "clear": True}]})
    tab = good("a form", "tabs", "new", base + "signin")["id"]
    broadway("wait", "--tab", tab)
    no("fill login needs a person", "needs_you", "fill", "login", "--tab", tab, "--no-person")
    data = yes("fill login", "fill", "login", "--tab", tab)
    check("no password back", "s3cret" not in str(data), data)
    check("the page got it", "s3cret-pass-word" in bench("eval", tab, "document.getElementById('pass').value"))
    no("fill code finds no code box on a sign-in page", "not_found", "fill", "code", "--tab", tab)
    no("no value leaks", "refused", "wait", "--selector", 'input[value^="s"]', "--seconds", "1", "--tab", tab)
    covered.discard("wait --selector")
    bench("autofill", "seed")
    form = good("a page", "tabs", "new", base + "details")["id"]
    broadway("wait", "--tab", form)
    data = yes("fill details", "fill", "details", "--tab", form)
    check("details fill the form", data.get("filled", 0) > 0, data)
    payment = good("a card form", "tabs", "new", base + "cardform")["id"]
    broadway("wait", "--tab", payment)
    no("fill card needs a person", "needs_you", "fill", "card", "--tab", payment, "--no-person")
    code, parsed, _, errors = with_person("fill card", "yes", "fill", "card", "--tab", payment)
    check("a card's number never comes back", "4242" not in json.dumps(parsed) and "4242" not in errors, parsed)
    check("a card is never filled on a page like this", code == 1 and "insecure" in str(parsed), parsed)


def page_tools(base):
    tab = good("a page", "tabs", "new", base + "tools")["id"]
    broadway("wait", "--tab", tab)
    wait_for(lambda: (run("page", "info", "--tab", tab)[1].get("data") or {}).get("title") == "Form", 10)
    info = good("page info", "page", "info", "--tab", tab)
    check("page info", info["title"] == "Form" and info["zoom"] == 100 and info["website"] is True, info)
    found = run("page", "find", "price", "--tab", tab)[1]["data"]
    check("page find", found["count"] == 1 and "12 dollars" in found["matches"][0]["text"] and found["website"], found)
    check("find gives elements", broadway("find", "Go", "--tab", tab).returncode == 0)
    texted = broadway("find", "price", "--tab", tab)
    check("find on words in the page text gives the line and the control near it", texted.returncode == 0 and "No control is named" in texted.stdout and "the price is 12 dollars" in texted.stdout and "near @e" in texted.stdout, texted.stdout + texted.stderr)
    _, parsed = envelope("find", "price", "--tab", tab)
    check("find's text lines stay out of elements", parsed["data"]["count"] == 0 and parsed["data"]["elements"] == [] and parsed["data"]["text"][0]["near"]["ref"], parsed)
    none = broadway("find", "Mark seenn", "--tab", tab)
    check("find with no element names the closest names", none.returncode == 1 and "No element fits" in none.stderr and "Closest names" in none.stderr and '"Mark seen"' in none.stderr, none.stderr)
    missed = broadway("click", "Delete drafts", "--tab", tab)
    check("a click on words that fit nothing names the closest and clicks nothing", missed.returncode == 1 and '"Delete draft"' in missed.stderr and "erased" not in broadway("tabs").stdout, missed.stderr)
    sections = good("sections", "tabs", "new", base + "sections")["id"]
    broadway("wait", "--tab", sections)
    _, parsed = envelope("find", "Edit", "--in", "Shipping address", "--tab", sections)
    check("--in words work in a tab never shown", parsed.get("ok") and parsed["data"]["count"] == 1, parsed)
    unseen = broadway("find", "zebra", "--tab", sections)
    check("find never gives text a person can't see", unseen.returncode == 1 and "hidden words" not in unseen.stdout + unseen.stderr and "faint words" not in unseen.stdout + unseen.stderr, unseen.stdout + unseen.stderr)
    started = time.time()
    read = broadway("read", "--tab", tab)
    check("read in a tab never shown answers at once", read.returncode == 0 and "price" in read.stdout and time.time() - started < 4, (time.time() - started, read.stdout[:200], read.stderr))
    started = time.time()
    shot = broadway("snapshot", "--tab", tab)
    check("snapshot in a tab never shown answers at once", shot.returncode == 0 and "@e" in shot.stdout and time.time() - started < 4, (time.time() - started, shot.stdout[:200], shot.stderr))
    check("find never reaches a box", good("secret", "page", "find", "hunter2", "--tab", tab)["count"] == 0)
    check("nor a card", good("card", "page", "find", "4242", "--tab", tab)["count"] == 0)
    check("--case", good("case", "page", "find", "PRICE", "--case", "--tab", tab)["count"] == 0)
    check("--words", good("words", "page", "find", "pric", "--words", "--tab", tab)["count"] == 0)
    marked = broadway("find", "Go", "--tab", tab)
    check("find is marked as website content", "Website content" in marked.stderr, marked.stderr)
    good("page zoom in", "page", "zoom", "125", "--tab", tab)
    check("page zoom reads", good("page zoom", "page", "zoom", "--tab", tab)["zoom"] == 125)
    good("zoom in word", "page", "zoom", "in", "--tab", tab)
    check("zoom reset", good("zoom reset", "page", "zoom", "reset", "--tab", tab)["zoom"] == 100)
    no("a silly zoom", "usage", "page", "zoom", "9000", "--tab", tab)
    good("page go on", "go", base + "second", "--tab", tab)
    broadway("wait", "Other", "--tab", tab)
    good("page back", "page", "back", "--tab", tab)
    broadway("wait", "price", "--tab", tab)
    good("page forward", "page", "forward", "--tab", tab)
    broadway("wait", "Other", "--tab", tab)
    good("page reload", "page", "reload", "--tab", tab)
    broadway("wait", "Other", "--tab", tab)
    good("page back again", "page", "back", "--tab", tab)
    broadway("wait", "price", "--tab", tab)
    translated = good("page translate", "page", "translate", "fr", "--tab", tab)
    check("translate says", translated["language"].startswith("fr"), translated)
    good("page original", "page", "original", "--tab", tab)
    no("not translated", "refused", "page", "original", "--tab", tab)

    out = Path(tempfile.mkdtemp()) / "page.pdf"
    made = broadway("pdf", "-o", str(out), "--tab", tab)
    covered.add("page pdf")
    check("pdf -o", made.returncode == 0 and out.read_bytes()[:4] == b"%PDF", made.stderr)
    reader = out.parent / "read.swift"
    reader.write_text("import PDFKit\nlet d = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1]))!\nprint(d.string ?? \"\")\n")
    text = subprocess.run(["swift", str(reader), str(out)], capture_output=True, text=True, timeout=120).stdout
    check("the pdf has the page", "the price is 12 dollars" in " ".join(text.split()), text)
    check("and neither secret", "hunter2" not in text and "4242" not in text, text)
    good("bring it up", "tabs", "select", tab)
    still = broadway("snapshot", "--tab", tab)
    check("the boxes are as they were", "value hidden" in still.stdout, still.stdout + still.stderr)
    raw = broadway("pdf", "--tab", tab, text=False)
    check("pdf on a pipe names its file and writes no PDF there", raw.returncode == 0 and raw.stdout[:4] != b"%PDF" and b".pdf" in raw.stdout, raw.stdout[:200])
    raw = broadway("pdf", "--tab", tab, "--out", "-", text=False)
    check("pdf --out - is the file", raw.stdout[:4] == b"%PDF")
    shutil.rmtree(out.parent)

    info = good("site info", "site", "info", "--tab", tab)
    check("site info", info["site"] == "127.0.0.1" and info["hidden"] == 0, info)
    no("a selector that reads", "refused", "site", "hide", 'input[value^="h"]', "--tab", tab)
    no("nor css", "refused", "site", "hide", "p { color: red }", "--tab", tab)
    good("site hide", "site", "hide", "#go", "--label", "the button", "--tab", tab)
    check("site hidden", [row["selector"] for row in good("site hidden", "site", "hidden", "--tab", tab)["hidden"]] == ["#go"])
    check("it's really gone", "Go" not in broadway("read", "--tab", tab).stdout.split(), broadway("read", "--tab", tab).stdout)
    good("site unhide", "site", "unhide", "#go", "--tab", tab)
    no("nothing to unhide", "not_found", "site", "unhide", "#go", "--tab", tab)
    good("site hide two", "site", "hide", "#plain", "--tab", tab)
    good("site unhide --all", "site", "unhide", "--all", "--tab", tab)

    front = next(row for row in good("tabs", "tabs", "list")["tabs"] if row["front"])
    no("the person's front tab isn't sent back", "refused", "page", "back", "--tab", front["id"])
    no("nor reloaded", "refused", "page", "reload", "--tab", front["id"])
    agent = broadway("open", base + "agentside").stdout.strip()
    broadway("wait", "--tab", agent)
    good("an agent's tab reloads", "page", "reload", "--tab", agent)
    broadway("close", "--tab", agent)


def settings_commands(base):
    rows = good("settings list", "settings", "list")["settings"]
    check("settings list", len(rows) > 30 and any(row["id"] == "newtab.floating" for row in rows) and not any(row["id"] == "tabs.give" for row in rows), len(rows))
    check("--page", all(row["page"] == "privacy" for row in good("settings privacy", "settings", "list", "--page", "privacy")["settings"]))
    no("a bad page", "not_found", "settings", "list", "--page", "nowhere")
    check("settings find", any(row["id"] == "newtab.floating" for row in good("settings find", "settings", "find", "floating")["settings"]))
    check("settings get", "changes" in good("settings get", "settings", "get", "newtab.floating"))
    check("agents are readable", good("settings get", "settings", "get", "ai.agents")["value"] is True)
    check("what can't be changed says so", "person" in good("settings get", "settings", "get", "ai.agents")["changes"])
    good("settings set", "settings", "set", "newtab.floating", "true")
    check("it took", good("get", "settings", "get", "newtab.floating")["value"] is True)
    good("settings set back", "settings", "set", "newtab.floating", "false")
    no("a setting the cut fixed", "not_found", "settings", "set", "tabs.give", "false")
    good("a choice", "settings", "set", "look", "dark")
    no("a bad value", "usage", "settings", "set", "look", "plaid")
    no("no such setting", "not_found", "settings", "set", "nope", "true")
    for setting, value in SETTINGS_REFUSED:
        no(f"settings set {setting} {value}", "person_only", "settings", "set", setting, value)
    no("codes from Messages is gone", "not_found", "settings", "get", "codes.messages")
    apple = good("settings get passwords.apple", "settings", "get", "passwords.apple")
    if apple["changes"] == "not available yet":
        check("Apple Passwords reads as off", apple["value"] is False, apple)
        said = no("settings set passwords.apple true", "refused", "settings", "set", "passwords.apple", "true")
        check("…and it says it isn't available yet", "isn't available yet" in said["error"]["message"], said)
    else:
        no("settings set passwords.apple true", "person_only", "settings", "set", "passwords.apple", "true")
    check("the switch is unchanged", good("get", "settings", "get", "ai.agents")["value"] is True)
    check("nor the mode", good("agents status", "agents", "status")["mode"] != "bypass")
    good("turning safety up is fine", "settings", "set", "shield", "true")
    no("no control", "refused", "settings", "set", "clear.history", "true")
    no("nor a custom engine", "person_only", "settings", "set", "search.engine", "custom")
    good("settings open", "settings", "open", "shield")
    good("settings open plain", "settings", "open")

    rows = good("shortcuts list", "shortcuts", "list")["shortcuts"]
    check("shortcuts list", len(rows) > 20, len(rows))
    target = rows[0]["id"]
    good("shortcuts set", "shortcuts", "set", target, "cmd+shift+option+y")
    check("the key shows", next(row for row in good("list", "shortcuts", "list")["shortcuts"] if row["id"] == target)["key"], "")
    no("a key that isn't", "usage", "shortcuts", "set", target, "banana+k")
    good("shortcuts clear", "shortcuts", "clear", target)
    check("no key", not next(row for row in good("list", "shortcuts", "list")["shortcuts"] if row["id"] == target)["key"])
    good("shortcuts reset", "shortcuts", "reset", target)
    good("shortcuts reset --all", "shortcuts", "reset", "--all")
    no("reset says which", "usage", "shortcuts", "reset")
    no("no such command", "not_found", "shortcuts", "set", "nope", "cmd+y")

    folder = Path(tempfile.mkdtemp())
    (folder / "manifest.json").write_text(json.dumps({"manifest_version": 3, "name": "Test ext", "version": "1.0", "permissions": ["storage"]}))
    installed = bench("ext-folder", str(folder), "--yes")
    rows = good("extensions list", "extensions", "list")["extensions"]
    check("extensions list", len(rows) == 1 and rows[0]["name"] == "Test ext", (rows, installed))
    extension = rows[0]["id"]
    check("extensions show", good("extensions show", "extensions", "show", extension)["name"] == "Test ext")
    good("extensions disable", "extensions", "disable", extension)
    check("off", good("show", "extensions", "show", extension)["enabled"] is False)
    good("extensions enable", "extensions", "enable", extension)
    good("extensions reload", "extensions", "reload", extension)
    no("extensions private", "person_only", "extensions", "private", extension)
    no("extensions install takes a link", "usage", "extensions", "install", "not a link")
    yes("extensions remove", "extensions", "remove", extension)
    check("removed", not good("list", "extensions", "list")["extensions"])
    shutil.rmtree(folder)

    hooks = good("hooks list", "hooks", "list")
    check("hooks list is a list, empty in a new world", hooks.get("hooks") == [], hooks)

    state = good("shields list", "shields", "list")
    check("shields list", state["on"] is True and "sites" in state, state)
    no("shields off", "person_only", "shields", "off", "example.com")
    bench("shield", "pause", "example.com")
    check("a paused site shows", any(row["site"] == "example.com" for row in good("list", "shields", "list")["sites"]), good("list", "shields", "list"))
    good("shields on", "shields", "on", "example.com")
    check("back on", not good("list", "shields", "list")["sites"])
    good("shields update", "shields", "update")

    subprocess.run(["defaults", "write", SUITE, "capture.https://allowed.example|0", "-bool", "true"], check=True)
    time.sleep(0.3)
    no("permissions allow", "person_only", "permissions", "allow", "https://allowed.example")
    listed = good("permissions list", "permissions", "list")["permissions"]
    check("permissions list", any("allowed.example" in row["site"] for row in listed), listed)
    good("permissions reset", "permissions", "reset", "allowed.example")
    check("forgotten", not good("again", "permissions", "list")["permissions"])
    no("nothing to reset", "not_found", "permissions", "reset", "allowed.example")


def ai_commands(base):
    built = good("skills list", "skills", "list")["skills"]
    check("skills list", built and any(row["yours"] is False for row in built), built)
    name = built[0]["name"]
    check("skills show", good("skills show", "skills", "show", name)["text"])
    no("a built-in stays", "refused", "skills", "delete", name, "--no-person")
    copy = good("skills duplicate", "skills", "duplicate", name)["name"]
    yes("skills delete", "skills", "delete", copy)
    skill = "# cli-skill\nsites: example.com\n\nDo the thing.\n"
    covered.add("skills new")
    made = subprocess.run([BROADWAY, "--world", WORLD, "--json", "skills", "new"], input=skill, capture_output=True, text=True, timeout=20)
    check("skills new from stdin", made.returncode == 0, made.stdout + made.stderr)
    check("it's there", any(row["name"] == "cli-skill" for row in good("list", "skills", "list")["skills"]))
    no("rubbish", "usage", "skills", "new", "/etc/hosts")
    yes("your skill goes", "skills", "delete", "cli-skill")

    check("replies list", good("replies list", "replies", "list")["watches"] == [])
    no("replies stop", "not_found", "replies", "stop", "zzzzzzzz")
    check("now list", "rows" in good("now list", "now", "list"))
    no("now done", "not_found", "now", "done", "nothing")
    status = good("agents status", "agents", "status")
    check("agents status", status["switch"] is True and status["mode"] in ("auto", "ask", "bypass"), status)
    connected = good("agents connect", "agents", "connect")["connected"]
    listed = good("agents list", "agents", "list")["agents"]
    check("the named agent is connected", connected["name"] == AGENT_NAME and any(row["id"] == connected["id"] and row["state"] == "connected" for row in listed), listed)
    idle = good("agents idle", "agents", "idle", "--summary", "Asked about the dates")["agent"]
    check("idle marks the turn finished and keeps the session", idle["id"] == connected["id"] and idle["state"] == "finished" and idle["status"] == "Asked about the dates", idle)
    again = good("agents list after idle", "agents", "list")["agents"]
    check("the next command makes it connected again", any(row["id"] == connected["id"] and row["state"] == "connected" for row in again), again)
    ended = good("agents disconnect", "agents", "disconnect", "--summary", "Finished CLI checks")["ended"]
    check("disconnect ends this session", ended["id"] == connected["id"] and ended["state"] == "done" and ended["summary"] == "Finished CLI checks", ended)
    reconnected = good("agents reconnect", "agents", "connect")["connected"]
    check("reconnecting starts another session", reconnected["id"] != connected["id"], reconnected)
    ended = good("agents done", "agents", "done", "--failed", "--summary", "Stopped CLI check", "--tab", "a8b6db94")["ended"]
    check("done records the ending", ended["id"] == reconnected["id"] and ended["state"] == "failed" and ended["summary"] == "Stopped CLI check", ended)
    good("agents connect again", "agents", "connect")
    plain_done = broadway("agents", "done", "--summary", "Plain CLI check")
    check("agents done prints its line and no row", plain_done.returncode == 0 and plain_done.stdout == "" and "Ended." in plain_done.stderr, plain_done.stdout + plain_done.stderr)
    good("agents connect after done", "agents", "connect")
    tab = good("a tab to ask about", "tabs", "new", base + "asked")["id"]
    running = subprocess.Popen([BROADWAY, "--world", WORLD, "tabs", "close", tab, "--wait-person", "1", "--json"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    wait_for(desk, 8)
    check("approvals list", good("approvals list", "approvals", "list")["approvals"][0]["title"] == "Close tabs?")
    check("there's no way to answer", broadway("approvals", "yes").returncode == 2)
    running.kill()
    check("a command that leaves takes its question", wait_for(lambda: not desk(), 5))
    check("nothing happened", tab in str(good("list", "tabs", "list")))


def setting_up(base):
    can = good("settings list --can-set", "settings", "list", "--can-set")["settings"]
    check("--can-set lists only what the command changes", can and all(row["changes"] in ("this command", "true here, false only the person", "false here, true only the person") for row in can) and any(row["id"] == "pageZoom" for row in can), can[:3])
    no("one wrong pair changes nothing", "usage", "settings", "set", "look", "light", "pageZoom", "7")
    check("…so the first pair stood still", good("get", "settings", "get", "look")["value"] != "light")
    no("a pair without its value", "usage", "settings", "set", "look", "light", "pageZoom")
    many = good("several settings at once", "settings", "set", "look", "light", "pageZoom", "110", "newtab.floating", "true", "bookmarks.bar", "true")
    check("…each one says what it was", [row["id"] for row in many.get("settings", [])] == ["look", "pageZoom", "newtab.floating", "bookmarks.bar"], many)
    good("a theme", "settings", "set", "look", "dark")
    target = "view.reload"
    good("a shortcut", "shortcuts", "set", target, "cmd+shift+option+r")
    good("a space", "spaces", "new", "Setup")
    no("a colour that isn't one", "usage", "spaces", "colour", "Setup", "plaid")
    good("its colour", "spaces", "colour", "Setup", "sage")
    no("a rule to another app is the person's", "person_only", "links", "add", "setup.example", "--app", "Safari")
    no("a rule needs a space", "usage", "links", "add", "setup.example")
    rule = good("a link rule", "links", "add", "setup.example", "--space", "Setup")["id"]
    other = good("another rule", "links", "add", "/pull/", "--kind", "contains", "--space", "Setup")["id"]
    good("links move", "links", "move", other, "1")
    good("links open goes to a space", "settings", "set", "links.open", "Setup")
    good("a site shortcut", "keywords", "add", "ex", "https://example.com/search?q=%s")
    no("pointing it elsewhere is the person's", "person_only", "keywords", "add", "ex", "https://other.example/?q=%s")
    action = good("a Quick Action", "actions", "add", "zzpr", "example.com/pulls", "--name", "Pulls")["id"]
    good("actions rename", "actions", "rename", action, "My pulls")
    good("actions move", "actions", "move", action, "1")
    good("a snippet", "snippets", "add", "zzsig", "Best, Sam", "--title", "Signature")
    good("snippets rename", "snippets", "rename", "zzsig", "Sign-off")
    live = good("a live folder", "live", "add", "Setup News", base + "feed.xml")["id"]

    settings = {row["id"]: row["value"] for row in good("settings list", "settings", "list")["settings"]}
    check("the theme reads back", settings.get("look") == "dark", settings.get("look"))
    check("the zoom reads back", settings.get("pageZoom") == 110, settings.get("pageZoom"))
    check("the two more read back", settings.get("newtab.floating") is True and settings.get("bookmarks.bar") is True, settings)
    check("links from outside read back", settings.get("links.open") == "Setup", settings.get("links.open"))
    check("the shortcut reads back", next(row for row in good("list", "shortcuts", "list")["shortcuts"] if row["id"] == target)["key"], target)
    check("the colour reads back", next(row for row in good("list", "spaces", "list")["spaces"] if row["name"] == "Setup").get("colour") == "sage")
    rules = good("links list", "links", "list")["rules"]
    check("the rules read back in order", [row["id"] for row in rules][:2] == [other, rule] and rules[1]["space"] == "Setup", rules)
    check("the site shortcut reads back", any(row["keyword"] == "ex" for row in good("keywords list", "keywords", "list")["keywords"]))
    actions = good("actions list", "actions", "list")["actions"]
    check("the Quick Action reads back first", actions and actions[0]["id"] == action and actions[0]["name"] == "My pulls", actions[:2])
    check("the snippet reads back", any(row["keyword"] == "zzsig" and row["title"] == "Sign-off" for row in good("snippets list", "snippets", "list")["snippets"]))
    check("the live folder reads back", any(row["id"] == live for row in good("live list", "live", "list")["folders"]))

    yes("links delete", "links", "delete", other)
    yes("keywords delete", "keywords", "delete", "ex")
    yes("actions delete", "actions", "delete", action)
    yes("snippets delete", "snippets", "delete", "zzsig")
    check("they are gone", not any(row["id"] == other for row in good("links", "links", "list")["rules"])
          and not good("keywords", "keywords", "list")["keywords"] and not any(row["keyword"] == "zzsig" for row in good("snippets", "snippets", "list")["snippets"]))
    good("shortcut back", "shortcuts", "reset", target)


def everyday(base):
    sv.cmd({"do": "ui", "lead": "history"})
    pages = [row for row in good("internal tab list", "tabs", "list")["tabs"] if row["url"] == "broadway://history"]
    check("an internal page has its address", len(pages) == 1, pages)
    if pages:
        no("internal tab cannot be arranged", "person_only", "tabs", "rename", pages[0]["id"], "Changed")
    gone, unknown = broadway("brief"), broadway("zzzz")
    check("a retired word answers as any unknown one", gone.returncode == unknown.returncode != 0
          and gone.stdout == unknown.stdout and gone.stderr.replace("brief", "zzzz") == unknown.stderr, (gone, unknown))
    gone, unknown = envelope("brief", "read")[1], envelope("zzzz", "read")[1]
    same = lambda answer: (answer["command"].replace("zzzz", "brief"), answer["ok"], (answer["error"] or {}).get("code"), str((answer["data"] or {}).get("answer", "")).replace("zzzz", "brief"))
    check("…with --json too", same(gone) == same(unknown), (gone, unknown))
    drift_cli = envelope("__nouns")[1]["data"]["verbs"]
    drift_app = [name for name in envelope("__nouns", "--app")[1]["data"]["verbs"] if not name.startswith("complete ")]
    check("the two tables say the same", sorted(drift_cli) == sorted(drift_app), set(drift_cli) ^ set(drift_app))
    left = set(drift_cli) - covered
    check("every verb was run", not left, sorted(left))
    for noun in {name.split()[0] for name in drift_cli}:
        page = broadway("help", noun)
        check(f"help {noun}", page.returncode == 0 and f"broadway {noun}" in page.stdout, page.stdout)
    one = broadway("help", "tabs", "move")
    check("help for a verb", one.returncode == 0 and "--space" in one.stdout, one.stdout)
    check("--help on a verb", broadway("tabs", "move", "--help").stdout == one.stdout)
    check("noun --help", broadway("tabs", "--help").stdout == broadway("help", "tabs").stdout)
    check("broadway --help shows the groups", "Spaces and tabs" in broadway("help").stdout and "Your stuff" in broadway("help").stdout)
    typo = broadway("tabs", "clsoe")
    check("a verb typo", typo.returncode == 2 and "Did you mean tabs close" in typo.stderr, typo.stderr)
    check("verbs complete", "move" in broadway("__complete", "tabs", "--", "mo").stdout)
    check("flags complete", "--space" in broadway("__complete", "tabs", "move", "--", "--s").stdout)
    check("spaces complete", "Work" in broadway("__complete", "spaces", "switch", "--", "W").stdout, broadway("__complete", "spaces", "switch", "--", "W").stdout)
    check("settings complete", "newtab.floating" in broadway("__complete", "settings", "get", "--", "newtab.f").stdout)
    for shell in ("fish", "zsh", "bash"):
        check(f"completions {shell}", broadway("completions", shell).returncode == 0 and len(broadway("completions", shell).stdout) > 50)
    check("completions needs a shell", broadway("completions", "tcsh").returncode == 2)

    def timed(*words):
        times = []
        for _ in range(30):
            began = time.perf_counter()
            broadway(*words)
            times.append((time.perf_counter() - began) * 1000)
        times.sort()
        return statistics.median(times)
    for words in (["spaces"], ["tabs", "--all"], ["settings", "get", "newtab.floating"], ["bookmarks"]):
        print(f"     latency {' '.join(words)}: median {timed(*words):.1f} ms")

    watch = subprocess.Popen([BROADWAY, "--world", WORLD, "watch", "--json", "--only", "tabs,spaces,downloads", "--seconds", "12"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(1)
    opened = broadway("tabs", "new", base + "watched").stdout.split()[0]
    sv.cmd({"do": "ui", "settingspage": "privacy"})
    broadway("spaces", "new", "Watched")
    private = bench("open", base + "secretwatch", "private").strip()
    time.sleep(1)
    broadway("--json", "spaces", "rename", "Watched", "Seen")
    bench("close", private)
    time.sleep(1)
    watch.terminate()
    lines = watch.communicate(timeout=5)[0].splitlines()
    events = [json.loads(line)["data"] for line in lines]
    check("watch sees an internal address", any(event.get("url") == "broadway://settings/privacy" for event in events), events)
    check("watch sees a tab", any(event["event"] == "tab.added" and event["id"] == opened for event in events), events)
    check("watch sees a space", any(event["event"] == "space.added" for event in events) and any(event["event"] == "space.changed" for event in events), events)
    check("watch never sees a private tab", "secretwatch" not in str(events), events)
    counted = subprocess.Popen([BROADWAY, "--world", WORLD, "watch", "--count", "1", "--only", "tabs"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(0.8)
    broadway("tabs", "new", base + "counted")
    check("--count stops it", counted.wait(timeout=8) == 0 and "tab.added" in counted.stdout.read())
    interrupted = subprocess.Popen([BROADWAY, "--world", WORLD, "watch"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    time.sleep(0.8)
    interrupted.send_signal(signal.SIGINT)
    check("Control-C exits 130", interrupted.wait(timeout=8) == 130, interrupted.returncode)
    check("a bad --only", broadway("watch", "--only", "cats").returncode == 2)


def person_switched_off(base):
    write_settings("false")
    refused = [["spaces"], ["bookmarks"], ["downloads"], ["history", "list"], ["skills"], ["settings", "get", "newtab.floating"],
               ["settings", "set", "newtab.floating", "true"], ["page", "info"], ["logins"], ["watch"]]
    for words in refused:
        result, parsed = envelope(*words)
        check(f"{' '.join(words)} is refused off", result.returncode == 1 and parsed["error"]["code"] == "agents_off", result.stdout + result.stderr)
    listed, parsed = envelope("settings", "list")
    check("settings list works off, without values", listed.returncode == 0 and all(row["value"] == "" for row in parsed["data"]["settings"]), listed.stdout[:200])
    found, parsed = envelope("settings", "find", "tabs")
    check("settings find works off", found.returncode == 0 and parsed["data"]["settings"], found.stdout[:200])
    refused, parsed = envelope("shields", "off", "example.com")
    check("a person_only refusal stands off too", parsed["error"]["code"] == "person_only", parsed)
    write_settings("true")


def ask_mode():
    subprocess.run(["defaults", "write", SUITE, "agents.mode", "-string", "ask"], check=True)
    check_quit("quit for ask mode", "quit")
    tab_rows = envelope("tabs")
    check("it wakes in ask mode", tab_rows[0].returncode in (0, 1), tab_rows[0].stderr)
    no("an unconnected read needs a task in ask mode", "needs_task", "bookmarks", "list")
    no("unconnected spaces too", "needs_task", "spaces", "list")
    good("connect in ask mode", "agents", "connect")
    no("a read needs the person in ask mode", "needs_you", "bookmarks", "list", "--no-person")
    no("spaces too", "needs_you", "spaces", "list", "--no-person")
    no("a change needs the person", "needs_you", "bookmarks", "add", "https://example.com/x", "--no-person")
    result, parsed = envelope("watch")
    check("watch needs a task in ask mode", parsed["error"]["code"] == "needs_task", parsed)
    subprocess.run(["defaults", "delete", SUITE, "agents.mode"], check=True)


def people(base):
    forget_logins()
    write_settings("true")
    subprocess.run(["defaults", "write", SUITE, "spaces", "-bool", "true"], check=True)
    subprocess.run(["defaults", "write", SUITE, "live.on", "-bool", "true"], check=True)
    subprocess.run(["open", "-n", "-g", "-j", "--env", f"SEARCH_PROBE={WORLD}", "--env", "SEARCH_TRANSLATE_FAKE=1", str(APP)], check=True)
    check("the app is up", wait_for(lambda: broadway("status").returncode == 0, 30))
    good("connect the CLI probe", "agents", "connect")
    spaces_and_tabs(base)
    player_field(base)
    your_stuff(base)
    filling(base)
    page_tools(base)
    settings_commands(base)
    ai_commands(base)
    setting_up(base)
    everyday(base)
    probe = subprocess.run([BENCH, "--world", WORLD, "tabs"], capture_output=True, text=True, timeout=30)
    check("no window came on screen in all of that", probe.returncode == 0, probe.stderr)
    check_quit("quit after the commands", "quit")
    ask_mode()
    check_quit("quit after ask mode", "quit")
    person_switched_off(base)
    check_quit("quit after switched off", "quit")


def the_rest(base):
    wake_and_quit()
    latency()
    help_and_mistakes()
    browsing(base)
    looking(base)
    batching(base)
    old_task_words()
    setup()
    check_quit("quit", "quit")
    check("status after quit exits 1", broadway("status").returncode == 1)
    check("quit when not running", broadway("quit").returncode == 0)
    serving()
    switched_off(base)
    check_quit("last quit", "quit")


def main():
    if not os.access(BROADWAY, os.X_OK):
        sys.exit("build first: ./build.sh")
    os.environ["BROADWAY_AGENT"] = WORLD
    os.environ["BROADWAY_AGENT_NAME"] = AGENT_NAME
    os.environ.pop("BROADWAY_TAB", None)
    server = ThreadingHTTPServer(("127.0.0.1", 0), Page)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}/"
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    sv.wipe()
    try:
        write_settings("true")
        if sys.argv[1:] != ["people"]:
            the_rest(base)
        people(base)
    finally:
        subprocess.run([BENCH, "--world", WORLD, "quit"], capture_output=True)
        if not gone():
            for pid in held():
                os.kill(int(pid), signal.SIGKILL)
        forget_logins()
        sv.wipe()
        (Path.home() / f"Library/Preferences/{SUITE}.plist").unlink(missing_ok=True)
    print("FAILED: " + ", ".join(failures) if failures else "all good")
    sys.exit(1 if failures else 0)


main()
