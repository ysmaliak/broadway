import Foundation

enum CallScreen {
    static let finding = """
    var named = /presentation|presenting|screen[-_ ]?shar|shar(e|ed|ing)[-_ ]?(screen|content|desktop)|screencast/i;
    var controls = 'button, [role=button], [role=menu], [role=tooltip], [aria-hidden=true], i, svg, [class*=icon], [class*=Icon], [class*=symbol], [class*=Symbol]';
    var hold = 2000;
    var reason = '';
    function media() {
      return [].slice.call(document.querySelectorAll('video, canvas')).filter(function (el) { return el.tagName === 'VIDEO' ? sized(el) : big(el); });
    }
    function area(el) { return el.offsetWidth * el.offsetHeight; }
    function tracks(el) {
      try {
        var stream = el.srcObject;
        return stream && stream.getVideoTracks ? stream.getVideoTracks() : [];
      } catch (e) { return []; }
    }
    function settings(t) {
      try { return (t.getSettings && t.getSettings()) || {}; } catch (e) { return {}; }
    }
    function display(el) {
      return tracks(el).some(function (t) { return !!settings(t).displaySurface; });
    }
    function own(el) {
      return !display(el) && tracks(el).some(function (t) { var s = settings(t); return !!s.deviceId && !s.displaySurface; });
    }
    function cropped(el, unit) {
      for (var at = el; at; at = at.parentElement) {
        if (at.getAttribute('data-layout') === 'roi-crop') return true;
        if (at === unit) break;
      }
      return false;
    }
    function camera(el) {
      if (el.tagName !== 'VIDEO') return false;
      var w = el.videoWidth || 0, h = el.videoHeight || 0;
      if (!w || !h) return true;
      if (Math.min(w, h) > 720) return false;
      var r = Math.max(w, h) / Math.min(w, h);
      return [16 / 9, 4 / 3, 1].some(function (k) { return Math.abs(r - k) <= k * 0.02; });
    }
    function whole(el, all) {
      function fits(v) { return /contain|scale-down/.test(getComputedStyle(v).objectFit); }
      if (el.tagName !== 'VIDEO') return all.some(function (o) { return o.tagName === 'VIDEO'; });
      return fits(el) && !all.some(function (o) { return o !== el && o.tagName === 'VIDEO' && fits(o); });
    }
    function wrapOf(unit, rest) {
      var wrap = unit;
      while (wrap.parentElement && wrap.parentElement !== document.body && wrap.parentElement !== root
        && !rest.some(function (u) { return wrap.parentElement.contains(u); })) wrap = wrap.parentElement;
      return wrap;
    }
    function words(el) {
      var list = [];
      ['aria-label', 'title', 'alt', 'id'].forEach(function (n) { var v = el.getAttribute(n); if (v) list.push(v); });
      (el.getAttribute('class') || '').split(/\\s+/).forEach(function (c) { if (c) list.push(c); });
      [].forEach.call(el.attributes, function (a) {
        if (a.name.indexOf('data-') !== 0 || a.name.indexOf('data-broadway') === 0) return;
        list.push(a.name);
        if (a.value) list.push(a.value);
      });
      return list;
    }
    function path(unit, units, all) {
      var wrap = wrapOf(unit, units.filter(function (u) { return u !== unit; }));
      var starts = all.filter(function (m) { return m === unit || unit.contains(m); });
      if (!starts.length) starts = [unit];
      var list = [];
      starts.forEach(function (m) {
        for (var at = m; at; at = at.parentElement) {
          if (list.indexOf(at) < 0) list.push(at);
          if (at === wrap) break;
        }
      });
      return list;
    }
    function said(wrap) {
      var text = '';
      var walk = document.createTreeWalker(wrap, NodeFilter.SHOW_TEXT);
      for (var n = walk.nextNode(); n; n = walk.nextNode()) {
        var p = n.parentElement;
        if (p && p.closest(controls)) continue;
        text += ' ' + n.nodeValue;
      }
      return text.replace(/\\s+/g, ' ').trim();
    }
    function labelled(el, unit, units, all) {
      var theirs = {};
      units.forEach(function (u) {
        if (u === unit) return;
        path(u, units, all).forEach(function (at) { words(at).forEach(function (w) { theirs[w] = true; }); });
      });
      var mine = path(unit, units, all).filter(function (at) { return at === el || at.contains(el); });
      for (var i = 0; i < mine.length; i++) {
        if (words(mine[i]).some(function (w) { return !theirs[w] && named.test(w); })) return true;
      }
      var text = said(wrapOf(unit, units.filter(function (u) { return u !== unit; })));
      return text.length > 0 && text.length <= 160 && named.test(text);
    }
    function alive(kept) {
      var el = kept.el;
      if (!el || !el.isConnected || !el.getClientRects().length) return false;
      if (el.tagName !== 'VIDEO') return true;
      if ((el.srcObject || null) !== kept.stream || (el.currentSrc || '') !== kept.src || el.ended) return false;
      var stream = el.srcObject;
      if (!stream || !stream.getVideoTracks) return true;
      var tracks = stream.getVideoTracks();
      return tracks.length > 0 && tracks.some(function (t) { return t.readyState !== 'ended'; });
    }
    function leads(unit, units, why) {
      var rest = units.filter(function (u) { return u !== unit; });
      var most = rest.reduce(function (a, u) { return Math.max(a, area(u)); }, 0);
      return why === 'label' ? rest.length >= 1 && area(unit) >= most * 2 : rest.length >= 2 && area(unit) >= most * 3;
    }
    function shared() {
      var state = window.__broadwayCallPick;
      if (!state) state = window.__broadwayCallPick = { el: null, since: 0, lost: 0, dropped: [] };
      var now = performance.now();
      var all = media();
      var units = outer([].slice.call(document.querySelectorAll('[data-participant-id]')).concat(all));
      function unitOf(el) { return units.filter(function (u) { return u === el || u.contains(el); })[0] || el; }
      function gone(el, unit) {
        return state.dropped.some(function (d) { return d === el || d === unit || d.contains(el) || unit.contains(d); });
      }
      var kept = window.__broadwayCallScreen;
      if (kept && alive(kept)) {
        var why = kept.el.getAttribute('data-broadway-tiles-screen') || '';
        var unit = unitOf(kept.el);
        if (why === 'display' || unit === kept.el || leads(unit, units, why)) {
          state.lost = 0;
          reason = why;
          return kept.el;
        }
        if (!state.lost) state.lost = now;
        if (now - state.lost < hold) {
          reason = why;
          return kept.el;
        }
        state.dropped.push(kept.el, unit);
      }
      state.lost = 0;
      if (kept) {
        clear();
        drop('broadway-call-fit');
        root.setAttribute('data-broadway-tiles', '');
      }
      var best = null;
      all.forEach(function (el) {
        var size = area(el);
        if (!size) return;
        var unit = unitOf(el);
        if (gone(el, unit) || own(el) || cropped(el, unit)) return;
        var rest = units.filter(function (u) { return u !== unit; });
        var most = rest.reduce(function (a, u) { return Math.max(a, area(u)); }, 0);
        var why = '';
        if (display(el)) {
          if (size >= most * 0.5) why = 'display';
        } else if (leads(unit, units, 'label') && labelled(el, unit, units, all)) {
          why = 'label';
        } else if (rest.length >= 2 && size >= most * 3 && whole(el, all) && !camera(el)) {
          why = 'guess';
        }
        if (!why) return;
        var score = { display: 3, label: 2, guess: 1 }[why];
        if (!best || score > best.score || (score === best.score && size > best.size)) best = { el: el, score: score, size: size, why: why };
      });
      if (!best) {
        state.el = null;
        return null;
      }
      if (best.why !== 'display') {
        if (state.el !== best.el) {
          state.el = best.el;
          state.since = now;
        }
        if (now - state.since < hold) return null;
      }
      reason = best.why;
      return best.el;
    }
    function tell(lone, grid) {
      if (lone) {
        if (lone.getAttribute('data-broadway-tiles-screen') !== reason) lone.setAttribute('data-broadway-tiles-screen', reason);
        root.removeAttribute('data-broadway-tiles-found');
        return;
      }
      var found = find(grid);
      var people = found.length || (/^(VIDEO|CANVAS)$/.test(grid.tagName) ? 1 : 0);
      if (root.getAttribute('data-broadway-tiles-found') !== String(people)) root.setAttribute('data-broadway-tiles-found', String(people));
      var least = found.reduce(function (a, p) {
        var r = p.getBoundingClientRect();
        return r.width * r.height > 0 && (!a || r.width * r.height < a.width * a.height) ? r : a;
      }, null);
      if (!least) return;
      [].forEach.call(grid.querySelectorAll('button, [role=button], [role=menu], [role=tooltip]'), function (el) {
        if (el.hasAttribute('data-broadway-tiles-chrome') || el.closest('[data-participant-id]')
          || el.querySelector('video, canvas, [data-participant-id]')) return;
        var r = el.getBoundingClientRect();
        if (r.width < least.width * 0.5 || r.height < least.height * 0.5) el.setAttribute('data-broadway-tiles-chrome', '');
      });
    }
    """

    static let forget = """
    window.__broadwayCallPick = null;
    document.documentElement.removeAttribute('data-broadway-tiles-found');
    """
}
