import WebKit

enum FloatFind {
    static let least = (width: 320.0, height: 180.0, share: 0.05, length: 60.0)

    static func look(strict: Bool) -> String {
        """
        (function () {
          var strict = \(strict ? "true" : "false");
          window.__officeFloatPick = null;
          var videos = document.querySelectorAll('video'), best = null, area = 0;
          var picture = \(MiniScripts.picture);
          for (var i = 0; i < videos.length; i++) {
            var v = videos[i];
            if ((v.paused && !v.hasAttribute('\(Tempo.holdMark)')) || v.ended || v.readyState < 2) continue;
            if (!picture(v)) continue;
            var box = v.getBoundingClientRect();
            if (strict) {
              if (v.muted || v.volume === 0) continue;
              if (v.duration < \(least.length)) continue;
              if (box.width < \(least.width) || box.height < \(least.height)) continue;
            }
            if (box.width * box.height >= area) { area = box.width * box.height; best = v; }
          }
          if (!best) return null;
          window.__officeFloatPick = best;
          var r = best.getBoundingClientRect(), path = [], w = window;
          try {
            while (w !== w.top) {
              var up = w.parent, at = -1;
              for (var j = 0; j < up.frames.length; j++) if (up.frames[j] === w) { at = j; break; }
              path.unshift(at);
              w = up;
            }
          } catch (e) { path = []; }
          return { width: r.width, height: r.height, path: path };
        })();
        """
    }

    static func carry(_ path: [Int]) -> String {
        """
        (function () {
          window.__officeFloatPick = null;
          var at = \(path.first ?? -1);
          if (at < 0 || at >= window.frames.length) return;
          var inner = window.frames[at], all = document.querySelectorAll('iframe, frame');
          for (var i = 0; i < all.length; i++) {
            if (all[i].contentWindow === inner) { window.__officeFloatPick = all[i]; return; }
          }
        })();
        """ + Isolate.on
    }

    static func sizeable(_ seen: Any?, in web: WKWebView, strict: Bool) -> [Int]? {
        guard let seen = seen as? [String: Any] else { return nil }
        let path = (seen["path"] as? [NSNumber] ?? []).map(\.intValue)
        guard strict else { return path }
        let zoom = max(web.pageZoom, 0.1)
        let width = (seen["width"] as? NSNumber)?.doubleValue ?? 0
        let height = (seen["height"] as? NSNumber)?.doubleValue ?? 0
        let page = Double(web.bounds.width * web.bounds.height)
        guard width >= least.width, height >= least.height,
              page <= 0 || width * height * zoom * zoom >= least.share * page else { return nil }
        return path
    }
}
