import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentPageRoomTests {
    private let task = UUID()
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!

    private static let page = """
    <!doctype html><title>Seed Shelf</title>
    <style>#card{width:200px;height:60px;background:rgb(0,90,200)}#card:hover{background:rgb(220,40,40)}</style>
    <div id="card" role="button" tabindex="0" aria-label="Seed card">Seed card</div>
    <label>Season <select id="season"><option>Spring</option><option>Autumn</option></select></label>
    <label>Sowing day <input id="day" type="date"></label>
    <button id="add" onclick="document.body.dataset.added = Number(document.body.dataset.added || 0) + 1">Add a packet</button>
    <script>var painted = 0; (function frame() { painted++; document.documentElement.dataset.painted = painted; requestAnimationFrame(frame); })();</script>
    """

    init() async throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        server = try LocalPageServer(["/page": .init(type: "text/html", body: Self.page)])
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        AgentDesk.shared.drop(task: task)
        server?.stop()
        browser?.closeAll()
        browser = nil
    }

    private func open() async throws -> (tab: Tab, id: String) {
        _ = await box.call("open", ["url": server.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id, "selector": "#add"], task: task)
        return (tab, id)
    }

    private func ref(_ tab: Tab, _ name: String) async throws -> String {
        let captured = await PageSelection.run(tab, AgentPage.snapshotScript, AgentPage.snapshotArguments)
        let items = try #require((captured as? [String: Any])?["items"] as? [[String: Any]])
        return try #require(items.first { ($0["name"] as? String ?? "").contains(name) }?["ref"] as? String)
    }

    private func frames(_ tab: Tab) async -> Int {
        (await PageSelection.run(tab, "return document.documentElement.dataset.painted || '0';") as? String).flatMap { Int($0) } ?? 0
    }

    @Test func theRoomNeverComesOntoAScreen() {
        let room = AgentPageRoom.make()
        defer { room.close() }

        room.orderFront(nil)
        room.orderBack(nil)
        room.orderFrontRegardless()
        room.makeKeyAndOrderFront(nil)
        room.order(.above, relativeTo: 0)
        room.makeKey()
        room.makeMain()

        #expect(!room.isVisible)
        #expect(!room.canBecomeKey)
        #expect(!room.canBecomeMain)
        #expect(room.isExcludedFromWindowsMenu)
        #expect(room.collectionBehavior.contains(.transient))
        #expect(room.collectionBehavior.contains(.ignoresCycle))
        #expect(NSApp.keyWindow !== room)
    }

    @Test func anUnseenPageIsBuiltToCountAsSeen() {
        let plain = WKWebViewConfiguration()

        let unseen = AgentPageRoom.unseen(plain)
        let kept = WKWebView(frame: .zero, configuration: unseen)
        let ordinary = WKWebView(frame: .zero, configuration: plain)

        #expect(plain.responds(to: NSSelectorFromString("_setBackgroundTextExtractionEnabled:")))
        #expect(unseen !== plain)
        #expect(AgentPageRoom.keepsAlive(kept))
        #expect(!AgentPageRoom.keepsAlive(ordinary))
    }

    @Test func anAgentPageLivesAwakeInARoomThatIsNeverShown() async throws {
        let (tab, id) = try await open()
        let room = try #require(tab.web.window as? AgentPageRoom)

        let seen = await PageSelection.run(tab, "return document.visibilityState;") as? String
        let before = await frames(tab)
        try await Task.sleep(for: .seconds(1))
        let after = await frames(tab)
        let shot = await box.call("screenshot", ["tab": id], task: task)

        #expect(!room.isVisible)
        #expect(AgentPageRoom.keepsAlive(tab.web))
        #expect(seen == "visible")
        #expect(after - before >= 10, "\(before) then \(after)")
        #expect(!shot.failed)
        #expect((shot.imagePNG?.count ?? 0) > 1000)
        #expect(!tab.web.configuration.preferences.isElementFullscreenEnabled)
    }

    @Test func hoverWorksInTheRoomWithoutShowingIt() async throws {
        let (tab, id) = try await open()
        let card = try await ref(tab, "Seed card")

        let hovered = await box.call("hover", ["tab": id, "ref": card], task: task)
        let colour = await PageSelection.run(tab, "return getComputedStyle(document.getElementById('card')).backgroundColor;") as? String

        #expect(!hovered.failed, "\(hovered.text ?? "")")
        #expect(colour == "rgb(220, 40, 40)")
        #expect(tab.web.window?.isVisible == false)
    }

    @Test func aPageTakenOutOfItsWindowGoesBackToTheRoom() async throws {
        let (tab, _) = try await open()
        let stage = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        stage.isReleasedWhenClosed = false
        defer { stage.close() }

        stage.contentView?.addSubview(tab.web)
        let shownMayFill = tab.web.configuration.preferences.isElementFullscreenEnabled
        tab.web.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(100))

        #expect(shownMayFill)
        #expect(tab.web.window is AgentPageRoom)
        #expect(tab.web.window?.isVisible == false)
        #expect(!tab.web.configuration.preferences.isElementFullscreenEnabled)
    }

    @Test func aTabThePersonKeptIsNotTakenBackToTheRoom() async throws {
        let (tab, _) = try await open()

        browser.keepAgentTab(tab)
        tab.web.removeFromSuperview()
        try await Task.sleep(for: .milliseconds(100))

        #expect(tab.web.window == nil)
    }

    @Test func aListBoxOrDatePickerIsNeverOpenedByAClickOrAKey() async throws {
        let (tab, id) = try await open()
        let season = try await ref(tab, "Season")
        let day = try await ref(tab, "Sowing day")

        let list = await box.call("click", ["tab": id, "ref": season], task: task)
        let picker = await box.call("click", ["tab": id, "ref": day], task: task)
        _ = await PageSelection.run(tab, "document.getElementById('season').focus(); return true;")
        let key = await box.call("press", ["tab": id, "key": "Space"], task: task)
        let chosen = await box.call("choose", ["tab": id, "ref": season, "value": "Autumn"], task: task)
        let value = await PageSelection.run(tab, "return document.getElementById('season').value;") as? String

        #expect(list.failed)
        #expect(list.text?.contains("Use choose") == true, "\(list.text ?? "")")
        #expect(picker.failed)
        #expect(picker.text?.contains("Use type") == true, "\(picker.text ?? "")")
        #expect(key.failed)
        #expect(!chosen.failed, "\(chosen.text ?? "")")
        #expect(value == "Autumn")
        #expect(ToolFailure.code(list.text ?? "") == "opens_window")
        #expect(ToolFailure.code(picker.text ?? "") == "opens_window")
        #expect(ToolFailure.retrySafe("opens_window", tool: "click"))
    }

    @Test func aPlainClickStillLandsInTheRoom() async throws {
        let (tab, id) = try await open()
        let add = try await ref(tab, "Add a packet")

        let clicked = await box.call("click", ["tab": id, "ref": add], task: task)
        try await Task.sleep(for: .milliseconds(300))
        let added = await PageSelection.run(tab, "return document.body.dataset.added || '0';") as? String

        #expect(!clicked.failed, "\(clicked.text ?? "")")
        #expect(added == "1")
        #expect(tab.web.window?.isVisible == false)
    }

    @Test func aHoverThisMacOSCannotKeepAliveSaysSoWithACode() {
        let said = "This macOS cannot hover over a page nobody is looking at. Ask the person to select the agent's tab in Broadway, then hover again."

        #expect(ToolFailure.code(said) == "unseen")
        #expect(ToolFailure.retrySafe("unseen", tool: "hover"))
    }
}
