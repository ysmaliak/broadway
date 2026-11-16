import WebKit

enum MiniScripts {
    static let changed = "broadwaysound"
    static let ask = "broadwaysoundask"
    static let key = "broadway.sound"

    static let picture = """
    function (v) {
      if (!(v instanceof HTMLVideoElement)) return false;
      var stream = v.srcObject && v.srcObject.getVideoTracks ? v.srcObject.getVideoTracks().length : 0;
      var tracks = v.videoTracks ? v.videoTracks.length : 0;
      if (!(v.videoWidth && v.videoHeight) && !stream && !tracks) return false;
      var b = v.getBoundingClientRect();
      if (b.width < 32 || b.height < 18) return false;
      var s = getComputedStyle(v);
      return s.visibility !== 'hidden' && s.display !== 'none';
    }
    """

    static let hook = """
    (function () {
      if (typeof MediaSession === 'undefined') return;
      var key = Symbol.for('\(key)');
      var proto = MediaSession.prototype;
      if (proto[key]) return;
      var least = \(Int(MiniRule.soundLeast));
      var kept = {}, position = null, main = null, prior = null, why = '', loose = [], wanted = null, wantedAt = 0, refused = 0;
      function now() { return performance.now(); }
      function tell() { try { document.dispatchEvent(new CustomEvent('\(changed)', { detail: state() })); } catch (e) {} }
      var set = proto.setActionHandler;
      proto.setActionHandler = function setActionHandler(action, handler) {
        if (handler) kept[action] = handler; else delete kept[action];
        var answer = set.apply(this, arguments);
        tell();
        return answer;
      };
      var place = proto.setPositionState;
      if (place) {
        proto.setPositionState = function setPositionState(given) {
          var answer = place.apply(this, arguments);
          position = given && isFinite(+given.duration) && +given.duration > 0
            ? { duration: +given.duration, time: +(given.position || 0), rate: +(given.playbackRate || 1), at: now(), playing: null } : null;
          tell();
          return answer;
        };
      }
      ['metadata', 'playbackState'].forEach(function (name) {
        var held = Object.getOwnPropertyDescriptor(proto, name);
        if (!held || !held.set) return;
        Object.defineProperty(proto, name, { configurable: true, enumerable: held.enumerable, get: held.get,
          set: function (value) { held.set.call(this, value); tell(); } });
      });
      function audible(el) { return !el.muted && el.volume > 0; }
      function short(el) { var d = el.duration; return isFinite(d) && d > 0 && d < least; }
      function minor(el) { return short(el) && (el.loop || !!(main && main !== el && !gone(main) && !short(main))); }
      function gone(el) {
        if (!el || el.error) return true;
        if (!el.isConnected && loose.indexOf(el) < 0) return true;
        return el.networkState === 0 && !el.currentSrc;
      }
      function take(el) {
        if (el === main) return;
        if (main && !gone(main)) {
          if (minor(el)) return;
          if (!audible(el) && audible(main)) return;
          prior = main;
          why = 'the latest to start';
        } else {
          prior = null;
          why = 'the one playing';
        }
        main = el;
      }
      function settle(el) {
        if (el !== main || !prior || gone(prior) || !minor(el)) return;
        main = prior;
        prior = null;
        why = 'the main track, a short clip beside it set aside';
      }
      function heard(el, type) {
        if (type === 'play') take(el);
        if (type === 'durationchange' || type === 'loadedmetadata') settle(el);
        if (type === 'ratechange' && el === main && wanted !== null) {
          if (Math.abs(el.playbackRate - wanted) < 0.01) wantedAt = 0;
          else if (now() - wantedAt > 40) { refused = wanted; wanted = null; }
        }
        if (el === main || type === 'play') tell();
      }
      function watch(el) {
        if (loose.indexOf(el) >= 0) return;
        loose.push(el);
        if (loose.length > 8) loose.shift();
        ['play', 'pause', 'ended', 'ratechange', 'durationchange', 'seeked', 'loadedmetadata', 'emptied'].forEach(function (type) {
          el.addEventListener(type, function () { if (loose.indexOf(el) >= 0) heard(el, type); });
        });
      }
      var play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        if (!this.isConnected) watch(this);
        return play.apply(this, arguments);
      };
      ['play', 'pause', 'ended', 'durationchange', 'loadedmetadata', 'ratechange', 'seeked'].forEach(function (type) {
        document.addEventListener(type, function (e) {
          if (e.target instanceof HTMLMediaElement && loose.indexOf(e.target) < 0) heard(e.target, type);
        }, true);
      });
      function all() {
        var found = Array.prototype.slice.call(document.querySelectorAll('audio, video'));
        loose.forEach(function (e) { if (!gone(e) && found.indexOf(e) < 0) found.push(e); });
        return found;
      }
      function element() {
        if (main && !gone(main)) return main;
        var best = null, list = all();
        for (var i = 0; i < list.length; i++) {
          var e = list[i];
          if (!best || (!e.paused && best.paused) || (e.paused === best.paused && short(best) && !short(e))) best = e;
        }
        if (best && !best.paused) { main = best; prior = null; why = 'the one playing'; return best; }
        return best && best.currentTime > 0 ? best : null;
      }
      function sounding(el) { return !el.paused && !el.ended; }
      function reading() {
        var el = element(), t = now();
        if (position) {
          var playing = el ? sounding(el) : navigator.mediaSession.playbackState !== 'paused';
          if (position.playing) position.time = Math.min(position.duration, position.time + (t - position.at) / 1000 * position.rate);
          position.at = t;
          position.playing = playing;
          if (el && el.playbackRate > 0) position.rate = el.playbackRate;
          return { source: 'page', why: 'the position the page reports', playing: playing, time: Math.max(0, position.time),
                   duration: position.duration, rate: position.rate, live: false, minor: false, element: !!el,
                   loop: !!el && el.loop };
        }
        if (!el) return null;
        var live = el.duration === Infinity;
        return { source: el instanceof HTMLVideoElement ? 'video' : 'audio', why: why || 'the only one', playing: sounding(el),
                 time: el.currentTime || 0, duration: live || !isFinite(el.duration) ? 0 : el.duration,
                 rate: el.playbackRate || 1, live: live, minor: minor(el), element: true, loop: el.loop };
      }
      function round(n) { return Math.round((+n || 0) * 10) / 10; }
      function media() {
        var el = element();
        return all().slice(0, 8).map(function (e) {
          return { kind: e instanceof HTMLVideoElement ? 'video' : 'audio', duration: e.duration === Infinity ? -1 : round(e.duration),
                   time: round(e.currentTime), paused: e.paused, muted: e.muted || e.volume === 0, loop: e.loop,
                   loose: loose.indexOf(e) >= 0, chosen: e === el };
        });
      }
      function state() {
        return JSON.stringify({ actions: Object.keys(kept), reading: reading(), refused: refused, media: media(),
          reported: position ? { duration: round(position.duration), time: round(position.time), rate: position.rate } : null,
          audible: (function () { var el = element(); return !!el && audible(el); })(),
          loose: (function () { var el = element(); return !!el && loose.indexOf(el) >= 0 && !el.paused; })() });
      }
      document.addEventListener('\(ask)', tell, true);
      function clamp(time, el) {
        var end = position ? position.duration : el && isFinite(el.duration) ? el.duration : Infinity;
        return Math.max(0, Math.min(end, time));
      }
      function call(name, details) {
        details.action = name;
        try { kept[name](details); } catch (e) {}
        return 'page';
      }
      Object.defineProperty(proto, key, { value: function (action, value) {
        var el = element();
        if (action === 'skip' || action === 'seekto') {
          var r = reading();
          var here = r ? r.time : null;
          var target = action === 'skip' ? (here === null ? null : here + value) : value;
          if (target !== null && kept.seekto) return call('seekto', { seekTime: clamp(target, el), fastSeek: false });
          if (target !== null && el && isFinite(el.duration)) {
            el.currentTime = clamp(target, el);
            if (position) { position.time = clamp(target, el); position.at = now(); }
            return 'element';
          }
          if (action === 'skip') {
            var name = value < 0 ? 'seekbackward' : 'seekforward';
            if (kept[name]) return call(name, { seekOffset: Math.abs(value) });
          }
          return '';
        }
        if (action === 'rate') {
          if (!el || refused) return '';
          wanted = value;
          wantedAt = now();
          try { el.dispatchEvent(new CustomEvent('\(Tempo.rateEvent)', { detail: String(value) })); } catch (e) {}
          el.playbackRate = value;
          return 'element';
        }
        if (kept[action]) return call(action, {});
        if (action === 'play' && el) { var p = el.play(); if (p && p.catch) p.catch(function () {}); return 'element'; }
        if (action === 'pause' && el) { el.pause(); return 'element'; }
        return '';
      } });
    })();
    """

    static var relay: String {
        """
        (function () {
          if (window.__broadwaySound) return;
          var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(MediaKeys.name);
          if (!relay) return;
          var picture = \(picture);
          var id = Math.random().toString(36).slice(2), page = null, timer = 0, sent = '', heard = false, reading = false;
          function audible(e) { return !e.muted && e.volume > 0; }
          function art(list) {
            var best = '', most = -1;
            for (var i = 0; i < list.length; i++) {
              var size = 0, sizes = String(list[i].sizes || '').split(/\\s+/);
              for (var j = 0; j < sizes.length; j++) {
                var wh = sizes[j].toLowerCase().split('x');
                if (wh.length === 2) size = Math.max(size, (+wh[0] || 0) * (+wh[1] || 0));
              }
              if (size >= most) { most = size; best = list[i].src || ''; }
            }
            return best;
          }
          function read() {
            page = null;
            reading = true;
            try { document.dispatchEvent(new CustomEvent('\(ask)')); } catch (e) {}
            reading = false;
            var told = null;
            try { told = page ? JSON.parse(page) : null; } catch (e) {}
            var r = { kind: 'sound', id: id, picture: false, sound: false, undecided: false };
            var all = document.querySelectorAll('audio, video');
            for (var i = 0; i < all.length; i++) {
              var e = all[i];
              if (e.paused || e.ended || !audible(e)) continue;
              if (e instanceof HTMLVideoElement) {
                if (e.readyState < 1) r.undecided = true;
                else if (picture(e)) r.picture = true;
                else r.sound = true;
              } else r.sound = true;
            }
            if (told && told.loose && told.audible) r.sound = true;
            r.reading = (told && told.reading) || null;
            r.refused = (told && told.refused) || 0;
            r.media = (told && told.media) || [];
            r.reported = (told && told.reported) || null;
            var s = navigator.mediaSession, m = s && s.metadata;
            if (m || (told && told.actions && told.actions.length)) {
              r.session = { title: (m && m.title) || '', artist: (m && m.artist) || '', album: (m && m.album) || '',
                art: m ? art(Array.from(m.artwork || [])) : '', actions: (told && told.actions) || [],
                state: (s && s.playbackState) || '' };
            }
            return r;
          }
          function post() {
            timer = 0;
            var r = read();
            if (!heard && !r.reading && !r.session && !r.picture && !r.sound) return;
            heard = true;
            var text = JSON.stringify(r);
            if (text === sent) return;
            sent = text;
            relay.postMessage(r);
          }
          function soon() { if (!timer) timer = setTimeout(post, 120); }
          window.__broadwaySound = { now: function () { sent = ''; post(); } };
          document.addEventListener('\(changed)', function (e) {
            if (typeof e.detail === 'string') page = e.detail;
            if (!reading) soon();
          }, true);
          ['play', 'pause', 'ended', 'ratechange', 'durationchange', 'loadedmetadata', 'loadeddata', 'resize', 'emptied', 'seeked', 'volumechange'].forEach(function (type) {
            document.addEventListener(type, soon, true);
          });
          window.addEventListener('pagehide', function () {
            if (!heard) return;
            sent = '';
            relay.postMessage({ kind: 'sound', id: id, gone: true });
          });
          window.addEventListener('pageshow', function (e) { if (e.persisted && heard) { sent = ''; soon(); } });
        })();
        """
    }

    @MainActor
    static func scripts() -> [WKUserScript] {
        [
            WKUserScript(source: hook, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page),
            WKUserScript(source: relay, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world),
        ]
    }

    static func act(_ action: String, _ value: Double = 0) -> String {
        "(function () { var s = navigator.mediaSession, f = s && s[Symbol.for('\(key)')]; return f ? f('\(action)', \(value.isFinite ? value : 0)) : ''; })()"
    }

    static let refresh = "window.__broadwaySound && window.__broadwaySound.now(); 0"
}
