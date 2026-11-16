#!/usr/bin/env python3
"""Video speed keys (Tempo, built in), checked in a hidden probe of its own.

Build first (`./build.sh`), then `python3 Tests/tempo_keys.py`. Key presses
are bench key events handed to the tab's own view: no real input, no window
brought forward. A second launch of the same world checks that an installed
Tempo extension (a fixture written into the test world, never the real
profile) is turned off once.
"""
import functools
import json
import subprocess
import sys
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("tempo-keys")

TEMPO = "jmeijciilikghhkcojjcfmfnancpaklk"
RATE = "document.getElementById('video').playbackRate"


def main():
    with tempfile.TemporaryDirectory(prefix="broadway-tempo-keys-") as folder:
        root = Path(folder)
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                        "testsrc2=size=640x360:rate=24", "-t", "120", "-c:v", "libx264",
                        "-preset", "ultrafast", "-pix_fmt", "yuv420p", str(root / "clip.mp4")], check=True)
        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Quiet, directory=folder))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        port = server.server_port
        (root / "index.html").write_text(f"""<!doctype html><title>Tempo keys</title>
        <body style='margin:0;background:#111'>
        <input id=field value=''>
        <div><video id=video src=clip.mp4 muted loop playsinline style='display:block;width:640px;height:360px'></video></div>
        <iframe id=same src=empty.html style='width:300px;height:120px'></iframe>
        <iframe id=cross src='http://localhost:{port}/framed.html' style='width:360px;height:220px'></iframe>
        <script>
          window.keys = []; addEventListener('keydown', e => keys.push(e.key));
          window.childRate = null; addEventListener('message', e => {{ if (e.data && e.data.childRate) childRate = e.data.childRate; }});
        </script>""")
        (root / "empty.html").write_text("""<!doctype html><title>empty</title><p>No video here.<button id=here>here</button>
        <script>addEventListener('message', e => { if (e.data === 'focus') document.getElementById('here').focus(); });</script>""")
        (root / "framed.html").write_text("""<!doctype html><title>framed</title><body style='margin:0'>
        <video id=inner src=clip.mp4 muted loop playsinline style='display:block;width:320px;height:180px'></video>
        <button id=here>here</button>
        <script>
          addEventListener('message', e => { if (e.data === 'focus') document.getElementById('here').focus(); });
          var v = document.getElementById('inner');
          v.addEventListener('ratechange', () => parent.postMessage({childRate: v.playbackRate}, '*'));
        </script>""")
        t = sv.T()
        base = f"http://127.0.0.1:{port}"
        try:
            sv.setup(**{"float.leave": False})
            sv.launch()
            sv.cmd({"do": "window"})
            tab = sv.sp("open", url=f"{base}/index.html")["resultID"]
            sv.cmd({"do": "select", "id": tab})
            time.sleep(2.5)

            def ev(js, id=None, world=None):
                ask = {"do": "eval", "id": id or tab, "js": js}
                if world: ask["world"] = world
                return sv.cmd(ask).get("value")

            def press(text, id=None, **fields):
                sv.cmd({"do": "key", "id": id or tab, "text": text, **fields})
                time.sleep(0.15)
                return ev(RATE, id)

            def hud(id=None):
                return ev("""(() => { const b = window.__broadwayTempoBadge && window.__broadwayTempoBadge();
                  if (!b) return null;
                  const r = b.getRootNode(), h = r.host;
                  return { text: b && b.textContent, svg: !!r.querySelector('svg'),
                    dot: r.querySelector('.tempo-dot') && r.querySelector('.tempo-dot').textContent,
                    face: !!r.querySelector('.tempo-face-dot'), shown: h.style.opacity, closed: h.shadowRoot === null,
                    pulls: Array.from(r.querySelectorAll('.tempo-dot, .tempo-dot + .tempo-digit'))
                      .map(n => parseFloat(n.style.marginLeft || '0')),
                    cell: b && b.querySelector('.tempo-number') && b.querySelector('.tempo-number').dataset.cell,
                    place: [b, r.querySelector('.tempo-dot')].filter(Boolean).map(n => {
                      const r = n.getBoundingClientRect(); return [+r.left.toFixed(2), +r.right.toFixed(2)]; }) }; })()""", id, "search")

            def tight(shown):
                return bool(shown) and len(shown["pulls"]) == 2 and all(pull < -0.05 for pull in shown["pulls"])

            t.ok("a fresh video plays at 1x", ev(RATE) == 1)
            t.ok("F moves 1.0x to 1.1x", press("f") == 1.1)
            shown = hud()
            t.ok("the HUD shows 1.1 over the video", shown and shown["text"] == "1.1" and shown["shown"] == "1", shown)
            t.ok("the HUD separator is a plain dot, no face", shown and shown["dot"] == "." and not shown["svg"] and not shown["face"], shown)
            t.ok("the digits are pulled in to the dot", tight(shown), shown)
            t.ok("Tempo's keys never reach the page", ev("JSON.stringify(keys)") == "[]", ev("JSON.stringify(keys)"))
            t.ok("S slows back to 1.0x", press("s") == 1)
            back = hud()
            t.ok("S again slows to 0.9x", press("s") == 0.9)
            slower = hud()
            t.ok("the digits sit in fixed cells", all(bool(h and h["cell"]) for h in [shown, back, slower]),
                 [shown, back, slower])
            t.ok("the number and its dot stay put from 1.1 to 1.0 to 0.9",
                 bool(shown and back and slower) and len(shown["place"]) == 2
                 and all(abs(a - b) < 0.1 for h in [back, slower]
                         for box, other in zip(shown["place"], h["place"]) for a, b in zip(box, other)),
                 [shown, back, slower])
            t.ok("D resets to 1.0x", press("d") == 1)
            t.ok("the physical F key works with a Russian layout", press("а", code=3) == 1.1)
            t.ok("a Latin letter other than S, D, F, E is left alone", press("j", code=3) == 1.1)
            press("d")
            time.sleep(1.2)
            t.ok("the HUD fades after it shows", (hud() or {}).get("shown") == "0", hud())

            ev("""(() => { const v = document.getElementById('video'); window.media = [];
              const note = (e) => media.push([e.type, performance.now(), v.hasAttribute('data-broadway-tempo-hold')]);
              v.addEventListener('pause', note); v.addEventListener('play', note);
              v.play(); return 0; })()""")
            time.sleep(1)
            playback = "(() => { const v = document.getElementById('video'); return { paused: v.paused, " \
                       "held: v.hasAttribute('data-broadway-tempo-hold'), events: media.splice(0) }; })()"
            names = lambda events: [event[0] for event in events]
            paused_for = lambda events: events[1][1] - events[0][1] if len(events) == 2 else 0
            ev(playback)
            press("f")
            time.sleep(1.5)
            after = ev(playback)
            t.ok("F pauses a playing video while the speed changes", names(after["events"]) == ["pause", "play"]
                 and after["events"][0][2] and paused_for(after["events"]) >= 200, after)
            t.ok("and plays it again once the change is done", not after["paused"] and not after["held"], after)
            press("d")
            time.sleep(1.5)
            ev(playback)

            held = press("f", hold=0.75)
            t.ok("holding F keeps raising the speed", held >= 1.4, held)
            time.sleep(0.5)
            t.ok("letting go of F stops raising it", ev(RATE) == held, (held, ev(RATE)))
            time.sleep(1)
            after = ev(playback)
            t.ok("a held F pauses once and plays once, after the last step", not after["paused"]
                 and names(after["events"]) == ["pause", "play"] and paused_for(after["events"]) >= 700, after)
            ev("document.getElementById('video').pause(), 0")
            time.sleep(0.3)
            press("f" * 30)
            t.ok("F stops at 3.0x", ev(RATE) == 3, ev(RATE))
            press("s" * 30)
            t.ok("S stops at 0.5x", ev(RATE) == 0.5, ev(RATE))
            press("d")
            ev("document.getElementById('video').currentTime = 2")
            time.sleep(0.3)
            press("e")
            time.sleep(0.2)
            t.ok("E with no ad, section or chapter jumps ahead", ev("document.getElementById('video').currentTime") > 100, ev("document.getElementById('video').currentTime"))
            t.ok("and the HUD says exit", (hud() or {}).get("text") == "exit", hud())
            ev("document.getElementById('video').currentTime = 0")

            ev("document.getElementById('field').focus()")
            time.sleep(0.2)
            t.ok("typing F in a field leaves the speed alone", press("f") == 1)
            t.ok("the field gets the letter", ev("document.getElementById('field').value") == "f", ev("document.getElementById('field').value"))
            ev("document.getElementById('field').blur()")
            ev("""dispatchEvent(new KeyboardEvent('keydown', {key: 'f', code: 'KeyF', metaKey: true, bubbles: true}));
                  dispatchEvent(new KeyboardEvent('keydown', {key: 'f', code: 'KeyF', altKey: true, bubbles: true}));
                  dispatchEvent(new KeyboardEvent('keydown', {key: 'f', code: 'KeyF', ctrlKey: true, bubbles: true}));""")
            time.sleep(0.2)
            t.ok("F with Command, Option or Control is left alone", ev(RATE) == 1)

            ev("document.getElementById('video').playbackRate = 1.04")
            press("d")
            t.ok("D after a live catch-up reads 1x in the page", ev(RATE) == 1)
            native = ev(RATE, world="search")
            t.ok("and plays at LiveRate's 1.0001", native == 1.0001, native)
            t.ok("F from there steps to 1.1x", press("f") == 1.1)
            press("d")

            ev("document.getElementById('same').contentWindow.postMessage('focus', '*')")
            time.sleep(0.3)
            t.ok("the same-site frame has the keys", ev("document.activeElement.id") == "same", ev("document.activeElement.id"))
            press("f")
            t.ok("F in a frame without a video speeds up the page's video", ev(RATE) == 1.1, ev(RATE))
            ev("document.getElementById('cross').contentWindow.postMessage('focus', '*')")
            time.sleep(0.3)
            t.ok("the other site's frame has the keys", ev("document.activeElement.id") == "cross", ev("document.activeElement.id"))
            press("f")
            time.sleep(0.3)
            t.ok("F in another site's frame speeds up that frame's video", ev("childRate") == 1.1, ev("childRate"))
            t.ok("and leaves the page's own video alone", ev(RATE) == 1.1)
            press("f", hold=0.75)
            time.sleep(0.3)
            t.ok("holding F in that frame keeps raising its video", (ev("childRate") or 0) >= 1.5, ev("childRate"))
            ev("document.activeElement && document.activeElement.blur(); window.focus()")
            time.sleep(0.2)
            press("f")
            press("f")
            t.ok("back on the page, F steps the page's video", ev(RATE) == 1.3, ev(RATE))

            floating = lambda action="chrome", value=None: sv.cmd({"do": "float", "action": action, "value": value})
            key = lambda code, chars="", mods=None: floating("key", json.dumps(dict(code=code, chars=chars, mods=mods or [])))
            ev("document.getElementById('video').play(); 0")
            time.sleep(1)
            sv.cmd({"do": "film", "action": "float", "path": str(root / "float"), "seconds": 1})
            floating("hover", "on")
            time.sleep(0.8)
            t.ok("the floating video shows the speed Tempo set", floating()["rate"] == 1.3, floating()["rate"])
            ev("media.splice(0), 0")
            holding = threading.Thread(target=lambda: sv.cmd({"do": "key", "id": tab, "text": "f", "hold": 1.5}))
            holding.start()
            seen = []
            while holding.is_alive():
                seen.append(floating()["playing"])
                time.sleep(0.1)
            holding.join()
            time.sleep(1)
            events = ev("media.splice(0)")
            t.ok("Tempo's pause leaves the floating video's play button alone",
                 len(seen) >= 5 and all(seen) and names(events) == ["pause", "play"]
                 and paused_for(events) >= 1000, (seen, events))
            for key_text in ["d", "f", "f", "f"]:
                sv.cmd({"do": "key", "id": tab, "text": key_text})
                time.sleep(0.4)
            time.sleep(1)
            t.ok("and the speed is back at 1.3x", ev(RATE) == 1.3, ev(RATE))
            key(3, "f")
            time.sleep(0.3)
            t.ok("F in the floating video steps by a tenth", ev(RATE) == 1.4, ev(RATE))
            key(1, "ы")
            time.sleep(0.3)
            t.ok("S with a Russian layout in the floating video slows it", ev(RATE) == 1.3, ev(RATE))
            key(2, "d")
            time.sleep(0.3)
            t.ok("D in the floating video resets to 1x", ev(RATE) == 1, ev(RATE))
            floating("press", "speed")
            time.sleep(0.3)
            state = floating()
            t.ok("the top speed capsule still steps the speed", ev(RATE) == 1.25 and state["rate"] == 1.25, state)
            t.ok("no second speed shows under the play button", state["feedback"] == "", state)
            key(36, "\r")
            time.sleep(1.5)
            t.ok("F on the tab steps from the floating video's speed", press("f") == 1.4, ev(RATE))
            press("d")

            print("  skip  turned off: video.keys is fixed on since the Settings cut, so there is no off case")

            private = sv.cmd({"do": "open", "url": f"{base}/index.html?private", "private": True})["id"]
            sv.cmd({"do": "wait", "id": private, "seconds": 10})
            time.sleep(1.5)
            t.ok("a private tab gets the same keys", press("f", id=private) == 1.1, ev(RATE, private))
            t.ok("and its HUD digits are pulled in to the dot too", tight(hud(private)), hud(private))
            sv.cmd({"do": "close", "id": private})
            sv.quit()

            sv.setup(**{"float.leave": False})
            ext = Path(sv.SUPPORT, "Extensions", TEMPO)
            ext.mkdir(parents=True)
            (ext / "manifest.json").write_text(json.dumps({
                "manifest_version": 3, "name": "Tempo", "version": "1.0.1", "description": "Fixture",
                "content_scripts": [{"matches": ["<all_urls>"], "js": ["content.js"], "all_frames": True}]}))
            (ext / "content.js").write_text("document.documentElement.setAttribute('data-fixture-tempo', 'ran');")
            Path(sv.SUPPORT, "Extensions", "installed.json").write_text(json.dumps([{
                "id": TEMPO, "name": "Tempo", "version": "1.0.1", "enabled": True, "fromStore": True, "permissions": []}]))
            sv.launch()
            said = ""
            for _ in range(40):
                said = sv.cmd({"do": "ui", "tabKeys": {}}).get("announcement", "")
                if said: break
                time.sleep(0.1)

            def tempo_entry():
                for _ in range(60):
                    got = sv.cmd({"do": "extensions"})
                    if got["started"]:
                        return next((e for e in got["extensions"] if e["id"] == TEMPO), None)
                    time.sleep(0.25)
                return None

            entry = tempo_entry()
            t.ok("an installed Tempo is turned off, not removed", entry and entry["enabled"] is False and entry["loaded"] is False, entry)
            t.ok("and Broadway says so once", "Tempo is off" in said, said)
            listed = json.loads(Path(sv.SUPPORT, "Extensions", "installed.json").read_text())
            t.ok("the list on disk keeps it, off", [(e["id"], e["enabled"]) for e in listed] == [(TEMPO, False)], listed)
            sv.cmd({"do": "ext-enable", "id": TEMPO, "on": True})
            time.sleep(1)
            sv.quit()
            sv.launch()
            entry = tempo_entry()
            t.ok("turned back on by hand, it stays on", entry and entry["enabled"] is True, entry)
        finally:
            t.done()
            sv.finish()
            server.shutdown()
        return 1 if t.failed else 0


class Quiet(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


if __name__ == "__main__":
    sys.exit(main())
