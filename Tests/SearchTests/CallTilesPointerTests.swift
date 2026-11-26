import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct CallTilesPointerTests {
    enum Kind: String, CaseIterable {
        case participant, video, canvas
    }

    private static let room = NSEdgeInsets(top: 8, left: 8, bottom: 58, right: 8)
    private static let pill = "<div class=pill><button aria-label=\"Pin\">p</button><button aria-label=\"More options\">o</button></div>"

    private static func tile(_ kind: Kind, _ number: Int) -> String {
        switch kind {
        case .participant: "<div class=tile data-participant-id=\"spaces/a/devices/\(number)\"><div class=face></div>\(pill)</div>"
        case .video: "<div class=tile><video muted playsinline></video>\(pill)</div>"
        case .canvas: "<div class=tile><canvas width=320 height=180></canvas>\(pill)</div>"
        }
    }

    private static func page(_ tiles: String) -> String {
        """
        <!doctype html><title>Call fixture</title><style>
        html, body { margin: 0; height: 100%; background: #202124; overflow: hidden; }
        .app { position: absolute; inset: 0; display: flex; flex-direction: column; }
        .stage { flex: 1; position: relative; }
        .grid { position: absolute; inset: 8px; display: flex; gap: 8px; }
        .tile { position: relative; flex: 1; background: #3c4043; border-radius: 10px; overflow: hidden; }
        .tile.wide { flex: 4; }
        .tile video, .tile canvas, .tile .face { position: absolute; inset: 0; width: 100%; height: 100%; }
        .pill { position: absolute; left: 50%; top: 50%; width: 140px; height: 45px; margin: -22px 0 0 -70px; border-radius: 23px; \
        background: rgba(32, 33, 36, 0.9); display: none; }
        .tile:hover .pill { display: flex; }
        .bar { height: 64px; flex: none; display: flex; justify-content: center; align-items: center; gap: 8px; }
        </style>
        <div class=app><div class=stage><div class=grid>\(tiles)</div></div>
        <div class=bar role=toolbar><button aria-label="Turn off microphone" data-is-muted=false \
        onclick="this.dataset.isMuted = this.dataset.isMuted === 'false' ? 'true' : 'false'">m</button>
        <button aria-label="Leave call">x</button></div></div>
        <script>
        window.hits = function () {
          return [].map.call(document.querySelectorAll('.tile'), function (el) {
            var r = el.getBoundingClientRect();
            var hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
            return !!(hit && hit.closest('.tile'));
          }).filter(Boolean).length;
        };
        </script>
        """
    }

    @Test(arguments: Kind.allCases)
    func theTilesOfAFloatingCallTakeNoPointerSoThePagesOwnPillNeverShows(kind: Kind) async throws {
        let (web, window) = try await load(Self.page((1...3).map { Self.tile(kind, $0) }.joined()))
        defer { window.close() }
        let found = try await web.evaluateJavaScript(CallTiles.enter(room: Self.room))
        #expect((found as? NSNumber)?.intValue == 3)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await number(web, "hits()") == 0)
        #expect(try await text(web, "getComputedStyle(document.querySelector('.pill')).pointerEvents") == "none")
    }

    @Test(arguments: Kind.allCases)
    func backInItsTabThePageHearsThePointerOnItsTilesAgain(kind: Kind) async throws {
        let (web, window) = try await load(Self.page((1...3).map { Self.tile(kind, $0) }.joined()))
        defer { window.close() }
        _ = try await web.evaluateJavaScript(CallTiles.enter(room: Self.room))
        _ = try await web.evaluateJavaScript(CallTiles.leave)
        try await Task.sleep(for: .milliseconds(100))
        #expect(try await number(web, "hits()") == 3)
        #expect(try await text(web, "getComputedStyle(document.querySelector('.pill')).pointerEvents") == "auto")
    }

    @Test func aSharedScreenInTheFloatTakesNoPointerEither() async throws {
        let tiles = "<div class=\"tile wide\" aria-label=\"Presentation\"><canvas width=1280 height=720></canvas>\(Self.pill)</div>"
            + Self.tile(.canvas, 2)
        let (web, window) = try await load(Self.page(tiles))
        defer { window.close() }
        _ = try await web.evaluateJavaScript(CallTiles.enter(room: Self.room))
        try await Task.sleep(for: .milliseconds(2100))
        let found = try await web.evaluateJavaScript(CallTiles.enter(room: Self.room))
        #expect(found as? String == "screen")
        try await Task.sleep(for: .milliseconds(100))
        let screen = "document.querySelector('[data-broadway-tiles-screen]')"
        let hit = "(function () { var r = \(screen).getBoundingClientRect(); var hit = document.elementFromPoint(r.left + r.width / 2, "
            + "r.top + r.height / 2); return !!(hit && hit.closest('.tile')); })()"
        #expect(try await web.evaluateJavaScript(hit) as? Bool == false)
        #expect(try await text(web, "getComputedStyle(\(screen)).pointerEvents") == "none")
    }

    @Test func broadwaysOwnButtonsStillPressThePageWhileItTakesNoPointer() async throws {
        let (web, window) = try await load(Self.page((1...3).map { Self.tile(.participant, $0) }.joined()))
        defer { window.close() }
        _ = try await web.evaluateJavaScript(CallTiles.enter(room: Self.room))
        let pressed = try await web.evaluateJavaScript(CallButtons.press(CallButtons.mic))
        #expect(pressed as? Bool == true)
        #expect(try await text(web, "document.querySelector('[aria-label^=\"Turn off microphone\"]').dataset.isMuted") == "true")
    }

    private func load(_ html: String) async throws -> (WKWebView, NSWindow) {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 640, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        web.loadHTMLString(html, baseURL: URL(string: "https://meet.example"))
        try await waitUntil("load") { web.title == "Call fixture" && !web.isLoading }
        return (web, window)
    }

    private func number(_ web: WKWebView, _ script: String) async throws -> Int {
        (try await web.evaluateJavaScript(script) as? NSNumber)?.intValue ?? -1
    }

    private func text(_ web: WKWebView, _ script: String) async throws -> String {
        try await web.evaluateJavaScript(script) as? String ?? ""
    }

    private func waitUntil(_ description: String, _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while try await condition() == false {
            guard Date() < deadline else {
                Issue.record("Timed out: \(description)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
