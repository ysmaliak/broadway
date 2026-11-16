#!/usr/bin/env python3
import json
import sys
import time
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("bld-signin")
PORT = sv.srv.server_port
SITE = f"http://localhost:{PORT}"
IDP = f"http://127.0.0.1:{PORT}"

HEAD = """
<style>body { font: 18px system-ui; margin: 60px; } button, .b { font-size: 18px; padding: 8px 14px; }</style>
<script>
  const AUTH = 'IDP/idp/auth';
  const SIZE = 'width=500,height=600';
  const OAUTH = '&client_id=site&response_type=code&redirect_uri=' + encodeURIComponent('SITE/cb');
  const mark = (key, value) => { document.documentElement.dataset[key] = value; };
  addEventListener('message', e => {
    if (e.data && e.data.token) mark('token', e.data.token);
    if (e.data && e.data.open) mark('win', window.open(e.data.open, 'signin', e.data.sized ? SIZE : '') ? 'yes' : 'no');
  });
  const signin = (name, features, extra) => {
    const w = window.open(AUTH + '?n=' + name + (extra || ''), 'signin', features === undefined ? SIZE : features);
    mark('win', w ? 'yes' : 'no');
    return w;
  };
</script>
"""

AUTH_PAGE = """
<title>Provider sign-in</title>
<style>body { font: 18px system-ui; margin: 40px; }</style>
<h1>Sign in to Provider</h1>
<button id="finish">Continue</button>
<button id="more">Use another window</button>
<script>
  const q = new URLSearchParams(location.search);
  function finish() {
    if (q.get('back')) { location.href = q.get('back'); return; }
    if (window.opener) window.opener.postMessage({ token: 'tok-' + q.get('n') }, '*');
    window.close();
  }
  document.getElementById('finish').onclick = finish;
  document.getElementById('more').onclick = () => {
    const w = window.open('IDP/idp/auth?n=second&relay=1', 'second', 'width=400,height=500');
    document.documentElement.dataset.win = w ? 'yes' : 'no';
  };
  addEventListener('message', e => { if (e.data && e.data.token) finish(); });
  if (q.get('auto')) setTimeout(finish, Number(q.get('auto')));
</script>
"""

FRAME_BUTTON = """
<style>
  html, body { margin: 0; height: 100%; font: 14px system-ui; }
  #b { box-sizing: border-box; width: 100%; height: 100%; }
  #layered { position: relative; box-sizing: border-box; height: 100%; border: 1px solid #dadce0; border-radius: 4px;
             cursor: pointer; display: flex; align-items: center; justify-content: center; background: #fff; }
  #layered .state { position: absolute; inset: 0; z-index: 1; }
</style>
<div id="slot"></div>
<script>
  const q = new URLSearchParams(location.search);
  const slot = document.getElementById('slot');
  slot.style.height = '100%';
  slot.innerHTML = q.get('look') === 'layered'
    ? '<div id="layered" role="button" tabindex="0"><div class="state"></div>' +
      '<svg width="18" height="18"><circle cx="9" cy="9" r="8" fill="#4285f4"/></svg>' +
      '<span style="margin-left:8px">Sign in with Provider</span></div>'
    : '<button id="b">Sign in with Provider</button>';
  slot.firstChild.addEventListener('click', () => {
    const url = 'IDP/idp/auth?n=' + q.get('n') + (q.get('auto') ? '&auto=' + q.get('auto') : '');
    const sized = q.get('size') !== '0';
    if (q.get('how') === 'parent') parent.postMessage({ open: url, sized }, '*');
    else window.open(url, 'signin', sized ? 'width=500,height=600' : '');
  });
</script>
"""

CARD = """
<style>
  html, body { margin: 0; height: 100%; font: 14px system-ui; }
  body { display: flex; flex-direction: column; align-items: center; justify-content: center; border: 1px solid #ccc;
         box-sizing: border-box; background: #fff; }
  #go { margin-top: 12px; padding: 8px 60px; background: #1a73e8; color: #fff; border-radius: 4px; cursor: pointer; }
</style>
<div>Sign in to localhost with Provider</div>
<div id="go" role="button" tabindex="0">Continue</div>
<script>
  document.getElementById('go').addEventListener('click', () =>
    window.open('IDP/idp/auth?n=onetap', 'signin', 'width=500,height=600'));
</script>
"""

ATTACK = """
<style>body { margin: 0; } #player { position: relative; width: 640px; height: 360px; margin: 40px; background: #111; }
  #play { position: absolute; left: 270px; top: 130px; width: 100px; height: 100px; border-radius: 50%; background: #e33; cursor: pointer; }</style>
<div id="player"><div id="play" class="play-button"></div></div>
"""

PAGES = {
    "/plain": HEAD + "<p>nothing here</p>",
    "/sized": HEAD + """<button id="b" onclick="signin('sized')">Sign in with Provider</button>""",
    "/nosize": HEAD + """<button id="b" onclick="signin('nosize', '')">Sign in with Provider</button>""",
    "/link": HEAD + """<a id="b" href="IDP/idp/auth?n=link" target="_blank">Sign in with Provider</a>""",
    "/framed": HEAD + """<iframe id="f" src="IDP/idp/button?n=framed" width="240" height="44" style="border:0"></iframe>""",
    "/framed-tab": HEAD + """<iframe id="f" src="IDP/idp/button?n=framedtab&size=0" width="240" height="44" style="border:0"></iframe>""",
    "/framed-parent": HEAD + """<iframe id="f" src="IDP/idp/button?n=framedparent&how=parent" width="240" height="44" style="border:0"></iframe>""",
    "/framed-layered": HEAD + """<iframe id="f" src="IDP/idp/button?n=framedlayered&look=layered" width="240" height="44" style="border:0"></iframe>""",
    "/custom": HEAD + """
      <div style="position:relative;display:inline-block">
        <button id="b" style="width:240px;height:44px">Continue with Provider</button>
        <iframe src="IDP/idp/button?n=custom" style="position:absolute;inset:0;width:240px;height:44px;border:0;opacity:0"></iframe>
      </div>""",
    "/onetap": HEAD + """<p>An article.</p>
      <iframe id="f" src="IDP/idp/card" style="position:fixed;top:10px;right:10px;width:380px;height:160px;border:0;z-index:99"></iframe>""",
    "/nested": HEAD + """<iframe id="f" src="IDP/idp/holder" width="260" height="64" style="border:0"></iframe>""",
    "/delay": HEAD + """<button id="b">Sign in with Provider</button><script>
      document.getElementById('b').onclick = async () => { await fetch('/wait?ms=1500'); signin('delay'); };</script>""",
    "/delay-long": HEAD + """<button id="b">Sign in with Provider</button><script>
      document.getElementById('b').onclick = async () => { await fetch('/wait?ms=6500'); signin('delaylong'); };</script>""",
    "/delay-fallback": HEAD + """<button id="b">Sign in with Provider</button><script>
      document.getElementById('b').onclick = async () => {
        await fetch('/wait?ms=6500');
        if (!signin('delayfallback')) location.href = AUTH + '?n=delayfallback&back=' + encodeURIComponent('SITE/cb');
      };</script>""",
    "/blank-first": HEAD + """<button id="b">Sign in with Provider</button><script>
      document.getElementById('b').onclick = () => {
        const w = window.open('about:blank', 'signin', SIZE);
        mark('win', w ? 'yes' : 'no');
        fetch('/wait?ms=400').then(() => { if (w) w.location.href = AUTH + '?n=blank'; });
      };</script>""",
    "/blank-tab": HEAD + """<button id="b">Sign in with Provider</button><script>
      document.getElementById('b').onclick = () => {
        const w = window.open('', '_blank');
        mark('win', w ? 'yes' : 'no');
        if (w) { w.document.write('Loading…'); fetch('/wait?ms=400').then(() => { w.location.href = AUTH + '?n=blanktab'; }); }
      };</script>""",
    "/own-first": HEAD + """<button id="b" onclick="mark('win', window.open('/go?n=ownfirst', 'signin', SIZE) ? 'yes' : 'no')">Sign in</button>""",
    "/own-first-tab": HEAD + """<button id="b" onclick="mark('win', window.open('/go?n=ownfirsttab') ? 'yes' : 'no')">Sign in</button>""",
    "/div": HEAD + """<div id="b" class="b" style="display:inline-block;border:1px solid #888">Sign in with Provider</div>
      <script>document.getElementById('b').addEventListener('click', () => signin('div'));</script>""",
    "/layered": HEAD + """
      <div id="b" role="button" tabindex="0" class="b" style="position:relative;display:inline-flex;align-items:center;border:1px solid #888;cursor:pointer">
        <span id="layer" style="position:absolute;inset:0;z-index:1"></span>
        <svg width="18" height="18"><circle cx="9" cy="9" r="8" fill="#4285f4"/></svg><span style="margin-left:8px">Sign in with Provider</span>
      </div>
      <script>document.getElementById('b').addEventListener('click', () => signin('layered'));</script>""",
    "/shadow-open": HEAD + """<signin-button id="b"></signin-button><script>
      customElements.define('signin-button', class extends HTMLElement {
        constructor() {
          super();
          const root = this.attachShadow({ mode: 'open' });
          root.innerHTML = '<button style="font-size:18px;padding:8px 14px">Sign in with Provider</button>';
          root.firstChild.addEventListener('click', () => signin('shadowopen'));
        }
      });</script>""",
    "/shadow-closed": HEAD + """<signin-button id="b"></signin-button><script>
      customElements.define('signin-button', class extends HTMLElement {
        constructor() {
          super();
          const root = this.attachShadow({ mode: 'closed' });
          root.innerHTML = '<button style="font-size:18px;padding:8px 14px">Sign in with Provider</button>';
          root.firstChild.addEventListener('click', () => signin('shadowclosed'));
        }
      });</script>""",
    "/shadow-layered": HEAD + """<signin-button id="b"></signin-button><script>
      customElements.define('signin-button', class extends HTMLElement {
        constructor() {
          super();
          const root = this.attachShadow({ mode: 'open' });
          root.innerHTML = '<div role="button" tabindex="0" style="position:relative;display:inline-flex;padding:8px 14px;border:1px solid #888;cursor:pointer">' +
            '<span style="position:absolute;inset:0;z-index:1"></span><span>Sign in with Provider</span></div>';
          root.firstChild.addEventListener('click', () => signin('shadowlayered'));
        }
      });</script>""",
    "/plain-tag": HEAD + """<app-text id="b" style="display:inline-block">A line of the article in a tag of the site's own.</app-text><script>
      document.addEventListener('mousedown', () => signin('plaintag', SIZE, OAUTH));</script>""",
    "/own-link": HEAD + """<a id="b" href="/auth/provider">Sign in with Provider</a><script>
      document.getElementById('b').addEventListener('click', e => { e.preventDefault(); signin('ownlink', '', OAUTH); });</script>""",
    "/ghost": HEAD + """
      <auth-buttons id="b" style="display:inline-block">
        <div id="real" role="button" tabindex="0" style="position:relative;height:44px;cursor:pointer">
          <svg width="300" height="44"><rect width="300" height="44" fill="#000"/></svg><div style="position:absolute;inset:0"></div>
        </div>
      </auth-buttons>
      <script>
        customElements.define('auth-buttons', class extends HTMLElement {
          constructor() {
            super();
            this.attachShadow({ mode: 'open' }).innerHTML =
              '<div style="position:relative;width:300px;height:44px;background:#fff;border:1px solid #888;border-radius:22px;cursor:pointer;' +
              'display:flex;align-items:center;justify-content:center"><span>Continue with Provider</span>' +
              '<div style="position:absolute;inset:0;opacity:0"><slot></slot></div></div>';
          }
        });
        document.getElementById('real').addEventListener('click', () => signin('ghost'));
      </script>""",
    "/ghost-inside": HEAD + """
      <button id="b" style="position:relative;width:320px;height:48px;font-size:16px;cursor:pointer">
        <svg width="18" height="18"><circle cx="9" cy="9" r="8" fill="#4285f4"/></svg> <span>Sign in with Provider</span>
        <div style="position:absolute;inset:0;opacity:0">
          <div id="real" role="button" tabindex="0" style="height:48px;background:#fff">Sign in with Provider</div>
          <iframe src="about:blank" width="0" height="0" style="border:0"></iframe>
        </div>
      </button>
      <script>document.getElementById('real').addEventListener('click', e => { e.stopPropagation(); signin('ghostinside'); });</script>""",
    "/ghost-shell": HEAD + """
      <div id="b" style="position:relative;width:320px;height:44px">
        <div style="position:absolute;inset:0;display:flex;align-items:center;justify-content:center;background:#fff;
                    border:1px solid #888;border-radius:22px;pointer-events:none">Continue with Provider</div>
        <div style="position:absolute;inset:0;opacity:0">
          <div id="real" role="button" tabindex="0" style="height:44px;background:#fff">Sign in with Provider</div>
        </div>
      </div>
      <script>document.getElementById('real').addEventListener('click', () => signin('ghostshell'));</script>""",
    "/div-fallback": HEAD + """<div id="b" class="b" style="display:inline-block;border:1px solid #888">Sign in with Provider</div><script>
      document.getElementById('b').addEventListener('click', () => {
        if (!signin('divfallback', '')) location.href = AUTH + '?n=divfallback' + OAUTH;
      });</script>""",
    "/form": HEAD + """<form id="f" method="post" action="IDP/idp/auth?n=form" target="_blank">
        <input type="hidden" name="SAMLRequest" value="abc"><button id="b" type="button">Sign in with SSO</button></form><script>
      document.getElementById('b').onclick = async () => { await fetch('/wait?ms=300'); document.getElementById('f').submit(); };</script>""",
    "/handback": HEAD + """<button id="b" onclick="signin('handback', '', '&auto=100')">Sign in</button><script>
      addEventListener('message', e => { if (e.data && e.data.token) location.href = 'IDP/app'; });</script>""",
    "/handback-sized": HEAD + """<button id="b" onclick="signin('handbacksized', SIZE, '&auto=100')">Sign in</button><script>
      addEventListener('message', e => { if (e.data && e.data.token) location.href = 'IDP/app'; });</script>""",
    "/redirect-back": HEAD + """<button id="b" onclick="signin('redirectback', SIZE, '&auto=100&back=' + encodeURIComponent('SITE/cb'))">Sign in</button>""",
    "/strikes": ATTACK + HEAD + """
      <p id="text" style="font-size:22px;margin:0 40px">An article you are reading, with nothing to click.</p>
      <p><button id="sized" onclick="signin('warysized')">Sign in with Provider</button>
         <button id="tab" onclick="signin('warytab', '', OAUTH)">Sign in with Provider in a tab</button>
         <a id="link" href="IDP/idp/auth?n=warylink&client_id=site&response_type=code" target="_blank">Sign in with Provider</a>
         <button id="other" onclick="signin('waryother', '')">Open another site</button>
         <button id="ad" onclick="window.open('IDP/ad-wary')">Download</button></p>
      <script>
        const cover = document.createElement('div');
        cover.id = 'cover';
        cover.style.cssText = 'position:absolute;left:40px;top:40px;width:640px;height:360px;z-index:99;opacity:0.01;background:white;cursor:pointer';
        cover.addEventListener('click', () => window.open('IDP/ad-overlay'));
        document.body.appendChild(cover);
        document.addEventListener('mousedown', e => { if (e.target.id === 'text') window.open('IDP/ad-text'); });
      </script>""",
    "/attack-signin": ATTACK + HEAD + """<script>
        const cover = document.createElement('div');
        cover.id = 'cover';
        cover.style.cssText = 'position:fixed;inset:0;z-index:99;opacity:0.01;background:white;cursor:pointer';
        cover.addEventListener('click', () => signin('attackunseen', SIZE, OAUTH));
        document.body.appendChild(cover);
      </script>""",
    "/attack-ghost": HEAD + """<p id="text" style="font-size:22px">An article you are reading, with nothing to click.</p>
      <div style="width:10px;height:10px;cursor:pointer"><div id="cover" style="position:fixed;inset:0;opacity:0"></div></div><script>
      document.getElementById('cover').addEventListener('click', () => signin('attackghost', SIZE, OAUTH));</script>""",
    "/attack-ghost-box": HEAD + """<p id="text" style="font-size:22px">An article you are reading, with nothing to click.</p>
      <div style="width:120px;height:30px;background:#eee">Read more<div id="cover" role="button" style="position:fixed;inset:0;opacity:0"></div></div>
      <script>document.getElementById('cover').addEventListener('click', () => signin('attackghostbox', SIZE, OAUTH));</script>""",
    "/attack-noclick": HEAD + """<p id="text">An article.</p><script>setTimeout(() => signin('attacknoclick', SIZE, OAUTH), 300);</script>""",
    "/attack-late": HEAD + """<p id="text" style="font-size:22px">An article you are reading, with nothing to click.</p><script>
      document.addEventListener('mousedown', () => setTimeout(() => signin('attacklate', SIZE, OAUTH), 6500));</script>""",
    "/attack-doc": HEAD + """<p id="text" style="font-size:22px">An article you are reading, with nothing to click.</p><script>
      document.addEventListener('mousedown', () => signin('attackdoc', SIZE, OAUTH));</script>""",
}

IDP_PAGES = {
    "/idp/auth": AUTH_PAGE,
    "/idp/button": FRAME_BUTTON,
    "/idp/card": CARD,
    "/idp/holder": """<style>html, body { margin: 0; }</style>
      <iframe src="SITE/inner" width="240" height="44" style="border:0;margin:10px"></iframe><script>
      addEventListener('message', e => { if (e.data && e.data.open) window.open(e.data.open, 'signin', 'width=500,height=600'); });</script>""",
}

SITE_ONLY = {
    "/inner": """<style>html, body { margin: 0; height: 100%; } button { width: 100%; height: 100%; }</style>
      <button id="b">Sign in with Provider</button><script>
      document.getElementById('b').onclick = () => parent.postMessage({ open: 'IDP/idp/auth?n=nested' }, '*');</script>""",
    "/cb": """<title>callback</title><script>
      if (window.opener) { window.opener.postMessage({ token: 'tok-redirect' }, location.origin); window.close(); }
      else document.documentElement.dataset.token = 'tok-here';</script>""",
}


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = urlparse(self.path)
        page = parts.path
        query = parse_qs(parts.query)
        if page == "/wait":
            time.sleep(int(query.get("ms", ["0"])[0]) / 1000)
            return self.send(200, "ok", kind="text/plain", cors=True)
        if page == "/go":
            self.send_response(302)
            self.send_header("Location", f"{IDP}/idp/auth?n={query.get('n', [''])[0]}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        body = PAGES.get(page) or IDP_PAGES.get(page) or SITE_ONLY.get(page) or f"<title>{page}</title>plain {page}"
        self.send(200, "<!doctype html><meta charset=utf-8>" + body.replace("IDP", IDP).replace("SITE", SITE))

    do_POST = do_GET

    def send(self, status, text, kind="text/html", cors=False):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        if cors:
            self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


sv.srv.RequestHandlerClass = H
anchor = None
window = None


def cmd(req):
    if window:
        req = {**req, "window": window}
    return sv.cmd(req)


def tabs():
    return sv.cmd({"do": "tabs"})["tabs"]


def opened(name):
    return [t for t in tabs() if f"n={name}" in t["url"].replace("&", "?").split("?")]


def state(tab):
    return cmd({"do": "popups", "id": tab})


def address(tab):
    return next((t["url"] for t in tabs() if t["id"] == tab), "")


def data(tab, key):
    return cmd({"do": "eval", "id": tab, "js": f"document.documentElement.dataset.{key} || ''"}).get("value")


def visit(path, private=False):
    if private:
        tab = sv.cmd({"do": "open", "url": f"{SITE}{path}", "private": True})["id"]
    else:
        req = {"do": "split", "action": "open", "url": f"{SITE}{path}"}
        if anchor:
            req["from"] = anchor
        tab = sv.cmd(req)["resultID"]
    time.sleep(1.5)
    if not private:
        sv.cmd({"do": "popups", "id": tab, "action": "allow"})
        sv.cmd({"do": "popups", "action": "remove", "site": "localhost"})
    return tab


def private_window():
    return next(w["n"] for w in sv.cmd({"do": "windows"})["windows"] if w["private"])


def traced(tab):
    try:
        return len(sv.cmd({"do": "popups", "id": tab}).get("trace", []))
    except Exception:
        return 0


def tap(tab, selector, wait=1.5, **extra):
    cmd({"do": "select", "id": tab})
    ready = f"document.readyState === 'complete' && !!document.querySelector({json.dumps(selector)})"
    until = time.time() + 10
    while time.time() < until and not cmd({"do": "eval", "id": tab, "js": ready}).get("value"):
        time.sleep(0.1)
    before = traced(tab)
    reply = cmd({"do": "tap", "id": tab, "selector": selector, **extra})
    if selector != "#finish":
        until = time.time() + wait + 6
        while time.time() < until and traced(tab) == before:
            time.sleep(0.2)
    time.sleep(wait if wait > 1.5 or selector == "#finish" else 1)
    return reply


def verdicts(tab):
    return [f"{x['verdict']}{' sized' if x.get('sized') == 'true' else ''}" for x in state(tab).get("trace", [])]


def shut(tab):
    try:
        cmd({"do": "split", "action": "closeTab", "id": tab})
    except RuntimeError:
        pass


def close_opened(name):
    for tab in opened(name):
        shut(tab["id"])
    time.sleep(0.3)


OPENS = [
    ("a sized window from a button", "/sized", "#b", "sized", 1.5),
    ("a window with no size from a button", "/nosize", "#b", "nosize", 1.5),
    ("a target=_blank link to the provider", "/link", "#b", "link", 1.5),
    ("the provider's framed button, opened by the frame", "/framed", "#f", "framed", 1.5),
    ("the framed button with no size", "/framed-tab", "#f", "framedtab", 1.5),
    ("the framed button, opened by the page after a message", "/framed-parent", "#f", "framedparent", 1.5),
    ("a framed button with a clear state layer over its label", "/framed-layered", "#f", "framedlayered", 1.5),
    ("the page's own button under the provider's unseen frame", "/custom", "#b", "custom", 1.5),
    ("the One Tap card's continue button", "/onetap", "#f", "onetap", 1.5),
    ("a window opened 1.5 s after the click", "/delay", "#b", "delay", 3.5),
    ("about:blank first, sent to the provider afterwards", "/blank-first", "#b", "blank", 2.5),
    ("an empty tab first, sent to the provider afterwards", "/blank-tab", "#b", "blanktab", 2.5),
    ("the site's own redirect page first, sized", "/own-first", "#b", "ownfirst", 2),
    ("the site's own redirect page first, in a tab", "/own-first-tab", "#b", "ownfirsttab", 2),
    ("a button with a clear layer over its label", "/layered", "#b", "layered", 1.5),
    ("a button in an open shadow root", "/shadow-open", "#b", "shadowopen", 1.5),
    ("a button in a closed shadow root", "/shadow-closed", "#b", "shadowclosed", 1.5),
    ("a layered button in an open shadow root", "/shadow-layered", "#b", "shadowlayered", 1.5),
    ("the provider's own button, unseen inside the site's button by way of a slot", "/ghost", "#b", "ghost", 1.5),
    ("the provider's own button and frame, unseen inside the site's button", "/ghost-inside", "#b", "ghostinside", 1.5),
    ("a link to the site's own address whose script opens the provider in a tab", "/own-link", "#b", "ownlink", 1.5),
    ("a form posted to the provider in a new tab after a fetch", "/form", "#b", "form", 2.5),
]

REFUSED = [
    ("a sign-in window from a nearly transparent overlay over a player", "/attack-signin", "#play", "attackunseen", 1.5, "unseen"),
    ("a sign-in window with no click at all", "/attack-noclick", None, "attacknoclick", 1.5, "no-click"),
    ("a sign-in window from a document mousedown on plain text", "/attack-doc", "#text", "attackdoc", 1.5, "inert"),
    ("a sign-in window 6.5 s after a click on plain text", "/attack-late", "#text", "attacklate", 8, "no-click"),
    ("a window to a provider Broadway doesn't know from a div with nothing to say it is a button", "/div", "#b", "div", 1.5, "inert"),
    ("a window to a provider Broadway doesn't know 6.5 s after the click", "/delay-long", "#b", "delaylong", 8, "no-click"),
    ("a window opened by a frame other than the clicked one and the page", "/nested", "#f", "nested", 1.5, "no-click"),
    ("a window to a provider Broadway doesn't know from an unseen button beside a painted face", "/ghost-shell", "#b", "ghostshell", 1.5,
     "unseen"),
    ("a sign-in window from a document mousedown on text in a tag with a hyphen that is no custom element", "/plain-tag", "#b",
     "plaintag", 1.5, "inert"),
    ("a sign-in window from an unseen layer over the whole page that hangs off a small pointer box", "/attack-ghost", "#text",
     "attackghost", 1.5, "unseen"),
    ("a sign-in window from an unseen layer over the whole page that hangs off a small painted box", "/attack-ghost-box", "#text",
     "attackghostbox", 1.5, "unseen"),
]


def table():
    global anchor
    sv.setup(); sv.launch()
    rows = []
    try:
        anchor = visit("/plain")
        for words, path, selector, name, wait in OPENS:
            page = visit(path)
            tap(page, selector, wait=wait)
            rows.append((words, "opened" if opened(name) else "REFUSED", verdicts(page)))
            close_opened(name)
            shut(page)
        for words, path, selector, name, wait, reason in REFUSED:
            page = visit(path)
            if selector:
                tap(page, selector, wait=wait)
            rows.append((words, "OPENED" if opened(name) else "refused", verdicts(page)))
            close_opened(name)
            shut(page)
    finally:
        for words, result, trace in rows:
            print(f"{result:8} {words}  {trace}")
        sv.finish()
    return 0


def main():
    global anchor, window
    t = sv.T()
    try:
        sv.setup(); sv.launch()
        anchor = visit("/plain")

        for words, path, selector, name, wait in OPENS:
            page = visit(path)
            tap(page, selector, wait=wait)
            st = state(page)
            t.ok(f"{words} opens", len(opened(name)) == 1 and st["sign"] is False, (verdicts(page), st["blocked"]))
            close_opened(name)
            shut(page)

        for words, path, selector, name, wait, reason in REFUSED:
            page = visit(path)
            if selector:
                tap(page, selector, wait=wait)
            said = verdicts(page)
            t.ok(f"{words} is refused", not opened(name) and [x.split()[0] for x in said] == [reason], said)
            shut(page)

        page = visit("/ghost-shell")
        tap(page, "#b")
        hits = [x.get("hits", "") for x in state(page).get("trace", [])]
        t.ok("the unseen button beside a painted face is told apart from an overlay", any("masked true" in x for x in hits), hits)
        shut(page)

        page = visit("/attack-signin")
        tap(page, "#play")
        hits = [x.get("hits", "") for x in state(page).get("trace", [])]
        t.ok("an overlay over a player is not", hits and all("masked false" in x for x in hits), hits)
        shut(page)

        page = visit("/attack-ghost-box")
        tap(page, "#text")
        hits = [x.get("hits", "") for x in state(page).get("trace", [])]
        t.ok("nor is an unseen layer that reaches past the painted box it hangs off", hits and all("masked false" in x for x in hits), hits)
        shut(page)

        page = visit("/div-fallback")
        tap(page, "#b", wait=2.5)
        t.ok("after a refusal, the page may not send itself to an address that only looks like a sign-in",
             urlparse(address(page)).path == "/div-fallback" and "tab-under" in [x.split()[0] for x in verdicts(page)],
             (address(page), verdicts(page)))
        shut(page)

        page = visit("/handback")
        tap(page, "#b", wait=3)
        t.ok("after a tab-sized sign-in closes itself, the opener may leave for another site",
             urlparse(address(page)).path == "/app", (address(page), verdicts(page)))
        shut(page)

        page = visit("/handback-sized")
        tap(page, "#b", wait=3)
        t.ok("and after a sized one", urlparse(address(page)).path == "/app", (address(page), verdicts(page)))
        shut(page)

        page = visit("/redirect-back")
        tap(page, "#b", wait=3)
        t.ok("a sign-in that comes back by a redirect answers its opener and closes",
             data(page, "token") == "tok-redirect" and not opened("redirectback") and not [x for x in tabs() if x["url"].endswith("/cb")],
             (data(page, "token"), [x["url"] for x in tabs()]))
        shut(page)

        page = visit("/sized")
        tap(page, "#b")
        first = opened("sized")
        t.ok("the sign-in window is in front", len(first) == 1 and first[0]["active"], first)
        tap(first[0]["id"], "#more")
        second = opened("second")
        t.ok("the provider's window may open a second one", len(second) == 1, verdicts(first[0]["id"]) if first else "")
        if second:
            tap(second[0]["id"], "#finish", wait=2)
        t.ok("which hands back down the chain: both close and the page has its answer",
             not opened("second") and not opened("sized") and data(page, "token") == "tok-sized", (data(page, "token"), [x["url"] for x in tabs()]))
        active = next((x for x in tabs() if x["active"]), {})
        t.ok("and the page that asked is in front again", active.get("id") == page, active)
        shut(page)

        page = visit("/strikes")
        tap(page, "#play")
        tap(page, "#text")
        st = state(page)
        t.ok("an overlay's window and a document opener's are refused and the site is wary",
             st["wary"] is True and st["reasons"] == ["unseen", "inert"], st)
        tap(page, "#sized")
        t.ok("a wary site's sized sign-in window opens", len(opened("warysized")) == 1, verdicts(page))
        close_opened("warysized")
        tap(page, "#link")
        t.ok("its visible link to the provider opens", len(opened("warylink")) == 1, verdicts(page))
        close_opened("warylink")
        tap(page, "#ad")
        t.ok("its button's window to anything else waits in the sign", not [x for x in tabs() if "/ad-wary" in x["url"]] and state(page)["reasons"][-1] == "wary", state(page))
        tap(page, "#tab")
        t.ok("its sign-in in a tab opens, the address being a sign-in request", len(opened("warytab")) == 1, verdicts(page))
        close_opened("warytab")
        tap(page, "#other")
        st = state(page)
        t.ok("a tab to another site with nothing of a sign-in about it waits", not opened("waryother") and st["reasons"][-1] == "wary", st)
        sv.cmd({"do": "popups", "id": page, "action": "allow"})
        tap(page, "#other")
        t.ok("Allow Pop-ups opens it on the next click", len(opened("waryother")) == 1, verdicts(page))
        close_opened("waryother")
        sv.cmd({"do": "popups", "action": "remove", "site": "localhost"})
        shut(page)

        page = visit("/framed-layered")
        sv.cmd({"do": "popups", "id": page, "action": "allow"})
        tap(page, "#f")
        t.ok("Allow Pop-ups covers a click in the provider's frame", len(opened("framedlayered")) == 1, verdicts(page))
        close_opened("framedlayered")
        sv.cmd({"do": "popups", "action": "remove", "site": "localhost"})
        shut(page)

        for words, path, selector, name in [
            ("in an ordinary window", "/sized", "#b", "sized"),
            ("from the provider's frame", "/framed", "#f", "framed"),
            ("in a tab", "/nosize", "#b", "nosize"),
        ]:
            page = visit(path)
            tap(page, selector)
            made = opened(name)
            t.ok(f"far end {words}: the window opens on the provider", len(made) == 1, verdicts(page))
            if made:
                tap(made[0]["id"], "#finish", wait=1.5)
            t.ok(f"far end {words}: it closes and the page has its answer",
                 not opened(name) and (data(page, "token") == f"tok-{name}" or name == "framed"), (data(page, "token"), [x["url"] for x in tabs()]))
            active = next((x for x in tabs() if x["active"]), {})
            t.ok(f"far end {words}: the page that asked is in front", active.get("id") == page, active)
            shut(page)

        left = visit("/sized")
        right = visit("/plain")
        sv.sp("pair", id=right, **{"with": left}, side="right")
        time.sleep(0.8)
        tap(left, "#b")
        made = opened("sized")
        t.ok("far end in a split pair: the window opens", len(made) == 1, verdicts(left))
        if made:
            tap(made[0]["id"], "#finish", wait=1.5)
        st = sv.sp("state")
        t.ok("far end in a split pair: it closes, the page has its answer and the pair is whole",
             not opened("sized") and data(left, "token") == "tok-sized" and any(set(p["tabs"]) == {left, right} for p in st["splits"]),
             (data(left, "token"), st["splits"]))
        shut(right)
        shut(left)

        pinned = visit("/nosize")
        sv.cmd({"do": "pin", "id": pinned})
        time.sleep(0.5)
        tap(pinned, "#b")
        peek = sv.cmd({"do": "probe"}).get("peek", "")
        t.ok("far end from a pin: a sign-in with no size opens in the peek", data(pinned, "win") == "yes" and "n=nosize" in peek,
             (verdicts(pinned), peek))
        sv.cmd({"do": "peek", "url": "close"})
        sv.cmd({"do": "pin", "id": pinned, "off": True})
        shut(pinned)

        shy = visit("/sized", private=True)
        window = private_window()
        tap(shy, "#b")
        made = opened("sized")
        t.ok("far end in a private window: the window opens", len(made) == 1, verdicts(shy))
        if made:
            tap(made[0]["id"], "#finish", wait=1.5)
        t.ok("far end in a private window: it closes and the page has its answer",
             not opened("sized") and data(shy, "token") == "tok-sized", (data(shy, "token"), [x["url"] for x in tabs()]))
        window = None
    finally:
        t.done(); sv.finish()
    return 1 if t.failed else 0


if __name__ == "__main__":
    sys.exit(table() if "--table" in sys.argv else main())
