import WebKit

enum PullPageState: String, Equatable {
    case draft, open, merged, closed
}

final class PullPageRelay: NSObject, WKScriptMessageHandler {
    static let name = "officePullState"

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let said = message.body as? String else { return }
        if said == PullPageRelay.acted {
            MainActor.assumeIsolated {
                guard let tab, let web = tab.built, web === message.webView, let url = web.url, PullPageRelay.item(url) else { return }
                tab.onPageActed?(tab, url)
            }
            return
        }
        guard let state = PullPageState(rawValue: said) else { return }
        MainActor.assumeIsolated {
            guard let tab, let web = tab.built, web === message.webView, let url = web.url,
                  PullPageRelay.pull(url) else { return }
            tab.onPullState?(tab, url, state)
        }
    }

    static func pull(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host()?.lowercased(), Address.withoutWWW(host) == "github.com" else { return false }
        let path = url.path().split(separator: "/")
        return path.count >= 4 && path[2] == "pull" && Int(path[3]) != nil
    }

    static func item(_ url: URL) -> Bool {
        guard url.scheme == "https" else { return false }
        return LiveIdentity.of(url.absoluteString) != url.absoluteString
    }

    static let again = "window.__officePullAgain && window.__officePullAgain()"

    static let acted = "acted"
    static let actedEvent = "__broadwayLiveActed"

    static let acts = """
    (function () {
      if (window.top !== window) return;
      var hub = /^(www\\.)?github\\.com$/.test(location.hostname), linear = /(^|\\.)linear\\.app$/.test(location.hostname);
      if (!hub && !linear) return;
      var tell = function () { try { document.dispatchEvent(new CustomEvent('\(actedEvent)')); } catch (e) {} };
      var quiet = /^\\/_private\\/|\\/preview|\\/stats|hydro|hovercard|\\/suggestions|\\/markdown|\\/_filter|\\/notifications\\/beta/;
      var acting = function (method, address, body) {
        method = String(method || 'GET').toUpperCase();
        if (method === 'GET' || method === 'HEAD' || method === 'OPTIONS') return false;
        var u; try { u = new URL(String(address), location.href); } catch (e) { return false; }
        if (hub) return u.host === location.host && !quiet.test(u.pathname);
        return /(^|\\.)linear\\.app$/.test(u.hostname) && typeof body === 'string' && /\\bmutation\\b/.test(body);
      };
      var plain = window.fetch;
      if (typeof plain === 'function') {
        window.fetch = function (input, init) {
          var made = plain.apply(this, arguments);
          try {
            var method = (init && init.method) || (input && typeof input === 'object' && input.method) || 'GET';
            var address = typeof input === 'string' ? input : input && (input.url || String(input));
            if (acting(method, address, init && init.body)) made.then(function (r) { if (r && r.ok) tell(); }, function () {});
          } catch (e) {}
          return made;
        };
      }
      var open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, address) {
        try { this.__broadwayAsked = [method, address]; } catch (e) {}
        return open.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function (body) {
        try {
          var asked = this.__broadwayAsked;
          if (asked && acting(asked[0], asked[1], body)) {
            this.addEventListener('loadend', function () { if (this.status >= 200 && this.status < 300) tell(); });
          }
        } catch (e) {}
        return send.apply(this, arguments);
      };
    })();
    """

    static let heard = """
    (function () {
      if (window.top !== window || !/^(www\\.)?github\\.com$|(^|\\.)linear\\.app$/.test(location.hostname)) return;
      var last = 0;
      document.addEventListener('\(actedEvent)', function () {
        var now = Date.now();
        if (now - last < 1500) return;
        last = now;
        try { webkit.messageHandlers.officePullState.postMessage('\(acted)'); } catch (e) {}
      }, true);
    })();
    """

    static let script = """
    (function () {
      if (window.top !== window || !/^(www\\.)?github\\.com$/.test(location.hostname)) return;
      var told = null, timer = null, waiting = null;
      var number = function () {
        var m = location.pathname.match(/^\\/[^\\/]+\\/[^\\/]+\\/pull\\/(\\d+)(\\/|$)/);
        return m ? m[1] : null;
      };
      var away = '.Popover, [popover], [role=dialog], [role=tooltip], .js-hovercard-content, [class*="Hovercard"], [class*="hovercard"]';
      var head = '[data-component^="PageHeader"] [data-component="StateLabel"], [data-component="PH_LeadingVisual"] [data-component="StateLabel"], '
        + '.gh-header-meta .State, .gh-header-sticky .State';
      var statuses = { pullOpened: 'open', pullMerged: 'merged', pullClosed: 'closed', draft: 'draft' };
      var words = { open: 'open', draft: 'draft', merged: 'merged', closed: 'closed' };
      var shown = function () {
        var n = number();
        if (!n || document.title.indexOf('#' + n) < 0) return null;
        var marks = document.querySelectorAll(head);
        for (var i = 0; i < marks.length; i++) {
          var mark = marks[i];
          if (mark.closest(away)) continue;
          var status = statuses[mark.getAttribute('data-status') || ''];
          if (status) return status;
          return words[(mark.textContent || '').replace(/\\s+/g, ' ').trim().toLowerCase()] || null;
        }
        return null;
      };
      var look = function () {
        timer = null;
        var path = location.pathname, state = shown();
        var seen = state ? path + ' ' + state : null;
        if (!seen || seen === told) { waiting = null; return; }
        if (waiting !== seen) { waiting = seen; timer = setTimeout(look, 700); return; }
        told = seen;
        waiting = null;
        try { webkit.messageHandlers.officePullState.postMessage(state); } catch (e) {}
      };
      var soon = function () { if (!timer) timer = setTimeout(look, 300); };
      window.__officePullAgain = function () { told = null; soon(); };
      new MutationObserver(soon).observe(document.documentElement, { childList: true, subtree: true, characterData: true, attributes: true, attributeFilter: ['data-status'] });
      soon();
    })();
    """
}
