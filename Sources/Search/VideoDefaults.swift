import Foundation
import Observation
import WebKit

enum VideoQuality {
    static let key = "video.quality"
    static let lastKey = "video.quality.last"
    static let lastAtKey = "video.quality.last.at"
    static let releasedKey = "video.quality.released"
    static let event = "broadwayvideoquality"
    static let heights = [4320, 2160, 1440, 1080, 720, 480, 360, 240, 144]
    static let levels: [(name: String, height: Int)] = [
        ("highres", 4320), ("hd2880", 2880), ("hd2160", 2160), ("hd1440", 1440), ("hd1080", 1080),
        ("hd720", 720), ("large", 480), ("medium", 360), ("small", 240), ("tiny", 144),
    ]

    enum Choice: Equatable {
        case site
        case last
        case height(Int)

        init?(raw: String) {
            switch raw {
            case "site": self = .site
            case "last": self = .last
            default:
                guard let height = Int(raw), VideoQuality.heights.contains(height) else { return nil }
                self = .height(height)
            }
        }

        var raw: String {
            switch self {
            case .site: "site"
            case .last: "last"
            case .height(let height): String(height)
            }
        }

        var title: String {
            switch self {
            case .site: "Let YouTube Decide"
            case .last: "Last One I Picked"
            case .height(4320): "4320p (8K)"
            case .height(2160): "2160p (4K)"
            case .height(let height): "\(height)p"
            }
        }
    }

    static let choices: [Choice] = [.site, .last] + heights.map(Choice.height)
    static let takes = "site, last, or one of " + heights.map(String.init).joined(separator: ", ")

    static func choice(in store: UserDefaults = Store.settings) -> Choice {
        Choice(raw: store.string(forKey: key) ?? "") ?? .site
    }

    static func last(in store: UserDefaults = Store.settings) -> Int? {
        let kept = store.integer(forKey: lastKey)
        return kept > 0 ? kept : nil
    }

    static func wanted(shy: Bool = false, in store: UserDefaults = Store.settings) -> Int? {
        switch choice(in: store) {
        case .site: nil
        case .last: shy ? nil : last(in: store)
        case .height(let height): height
        }
    }

    static func picked(_ height: Int, shy: Bool, in store: UserDefaults = Store.settings, now: Date = Date()) {
        guard !shy else { return }
        if (100...9000).contains(height) {
            store.set(height, forKey: lastKey)
            store.set(now.timeIntervalSince1970, forKey: lastAtKey)
        } else {
            forgetLast(in: store)
        }
    }

    static func forgetLast(since date: Date = .distantPast, in store: UserDefaults = Store.settings) {
        let at = (store.object(forKey: lastAtKey) as? Double).map(Date.init(timeIntervalSince1970:))
        guard at.map({ $0 >= date }) ?? true else { return }
        store.removeObject(forKey: lastKey)
        store.removeObject(forKey: lastAtKey)
    }

    static func released(in store: UserDefaults = Store.settings) -> Double {
        store.double(forKey: releasedKey)
    }

    static func releases(from old: Choice, to new: Choice) -> Bool {
        switch (old, new) {
        case (.site, _), (_, .height): false
        case (_, .site): true
        case (.height, .last): true
        case (.last, .last): false
        }
    }

    static func release(in store: UserDefaults = Store.settings, now: Date = Date()) {
        store.set((now.timeIntervalSince1970 * 1000).rounded(), forKey: releasedKey)
    }

    static func page(hosts: [String], wanted: Int?, released: Double) -> String {
        let names = levels.map { "\($0.name): \($0.height)" }.joined(separator: ", ")
        return """
        (function () {
          'use strict';
          if (\(YouTubeAds.hostList(hosts)).indexOf(location.hostname) < 0) return;
          var wanted = \(wanted ?? 0), released = \(Int(released)), key = 'yt-player-quality';
          var heights = { \(names) };
          try {
            var kept = JSON.parse(localStorage.getItem(key) || 'null'), now = Date.now();
            if (wanted > 0) {
              var had = 0;
              try { had = +JSON.parse(kept.data).quality || 0; } catch (e) {}
              if (had !== wanted) {
                localStorage.setItem(key, JSON.stringify({
                  data: JSON.stringify({ quality: wanted, previousQuality: had }),
                  expiration: now + 31104000000, creation: now
                }));
              }
            } else if (released > 0 && kept && +kept.creation < released) {
              localStorage.removeItem(key);
            }
          } catch (e) {}
          var done = new WeakMap();
          document.addEventListener('\(event)', function (event) {
            try {
              var height = +event.detail, video = event.target;
              if (!(height > 0) || !(video instanceof HTMLVideoElement)) return;
              var player = video.closest('.html5-video-player');
              if (!player || typeof player.getAvailableQualityLevels !== 'function'
                  || typeof player.setPlaybackQualityRange !== 'function') return;
              var data = typeof player.getVideoData === 'function' ? player.getVideoData() : null;
              var mark = ((data && data.video_id) || video.currentSrc || '') + ':' + height;
              if (done.get(player) === mark) return;
              var levels = player.getAvailableQualityLevels() || [], best = null, lowest = null;
              for (var i = 0; i < levels.length; i++) {
                var one = heights[levels[i]];
                if (!one) continue;
                if (one <= height && (!best || one > heights[best])) best = levels[i];
                if (!lowest || one < heights[lowest]) lowest = levels[i];
              }
              var pick = best || lowest;
              if (!pick) return;
              done.set(player, mark);
              var now = typeof player.getPreferredQuality === 'function' ? player.getPreferredQuality() : null;
              if (now !== pick) player.setPlaybackQualityRange(pick, pick);
            } catch (e) {}
          }, true);
        })();
        """
    }

    @MainActor
    static func script(shy: Bool) -> WKUserScript {
        WKUserScript(source: page(hosts: YouTubeAds.hostsThisRun, wanted: wanted(shy: shy), released: released()),
                     injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
    }
}

enum VideoSpeed {
    static let key = "video.speed"
    static let prefix = "rate."
    static let atPrefix = "ratedAt."
    static let slowest = 0.1
    static let fastest = 16.0
    static let said = "window.__broadwayVideo && window.__broadwayVideo.said(); 0"
    static let audioLeast = 60

    static func on(in store: UserDefaults = Store.settings) -> Bool {
        store.object(forKey: key) as? Bool ?? true
    }

    static func site(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased()),
              let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func tidy(_ rate: Double) -> Double? {
        guard rate.isFinite, rate >= slowest - 1e-9, rate <= fastest + 1e-9 else { return nil }
        return (rate * 100).rounded() / 100
    }

    static func kept(for site: String, shy: Bool = false, in store: UserDefaults = Store.settings) -> Double? {
        guard !shy, on(in: store) else { return nil }
        return (store.object(forKey: prefix + site) as? Double).flatMap(tidy)
    }

    static func keep(_ rate: Double, for site: String, shy: Bool, in store: UserDefaults = Store.settings, now: Date = Date()) {
        guard !shy, on(in: store), let rate = tidy(rate) else { return }
        store.set(rate, forKey: prefix + site)
        store.set(now.timeIntervalSince1970, forKey: atPrefix + site)
    }

    static func sites(in store: UserDefaults = Store.settings) -> [(site: String, rate: Double)] {
        store.dictionaryRepresentation()
            .compactMap { key, value -> (site: String, rate: Double)? in
                guard key.hasPrefix(prefix), let rate = (value as? Double).flatMap(tidy) else { return nil }
                return (String(key.dropFirst(prefix.count)), rate)
            }
            .sorted { $0.site < $1.site }
    }

    static func forget(_ site: String, in store: UserDefaults = Store.settings) {
        store.removeObject(forKey: prefix + site)
        store.removeObject(forKey: atPrefix + site)
    }

    static func forgetAll(in store: UserDefaults = Store.settings) {
        for key in store.dictionaryRepresentation().keys where key.hasPrefix(prefix) || key.hasPrefix(atPrefix) {
            store.removeObject(forKey: key)
        }
    }

    static func covers(_ host: String, _ site: String) -> Bool {
        let bare = Address.withoutWWW(host.lowercased())
        return site == bare || site.hasSuffix("." + bare)
    }

    static func forget(under host: String, in store: UserDefaults = Store.settings) {
        for kept in sites(in: store) where covers(host, kept.site) {
            forget(kept.site, in: store)
        }
    }

    static func forget(since date: Date, in store: UserDefaults = Store.settings) {
        for kept in sites(in: store) {
            let at = (store.object(forKey: atPrefix + kept.site) as? Double).map(Date.init(timeIntervalSince1970:))
            if at.map({ $0 >= date }) ?? true { forget(kept.site, in: store) }
        }
    }

    static func page(hosts: [String]) -> String {
        """
        (function () {
          'use strict';
          if (\(YouTubeAds.hostList(hosts)).indexOf(location.hostname) < 0) return;
          document.addEventListener('\(Tempo.rateEvent)', function (event) {
            try {
              var video = event.target, rate = +event.detail;
              if (!(video instanceof HTMLVideoElement) || !(rate > 0)) return;
              var player = video.closest('.html5-video-player');
              if (!player || typeof player.setPlaybackRate !== 'function'
                  || typeof player.getPlaybackRate !== 'function') return;
              if (player.classList.contains('ad-showing') || player.classList.contains('ad-interrupting')) return;
              var low = 0.25, high = 2;
              try {
                var rates = player.getAvailablePlaybackRates();
                if (rates && rates.length) {
                  low = Math.min.apply(null, rates);
                  high = Math.max.apply(null, rates);
                }
              } catch (e) {}
              var near = Math.min(Math.max(rate, low), high);
              if (Math.abs(player.getPlaybackRate() - near) > 0.001) player.setPlaybackRate(near);
              if (Math.abs(video.playbackRate - rate) > 0.001) video.playbackRate = rate;
            } catch (e) {}
          }, true);
        })();
        """
    }

    @MainActor
    static func script() -> WKUserScript {
        WKUserScript(source: page(hosts: YouTubeAds.hostsThisRun), injectionTime: .atDocumentStart,
                     forMainFrameOnly: false, in: .page)
    }

    static func label(_ rate: Double) -> String {
        "\(rate.formatted(.number.precision(.fractionLength(0...2))))×"
    }

    static func line(_ rate: Double) -> String {
        "Videos open at \(label(rate))"
    }
}

@MainActor @Observable
final class VideoSpeedBook {
    static let shared = VideoSpeedBook()
    private(set) var turn = 0

    func changed() { turn += 1 }

    var sites: [(site: String, rate: Double)] {
        _ = turn
        return VideoSpeed.sites()
    }

    func forget(_ site: String) {
        VideoSpeed.forget(site)
        changed()
    }
}

enum VideoDefaults {
    static let name = "broadwayVideo"
    static let guardFor = 4000
    static let pushes = 6
    static let pressFor = 1500
    static let saidFor = 1000
    static let qualityAsks = 4

    static func watch(hosts: [String]) -> String {
        """
        (function () {
          'use strict';
          if (window.__broadwayVideo) return;
          var relay = window.webkit && webkit.messageHandlers && webkit.messageHandlers.\(name);
          if (!relay) return;
          if (/(^|\\.)(imasdk\\.googleapis\\.com|doubleclick\\.net|googlesyndication\\.com)$/.test(location.hostname)) return;
          var youtube = \(YouTubeAds.hostList(hosts)).indexOf(location.hostname) >= 0;
          var states = new WeakMap(), pressed = -Infinity, said = -Infinity;
          window.__broadwayVideo = { said: function () { said = performance.now(); } };
          function nothing() {}
          function state(video) {
            var held = states.get(video);
            if (!held) {
              held = { load: 0, since: 0, done: false, asking: false, wanted: null, guard: 0, pushes: 0, asks: 0, gave: false, before: 1 };
              states.set(video, held);
            }
            return held;
          }
          function tidy(rate) {
            return Math.abs(rate - 1.0001) < 0.00001 ? 1 : Math.round(rate * 100) / 100;
          }
          function advert(video) {
            return !!video.closest('.ad-showing, .ad-interrupting, .vjs-ad-playing, .vjs-ad-loading, .jw-flag-ads, .ima-ad-container');
          }
          function live(video) {
            if (video.duration === Infinity) return true;
            var player = video.closest('.html5-video-player');
            return !!player && (player.classList.contains('ytp-live') || !!player.querySelector('.ytp-time-display.ytp-live'));
          }
          function keeps(video) {
            return !video.loop && video.duration > 0 && !live(video) && !advert(video)
              && (video instanceof HTMLVideoElement || video.duration >= \(VideoSpeed.audioLeast));
          }
          function takes(video) {
            if (!keeps(video)) return false;
            if (!video.muted && video.volume > 0) return true;
            return youtube && !!video.closest('#movie_player') && !video.closest('ytd-video-preview, #video-preview');
          }
          function put(video, rate) {
            try { video.dispatchEvent(new CustomEvent('\(Tempo.rateEvent)', { detail: String(rate) })); } catch (e) {}
            if (Math.abs(video.playbackRate - rate) > 0.001) {
              try { video.playbackRate = rate; } catch (e) {}
            }
          }
          function consider(video) {
            var held = state(video);
            if (held.done || held.asking || !takes(video)) return;
            var load = held.load;
            held.asking = true;
            relay.postMessage({ kind: 'rate' }).then(function (rate) {
              held.asking = false;
              if (held.load !== load || held.done || !takes(video)) return;
              held.done = true;
              if (typeof rate !== 'number' || !(rate > 0)) return;
              held.wanted = rate;
              held.guard = performance.now() + \(guardFor);
              held.pushes = 0;
              held.before = tidy(video.playbackRate);
              if (Math.abs(held.before - rate) > 0.001) {
                held.gave = true;
                put(video, rate);
              }
            }, function () { held.asking = false; });
          }
          function settle(video) {
            var held = state(video);
            if (!held.gave || keeps(video)) return;
            held.gave = false;
            held.wanted = null;
            held.guard = 0;
            put(video, held.before);
          }
          function quality(video) {
            var held = state(video);
            if (!youtube || held.asks >= \(qualityAsks) || advert(video)) return;
            held.asks++;
            relay.postMessage({ kind: 'quality' }).then(function (height) {
              if (typeof height !== 'number' || !(height > 0)) return;
              try { video.dispatchEvent(new CustomEvent('\(VideoQuality.event)', { detail: String(height) })); } catch (e) {}
            }, nothing);
          }
          function began(event) {
            var video = event.target;
            if (!(video instanceof HTMLMediaElement)) return;
            var held = state(video);
            held.load++;
            held.since = performance.now();
            held.done = false;
            held.wanted = null;
            held.guard = 0;
            held.pushes = 0;
            held.asks = 0;
            held.gave = false;
          }
          document.addEventListener('emptied', began, true);
          document.addEventListener('loadstart', began, true);
          document.addEventListener('play', function (event) {
            if (event.target instanceof HTMLMediaElement) state(event.target).since = performance.now();
          }, true);
          ['loadedmetadata', 'loadeddata', 'canplay', 'playing'].forEach(function (type) {
            document.addEventListener(type, function (event) {
              if (!(event.target instanceof HTMLMediaElement)) return;
              settle(event.target);
              consider(event.target);
              quality(event.target);
            }, true);
          });
          ['durationchange', 'volumechange'].forEach(function (type) {
            document.addEventListener(type, function (event) {
              if (!(event.target instanceof HTMLMediaElement)) return;
              settle(event.target);
              consider(event.target);
            }, true);
          });
          document.addEventListener('ratechange', function (event) {
            var video = event.target;
            if (!(video instanceof HTMLMediaElement)) return;
            var held = state(video), now = performance.now(), rate = tidy(video.playbackRate);
            if (held.wanted !== null && Math.abs(rate - held.wanted) < 0.001) return;
            if (now - said < \(saidFor) || (pressed > held.since && now - pressed < \(pressFor))) {
              if (!keeps(video) || !(rate > 0)) return;
              held.done = true;
              held.wanted = rate;
              held.guard = 0;
              held.gave = false;
              relay.postMessage({ kind: 'rated', rate: rate }).then(nothing, nothing);
              return;
            }
            if (held.wanted !== null && now < held.guard && held.pushes < \(pushes) && takes(video)) {
              held.pushes++;
              put(video, held.wanted);
              return;
            }
            consider(video);
          }, true);
          ['pointerup', 'click', 'keydown', 'keyup', 'input', 'change'].forEach(function (type) {
            window.addEventListener(type, function (event) {
              if (event.isTrusted) pressed = performance.now();
            }, true);
          });
          if (youtube) {
            document.addEventListener('click', function (event) {
              if (!event.isTrusted || !(event.target instanceof Element)) return;
              var item = event.target.closest('.ytp-quality-menu .ytp-menuitem');
              if (!item) return;
              var found = /(\\d{3,4})p/.exec(item.textContent || '');
              relay.postMessage({ kind: 'picked', height: found ? +found[1] : 0 }).then(nothing, nothing);
            }, true);
          }
        })();
        """
    }

    @MainActor
    static func script() -> WKUserScript {
        WKUserScript(source: watch(hosts: YouTubeAds.hostsThisRun), injectionTime: .atDocumentStart,
                     forMainFrameOnly: false, in: Web.world)
    }
}

final class VideoRelay: NSObject, WKScriptMessageHandlerWithReply {
    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
    ) {
        MainActor.assumeIsolated {
            guard let tab, let web = tab.built, web === message.webView,
                  let body = message.body as? [String: Any]
            else { return replyHandler(nil, nil) }
            let site = VideoSpeed.site(of: web.url)
            let youtube = YouTubeAds.hostsThisRun.contains(message.frameInfo.securityOrigin.host)
            switch body["kind"] as? String {
            case "rate":
                replyHandler(site.flatMap { VideoSpeed.kept(for: $0, shy: tab.shy) }, nil)
            case "rated":
                if let site, let rate = (body["rate"] as? NSNumber)?.doubleValue {
                    VideoSpeed.keep(rate, for: site, shy: tab.shy)
                    VideoSpeedBook.shared.changed()
                }
                replyHandler(nil, nil)
            case "quality":
                replyHandler(youtube ? VideoQuality.wanted(shy: tab.shy) : nil, nil)
            case "picked":
                if youtube, let height = (body["height"] as? NSNumber)?.intValue {
                    VideoQuality.picked(height, shy: tab.shy)
                }
                replyHandler(nil, nil)
            default:
                replyHandler(nil, nil)
            }
        }
    }
}
