import Foundation

enum CallScreen {
    static let finding = """
    var named = /presentation|presenting|screen[-_ ]?shar|shar(e|ed|ing)[-_ ]?(screen|content|desktop)|screencast/i;
    function media() {
      return [].slice.call(document.querySelectorAll('video, canvas')).filter(function (el) { return el.tagName === 'VIDEO' ? sized(el) : big(el); });
    }
    function area(el) { return el.offsetWidth * el.offsetHeight; }
    function words(el) {
      var text = '';
      ['aria-label', 'title', 'alt', 'class', 'id'].forEach(function (n) { text += ' ' + (el.getAttribute(n) || ''); });
      [].forEach.call(el.attributes, function (a) {
        if (a.name.indexOf('data-') === 0 && a.name.indexOf('data-broadway') !== 0) text += ' ' + a.name + ' ' + a.value;
      });
      return text;
    }
    function labelled(el, wrap) {
      for (var at = el; at; at = at.parentElement) {
        if (named.test(words(at))) return true;
        if (at === wrap) break;
      }
      var said = (wrap.textContent || '').trim();
      return said.length > 0 && said.length <= 160 && named.test(said);
    }
    function display(el) {
      try {
        var stream = el.srcObject;
        return !!(stream && stream.getVideoTracks && stream.getVideoTracks().some(function (t) {
          return !!(t.getSettings && t.getSettings().displaySurface);
        }));
      } catch (e) { return false; }
    }
    function whole(el, all) {
      function fits(v) { return /contain|scale-down/.test(getComputedStyle(v).objectFit); }
      if (el.tagName !== 'VIDEO') return all.some(function (o) { return o.tagName === 'VIDEO'; });
      return fits(el) && !all.some(function (o) { return o !== el && o.tagName === 'VIDEO' && fits(o); });
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
    function shared() {
      var kept = window.__broadwayCallScreen;
      if (kept && alive(kept)) return kept.el;
      if (kept) {
        clear();
        drop('broadway-call-fit');
        root.setAttribute('data-broadway-tiles', '');
      }
      var all = media();
      var units = outer([].slice.call(document.querySelectorAll('[data-participant-id]')).concat(all));
      var best = null;
      all.forEach(function (el) {
        var size = area(el);
        if (!size) return;
        var unit = units.filter(function (u) { return u === el || u.contains(el); })[0] || el;
        var rest = units.filter(function (u) { return u !== unit; });
        var wrap = unit;
        while (wrap.parentElement && wrap.parentElement !== document.body && wrap.parentElement !== root
          && !rest.some(function (u) { return wrap.parentElement.contains(u); })) wrap = wrap.parentElement;
        var most = rest.reduce(function (a, u) { return Math.max(a, area(u)); }, 0);
        var sure = display(el) || labelled(el, wrap);
        var leads = rest.length >= 2 && size >= most * 3;
        var odd = whole(el, all);
        if (!(sure ? size >= most * 0.5 : leads && odd)) return;
        var score = (sure ? 2 : 0) + (leads ? 1 : 0) + (odd ? 1 : 0);
        if (!best || score > best.score || (score === best.score && size > best.size)) best = { el: el, score: score, size: size };
      });
      return best ? best.el : null;
    }
    """
}
