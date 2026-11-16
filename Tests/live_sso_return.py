#!/usr/bin/env python3
"""A live folder waiting on a sign-on fills by itself once the sign-on is done.

Build first (`./build.sh`), then `python3 Tests/live_sso_return.py`. Add
`--timeline` to print every request the fake saw, in seconds from the press.

The app starts hidden in a world of its own (live-sso-return-<checkout>). A
fake GitHub on ::1 knows the person (`user-login` is filled) and answers its
pull request list the way GitHub answers while an organisation's SAML
session has lapsed: the "Single sign-on to see results in the Octo Corp
organization" banner and no rows. The rows come only with a cookie that the
sign-on's last hop sets, so a read sees them only if it is made with the
cookies of the tab that signed on, and only after it has.

The sign-on is the one GitHub sends you through: the banner's link is
`/orgs/octocorp/sso?return_to=`, its page has a Continue button, that goes to
an identity provider on a second host (127.0.0.1), which sends you back to
`/orgs/octocorp/saml/consume`, which sets the cookie and redirects to
`return_to`. Nothing is pressed after that: no Update Now, no reload, no
switch of app.

Four worlds, each from a folder that already says "Single sign-on for
Octo Corp" and was last read longer ago than the gap between sign-in reads
(`signInGap`, 15 s):

- `straight`: the identity provider answers with a redirect at once.
- `slow`: the identity provider shows a page for four seconds first, as one
  asking for a code does.
- `signin`: a folder that says "Sign in" instead: its list redirects to
  `/login` until the form there is sent, which sets the session cookie and
  redirects back.
- `late`: the list keeps its banner for three seconds after the sign-on, so
  the read made on landing back is refused again. The folder must try once
  more by itself when the gap allows, and fill then.

Each must fill within FILLS seconds of the tab landing back on the list
(`late`: of the gap ending), no read may be spent before the sign-on is
done, and the fake must never be read twice by the folder within the gap.

Two worlds hold the rule for tabs the folder did not open:

- `ordinary`: signed in, the organisation's sign-on done in an ordinary
  tab. The address of the sign-on page is typed into it, its Continue goes
  through the identity provider and back to the list. The folder must stop
  asking at once (state `waiting`, the note gone) and fill.
  `ordinary-slow` stays four seconds at the identity provider, which then
  moves on by script, and `ordinary-signin` is the plain sign in form sent
  from an ordinary tab.
- `browsing`: signed out, three PRs kept under "Sign in", the person
  browses the site in an ordinary tab for about two gaps: addresses typed,
  links and script moves on the site, a link from another host, and one
  that comes through a redirect. Every landing is on the site and none of
  them comes through a sign-in, so the folder keeps asking the whole time:
  the note stays, the folded heading keeps its button, and the reads it
  makes are silent ones, never two within the gap. Pictured open and
  folded, dark and light.

A fifth world, `kept`, is the one in the person's crop: a PRs folder that
read three PRs, then got the banner and kept its rows under "Single sign-on
for Octo Corp". The folder's own reads of the list take LOADS seconds there
(the tab's do not), as GitHub's search pages do. Once the tab lands back the
folder must stop asking at once: state `waiting`, the note row gone, the
folded heading's sign-in button gone and its loading bar shown, the kept
rows where they were, one read made, and then the rows read fresh. It runs
in the dark Noir look of a fresh install and in light. With
`--shots=DIR` the probe's own window is pictured (WindowShot.swift) before
the sign-on and while the folder loads, open and folded.
"""
import shutil
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("live-sso-return")
sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
t = sv.T()
TIMELINE = "--timeline" in sys.argv
SHOTS = next((Path(a.split("=", 1)[1]) for a in sys.argv[1:] if a.startswith("--shots=")), None)
TOOLS = Path(__file__).resolve().parents[1] / ".context" / "live-sso-return-tools"
GAP = 15
FILLS = 6
LOADS = 12.0
NOIR = {"colours": ["000000"], "intensity": 1.0, "transparency": 0.12, "grain": 0.45}
LIST = "/work/pulls?q=is%3Aopen+is%3Apr+author%3A%40me"
BACK = "/work/pulls?q=is%3Aopen+is%3Apr+author%3A%40me&back=1"
SEEN = []
WORLD = {"dwell": 0.0, "signed": True, "late": 0.0, "tab": False, "at": 0.0, "open": False, "loads": 0.0}


def note(what, path):
    SEEN.append((time.time(), what, path))


def row(number, title, author):
    return (f'<li class="js-issue-row"><a href="/octocorp/ios/pull/{number}">{title}</a>'
            f'<span>#{number} opened today by <a data-testid="author-filter-link" href="/{author}">{author}</a></span></li>')


ROWS = "<ul>" + row(36, "Field Recording - Add the model", "octo-sam") + row(37, "Field Recording - Add the recorder", "octo-sam") \
    + row(41, "Cache the build graph", "dana") + "</ul>"
HEAD = '<!doctype html><meta name="user-login" content="octo-sam"><title>Pull requests</title>'
BANNER = ('<div class="js-flash-container"><div class="flash flash-full flash-notice"><div class="px-2">'
          '<div class="flex-auto">Single sign-on to see results in the <strong>Octo Corp</strong> organization</div>'
          f'<a href="/orgs/octocorp/sso?return_to={quote(BACK, safe="")}" class="btn btn-sm">Single sign-on</a></div></div></div>'
          '<main><h3>No results matched your search.</h3></main>')
LOGIN = ('<!doctype html><meta name="user-login" content=""><title>Sign in</title>'
         '<form action="/session" method="post"><input name="login" value="octo-sam"><input type="password" name="password" value="x">'
         '<input type="hidden" name="return_to" value="{back}"><button id="go">Sign in</button></form>')


class Hub(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, status, body="", headers=()):
        data = body.encode()
        self.send_response(status)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("cache-control", "no-store")
        self.send_header("content-length", str(len(data)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def has(self, name):
        return f"{name}=1" in (self.headers.get("cookie") or "")

    def do_GET(self):
        url = urlsplit(self.path)
        asked = parse_qs(url.query)
        if url.path == "/work/pulls":
            tab = "back" in asked
            if not WORLD["signed"] and not self.has("user_session"):
                tab, WORLD["tab"] = WORLD["tab"], False
                if not tab and WORLD["loads"] > 0:
                    note("read asked", self.path)
                    time.sleep(WORLD["loads"])
                note("the row's tab asks" if tab else "read: sign in", self.path)
                return self.send(302, headers=[("location", "/login?return_to=" + quote(BACK, safe=""))])
            filled = WORLD["open"] or not WORLD["signed"] or (self.has("saml") and time.time() - WORLD["at"] >= WORLD["late"])
            if not tab and WORLD["loads"] > 0:
                note("read asked", self.path)
                time.sleep(WORLD["loads"])
            note(("landed back" if tab else "read") + (": rows" if filled else ": banner"), self.path)
            return self.send(200, HEAD + (ROWS if filled else BANNER))
        if url.path == "/login":
            note("sign in page", self.path)
            return self.send(200, LOGIN.format(back=asked.get("return_to", [BACK])[0]))
        if url.path == "/orgs/octocorp/sso":
            note("sign-on page", self.path)
            onward = "/orgs/octocorp/saml/initiate?return_to=" + quote(asked.get("return_to", [BACK])[0], safe="")
            return self.send(200, f'{HEAD}<h1>Single sign-on to Octo Corp</h1><a id="go" href="{onward}">Continue</a>')
        if url.path == "/orgs/octocorp/saml/initiate":
            note("to the identity provider", self.path)
            back = f"{HUB}/orgs/octocorp/saml/consume?return_to=" + quote(asked.get("return_to", [BACK])[0], safe="")
            return self.send(302, headers=[("location", f"{IDP}/app/sso?back=" + quote(back, safe=""))])
        if url.path == "/orgs/octocorp/saml/consume":
            note("signed on", self.path)
            WORLD["at"] = time.time()
            return self.send(302, headers=[("location", asked.get("return_to", [BACK])[0]), ("set-cookie", "saml=1; Path=/")])
        if url.path == "/home" or url.path.startswith("/browse/"):
            note("browsed", self.path)
            return self.send(200, "<!doctype html><title>Home</title><h2>A page</h2>")
        if url.path == "/hop":
            return self.send(302, headers=[("location", "/browse/" + asked.get("to", ["0"])[0])])
        self.send(404, "Not Found")

    def do_POST(self):
        body = parse_qs(self.rfile.read(int(self.headers.get("content-length", "0"))).decode())
        if urlsplit(self.path).path == "/session":
            note("signed in", self.path)
            return self.send(302, headers=[("location", body.get("return_to", [BACK])[0]), ("set-cookie", "user_session=1; Path=/")])
        self.send(404, "Not Found")


class Provider(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        url = urlsplit(self.path)
        back = parse_qs(url.query).get("back", [""])[0]
        note("identity provider", url.path)
        if url.path != "/app/sso" or not back:
            body, status, headers = b"<!doctype html><title>Other</title>", 200, []
        elif WORLD["dwell"] > 0:
            wait = int(WORLD["dwell"] * 1000)
            page = f'<!doctype html><title>Verify</title><p>Enter the code</p><script>setTimeout(() => location.href = {back!r}, {wait})</script>'
            body, status, headers = page.encode(), 200, []
        else:
            body, status, headers = b"", 302, [("location", back)]
        self.send_response(status)
        self.send_header("content-type", "text/html; charset=utf-8")
        self.send_header("cache-control", "no-store")
        self.send_header("content-length", str(len(body)))
        for name, value in headers:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)


class Loopback6(ThreadingHTTPServer):
    import socket as _socket
    address_family = _socket.AF_INET6


hub = Loopback6(("::1", 0), Hub)
threading.Thread(target=hub.serve_forever, daemon=True).start()
HUB = f"http://[::1]:{hub.server_port}"
idp = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
threading.Thread(target=idp.serve_forever, daemon=True).start()
IDP = f"http://127.0.0.1:{idp.server_port}"


def live(*args):
    return sv.cmd({"do": "live", "args": list(args)})


def folder():
    return next(f for f in live()["folders"] if f["name"] == "PRs")


def tab_at(piece, within=10):
    until = time.time() + within
    while time.time() < until:
        found = next((x for x in sv.cmd({"do": "tabs"})["tabs"] if piece in x["url"] and not x["loading"]), None)
        if found:
            return found
        time.sleep(0.1)
    return None


def first(what, since):
    return next((at for at, said, _ in SEEN if at >= since and said.startswith(what)), None)


def reads(since=0):
    return [at for at, said, _ in SEEN if at >= since and said.startswith("read") and not said.startswith("read asked")]


def asked(since=0):
    return [at for at, said, _ in SEEN if at >= since and said.startswith("read asked")]


def window_shot(name):
    if not SHOTS:
        return
    shot = TOOLS / "shot"
    if not shot.exists():
        TOOLS.mkdir(parents=True, exist_ok=True)
        subprocess.run(["swiftc", "-parse-as-library", str(Path(__file__).resolve().parent / "WindowShot.swift"), "-o", str(shot)], check=True)
    number = sv.cmd({"do": "idle", "action": "unhide"})["number"]
    pid = next(iter(sv.holding() & sv.running()))
    out = SHOTS / f"{name}.png"
    said = subprocess.run([str(shot), str(pid), str(number), str(out)], capture_output=True, text=True).stdout.strip()
    t.ok(f"pictured {name}", out.exists(), said)


def timeline(pressed):
    if not TIMELINE:
        return
    for at, said, path in SEEN:
        if at >= pressed - 0.05:
            print(f"      {at - pressed:6.2f}s  {said:28} {path[:70]}")


def world(name, said, dwell=0.0, signed=True, late=0.0, ordinary=False):
    print(f"— {said}")
    sv.use(f"live-sso-return-{name}")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    sv.launch()
    WORLD.update(dwell=dwell, signed=signed, late=late, tab=False, at=0.0, open=False, loads=0.0)
    del SEEN[:]
    try:
        home = sv.cmd({"do": "open", "url": f"{IDP}/home"})
        sv.cmd({"do": "adopt", "id": home["id"]})
        live("add-page", "PRs", "pullRequests", HUB + LIST)
        live("unfold", "PRs")
        before = folder_after_update()
        wanted = ("signIn", "sso(") if signed else ("signIn", "signIn")
        t.ok("the folder says " + ("single sign-on" if signed else "sign in") + " and has no rows",
             before["state"] == wanted[0] and before["note"].startswith(wanted[1]) and not before["items"],
             (before["state"], before["note"], len(before["items"])))
        if signed:
            t.ok("its link is the banner's own", before["sso"] == f"{HUB}/orgs/octocorp/sso?return_to={quote(BACK, safe='')}", before["sso"])
        time.sleep(GAP + 1)

        pressed = time.time()
        WORLD["tab"] = not signed and not ordinary
        if ordinary:
            step = "/orgs/octocorp/sso" if signed else "/login"
            sv.cmd({"do": "go", "id": home["id"], "url": f"{HUB}{step}?return_to={quote(BACK, safe='')}"})
            page = tab_at(step)
            t.ok("the " + ("sign-on" if signed else "sign in") + " page is typed into the ordinary tab", page is not None and page["id"] == home["id"] and not page["bench"], page)
        else:
            live("sign-in", "PRs")
            page = tab_at("/orgs/octocorp/sso" if signed else "/login")
            t.ok("the row opens the " + ("sign-on" if signed else "sign in") + " page in an ordinary tab",
                 page is not None and not page["bench"], page)
        if page is None:
            return
        time.sleep(1.2)
        if ordinary:
            WORLD["loads"] = 3.0
        sv.cmd({"do": "eval", "id": page["id"], "js": "document.getElementById('go').click(); 1"})
        if ordinary:
            landed = None
            until = time.time() + 20
            while time.time() < until and landed is None:
                landed = first("landed back", pressed)
                time.sleep(0.05)
            loading = None
            until = time.time() + 3
            while landed and time.time() < until:
                now = folder()
                if now["state"] == "waiting" and now["note"] in ("", "loading") and now["sso"] == "":
                    loading = time.time()
                    break
                time.sleep(0.05)
            t.ok(f"back from the " + ("identity provider" if signed else "form") + f", the folder stops asking at once ({(loading or time.time()) - (landed or 0):.2f} s)",
                 landed is not None and loading is not None and loading - landed < 1.0, (folder()["state"], folder()["note"]))

        filled = None
        until = time.time() + 45
        while time.time() < until:
            now = folder()
            if now["state"] == "fine" and now["items"]:
                filled = time.time()
                break
            time.sleep(0.15)
        landed = first("landed back", pressed)
        timeline(pressed)
        t.ok("the tab comes back to the list through the " + ("identity provider" if signed else "form"),
             landed is not None and first("identity provider" if signed else "signed in", pressed) is not None, [s for _, s, _ in SEEN])
        t.ok("the folder fills by itself", filled is not None, folder()["note"])
        if filled is None or landed is None:
            return
        after = folder()
        took = filled - landed
        if late:
            asked = reads(landed)
            t.ok("the read on landing back is refused, and one more is made by itself", len(asked) == 2, [round(at - landed, 1) for at in asked])
            t.ok(f"within {FILLS} s of the gap ending ({took:.1f} s after landing back)", took < GAP + FILLS, round(took, 1))
        else:
            t.ok(f"within {FILLS} s of landing back ({took:.1f} s)", took < FILLS, round(took, 1))
        t.ok("the note is gone and the three PRs are tabs in the folder",
             after["note"] == "" and after["sso"] == "" and len(after["items"]) == 3 and len(after["tabs"]) == 3,
             (after["note"], after["sso"], len(after["items"]), len(after["tabs"])))
        time.sleep(1.0)
        made = reads()
        gaps = [round(b - a, 1) for a, b in zip(made, made[1:])]
        t.ok(f"never two reads within the gap (reads {gaps} s apart)", all(g >= GAP - 0.5 for g in gaps), gaps)
        t.ok("no read was spent before the sign-on was done", not [at for at in reads(pressed) if at < landed],
             [round(at - pressed, 1) for at in reads(pressed)])
    finally:
        sv.finish()


def kept(look):
    print(f"— the crop: three PRs kept under single sign-on, signed on, {look}")
    sv.use(f"live-sso-return-kept-{look}")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    sv.launch()
    WORLD.update(dwell=0.0, signed=True, late=0.0, tab=False, at=0.0, open=True, loads=0.0)
    del SEEN[:]
    try:
        if look == "dark":
            sv.cmd({"do": "space", "action": "look", **NOIR})
        sv.cmd({"do": "ui", "look": look})
        home = sv.cmd({"do": "open", "url": f"{IDP}/home"})
        sv.cmd({"do": "adopt", "id": home["id"]})
        live("add-page", "PRs", "pullRequests", HUB + LIST)
        live("unfold", "PRs")
        read = folder_after_update()
        t.ok("the folder reads three PRs", read["state"] == "fine" and len(read["items"]) == 3, (read["state"], len(read["items"])))
        WORLD["open"] = False
        asks = folder_after_update()
        t.ok("then the banner: single sign-on, the three PRs kept below the note",
             asks["state"] == "signIn" and asks["note"].startswith("sso(") and len(asks["items"]) == 3,
             (asks["state"], asks["note"], len(asks["items"])))
        sv.cmd({"do": "window"})
        time.sleep(1.2)
        window_shot(f"kept-asks-open-{look}")
        time.sleep(max(0.0, GAP + 1 - 1.2))

        WORLD["loads"] = LOADS
        pressed = time.time()
        live("sign-in", "PRs")
        page = tab_at("/orgs/octocorp/sso")
        t.ok("the note's link opens the sign-on page", page is not None, page)
        if page is None:
            return
        time.sleep(1.2)
        sv.cmd({"do": "eval", "id": page["id"], "js": "document.getElementById('go').click(); 1"})

        landed = None
        until = time.time() + 20
        while time.time() < until and landed is None:
            landed = first("landed back", pressed)
            time.sleep(0.05)
        t.ok("the tab lands back on the list", landed is not None, [s for _, s, _ in SEEN])
        if landed is None:
            return
        loading = None
        until = time.time() + 3
        while time.time() < until:
            now = folder()
            if now["state"] == "waiting" and now["note"] == "" and now["status"] == "":
                loading = time.time()
                break
            time.sleep(0.05)
        now = folder()
        t.ok(f"the folder stops asking at once ({(loading or time.time()) - landed:.2f} s after landing back)",
             loading is not None and loading - landed < 1.0, (now["state"], now["note"], now["status"]))
        t.ok("the kept PRs stay where they were", [i["title"] for i in now["items"]] == [i["title"] for i in asks["items"]],
             [i["title"] for i in now["items"]])
        started = asked(pressed)
        t.ok("a read starts at once", bool(started) and started[0] - landed < 1.0, [round(a - landed, 2) for a in started])
        time.sleep(0.4)
        window_shot(f"kept-loading-open-{look}")
        h = live("heading", "PRs")
        t.ok("open, the heading shows the loading bar and no sign-in button", h.get("loading") is True and not h.get("pill"), h)
        live("fold", "PRs")
        time.sleep(0.5)
        h = live("heading", "PRs")
        t.ok("folded, the heading shows the loading bar in place of the button", h.get("loading") is True and not h.get("pill"), h)
        window_shot(f"kept-loading-folded-{look}")
        live("unfold", "PRs")

        filled = None
        until = time.time() + LOADS + 30
        while time.time() < until:
            now = folder()
            if now["state"] == "fine":
                filled = time.time()
                break
            time.sleep(0.15)
        timeline(pressed)
        t.ok(f"the read answers and the rows are fine ({(filled or time.time()) - landed:.1f} s after landing back)",
             filled is not None and filled - landed < LOADS + FILLS, folder()["state"])
        made = asked(landed - 0.5)
        t.ok("one sign-on made one read", len(made) == 1, [round(a - landed, 2) for a in made])
        time.sleep(0.6)
        h = live("heading", "PRs")
        t.ok("filled, the heading has no loading bar", not h.get("loading"), h)
        window_shot(f"kept-filled-open-{look}")
    finally:
        WORLD.update(loads=0.0, open=False)
        sv.finish()


def browse(tab, how, url):
    if how == "go":
        sv.cmd({"do": "go", "id": tab, "url": url})
    elif how == "link":
        js = f"(() => {{ const a = document.createElement('a'); a.href = {url!r}; document.body.append(a); a.click(); return 1 }})()"
        sv.cmd({"do": "eval", "id": tab, "js": js})
    else:
        sv.cmd({"do": "eval", "id": tab, "js": f"location.href = {url!r}; 1"})


def browsing(look):
    print(f"— signed out, browsing the site in an ordinary tab, {look}")
    sv.use(f"live-sso-return-browsing-{look}")
    sv.guarded = lambda: {sv.FIRST_SPACE, sv.PERSONAL.lower()}
    sv.setup(**{"live.on": True, "sidebar": True, "layout.cards": True, "start.fresh": False})
    sv.launch()
    WORLD.update(dwell=0.0, signed=True, late=0.0, tab=False, at=0.0, open=True, loads=0.0)
    del SEEN[:]
    try:
        if look == "dark":
            sv.cmd({"do": "space", "action": "look", **NOIR})
        sv.cmd({"do": "ui", "look": look})
        home = sv.cmd({"do": "open", "url": f"{IDP}/home"})
        sv.cmd({"do": "adopt", "id": home["id"]})
        live("add-page", "PRs", "pullRequests", HUB + LIST)
        live("unfold", "PRs")
        read = folder_after_update()
        t.ok("the folder reads three PRs", read["state"] == "fine" and len(read["items"]) == 3, (read["state"], len(read["items"])))
        WORLD.update(signed=False, open=False)
        asks = folder_after_update()
        t.ok("signed out: Sign in, the three PRs kept below the note",
             asks["state"] == "signIn" and asks["note"] == "signIn" and len(asks["items"]) == 3,
             (asks["state"], asks["note"], len(asks["items"])))
        sv.cmd({"do": "window"})
        time.sleep(GAP + 1)

        WORLD["loads"] = 3.0
        steps = [("go", f"{HUB}/browse/0"), ("link", f"{HUB}/browse/1"), ("script", f"{HUB}/browse/2"),
                 ("go", f"{IDP}/home?n=3"), ("link", f"{HUB}/browse/3"), ("go", f"{HUB}/browse/4"),
                 ("go", f"{IDP}/home?n=5"), ("link", f"{HUB}/hop?to=5"), ("script", f"{HUB}/browse/6"),
                 ("link", f"{HUB}/browse/7"), ("go", f"{HUB}/browse/8"), ("script", f"{HUB}/browse/9"),
                 ("go", f"{IDP}/home?n=10"), ("link", f"{HUB}/browse/10"), ("go", f"{HUB}/browse/11")]
        began = time.time()
        landings, odd, pills = 0, [], []
        for number, (how, url) in enumerate(steps):
            if number == 7:
                live("fold", "PRs")
            browse(home["id"], how, url)
            piece = url.split("//", 1)[1].split("/", 1)[1] if "/hop" not in url else "browse/5"
            if tab_at(piece) is None:
                t.ok(f"the tab lands on {url}", False, url)
                return
            landings += url.startswith(HUB)
            until = time.time() + 2.2
            while time.time() < until:
                now = folder()
                if now["state"] != "signIn" or now["note"] != "signIn" or len(now["items"]) != 3:
                    odd.append((round(time.time() - began, 2), now["state"], now["note"], len(now["items"])))
                time.sleep(0.08)
            if number >= 7:
                pills.append(bool(live("heading", "PRs").get("pill")))
            if number == 2:
                window_shot(f"browsing-open-{look}")
            if number == 8:
                window_shot(f"browsing-folded-{look}")
        took = time.time() - began
        made = reads(began)
        gaps = [round(b - a, 1) for a, b in zip(made, made[1:])]
        timeline(began)
        t.ok(f"{landings} landings on the site in {took:.0f} s, the folder kept asking the whole time", not odd, odd[:6])
        t.ok("folded, the heading kept its Sign in button after every landing", pills and all(pills), pills)
        t.ok(f"silent reads were made, never two within the gap ({len(made)} reads, {gaps} s apart)",
             1 <= len(made) <= int(took // GAP) + 1 and all(g >= GAP - 0.5 for g in gaps), [round(at - began, 1) for at in made])
        live("unfold", "PRs")
    finally:
        WORLD.update(loads=0.0, open=False, signed=True)
        sv.finish()


def folder_after_update():
    return next(f for f in live("update", "PRs")["folders"] if f["name"] == "PRs")


def main():
    picked = [a for a in sys.argv[1:] if not a.startswith("--")]
    worlds = [("straight", "single sign-on, straight through the identity provider", 0.0, True, 0.0),
              ("slow", "single sign-on, four seconds at the identity provider", 4.0, True, 0.0),
              ("signin", "a plain sign in", 0.0, False, 0.0),
              ("late", "single sign-on that the list takes three seconds to show", 0.0, True, 3.0),
              ("ordinary", "single sign-on done in an ordinary tab, not the row's", 0.0, True, 0.0),
              ("ordinary-slow", "the same, four seconds at the identity provider", 4.0, True, 0.0),
              ("ordinary-signin", "a plain sign in done in an ordinary tab", 0.0, False, 0.0)]
    if SHOTS:
        SHOTS.mkdir(parents=True, exist_ok=True)
    for name, said, dwell, signed, late in worlds:
        if picked and name not in picked:
            continue
        world(name, said, dwell, signed, late, ordinary=name.startswith("ordinary"))
    if not picked or "browsing" in picked:
        for look in ("dark", "light"):
            browsing(look)
    if not picked or "kept" in picked:
        for look in ("dark", "light"):
            kept(look)
    shutil.rmtree(TOOLS, ignore_errors=True)
    t.done()
    sys.exit(1 if t.failed else 0)


if __name__ == "__main__":
    main()
