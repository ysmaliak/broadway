import Foundation
import JavaScriptCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct VideoDefaultsTests {
    private func store() -> UserDefaults {
        let name = "video-defaults-\(UUID().uuidString)"
        let made = UserDefaults(suiteName: name) ?? .standard
        made.removePersistentDomain(forName: name)
        return made
    }

    private func player(host: String, wanted: Int?, released: Double = 0, kept: String? = nil) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, error in Issue.record("JS: \(error?.toString() ?? "?")") }
        context.setObject(kept, forKeyedSubscript: "kept" as NSString)
        context.evaluateScript("""
        var window = this;
        var location = { hostname: '\(host)' };
        var held = {};
        if (typeof kept === 'string') held['yt-player-quality'] = kept;
        var localStorage = {
          getItem: function (key) { return key in held ? held[key] : null; },
          setItem: function (key, value) { held[key] = String(value); },
          removeItem: function (key) { delete held[key]; }
        };
        function HTMLVideoElement() {}
        var heard = {};
        var document = { addEventListener: function (type, act) { heard[type] = act; } };
        var calls = [];
        function ask(height, levels, id, preferred) {
          var video = new HTMLVideoElement();
          var made = {
            getAvailableQualityLevels: function () { return levels; },
            getPreferredQuality: function () { return preferred || 'auto'; },
            getVideoData: function () { return { video_id: id }; },
            setPlaybackQualityRange: function (low, high) { calls.push(low + '-' + high + '@' + id); }
          };
          video.closest = function () { return made; };
          return { video: video, send: function () { heard['\(VideoQuality.event)']({ detail: String(height), target: video }); } };
        }
        """)
        context.evaluateScript(VideoQuality.page(hosts: YouTubeAds.hosts, wanted: wanted, released: released))
        return context
    }

    private func quality(_ context: JSContext) -> Int? {
        let found = context.evaluateScript("(function () { try { return JSON.parse(JSON.parse(held['yt-player-quality']).data).quality; } catch (e) { return -1; } })()")!
        return found.toInt32() < 0 ? nil : Int(found.toInt32())
    }

    @Test func choicesRoundTripAndReadTheStore() {
        let kept = store()

        for choice in VideoQuality.choices {
            #expect(VideoQuality.Choice(raw: choice.raw) == choice)
        }
        #expect(VideoQuality.Choice(raw: "1000") == nil)
        #expect(VideoQuality.choice(in: kept) == .site)
        #expect(VideoQuality.wanted(in: kept) == nil)
        kept.set("1440", forKey: VideoQuality.key)
        #expect(VideoQuality.wanted(in: kept) == 1440)
        kept.set("last", forKey: VideoQuality.key)
        #expect(VideoQuality.wanted(in: kept) == nil)
    }

    @Test func theLastPickIsKeptOutsidePrivateWindows() {
        let kept = store()
        kept.set("last", forKey: VideoQuality.key)

        VideoQuality.picked(1080, shy: false, in: kept)

        #expect(VideoQuality.wanted(in: kept) == 1080)
        VideoQuality.picked(720, shy: true, in: kept)
        #expect(VideoQuality.wanted(in: kept) == 1080)
        VideoQuality.picked(0, shy: false, in: kept)
        #expect(VideoQuality.wanted(in: kept) == nil)
    }

    @Test func aSpeedIsKeptPerSiteAndForgotten() {
        let kept = store()

        VideoSpeed.keep(1.5, for: "youtube.com", shy: false, in: kept)
        VideoSpeed.keep(1, for: "vimeo.com", shy: false, in: kept)
        VideoSpeed.keep(2, for: "private.example", shy: true, in: kept)
        VideoSpeed.keep(40, for: "fast.example", shy: false, in: kept)

        #expect(VideoSpeed.kept(for: "youtube.com", in: kept) == 1.5)
        #expect(VideoSpeed.kept(for: "vimeo.com", in: kept) == 1)
        #expect(VideoSpeed.kept(for: "example.com", in: kept) == nil)
        #expect(VideoSpeed.sites(in: kept).map(\.site) == ["vimeo.com", "youtube.com"])
        VideoSpeed.forget("vimeo.com", in: kept)
        #expect(VideoSpeed.sites(in: kept).map(\.site) == ["youtube.com"])
        VideoSpeed.forgetAll(in: kept)
        #expect(VideoSpeed.sites(in: kept).isEmpty)
    }

    @Test func switchedOffNothingIsUsedOrKept() {
        let kept = store()
        VideoSpeed.keep(1.5, for: "youtube.com", shy: false, in: kept)

        kept.set(false, forKey: VideoSpeed.key)
        VideoSpeed.keep(2, for: "youtube.com", shy: false, in: kept)

        #expect(VideoSpeed.kept(for: "youtube.com", in: kept) == nil)
        kept.set(true, forKey: VideoSpeed.key)
        #expect(VideoSpeed.kept(for: "youtube.com", in: kept) == 1.5)
    }

    @Test func aSiteIsItsHostWithoutWww() {
        #expect(VideoSpeed.site(of: URL(string: "https://www.youtube.com/watch?v=x")) == "youtube.com")
        #expect(VideoSpeed.site(of: URL(string: "https://music.youtube.com/")) == "music.youtube.com")
        #expect(VideoSpeed.site(of: URL(string: "file:///tmp/a.html")) == nil)
        #expect(VideoSpeed.site(of: nil) == nil)
    }

    @Test func theChoiceIsInThePlayersMemoryBeforeItStarts() {
        let fresh = player(host: "www.youtube.com", wanted: 1440)
        let elsewhere = player(host: "example.com", wanted: 1440)
        let left = player(host: "www.youtube.com", wanted: nil)

        #expect(quality(fresh) == 1440)
        #expect(quality(elsewhere) == nil)
        #expect(quality(left) == nil)
    }

    @Test func lettingYouTubeDecideDropsOnlyWhatWasKeptBefore() {
        let old = #"{"data":"{\"quality\":1440,\"previousQuality\":720}","expiration":9000000000000,"creation":1000}"#
        let new = #"{"data":"{\"quality\":720,\"previousQuality\":0}","expiration":9000000000000,"creation":3000}"#

        let dropped = player(host: "www.youtube.com", wanted: nil, released: 2000, kept: old)
        let stayed = player(host: "www.youtube.com", wanted: nil, released: 2000, kept: new)

        #expect(quality(dropped) == nil)
        #expect(quality(stayed) == 720)
    }

    @Test func aVideoGetsTheBestQualityAtOrBelowTheChoiceOnce() {
        let context = player(host: "www.youtube.com", wanted: 1440)

        context.evaluateScript("""
        var full = ask(1440, ['hd2160', 'hd1440', 'hd1080', 'auto'], 'a');
        full.send(); full.send();
        ask(1440, ['hd1080', 'hd720', 'auto'], 'b').send();
        ask(144, ['hd720', 'large', 'auto'], 'c').send();
        ask(1440, [], 'd').send();
        ask(1440, ['hd1440', 'auto'], 'e', 'hd1440').send();
        """)

        let calls = context.evaluateScript("calls.join(',')")!.toString()
        #expect(calls == "hd1440-hd1440@a,hd1080-hd1080@b,large-large@c")
    }

    private func speedPlayer(host: String) -> JSContext {
        let context = JSContext()!
        context.exceptionHandler = { _, error in Issue.record("JS: \(error?.toString() ?? "?")") }
        context.evaluateScript("""
        var window = this;
        var location = { hostname: '\(host)' };
        function HTMLVideoElement() {}
        var heard = {};
        var document = { addEventListener: function (type, act) { heard[type] = act; } };
        var told = [];
        function make(own, classes, rates) {
          var video = new HTMLVideoElement();
          video.playbackRate = own;
          var player = {
            own: own,
            classList: { contains: function (name) { return (classes || []).indexOf(name) >= 0; } },
            getAvailablePlaybackRates: function () { return rates || [0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]; },
            getPlaybackRate: function () { return player.own; },
            setPlaybackRate: function (rate) {
              told.push(rate);
              player.own = Math.min(Math.max(rate, 0.25), 2);
              video.playbackRate = player.own;
            }
          };
          video.closest = function () { return player; };
          video.player = player;
          return video;
        }
        function say(video, rate) {
          if (heard['\(Tempo.rateEvent)']) heard['\(Tempo.rateEvent)']({ detail: String(rate), target: video });
          return video.playbackRate + '/' + video.player.own;
        }
        """)
        context.evaluateScript(VideoSpeed.page(hosts: YouTubeAds.hosts))
        return context
    }

    @Test func youTubesPlayerIsToldTheSpeedBroadwaySets() {
        let context = speedPlayer(host: "www.youtube.com")

        let found = context.evaluateScript("""
        var one = make(1);
        [say(one, 1.6), say(one, 1.6), say(one, 2.5), say(one, 3), say(one, 2), say(one, 0.5),
         say(make(1, ['ad-showing']), 1.5), say(make(1, [], [1]), 1.5)].join(' ') + ' | ' + told.join(',')
        """)!.toString()

        #expect(found == "1.6/1.6 1.6/1.6 2.5/2 3/2 2/2 0.5/0.5 1/1 1.5/1 | 1.6,2,0.5")
    }

    @Test func anotherSitesPlayerIsToldNothing() {
        let context = speedPlayer(host: "example.com")

        let found = context.evaluateScript("say(make(1), 1.5) + ' | ' + told.length")!.toString()

        #expect(found == "1/1 | 0")
    }

    @Test func privateWindowsTakeNoKeptSpeedAndNoLastPick() {
        let kept = store()
        VideoSpeed.keep(1.5, for: "youtube.com", shy: false, in: kept)
        VideoQuality.picked(1080, shy: false, in: kept)

        #expect(VideoSpeed.kept(for: "youtube.com", shy: true, in: kept) == nil)
        #expect(VideoSpeed.kept(for: "youtube.com", shy: false, in: kept) == 1.5)
        kept.set("last", forKey: VideoQuality.key)
        #expect(VideoQuality.wanted(shy: true, in: kept) == nil)
        #expect(VideoQuality.wanted(shy: false, in: kept) == 1080)
        kept.set("1440", forKey: VideoQuality.key)
        #expect(VideoQuality.wanted(shy: true, in: kept) == 1440)
    }

    @Test func aClearForgetsSpeedsByTimeAndBySite() {
        let kept = store()
        let old = Date(timeIntervalSince1970: 1_000_000)
        let new = Date(timeIntervalSince1970: 2_000_000)
        VideoSpeed.keep(1.5, for: "youtube.com", shy: false, in: kept, now: old)
        VideoSpeed.keep(2, for: "music.youtube.com", shy: false, in: kept, now: new)
        VideoSpeed.keep(1.25, for: "vimeo.com", shy: false, in: kept, now: new)
        kept.set(1.75, forKey: VideoSpeed.prefix + "undated.example")
        VideoQuality.picked(1080, shy: false, in: kept, now: old)

        VideoSpeed.forget(since: Date(timeIntervalSince1970: 1_500_000), in: kept)
        VideoQuality.forgetLast(since: Date(timeIntervalSince1970: 1_500_000), in: kept)

        #expect(VideoSpeed.sites(in: kept).map(\.site) == ["youtube.com"])
        #expect(VideoQuality.last(in: kept) == 1080)
        VideoSpeed.keep(2, for: "music.youtube.com", shy: false, in: kept, now: new)
        VideoSpeed.keep(1.25, for: "notyoutube.com", shy: false, in: kept, now: new)
        VideoSpeed.forget(under: "www.youtube.com", in: kept)
        #expect(VideoSpeed.sites(in: kept).map(\.site) == ["notyoutube.com"])
        VideoQuality.forgetLast(in: kept)
        #expect(VideoQuality.last(in: kept) == nil)
        VideoSpeed.forgetAll(in: kept)
        #expect(!kept.dictionaryRepresentation().keys.contains { $0.hasPrefix(VideoSpeed.atPrefix) || $0.hasPrefix(VideoSpeed.prefix) })
    }

    @Test func leavingAFixedQualityReleasesWhatThePlayerWasGiven() {
        #expect(VideoQuality.releases(from: .height(1440), to: .site))
        #expect(VideoQuality.releases(from: .last, to: .site))
        #expect(VideoQuality.releases(from: .height(1440), to: .last))
        #expect(!VideoQuality.releases(from: .site, to: .last))
        #expect(!VideoQuality.releases(from: .site, to: .height(720)))
        #expect(!VideoQuality.releases(from: .height(1440), to: .height(720)))
    }

    @Test func bothRowsAreOnWebsitesAndAnswerTheCommandLine() {
        let rows = ["video.quality", "video.speed"].compactMap(SettingsIndex.item)

        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.group == "video" && $0.page == .websites && !$0.findOnly })
        #expect(SettingsIndex.find("playback speed").contains { $0.id == "video.speed" })
        #expect(SettingsIndex.find("1440p").contains { $0.id == "video.quality" })
    }
}
