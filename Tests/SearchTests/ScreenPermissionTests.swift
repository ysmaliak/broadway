import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ScreenPermissionTests {
    init() {
        keepSetting(Shared.prefs, \.siteNotifications, "notifications.ask")
    }

    @Test func screenWindowAndDenialNeverOpenPickerInTests() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.closeAll() }
        for choice in ["screen", "window", "no"] {
            var replies: [Int] = []
            ask(browser, tab, frame) { replies.append($0) }
            browser.shareScreen() // Clickjacking guard still applies.
            #expect(replies.isEmpty)
            try await Task.sleep(nanoseconds: 550_000_000)
            if choice == "screen" { browser.shareScreen() }
            else if choice == "window" { browser.shareWindow() }
            else { browser.denyShare() }
            browser.denyShare()
            #expect(replies == [0], "\(choice)")
            #expect(Browser.displayAnswered == (choice == "screen" ? 1 : choice == "window" ? 2 : 0))
            #expect(browser.asking == nil)
        }
    }

    @Test func pendingScreenCannotBeReplacedByOtherPermissions() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.closeAll() }
        browser.prefs.siteNotifications = true
        #expect(!tab.shy)
        #expect(tab.web.configuration.websiteDataStore.isPersistent)
        #expect(tab.web.url?.host == frame.securityOrigin.host)
        #expect(SiteNotifications.choices["https://screen.example"] == nil)
        var screen: [Int] = []
        ask(browser, tab, frame) { screen.append($0) }
        for type: WKMediaCaptureType in [.camera, .microphone, .cameraAndMicrophone] {
            var reply: WKPermissionDecision?
            browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: type) { reply = $0 }
            #expect(reply == .deny)
            #expect(browser.asking?.wants == "screen")
        }
        var location: WKPermissionDecision?
        browser.askedForLocation(tab.web, origin: frame.securityOrigin, frame: frame) { location = $0 }
        #expect(location == .deny)
        var notification: Bool?
        browser.askedForNotifications(tab.web, origin: frame.securityOrigin) { notification = $0 }
        #expect(notification == false)
        var second: [Int] = []
        ask(browser, tab, frame) { second.append($0) }
        #expect(second == [0])
        #expect(screen.isEmpty)
        #expect(browser.asking?.wants == "screen")
        browser.cancelDisplay()
        browser.askedForNotifications(tab.web, origin: frame.securityOrigin) { notification = $0 }
        #expect(browser.asking?.wants == "notifications")
    }

    @Test func cameraCardRefusesScreenRequest() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.closeAll() }
        browser.askedForCapture(tab.web, origin: frame.securityOrigin, frame: frame, type: .microphone) { _ in }
        var replies: [Int] = []
        ask(browser, tab, frame) { replies.append($0) }
        #expect(replies == [0])
        #expect(browser.asking?.wants == "microphone")
    }

    @Test func visibleRequestEndsOnSwitchNavigationCloseAndWindowClose() async throws {
        for event in ["switch", "navigate", "close", "window", "crash", "replace", "discard"] {
            let (browser, tab, frame) = try await fixture()
            var replies: [Int] = []
            ask(browser, tab, frame) { replies.append($0) }
            switch event {
            case "switch": browser.newTab()
            case "navigate":
                tab.web.loadHTMLString("<p>A different document</p>", baseURL: URL(string: "https://screen.example/next"))
                try await until { !replies.isEmpty }
            case "close": browser.close(tab)
            case "window": browser.closeAll()
            case "crash": browser.webViewWebContentProcessDidTerminate(tab.web)
            case "discard": tab.rest()
            default: browser.replace(tab, going: URL(string: "about:blank")!)
            }
            #expect(replies == [0], "\(event)")
            #expect(browser.asking == nil, "\(event)")
            browser.denyShare()
            browser.closeAll()
            #expect(replies == [0], "\(event) answers exactly once")
        }
    }

    @Test func backgroundRequestWaitsForItsTabAndCancelsBeforePresentation() async throws {
        for event in ["select", "navigate", "close", "rapid-switch", "move"] {
            let (browser, tab, frame) = try await fixture()
            browser.newTab()
            let other = try #require(browser.active)
            var replies: [Int] = []
            ask(browser, tab, frame) { replies.append($0) }
            #expect(browser.asking == nil)
            switch event {
            case "select": browser.select(tab)
            case "navigate": tab.web.loadHTMLString("<p>Next</p>", baseURL: URL(string: "https://screen.example/next"))
            case "close": browser.close(tab)
            case "move":
                let destination = Browser(record: WindowRecord())
                browser.moveToWindow(tab, destination)
                destination.closeAll()
            default: browser.select(tab); browser.select(other)
            }
            if event == "select" {
                try await until { browser.asking != nil }
                #expect(browser.asking?.wants == "screen")
                #expect(replies.isEmpty)
            } else {
                try await until { !replies.isEmpty }
                #expect(replies == [0], "\(event)")
                #expect(browser.asking == nil, "\(event)")
                #expect(browser.heldDialogs[tab.id]?.isEmpty ?? true)
            }
            browser.closeAll()
            #expect(replies == [0], "\(event)")
        }
    }

    @Test func completionCanRequestAgainWithoutLosingTheNewCard() async throws {
        let (browser, tab, frame) = try await fixture()
        defer { browser.closeAll() }
        var first: [Int] = [], next: [Int] = []
        ask(browser, tab, frame) { decision in
            first.append(decision)
            self.ask(browser, tab, frame) { next.append($0) }
        }
        browser.cancelDisplay()
        #expect(first == [0])
        #expect(next.isEmpty)
        #expect(browser.asking?.wants == "screen")
        browser.cancelDisplay()
        #expect(first == [0])
        #expect(next == [0])
    }

    @Test func unknownPageCannotRaiseAWindowCard() async throws {
        let (browser, _, frame) = try await fixture()
        defer { browser.closeAll() }
        let web = WKWebView(frame: .zero)
        var replies: [Int] = []
        browser.askedToShareScreen(web, origin: frame.securityOrigin, frame: frame,
                                  systemAudio: false) { replies.append($0) }
        #expect(replies == [0])
        #expect(browser.asking == nil)
    }

    @Test func closingTheLastWindowCancelsWithoutDiscardingItsTabs() async throws {
        let (browser, tab, frame) = try await fixture()
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        browser.window = window
        Browsers.register(browser)
        defer { browser.closeAll(); browser.window = nil }
        var replies: [Int] = []
        ask(browser, tab, frame) { replies.append($0) }
        Browsers.closing(window)
        #expect(browser.shut)
        #expect(browser.tabs.contains { $0 === tab })
        #expect(replies == [0])
        #expect(browser.asking == nil)
        #expect(!window.isVisible)
    }

    @Test func privateRequestNeverRemembersAndSplitFocusCancels() async throws {
        let (browser, tab, frame) = try await fixture(shy: true)
        defer { browser.closeAll() }
        let before = Store.settings.dictionaryRepresentation().filter { $0.key.hasPrefix("capture.") } as NSDictionary
        for _ in 0..<2 {
            var replies: [Int] = []
            ask(browser, tab, frame) { replies.append($0) }
            #expect(browser.asking?.wants == "screen")
            try await Task.sleep(nanoseconds: 550_000_000)
            browser.shareWindow()
            #expect(replies == [0])
            #expect(Browser.displayAnswered == 2)
        }
        #expect(before == (Store.settings.dictionaryRepresentation().filter { $0.key.hasPrefix("capture.") } as NSDictionary))
        browser.newTab()
        let other = try #require(browser.active)
        browser.prefs.splitView = true
        browser.pair(other, with: tab, onLeft: false)
        browser.select(tab)
        #expect(browser.activeSplit != nil)
        var replies: [Int] = []
        ask(browser, tab, frame) { replies.append($0) }
        browser.focusPane(other)
        #expect(replies == [0])
        #expect(browser.asking == nil)
    }

    private func until(seconds: TimeInterval = 15, _ done: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func ask(_ browser: Browser, _ tab: Tab, _ frame: WKFrameInfo, reply: @escaping (Int) -> Void) {
        // The local reply keeps even a broken implementation from opening the picker.
        browser.askedToShareScreen(tab.web, origin: frame.securityOrigin, frame: frame,
                                  systemAudio: false, decisionHandler: reply)
    }

    private func fixture(shy: Bool = false) async throws -> (Browser, Tab, WKFrameInfo) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        #expect(Store.testing)
        let browser = shy ? Browser(record: WindowRecord(), privateStore: .nonPersistent()) : Browser(record: WindowRecord())
        browser.forgetCaptureChoices()
        let tab = shy ? browser.makeTab() : Tab()
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        browser.select(tab)
        let receiver = FrameReceiver()
        let controller = tab.web.configuration.userContentController
        controller.add(receiver, name: "screenFixture")
        defer { controller.removeScriptMessageHandler(forName: "screenFixture") }
        tab.web.loadHTMLString("<script>webkit.messageHandlers.screenFixture.postMessage('ready')</script>",
                               baseURL: URL(string: "https://screen.example/"))
        try await until { receiver.frame != nil }
        if let frame = receiver.frame { return (browser, tab, frame) }
        Issue.record("WebKit fixture did not load")
        throw NSError(domain: "ScreenPermissionTests", code: 1)
    }
}

@MainActor
private final class FrameReceiver: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
}
