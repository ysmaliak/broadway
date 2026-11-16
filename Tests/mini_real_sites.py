#!/usr/bin/env python3
"""The mini player and the float on real sites, once, near-silent.

Needs the network. Hidden probe world only: no window on screen, no sign-in,
no cookies but the world's own, no downloads. Videos wait for a click, so no
page plays by itself; every tab is muted (WebKit's page mute, which leaves
the elements' own mute alone) and every media element is held at volume 0.01
by a setter the probe puts in before anything plays.

Build first (`./build.sh`), then `python3 Tests/mini_real_sites.py`.
"""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import split_view as sv  # noqa: E402

sv.use("page-mini-real")
t = sv.T()

YOUTUBE = "https://www.youtube.com/watch?v=aqz-KE-bpKQ"
PODCAST = "https://podcasts.apple.com/us/podcast/the-daily/id1200361736"
RADIO = "https://somafm.com/player/#/now-playing/groovesalad"
ALBUM = "https://c418.bandcamp.com/album/minecraft-volume-alpha"

QUIET = r"""(function () {
  if (window.__quiet) return 'again';
  var said = window.__quiet = [], asked = window.__asked = [], played = window.__played = [];
  var held = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'volume');
  Object.defineProperty(HTMLMediaElement.prototype, 'volume', { configurable: true, enumerable: held.enumerable, get: held.get,
    set: function (v) { asked.push(+v); held.set.call(this, Math.min(+v, 0.01)); } });
  function hush(el) { if (el instanceof HTMLMediaElement && held.get.call(el) > 0.01) held.set.call(el, 0.01); }
  ['loadstart', 'loadedmetadata', 'play', 'playing', 'volumechange'].forEach(function (type) {
    document.addEventListener(type, function (e) { hush(e.target); }, true);
  });
  document.querySelectorAll('audio, video').forEach(hush);
  var play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () { hush(this); if (played.indexOf(this) < 0) played.push(this); return play.apply(this, arguments); };
  setInterval(function () { document.querySelectorAll('audio, video').forEach(hush); played.forEach(hush); }, 100);
  var named = /broadway|setActionHandler|setPositionState|MediaSession/i;
  ['error', 'warn'].forEach(function (kind) {
    var was = console[kind];
    console[kind] = function () {
      try {
        var text = Array.from(arguments).map(function (a) { return a && a.stack ? a.stack : String(a); }).join(' ');
        if (named.test(text)) said.push(kind + ': ' + text.slice(0, 400));
      } catch (e) {}
      return was.apply(this, arguments);
    };
  });
  window.addEventListener('error', function (e) {
    var text = String(e.message || '') + ' ' + String(e.error && e.error.stack || '');
    if (named.test(text)) said.push('error: ' + text.slice(0, 400));
  }, true);
  window.addEventListener('unhandledrejection', function (e) {
    var text = String(e.reason && (e.reason.stack || e.reason));
    if (named.test(text)) said.push('rejection: ' + text.slice(0, 400));
  });
  return 'on';
})()"""
MEDIA = """Array.from(new Set(Array.from(document.querySelectorAll('audio, video')).concat(window.__played || [])))
  .map(function (e) { return { tag: e.tagName, volume: e.volume, paused: e.paused, time: e.currentTime, rate: e.playbackRate }; })"""
LOUDEST = "Math.max.apply(null, [0].concat(" + MEDIA + ".map(function (m) { return m.paused ? 0 : m.volume; })))"
SESSION = """JSON.stringify(navigator.mediaSession.metadata ? { title: navigator.mediaSession.metadata.title,
  artist: navigator.mediaSession.metadata.artist, art: navigator.mediaSession.metadata.artwork.length } : null)"""


def ev(tab, js):
    return sv.cmd({"do": "eval", "id": tab, "js": js}).get("value")


def mini(action="state", *values):
    return sv.cmd({"do": "mini", "action": action, "values": [str(v) for v in values]})


def shown():
    return mini().get("shown") or {}


def short(tab):
    return tab[:8].lower()


def until(check, within=10):
    end = time.time() + within
    while time.time() < end:
        try:
            if check():
                return True
        except Exception:
            pass
        time.sleep(0.25)
    try:
        return bool(check())
    except Exception:
        return False


def opened(url):
    tab = sv.cmd({"do": "open", "url": url})["id"]
    sv.cmd({"do": "select", "id": tab})
    mini("mute", short(tab))
    ev(tab, QUIET)
    sv.cmd({"do": "wait", "id": tab, "seconds": 25})
    time.sleep(5)
    ev(tab, QUIET)
    return tab


def whisper(tab, name):
    loud = ev(tab, LOUDEST)
    t.ok(f"{name}: nothing louder than a whisper", loud is not None and loud <= 0.011, ev(tab, MEDIA))
    t.ok(f"{name}: nothing in the console names the hook", ev(tab, "JSON.stringify(window.__quiet || [])") == "[]",
         ev(tab, "JSON.stringify(window.__quiet)"))


def youtube(other):
    tab = opened(YOUTUBE)
    v = "document.querySelector('video')"
    if not ev(tab, f"!!{v}"):
        print("  skip  YouTube showed no video:", ev(tab, "location.href"))
        sv.cmd({"do": "close", "id": tab})
        return
    t.ok("YouTube: nothing played by itself", ev(tab, f"{v}.paused") is True, ev(tab, MEDIA))
    ev(tab, f"{v}.play().catch(function () {{}}), 1")
    t.ok("YouTube: it plays", until(lambda: ev(tab, f"!{v}.paused && {v}.currentTime > 1")), ev(tab, MEDIA))
    t.ok("YouTube: a picture, so the float's", until(lambda: mini()["roles"].get(short(tab)) == "float"), mini()["roles"])
    t.ok("YouTube: the page's Media Session reads back what it set", until(lambda: "title" in (ev(tab, SESSION) or "")), ev(tab, SESSION))
    rate = f"{v}.playbackRate"
    for key, want in (("f", 1.1), ("f", 1.2), ("s", 1.1), ("d", 1)):
        sv.cmd({"do": "key", "id": tab, "text": key})
        time.sleep(0.4)
        t.ok(f"YouTube: {key.upper()} sets {want}x", ev(tab, rate) == want and ev(tab, "!document.fullscreenElement"), ev(tab, rate))
    ev(tab, "document.querySelector('.ytp-play-button').click(), 1")
    t.ok("YouTube: its own button pauses", until(lambda: ev(tab, f"{v}.paused"), 4))
    ev(tab, "document.querySelector('.ytp-play-button').click(), 1")
    t.ok("YouTube: and plays", until(lambda: ev(tab, f"!{v}.paused"), 4))
    t.ok("YouTube: in front, the card does not take it either", all(not i["title"].startswith("Big Buck") for i in mini()["items"]),
         mini()["items"])
    sv.cmd({"do": "select", "id": other})
    t.ok("YouTube: leaving it, it floats", until(lambda: sv.cmd({"do": "lingering"}).get("floating", "").lower().startswith(short(tab))),
         sv.cmd({"do": "lingering"}))
    t.ok("YouTube: the card never takes it", all(not i["title"].startswith("Big Buck") for i in mini()["items"]), mini()["items"])
    whisper(tab, "YouTube")
    sv.cmd({"do": "select", "id": tab})
    time.sleep(1.5)
    sv.cmd({"do": "close", "id": tab})
    until(lambda: not sv.cmd({"do": "lingering"}).get("showing"), 4)


def podcast(other):
    tab = opened(PODCAST)
    pressed = ev(tab, """(function () { var b = Array.from(document.querySelectorAll('button')).find(function (b) {
      return /^Play, \\d+ minutes/.test(b.getAttribute('aria-label') || ''); }); if (!b) return ''; b.click(); return b.getAttribute('aria-label'); })()""")
    if not pressed:
        print("  skip  Apple Podcasts showed no episode to play")
        sv.cmd({"do": "close", "id": tab})
        return
    a = "document.querySelector('audio')"
    t.ok("Podcast: it plays", until(lambda: ev(tab, f"!{a}.paused && {a}.currentTime > 0.5")), ev(tab, MEDIA))
    sv.cmd({"do": "select", "id": other})
    t.ok("Podcast: the card has the episode", until(lambda: shown().get("title") and shown().get("art")), shown())
    item = shown()
    t.ok("Podcast: the show on the second line, skips for a long episode",
         bool(item.get("detail")) and item.get("pair") == "seconds" and item.get("duration", 0) > 600, item)
    mini("toggle")
    t.ok("Podcast: pause from the card pauses the page", until(lambda: ev(tab, f"{a}.paused"), 4))
    t.ok("Podcast: the card says paused", until(lambda: shown().get("playing") is False, 4), shown())
    until(lambda: shown().get("playing") is False, 4)
    mini("toggle")
    t.ok("Podcast: play from the card plays it", until(lambda: ev(tab, f"!{a}.paused"), 4))
    before = ev(tab, f"{a}.currentTime")
    mini("forward")
    t.ok("Podcast: forward 15", until(lambda: ev(tab, f"{a}.currentTime") - before > 12, 4), (before, ev(tab, f"{a}.currentTime")))
    mini("seek", 0.5)
    t.ok("Podcast: seek to the middle", until(lambda: abs(ev(tab, f"{a}.currentTime") - item["duration"] / 2) < 30, 5), ev(tab, f"{a}.currentTime"))
    mini("speed", 1.5)
    t.ok("Podcast: speed reaches the page", until(lambda: ev(tab, f"{a}.playbackRate") == 1.5, 3), ev(tab, f"{a}.playbackRate"))
    mini("speed", 1)
    whisper(tab, "Podcast")
    ev(tab, f"{a}.pause(), 1")
    sv.cmd({"do": "close", "id": tab})


def radio(other):
    tab = opened(RADIO)
    clicked = ev(tab, "(function () { var i = document.querySelector('i.fa-play'); var b = i && (i.closest('button, a, [ng-click]') || i); if (!b) return false; b.click(); return true; })()")
    if not clicked:
        print("  skip  SomaFM showed no play button")
        sv.cmd({"do": "close", "id": tab})
        return
    t.ok("Radio: it plays", until(lambda: ev(tab, "(window.__played || []).some(function (e) { return !e.paused && e.currentTime > 0.5; })")), ev(tab, MEDIA))
    sv.cmd({"do": "select", "id": other})
    t.ok("Radio: the card shows a live stream", until(lambda: shown().get("live") is True), shown())
    item = shown()
    t.ok("Radio: play and pause only, no speed", item.get("pair") == "none" and not item.get("speed"), item)
    first = "(window.__played || [])[0]"
    mini("toggle")
    t.ok("Radio: pause from the card stops it", until(lambda: ev(tab, f"{first}.paused"), 4))
    until(lambda: shown().get("playing") is False, 4)
    mini("toggle")
    t.ok("Radio: play from the card starts it", until(lambda: ev(tab, f"!{first}.paused"), 6))
    whisper(tab, "Radio")
    ev(tab, f"{first}.pause(), 1")
    sv.cmd({"do": "close", "id": tab})


def album(other):
    tab = opened(ALBUM)
    if not ev(tab, "(function () { var b = document.querySelector('.playbutton'); if (!b) return false; b.click(); return true; })()"):
        print("  skip  Bandcamp showed no play button")
        sv.cmd({"do": "close", "id": tab})
        return
    a = "Array.from(document.querySelectorAll('audio')).find(function (e) { return e.currentTime > 0; })"
    t.ok("Album: it plays", until(lambda: ev(tab, f"!!{a} && !{a}.paused")), ev(tab, MEDIA))
    sv.cmd({"do": "select", "id": other})
    t.ok("Album: the card has the album, without the page's playing mark",
         until(lambda: shown().get("title", "").startswith("Minecraft")), shown())
    mini("toggle")
    t.ok("Album: pause from the card, and the page's own button follows",
         until(lambda: ev(tab, f"{a}.paused") and "playing" not in ev(tab, "document.querySelector('.playbutton').className"), 4))
    until(lambda: shown().get("playing") is False, 4)
    mini("toggle")
    t.ok("Album: play from the card", until(lambda: ev(tab, f"!{a}.paused"), 4))
    before = ev(tab, f"{a}.currentTime")
    mini("forward")
    t.ok("Album: forward 15", until(lambda: ev(tab, f"{a}.currentTime") - before > 12, 4))
    whisper(tab, "Album")
    ev(tab, f"{a}.pause(), 1")
    sv.cmd({"do": "close", "id": tab})


def main():
    try:
        sv.setup(**{"media.click": True})
        sv.launch()
        other = sv.cmd({"do": "open", "url": "about:blank"})["id"]
        for run in (youtube, podcast, radio, album):
            try:
                run(other)
            except Exception as error:
                t.ok(f"{run.__name__} ran to the end", False, error)
            sv.cmd({"do": "select", "id": other})
    finally:
        t.done()
        sv.finish()
    sys.exit(1 if t.failed else 0)


main()
