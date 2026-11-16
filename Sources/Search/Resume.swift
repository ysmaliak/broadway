import Foundation
import WebKit

struct VideoSpot: Codable, Equatable, Sendable {
    var url: String
    var time: Double
    var duration: Double
    var src: String
    var score: Double
    var seen: Date

    static func page(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" || scheme == "file" else { return nil }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.fragment = nil
        return parts.string
    }
}

enum Resume {
    static let name = "broadwayResume"
    static let leastIn: Double = 10
    static let leastLeft: Double = 15
    static let sameLength: Double = 1
    static let siteResumed: Double = 3
    static let within: TimeInterval = 20
    static let settle = 1000
    static let every = 2000
    static let stale: TimeInterval = 15

    static func seek(saved: VideoSpot?, armedAt: Date?, page: String?, duration: Double, current: Double, now: Date = Date()) -> Double? {
        guard let saved, let armedAt, let page, saved.url == page else { return nil }
        guard now.timeIntervalSince(armedAt) <= within, now >= armedAt else { return nil }
        guard duration.isFinite, duration > 0, saved.duration.isFinite, abs(duration - saved.duration) <= sameLength else { return nil }
        guard saved.time > leastIn, saved.time < duration - leastLeft else { return nil }
        guard abs(current - saved.time) > siteResumed else { return nil }
        return saved.time
    }

    static func decides(saved: VideoSpot?, duration: Double) -> Bool {
        guard let saved, duration.isFinite else { return false }
        return abs(duration - saved.duration) <= sameLength
    }

    static func merge(_ old: VideoSpot?, _ new: VideoSpot, replaced: Bool = false) -> VideoSpot? {
        guard new.duration.isFinite, new.duration > 0, new.time.isFinite, new.time >= 0 else { return old }
        guard let old, old.url == new.url, !replaced else { return new }
        if abs(old.duration - new.duration) <= sameLength || new.score >= old.score { return new }
        if new.seen.timeIntervalSince(old.seen) > stale { return new }
        return old
    }

    static func armed(_ spot: VideoSpot?, for url: URL?) -> VideoSpot? {
        guard let spot, let page = VideoSpot.page(url), spot.url == page else { return nil }
        return spot
    }

    static let script = """
    (function () {
      if (window.__broadwayResume) return;
      window.__broadwayResume = true;
      var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
      if (!relay) return;
      var played = new WeakSet(), last = 0, done = false, born = Date.now(), shown = null, shownSrc = '';
      function area(v) {
        var r = v.getBoundingClientRect();
        return Math.max(1, r.width * r.height);
      }
      function best() {
        var pick = null, score = 0;
        document.querySelectorAll('video').forEach(function (v) {
          if (!played.has(v) || !isFinite(v.duration) || !(v.duration > 0)) return;
          var s = v.duration * area(v);
          if (s > score) { score = s; pick = v; }
        });
        if (!pick) return null;
        var src = String(pick.currentSrc || pick.src || '');
        var replaced = !!shown && (pick === shown ? src !== shownSrc : !shown.isConnected);
        shown = pick;
        shownSrc = src;
        return { t: pick.currentTime, d: pick.duration, src: src.split(/[?#]/)[0].slice(0, 300), score: score, replaced: replaced };
      }
      function send(body) {
        try { var answer = relay.postMessage(body); if (answer && answer.catch) answer.catch(function () {}); return answer; } catch (e) { return null; }
      }
      function report(force) {
        var now = Date.now();
        if (!force && now - last < \(every)) return;
        var spot = best();
        if (!spot) return;
        last = now;
        spot.kind = 'spot';
        send(spot);
      }
      function heard(e) {
        var v = e.target;
        if (!(v instanceof HTMLVideoElement)) return;
        if (e.type === 'playing') played.add(v);
        if (played.has(v)) report(e.type !== 'timeupdate');
      }
      ['playing', 'timeupdate', 'pause', 'seeked', 'ended'].forEach(function (type) {
        document.addEventListener(type, heard, true);
      });
      window.addEventListener('pagehide', function () { report(true); }, true);
      document.addEventListener('visibilitychange', function () { if (document.hidden) report(true); }, true);
      function meta(e) {
        var v = e.target;
        if (done || Date.now() - born > \(Int(within + 10) * 1000) || !(v instanceof HTMLVideoElement) || !isFinite(v.duration) || !(v.duration > 0)) return;
        var answer = send({ kind: 'meta', d: v.duration, t: v.currentTime });
        if (!answer || !answer.then) return;
        answer.then(function (to) {
          if (typeof to !== 'number' || done) return;
          done = true;
          setTimeout(function () {
            if (Math.abs(v.currentTime - to) <= \(siteResumed)) return;
            try { v.currentTime = to; } catch (e) {}
          }, \(settle));
        }, function () {});
      }
      document.addEventListener('loadedmetadata', meta, true);
      document.addEventListener('durationchange', meta, true);
    })();
    """
}

final class ResumeRelay: NSObject, WKScriptMessageHandlerWithReply {
    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let tab, let web = tab.built, web === message.webView,
                  let body = message.body as? [String: Any],
                  let duration = (body["d"] as? NSNumber)?.doubleValue,
                  let time = (body["t"] as? NSNumber)?.doubleValue,
                  let page = VideoSpot.page(web.url)
            else { return replyHandler(nil, nil) }
            switch body["kind"] as? String {
            case "spot":
                let spot = VideoSpot(url: page, time: time, duration: duration, src: body["src"] as? String ?? "",
                                     score: (body["score"] as? NSNumber)?.doubleValue ?? 0, seen: Date())
                tab.videoSpot = Resume.merge(tab.videoSpot, spot, replaced: body["replaced"] as? Bool == true)
                replyHandler(nil, nil)
            case "meta":
                replyHandler(tab.resumeAnswer(page: page, duration: duration, current: time), nil)
            default:
                replyHandler(nil, nil)
            }
        }
    }
}
