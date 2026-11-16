import AppKit
import JavaScriptCore
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TempoSpeedTests {
    @Test func stepsAreTenthsWithinHalfToThree() {
        var up: [Double] = [1]
        var down: [Double] = [1]

        for _ in 0..<25 { up.append(Tempo.next(from: up.last!, 1)) }
        for _ in 0..<8 { down.append(Tempo.next(from: down.last!, -1)) }

        #expect(up[1] == 1.1)
        #expect(up.last == 3)
        #expect(up.filter { $0 == 3 }.count == 6)
        #expect(down[1] == 0.9)
        #expect(down.last == 0.5)
        #expect(Tempo.next(from: 2.3, 0) == 1)
    }

    @Test func offGridRatesRoundToTheNearestTenth() {
        let nudged = 1.04, smoothed = 1.0001, picked = 1.75

        let fromNudge = Tempo.next(from: nudged, 1)
        let fromSmooth = Tempo.next(from: smoothed, -1)
        let fromPick = Tempo.next(from: picked, 1)

        #expect(fromNudge == 1.1)
        #expect(fromSmooth == 0.9)
        #expect(fromPick == 1.9)
        #expect(Tempo.next(from: .nan, 1) == 1.1)
        #expect(Tempo.label(1.1) == "1.1")
    }

    @Test func floatingVideoAcceptsTempoRatesAndShowsThem() {
        var rate = FloatRate()
        rate.polled(1, at: 0)

        let faster = rate.pick(Tempo.next(from: rate.value, 1), at: 1)
        let tooFast = rate.pick(3.5, at: 2)

        #expect(faster)
        #expect(!tooFast)
        #expect(rate.value == 1.1)
        #expect(FloatRate.label(rate.value) == "1.1×")
        #expect(Isolate.rate(1.1).contains("video.playbackRate = 1.1;"))
        #expect(Isolate.rate(3.5) == "null")
    }

    @Test func floatingVideoStepsFromATempoRateAboveItsList() {
        var rate = FloatRate()

        rate.polled(2.7, at: 0)

        #expect(rate.step(1) == 2.7)
        #expect(rate.step(-1) == 2)
        #expect(rate.step(1, wrapping: true) == 0.5)
    }

    @Test func floatingVideoReadsTempoKeysOnlyWhenTheSettingIsOn() {
        let codes: [UInt16] = [1, 2, 3]

        let on = codes.map { FloatCommand.read(code: $0, flags: [], tempo: true) }
        let off = codes.map { FloatCommand.read(code: $0, flags: [], tempo: false) }

        #expect(on == [.tempo(-1), .tempo(0), .tempo(1)])
        #expect(off.allSatisfy { $0 == nil })
        #expect(FloatCommand.read(code: 3, flags: [], repeated: true, tempo: true) == .tempo(1))
        #expect(FloatCommand.read(code: 2, flags: [], repeated: true, tempo: true) == nil)
        #expect(FloatCommand.read(code: 3, flags: .command, tempo: true) == nil)
        #expect(FloatCommand.read(code: 1, flags: .option, tempo: true) == nil)
    }

    @Test func tempoWritesGoThroughLiveRateInThePageWorld() {
        let context = JSContext()!
        context.evaluateScript("""
        var HTMLMediaElement = function () { this.real = 1; };
        Object.defineProperty(HTMLMediaElement.prototype, 'playbackRate', {
          get: function () { return this.real; },
          set: function (rate) { this.real = rate; }, configurable: true
        });
        var listeners = {};
        var document = { addEventListener: function (type, listener) { listeners[type] = listener; } };
        var video = new HTMLMediaElement();
        function tempo(rate) { listeners['\(Tempo.rateEvent)']({ target: video, detail: String(rate) }); }
        """)
        context.evaluateScript(LiveRate.script)

        context.evaluateScript("tempo(1.5); tempo(1)")
        let plain = context.evaluateScript("video.real")!.toDouble()
        context.evaluateScript("video.playbackRate = 1.04; tempo(1.1); tempo(1)")
        let afterNudge = context.evaluateScript("video.real")!.toDouble()
        context.evaluateScript("listeners['\(Tempo.rateEvent)']({ target: {}, detail: '2' }); tempo('x')")

        #expect(context.exception == nil)
        #expect(plain == 1)
        #expect(afterNudge == 1.0001)
        #expect(context.evaluateScript("video.playbackRate")!.toDouble() == 1)
    }

    @Test func theHUDSeparatorIsAPlainDot() {
        let script = Tempo.script

        let face = ["FACE_DOT", "tempo-face-dot", "<svg", "mask"].filter { script.contains($0) }

        #expect(face == [])
        #expect(script.contains("dotNode.textContent = \".\";"))
        #expect(script.contains("const HOLD_REPEAT_DELAY_MS = 180;"))
        #expect(script.contains("const HOLD_REPEAT_INTERVAL_MS = 100;"))
        #expect(!script.contains("chrome."))
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TempoHandOffTests {
    private func tempo(enabled: Bool) -> Installed {
        Installed(id: Tempo.extensionID, name: "Tempo", version: "1.0.1", enabled: enabled, fromStore: true, permissions: ["storage"])
    }

    private let other = Installed(id: String(repeating: "a", count: 32), name: "Other", version: "1", enabled: true, fromStore: true, permissions: [])

    @Test func anEnabledTempoIsTurnedOffOnceWhileTheKeysAreBuiltIn() {
        let installed = [other, tempo(enabled: true)]

        let first = Tempo.handOff(on: true, installed: installed, handedOff: false)
        let again = Tempo.handOff(on: true, installed: installed, handedOff: true)

        #expect(first == Tempo.extensionID)
        #expect(again == nil)
    }

    @Test func nothingIsTurnedOffWithoutAReason() {
        let off = [tempo(enabled: false)]
        let missing = [other]
        let on = [tempo(enabled: true)]

        let results = [
            Tempo.handOff(on: true, installed: off, handedOff: false),
            Tempo.handOff(on: true, installed: missing, handedOff: false),
            Tempo.handOff(on: false, installed: on, handedOff: false),
        ]

        #expect(results.allSatisfy { $0 == nil })
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TempoBadgeTests {
    private static let player = """
    <!doctype html><style>body { margin: 0 } #player { position: relative; width: 640px; height: 360px }
    video { display: block; width: 640px; height: 360px; background: black }
    #controls { position: absolute; inset: 0; z-index: 10 }</style>
    <div id=player><video></video><div id=controls></div></div><script>window.ready = true</script>
    """

    @Test func theSpeedBadgeNeverTakesThePointerFromTheVideo() async throws {
        let (web, window) = try await page()
        defer { window.close() }

        _ = try await web.evaluateJavaScript("document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', code: 'KeyD', bubbles: true }))",
                                             in: nil, contentWorld: .page)
        try await Task.sleep(nanoseconds: 100_000_000)
        let seen = try await web.callAsyncJavaScript("""
        const badge = window.__broadwayTempoBadge();
        if (!badge) return null;
        const box = badge.getBoundingClientRect();
        const parts = [badge, ...badge.querySelectorAll("*")];
        return {
          width: box.width,
          under: document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2)?.id ?? "",
          taking: parts.filter(part => getComputedStyle(part).pointerEvents !== "none").length,
          host: getComputedStyle(document.getElementById("tempo-hud-host")).pointerEvents
        };
        """, arguments: [:], in: nil, contentWorld: Web.world) as? [String: Any]

        let found = try #require(seen)
        #expect((found["width"] as? Double ?? 0) > 0, "the badge is up")
        #expect(found["under"] as? String == "controls", "a press on the badge reaches the site's controls under it")
        #expect(found["taking"] as? Int == 0, "nothing inside the badge takes a click, a hover or a scroll")
        #expect(found["host"] as? String == "none")
    }

    @Test func everyPointOverTheVideoReachesTheSiteAfterTheBadgeFades() async throws {
        let (web, window) = try await page()
        defer { window.close() }

        _ = try await web.evaluateJavaScript("document.body.dispatchEvent(new KeyboardEvent('keydown', { key: 'd', code: 'KeyD', bubbles: true }))",
                                             in: nil, contentWorld: .page)
        try await Task.sleep(nanoseconds: UInt64(Tempo.hudFor + 600) * 1_000_000)
        let seen = try await web.callAsyncJavaScript("""
        const host = document.getElementById("tempo-hud-host");
        const box = document.querySelector("video").getBoundingClientRect();
        const missed = [];
        for (let i = 0; i <= 16; i++) for (let j = 0; j <= 9; j++) {
          const x = box.left + 1 + (box.width - 2) * i / 16, y = box.top + 1 + (box.height - 2) * j / 9;
          const top = document.elementFromPoint(x, y);
          if (top?.id !== "controls") missed.push(`${Math.round(x)},${Math.round(y)} ${top?.id || top?.tagName}`);
        }
        return { shown: !!host, faded: host ? getComputedStyle(host).opacity : "", missed };
        """, arguments: [:], in: nil, contentWorld: Web.world) as? [String: Any]

        let found = try #require(seen)
        #expect(found["shown"] as? Bool == true, "the badge was put over the video")
        #expect(found["faded"] as? String == "0")
        #expect((found["missed"] as? [String]) == [], "every point over the video reaches the site's own layer")
    }

    private func page() async throws -> (WKWebView, NSWindow) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(
            WKUserScript(source: Tempo.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Web.world)
        )
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 500),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        web.loadHTMLString(Self.player, baseURL: URL(string: "https://video.test/"))
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript("window.ready")) as? Bool == true { return (web, window) }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        window.close()
        throw NSError(domain: "Tempo fixture did not load", code: 1)
    }
}
