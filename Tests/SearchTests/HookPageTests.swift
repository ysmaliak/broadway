import AppKit
import Foundation
import Testing
import WebKit
@testable import Search

@MainActor
private final class FrameCatcher: NSObject, WKScriptMessageHandler {
    var frame: WKFrameInfo?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        frame = message.frameInfo
    }
}

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class HookPageTests {
    private let lab: HookLab
    private var browser: Browser!
    private var window: NSWindow!
    private var hooks: [UUID] = []
    private let port = Int.random(in: 41_000...48_000)
    private let catcher = FrameCatcher()

    init() throws {
        let lab = try HookLab("pages")
        self.lab = lab
        keepSetting(Shared.prefs, \.siteNotifications, "notifications.ask")
        addTeardownBlock { [self] in tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
    }

    private func tearDown() {
        browser.cancelCapture()
        for id in hooks { HookBook.shared.remove(id) }
        for kind in ["location", "0", "notifications"] { Store.settings.removeObject(forKey: "capture.\(site)|\(kind)") }
        lab.close()
        window.contentView = nil
        window.close()
        browser.closeAll()
        browser = nil
    }

    private var site: String { "http://localhost:\(port)" }

    private func hook(answer: String) throws {
        let body = "request=$(cat)\nprintf '%s' \"$request\" > '\(lab.path("asked.in"))'\ncase \"$request\" in\n  *'\"site\":\"\(site)\"'*) echo '\(answer)' ;;\n  *) echo '{}' ;;\nesac"
        let program = try lab.program("site-requests", body)
        let made = try #require(HookBook.shared.add(.permission, program: program))
        hooks.append(made.id)
    }

    private func page() async throws -> (WKWebView, WKFrameInfo) {
        let configuration = Web.configuration(space: browser.spaceID)
        configuration.userContentController.add(catcher, name: "hooklab")
        let tab = Tab(configuration: configuration)
        browser.prepare(tab)
        browser.insert(tab, at: browser.tabs.count)
        browser.select(tab)
        let web = tab.web
        window.contentView = web
        web.loadHTMLString("<title>Where</title><script>webkit.messageHandlers.hooklab.postMessage('here')</script>",
                           baseURL: URL(string: site + "/"))
        #expect(await hookSoon { self.catcher.frame != nil && !web.isLoading })
        let frame = try #require(catcher.frame)
        return (web, frame)
    }

    private func location(_ web: WKWebView, _ frame: WKFrameInfo) async -> WKPermissionDecision? {
        var said: WKPermissionDecision?
        browser.askedForLocation(web, origin: frame.securityOrigin, frame: frame) { said = $0 }
        _ = await hookSoon(4) { said != nil || self.browser.asking != nil }
        return said
    }

    @Test func aPermissionHookAllowsAPagesRequestForTheLocationAndTheAnswerIsNotKept() async throws {
        try hook(answer: #"{"answer": "allow"}"#)
        let (web, frame) = try await page()

        _ = await location(web, frame)

        #expect(lab.json("asked.in")?["wants"] as? [String] == ["location"])
        #expect(Browser.locationAnswered == "granted")
        #expect(browser.asking == nil)
        #expect(Store.settings.object(forKey: "capture.\(site)|location") == nil)
    }

    @Test func aPermissionHookRefusesAPagesRequestForTheCamera() async throws {
        try hook(answer: #"{"answer": "deny"}"#)
        let (web, frame) = try await page()
        var said: WKPermissionDecision?

        browser.askedForCapture(web, origin: frame.securityOrigin, frame: frame, type: .camera) { said = $0 }

        #expect(await hookSoon(4) { said != nil })
        #expect(said == .deny)
        #expect(lab.json("asked.in")?["wants"] as? [String] == ["camera"])
        #expect(browser.asking == nil)
        #expect(Store.settings.object(forKey: "capture.\(site)|0") == nil)
    }

    @Test func aPermissionHookThatAnswersNothingLeavesTheQuestionToThePerson() async throws {
        try hook(answer: "{}")
        let (web, frame) = try await page()

        let said = await location(web, frame)

        #expect(said == nil)
        #expect(lab.exists("asked.in"))
        #expect(browser.asking?.wants == "location")
    }

    @Test func limit8AHookCannotAnswerForASiteThePersonAlreadyAnsweredFor() async throws {
        Store.settings.set(false, forKey: "capture.\(site)|location")
        try hook(answer: #"{"answer": "allow"}"#)
        let (web, frame) = try await page()

        _ = await location(web, frame)

        #expect(!lab.exists("asked.in"))
        #expect(Browser.locationAnswered == "denied")
    }

    @Test func limit8AHookCannotAllowNotificationsWhenSettingsForbidThemForEverySite() async throws {
        browser.prefs.siteNotifications = false
        try hook(answer: #"{"answer": "allow"}"#)
        let (web, frame) = try await page()
        var said: Bool?

        browser.askedForNotifications(web, origin: frame.securityOrigin) { said = $0 }

        #expect(await hookSoon(4) { said != nil })
        #expect(said == false)
        #expect(!lab.exists("asked.in"))
    }

    @Test func aPermissionHookAllowsNotificationsOnceWithoutKeepingTheAnswer() async throws {
        browser.prefs.siteNotifications = true
        try hook(answer: #"{"answer": "allow"}"#)
        let (web, frame) = try await page()
        var said: Bool?

        browser.askedForNotifications(web, origin: frame.securityOrigin) { said = $0 }

        #expect(await hookSoon(4) { said != nil })
        #expect(said == true)
        #expect(lab.json("asked.in")?["wants"] as? [String] == ["notifications"])
        #expect(SiteNotifications.choices[site] == nil)
    }

    @Test func limit2APermissionInAnAgentsTabRaisesNoEvent() async throws {
        try hook(answer: #"{"answer": "allow"}"#)
        let (web, frame) = try await page()
        let tab = try #require(browser.tabs.first { $0.built === web })
        tab.agent = true
        defer { tab.agent = false }

        let said = await location(web, frame)

        #expect(said == nil)
        #expect(!lab.exists("asked.in"))
    }
}
