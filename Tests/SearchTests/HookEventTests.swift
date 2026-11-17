import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class HookEventTests {
    private let lab: HookLab
    private var browser: Browser!
    private var window: NSWindow!
    private var first = UUID()
    private var second = UUID()
    private let store = LinkRules.shared

    init() throws {
        let lab = try HookLab("events")
        self.lab = lab
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        addTeardownBlock { [self] in tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesSpaces = true
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 600), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        first = browser.spaceID
        browser.addSpace(named: "Reading")
        second = browser.spaceID
        browser.switchSpace(to: first)
        store.replaceAll([])
        store.clearRecent()
        store.set { $0 = LinkSettings() }
    }

    private func tearDown() {
        lab.close()
        store.replaceAll([])
        store.clearRecent()
        store.set { $0 = LinkSettings() }
        browser.showLinkNotice(nil)
        if let space = browser.spaces.first(where: { $0.id == second }) {
            browser.spaces.removeAll { $0.id == space.id }
            Spaces.write(browser.spaces)
        }
        window.contentView = nil
        window.close()
        browser.closeAll()
        browser = nil
    }

    private func recorder(_ name: String, answer: String) throws -> URL {
        try lab.program(name, "cat > '\(lab.path(name + ".in"))'\necho '\(answer)'")
    }

    private func outside(_ text: String, chooses: Bool = false) -> IncomingLink {
        IncomingLink(url: URL(string: text)!, source: .app(bundleID: "com.example.mail", name: "Example Mail"), chooses: chooses)
    }

    private func arrive(_ link: IncomingLink, front: Browser? = nil) async -> LinkLanding? {
        var landing: LinkLanding?
        var delivered = false
        HookLinks.consider(link, front: front ?? browser, book: lab.book) { [browser] link in
            if let browser { landing = Browsers.place(link, from: browser) }
            delivered = true
        }
        _ = await hookSoon { delivered }
        return landing
    }

    @Test func aLinkHookSendsALinkToANamedSpace() async throws {
        try lab.add(.link, recorder("links", answer: #"{"space": "reading"}"#))
        let front = browser.space.name

        let landing = await arrive(outside("https://docs.example.com/guide?id=7"))

        #expect(landing != nil)
        #expect(browser.spaceID == second)
        let given = try #require(lab.json("links.in"))
        #expect(given["url"] as? String == "https://docs.example.com/guide?id=7")
        #expect(given["from"] as? String == "com.example.mail")
        #expect(given["space"] as? String == front)
    }

    @Test func aLinkHookCanSendALinkToAnotherApp() async throws {
        try lab.add(.link, recorder("apps", answer: #"{"app": "com.apple.TextEdit"}"#))
        let before = browser.tabs.count

        let landing = await arrive(outside("https://docs.example.com/notes.txt"))

        #expect(landing?.tab == nil)
        #expect(landing?.forward == false)
        #expect(browser.tabs.count == before)
    }

    @Test func thePersonsLinkRuleWinsOverAHook() async throws {
        store.add(LinkRule(match: .site("example.com"), target: .space(first, folder: nil)))
        try lab.add(.link, recorder("links", answer: #"{"space": "Reading"}"#))

        _ = await arrive(outside("https://docs.example.com/guide"))

        #expect(browser.spaceID == first)
        #expect(!lab.exists("links.in"))
    }

    @Test func aLinkHookWinsOverTheDefault() async throws {
        store.set { $0.outsideDefault = .space(first) }
        try lab.add(.link, recorder("links", answer: #"{"space": "Reading"}"#))

        _ = await arrive(outside("https://docs.example.com/guide"))

        #expect(browser.spaceID == second)
    }

    @Test func aLinkHookThatNamesASpaceThatDoesNotExistLeavesTheDefault() async throws {
        let hook = try lab.add(.link, recorder("links", answer: #"{"space": "Nowhere"}"#))

        _ = await arrive(outside("https://docs.example.com/guide"))

        #expect(browser.spaceID == first)
        #expect(lab.book.line(try #require(lab.book.hook(hook.id))) == "It named a space that doesn't exist: Nowhere")
    }

    @Test func holdingOptionStillLetsThePersonChoose() async throws {
        try lab.add(.link, recorder("links", answer: #"{"space": "Reading"}"#))
        var delivered: IncomingLink?

        HookLinks.consider(outside("https://docs.example.com/guide", chooses: true), front: browser, book: lab.book) { delivered = $0 }

        #expect(delivered?.hooked == nil)
        #expect(delivered?.chooses == true)
        #expect(!lab.exists("links.in"))
    }

    @Test func limit4ALinkWithAPrivateWindowInFrontRaisesNoEvent() async throws {
        try lab.add(.link, recorder("links", answer: #"{"space": "Reading"}"#))
        let quiet = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { quiet.closeAll() }
        var delivered: IncomingLink?

        HookLinks.consider(outside("https://docs.example.com/guide"), front: quiet, book: lab.book) { delivered = $0 }

        #expect(delivered != nil)
        #expect(delivered?.hooked == nil)
        #expect(!lab.exists("links.in"))
        #expect(HookGate.asked.isEmpty)
    }

    @Test func aLinkHookAnswerIsReadAsASpaceAPrivateWindowOrAnApp() {
        let spaces = [(id: first, name: "Personal"), (id: second, name: "Reading")]
        func read(_ object: [String: Any]) -> HookReading<HookLinkAnswer> {
            HookLinks.read(object, spaces: spaces, usesSpaces: true, broadway: "com.example.broadway") { $0 == "com.example.reader" ? "Reader" : nil }
        }

        guard case .answer(.space(second, "Reading")) = read(["space": "Reading"]) else { Issue.record("space"); return }
        guard case .answer(.privately) = read(["private": true]) else { Issue.record("private"); return }
        guard case .answer(.app("com.example.reader", "Reader")) = read(["app": "com.example.reader"]) else { Issue.record("app"); return }
        guard case .wrong = read(["app": "com.example.broadway"]) else { Issue.record("itself"); return }
        guard case .wrong = read(["app": "com.example.missing"]) else { Issue.record("missing app"); return }
        guard case .wrong = read(["space": "Reading", "app": "com.example.reader"]) else { Issue.record("two answers"); return }
    }

    @Test func aDownloadHookMovesAFinishedDownload() async throws {
        let downloads = lab.home.appendingPathComponent("Downloads")
        let invoices = lab.home.appendingPathComponent("Documents/Invoices")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: invoices, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent("invoice 42.pdf")
        try Data(repeating: 7, count: 1234).write(to: file)
        let loot = browser.loot
        loot.add(Keep(name: file.lastPathComponent, from: "billing.example.com", path: file.path, date: Date()))
        defer { loot.kept.filter { $0.path.hasPrefix(lab.folder.path) }.forEach(loot.forget) }
        try lab.add(.download, recorder("downloads", answer: #"{"folder": "~/Documents/Invoices"}"#))
        var moved: URL?
        var done = false

        HookDownloads.finished(file, site: "billing.example.com", scene: .outside, loot: loot, book: lab.book, home: lab.home) {
            moved = $0
            done = true
        }

        #expect(await hookSoon { done })
        let there = invoices.resolvingSymlinksInPath().appendingPathComponent("invoice 42.pdf")
        #expect(moved?.path == there.path)
        #expect(FileManager.default.fileExists(atPath: there.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(loot.kept.contains { $0.path == there.path })
        #expect(!loot.kept.contains { $0.path == file.path })
        let given = try #require(lab.json("downloads.in"))
        #expect(given["file"] as? String == file.path)
        #expect(given["site"] as? String == "billing.example.com")
        #expect(given["type"] as? String == "application/pdf")
        #expect(given["size"] as? Int == 1234)
    }

    @Test func aDownloadMovedBesideAFileOfTheSameNameGetsANumber() async throws {
        let shelf = lab.home.appendingPathComponent("Shelf")
        try FileManager.default.createDirectory(at: shelf, withIntermediateDirectories: true)
        try Data("kept".utf8).write(to: shelf.appendingPathComponent("notes.txt"))
        let file = lab.home.appendingPathComponent("notes.txt")
        try Data("new".utf8).write(to: file)
        try lab.add(.download, recorder("downloads", answer: #"{"folder": "~/Shelf"}"#))
        var moved: URL?
        var done = false

        HookDownloads.finished(file, site: "files.example.com", scene: .outside, loot: browser.loot, book: lab.book, home: lab.home) {
            moved = $0
            done = true
        }

        #expect(await hookSoon { done })
        #expect(moved?.lastPathComponent == "notes 2.txt")
        #expect(try String(contentsOf: shelf.appendingPathComponent("notes.txt"), encoding: .utf8) == "kept")
    }

    @Test func aDownloadHookCannotMoveAFileOutsideTheHomeFolder() async throws {
        let file = lab.home.appendingPathComponent("report.csv")
        try Data("a,b".utf8).write(to: file)
        let hook = try lab.add(.download, recorder("downloads", answer: #"{"folder": "/tmp"}"#))
        var done = false

        HookDownloads.finished(file, site: "files.example.com", scene: .outside, loot: browser.loot, book: lab.book, home: lab.home) { _ in
            done = true
        }

        #expect(await hookSoon { done })
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(lab.book.line(try #require(lab.book.hook(hook.id))) == "Its folder is outside your home folder")
    }

    @Test func aPermissionHookRefusesARequest() async throws {
        try lab.add(.permission, recorder("asks", answer: #"{"answer": "deny"}"#))

        let said = await lab.permission("https://meet.example.com", wants: ["camera", "microphone"])

        #expect(said == false)
        let given = try #require(lab.json("asks.in"))
        #expect(given["site"] as? String == "https://meet.example.com")
        #expect(given["wants"] as? [String] == ["camera", "microphone"])
    }

    @Test func aPermissionHookAllowsARequest() async throws {
        try lab.add(.permission, recorder("asks", answer: #"{"answer": "allow"}"#))

        let said = await lab.permission("https://maps.example.com", wants: ["location"])

        #expect(said == true)
    }

    @Test func aPermissionAnswerThatIsNeitherAllowNorDenyCountsAsNothing() async throws {
        let hook = try lab.add(.permission, recorder("asks", answer: #"{"answer": "maybe"}"#))

        let said = await lab.permission()

        #expect(said == nil)
        #expect(lab.book.line(try #require(lab.book.hook(hook.id))) == "Its answer wasn't allow or deny")
    }

    @Test func aTimerHookRunsWhenItsMinutesHavePassed() async throws {
        let start = Date()
        HookClock.reset(at: start)
        try lab.add(.timer, recorder("timer", answer: "{}"), minutes: 5)

        HookClock.tick(now: start.addingTimeInterval(4 * 60), book: lab.book)
        let early = HookGate.asked.count
        HookClock.tick(now: start.addingTimeInterval(5 * 60), book: lab.book)

        #expect(early == 0)
        #expect(await hookSoon { self.lab.exists("timer.in") })
        let given = try #require(lab.json("timer.in"))
        #expect(given["event"] as? String == "timer")
        #expect(given["minutes"] as? Int == 5)
        #expect(await hookSoon { self.lab.book.results.values.contains { $0.problem == nil } })
    }

    @Test func limit1TheCommandCanListHooksAndNothingMore() {
        let verbs = PersonCommands.table.filter { $0.noun == "hooks" }

        #expect(verbs.map(\.verb) == ["list"])
        #expect(verbs.first?.kind == .look)
        for verb in ["add", "on", "off", "enable", "approve", "remove", "set"] {
            #expect(PersonCommands.find("hooks", verb) == nil)
        }
    }

    @Test func limit1NoAgentOrMCPToolTouchesHooks() {
        #expect(!AgentCatalog.shapes.keys.contains { $0.lowercased().contains("hook") })
        #expect(!MCPServer.descriptions.keys.contains { $0.lowercased().contains("hook") })
    }

    @Test func limit1SettingsSetCannotChangeHooks() {
        #expect(PersonSettings.table["agents.hooks"]?.bar == .always)
    }

    @Test func limit1TheBenchCannotAddOrSwitchAHook() {
        var said: [String: Any] = [:]
        for action in ["add", "on", "approve"] {
            BenchHooks.run(["action": action], browser: browser) { said = $0 }
            #expect(said["error"] != nil, "\(action)")
        }
    }

    @Test func limit1TheSheetTakesOnlyAProgramInsideTheTestWorld() throws {
        HookSheet.chosenForTests = URL(fileURLWithPath: "/usr/bin/true")
        defer { HookSheet.chosenForTests = nil }

        #expect(HookSheet.choose(over: window) == nil)
        HookSheet.chosenForTests = try lab.program("mine", "echo '{}'")
        #expect(HookSheet.choose(over: window) == HookSheet.chosenForTests)
    }

    @Test func hooksListShowsEachHooksEventProgramSwitchAndResult() async throws {
        let program = try lab.program("listed", "echo '{}'")
        let hook = try #require(HookBook.shared.add(.download, program: program))
        defer { HookBook.shared.remove(hook.id) }
        let verb = try #require(PersonCommands.find("hooks", "list"))
        let box = BrowserToolbox()
        box.browser = browser

        let data = try await verb.run(PersonCall(noun: "hooks", verb: "list", arguments: [:], browser: browser, box: box))

        let rows = try #require(data["hooks"] as? [[String: Any]])
        let row = try #require(rows.first { $0["program"] as? String == program.path })
        #expect(row["event"] as? String == "download")
        #expect(row["on"] as? Bool == true)
        #expect(row["result"] as? String == "Hasn't run yet")
    }

    @Test func pressingTheHooksRowUnfoldsItsHooksAndAddHook() throws {
        let made = try #require(HookBook.shared.add(.link, program: try lab.program("links", "echo '{}'")))
        let open = HookSettings.open
        defer {
            HookBook.shared.remove(made.id)
            HookSettings.open = open
        }
        HookSettings.open = false
        let shell = SettingsShell()
        shell.go(to: .agents)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        let fold = try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == "agents.hooks" })

        #expect(fold.accessibilityPerformPress())

        let rows = view.kitSubviews(of: SettingsRowView.self).map(\.rowID)
        #expect(rows.contains("agents.hook.\(made.id.uuidString.lowercased())"))
        #expect(rows.contains("agents.hooks.add"))
    }

    @Test func findASettingFindsHooks() throws {
        let found = SettingsIndex.find("hooks")

        let hooks = try #require(found.first { $0.id == "agents.hooks" })
        #expect(hooks.page == .agents)
        #expect(SettingsIndex.item("agents.hooks")?.detail.count ?? 0 <= 90)
    }
}
