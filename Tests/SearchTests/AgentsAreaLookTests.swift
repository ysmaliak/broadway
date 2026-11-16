import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentsAreaLookTests {
    private var windows: [NSWindow] = []
    private var browser: Browser!

    init() {
        addTeardownBlock { try await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        AgentLinks.shared.reset()
        keepSetting(AgentsFolds.shared, \.folded, AgentsFolds.key)
        browser = Browser(record: WindowRecord())
        let mine = Search.Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        AgentBoard.note(browser)
    }

    private func tearDown() async throws {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
        browser?.closeAll()
        browser = nil
        AgentLinks.shared.reset()
        try await Task.sleep(for: .milliseconds(100))
    }

    private var filmFolder: URL? {
        ProcessInfo.processInfo.environment["SEARCH_FILM"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func agentTab(_ link: AgentLink, _ address: String, _ title: String, acting: String? = nil, mood: AgentMood? = .reading) -> Search.Tab {
        let tab = Search.Tab(configuration: Web.configuration(space: browser.spaceID))
        tab.restore(url: URL(string: address)!, title: title)
        tab.agent = true
        tab.agentTask = link.id
        tab.agentMood = mood
        tab.agentActing = acting
        browser.showRow(browser.tabs + [tab], active: browser.activeID ?? tab.id)
        return tab
    }

    private func column(dark: Bool) -> NSView {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 520))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor(white: dark ? 0.13 : 0.94, alpha: 1).cgColor
        let area = AgentsAreaView(browser: browser)
        area.column = 700
        let height = AgentsAreaView.height(of: browser, column: 700)
        area.frame = NSRect(x: 0, y: 0, width: 280, height: height)
        area.autoresizingMask = [.width]
        root.addSubview(area)
        return root
    }

    private func head(of area: AgentsAreaView) -> AgentHeadView? {
        area.subviews.compactMap { $0 as? AgentHeadView }.first
    }

    @Test func aPressOnTheFoldedRowShowsTheTabThatAsksAndTheNextOneUnfolds() {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        _ = agentTab(claude, "https://github.com/pulls", "Pull requests")
        let asking = agentTab(codex, "https://mail.google.com/", "Inbox", mood: .waving)
        AgentsFolds.shared.folded = true

        browser.pressAgents()
        let shown = browser.activeID
        let stillFolded = AgentsFolds.shared.folded
        browser.pressAgents()

        #expect(shown == asking.id)
        #expect(stillFolded)
        #expect(!AgentsFolds.shared.folded)
    }

    @Test func anAgentArrivingLeavesTheRowFoldedAndOneRowTall() {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        _ = agentTab(claude, "https://github.com/pulls", "Pull requests")
        AgentsFolds.shared.folded = true
        let before = AgentsAreaView.height(of: browser, column: 700)

        let codex = links.join(.named("codex"), name: "Codex")
        _ = agentTab(codex, "https://mail.google.com/", "Inbox")
        _ = agentTab(codex, "https://calendar.google.com/", "Calendar")

        #expect(AgentsFolds.shared.folded)
        #expect(before == (AgentsLayout.row + AgentsLayout.margin))
        #expect(AgentsAreaView.height(of: browser, column: 700) == before)
    }

    @Test func nothingAnAgentDoesUnfoldsTheArea() async throws {
        let links = AgentLinks.shared
        AgentsFolds.shared.folded = true
        let stored = Store.settings.object(forKey: AgentsFolds.key) as? Bool
        let area = AgentsAreaView(browser: browser)
        var seen: [Bool] = []
        func note() {
            area.layoutSubtreeIfNeeded()
            seen.append(AgentsFolds.shared.folded)
        }

        let claude = links.join(.named("claude"), name: "Claude Code")
        note()
        let tab = agentTab(claude, "https://example.com/work", "Work", acting: "Typing")
        note()
        var question = AgentQuestion(kind: .approval(.send), title: "Send on example.com?")
        question.task = claude.id
        question.tab = tab.id
        let asked = Task { await AgentDesk.shared.ask(question) }
        try await Task.sleep(for: .milliseconds(50))
        note()
        for pending in AgentDesk.shared.pending { AgentDesk.shared.take(pending.id, .yes) }
        _ = await asked.value
        tab.driving = true
        note()
        tab.driving = false
        links.end(claude.id, .done("Sent it"))
        note()
        let codex = links.join(.named("codex"), name: "Codex")
        _ = agentTab(codex, "https://example.com/other", "Other")
        links.end(codex.id, .failed("The page would not load"))
        note()
        let script = links.join(.named("script"), name: "Script", at: Date(timeIntervalSinceNow: -3600))
        links.idleLimit = 60
        defer { links.idleLimit = 20 * 60 }
        links.sweep()
        note()

        #expect(links.link(script.id)?.ended == .left)
        #expect(seen == Array(repeating: true, count: seen.count))
        #expect(seen.count == 7)
        #expect(Store.settings.object(forKey: AgentsFolds.key) as? Bool == stored)
        #expect(AgentsAreaView.height(of: browser, column: 700) == (AgentsLayout.row + AgentsLayout.margin))
    }

    @Test func theFoldedRowTellsVoiceOverWhoWaitsAndThatItIsShut() throws {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let second = links.join(.named("claude-2"), name: "Claude Code")
        _ = agentTab(claude, "https://github.com/pulls", "Pull requests")
        _ = agentTab(second, "https://mail.google.com/", "Inbox", mood: .waving)
        AgentsFolds.shared.folded = true

        let area = AgentsAreaView(browser: browser)
        let row = try #require(head(of: area))

        #expect(row.accessibilityLabel() == "Claude Code 2 needs you: 1 working")
        #expect(row.accessibilityValue() as? String == "Shut")
        #expect(row.accessibilityRole() == .button)
    }

    @Test func unfoldedOneAgentHasNoHeadingAndSeveralHaveOneEach() {
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        _ = agentTab(claude, "https://github.com/pulls", "Pull requests")
        _ = agentTab(claude, "https://linear.app/team/ENG-42", "ENG-42")
        AgentsFolds.shared.folded = false

        let alone = AgentsAreaView(browser: browser)
        let aloneHeight = AgentsAreaView.height(of: browser, column: 700)
        let codex = links.join(.named("codex"), name: "Codex")
        _ = agentTab(codex, "https://mail.google.com/", "Inbox")
        let both = AgentsAreaView(browser: browser)

        #expect(headings(in: alone) == [])
        #expect(rows(in: alone) == 2)
        #expect(aloneHeight == (AgentsLayout.row + 2 * AgentsLayout.step + AgentsLayout.margin))
        #expect(headings(in: both) == ["Claude Code: Thinking", "Codex: Thinking"])
        #expect(rows(in: both) == 3)
    }

    private func list(in area: AgentsAreaView) -> [NSView] {
        area.subviews.compactMap { $0 as? NSScrollView }.first?.documentView?.subviews ?? []
    }

    private func headings(in area: AgentsAreaView) -> [String] {
        list(in: area).compactMap { $0 as? AgentHeadView }.compactMap { $0.accessibilityLabel() }.sorted()
    }

    private func rows(in area: AgentsAreaView) -> Int {
        list(in: area).filter { $0 is AgentRowView }.count
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names a folder to film the Agents area into"))
    func filmsTheAgentsArea() async throws {
        let folder = try #require(filmFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let links = AgentLinks.shared
        let claude = links.join(.named("claude"), name: "Claude Code")
        let codex = links.join(.named("codex"), name: "Codex")
        let script = links.join(.named("script"), name: "Nightly check")
        _ = agentTab(claude, "https://github.com/pulls", "Pull requests · GitHub", acting: "Typing")
        _ = agentTab(claude, "https://linear.app/team/ENG-42", "ENG-42 Fix the sign-in loop")
        let asking = agentTab(codex, "https://mail.google.com/", "Inbox (3) - Gmail", mood: .waving)
        _ = agentTab(script, "https://status.example.com/", "Status")
        links.end(script.id, .done("Checked the status page: all green"))
        var question = AgentQuestion(kind: .approval(.send), title: "Send on mail.google.com?")
        question.task = codex.id
        question.tab = asking.id
        Task { _ = await AgentDesk.shared.ask(question) }
        for dark in [false, true] {
            AgentsFolds.shared.folded = false
            let window = makeWindow(column(dark: dark), dark: dark, size: CGSize(width: 280, height: 520))
            try await Task.sleep(for: .milliseconds(700))
            try await shoot(window, frames: 4, every: 0.18, to: folder.appendingPathComponent("area-\(dark ? "dark" : "light")"))
            AgentsFolds.shared.folded = true
            let folded = makeWindow(column(dark: dark), dark: dark, size: CGSize(width: 280, height: 520))
            try await Task.sleep(for: .milliseconds(500))
            try await shoot(folded, frames: 1, every: 0, to: folder.appendingPathComponent("row-\(dark ? "dark" : "light")"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names a folder to film the Codex cards into"))
    func filmsCodexDesktopCards() async throws {
        let folder = try #require(filmFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let links = AgentLinks.shared
        let busy = CodexThread(id: "a", folder: "/tmp/broadway", title: "Fix the build", working: true, doing: "Running swift test --filter")
        let done = CodexThread(id: "b", folder: "/tmp/notes", said: "Fixed the failing test. All green.", finished: true)
        let waiting = CodexThread(id: "c", folder: "/tmp/site")
        for thread in [busy, done, waiting] {
            let link = links.join(.codex(thread.id), name: thread.name)
            links.announce(link.id)
            links.setCodex(link.id, thread)
        }
        for dark in [false, true] {
            AgentsFolds.shared.folded = false
            let window = makeWindow(column(dark: dark), dark: dark, size: CGSize(width: 280, height: 520))
            try await Task.sleep(for: .milliseconds(700))
            try await shoot(window, frames: 1, every: 0, to: folder.appendingPathComponent("codex-\(dark ? "dark" : "light")"))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names a folder to film the faces into"))
    func filmsTheFaces() async throws {
        let folder = try #require(filmFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for dark in [false, true] {
            let size = CGSize(width: 700, height: 130)
            let faces = NSView(frame: NSRect(origin: .zero, size: size))
            faces.wantsLayer = true
            faces.layer?.backgroundColor = NSColor(white: dark ? 0.13 : 0.97, alpha: 1).cgColor
            for (index, mood) in AgentCharacter.Mood.allCases.enumerated() {
                let x = 20 + CGFloat(index) * 74
                let face = AgentCharacterFace()
                face.seed = UInt64(index * 7919)
                face.mood = mood
                face.colour = mood == .waving ? Palette.NS.unsafe : AgentCharacter.accentColor(index)
                face.frame = NSRect(x: x, y: 44, width: 56, height: 56)
                faces.addSubview(face)
                let title = KitLabel(mood.title, font: .systemFont(ofSize: 10), color: KitColor.muted)
                title.alignment = .center
                title.frame = NSRect(x: x - 9, y: 24, width: 74, height: 14)
                faces.addSubview(title)
            }
            let window = makeWindow(view: faces, dark: dark, size: size)
            try await Task.sleep(for: .milliseconds(500))
            try await shoot(window, frames: 4, every: 0.25, to: folder.appendingPathComponent("faces-\(dark ? "dark" : "light")"), columns: 1)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names a folder to film the pointer into"))
    func filmsThePointer() async throws {
        let folder = try #require(filmFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let link = AgentLinks.shared.join(.named("claude"), name: "Claude Code")
        let tab = agentTab(link, "https://example.com/search", "Search")
        let field = CGRect(x: 60, y: 70, width: 300, height: 34)
        let page = FlippedPage(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
        page.wantsLayer = true
        page.layer?.backgroundColor = NSColor.white.cgColor
        func text(_ string: String, _ font: NSFont, _ colour: NSColor, at point: CGPoint) {
            let label = NSTextField(labelWithString: string)
            label.font = font
            label.textColor = colour
            label.sizeToFit()
            label.setFrameOrigin(point)
            page.addSubview(label)
        }
        func box(_ rect: CGRect, fill: NSColor?, stroke: NSColor?) {
            let view = NSView(frame: rect)
            view.wantsLayer = true
            view.layer?.cornerRadius = 6
            view.layer?.backgroundColor = fill?.cgColor
            view.layer?.borderColor = stroke?.cgColor
            view.layer?.borderWidth = stroke == nil ? 0 : 1
            page.addSubview(view)
        }
        text("Find a flight", .systemFont(ofSize: 22, weight: .semibold), .black, at: CGPoint(x: 60, y: 24))
        box(field, fill: nil, stroke: NSColor.gray.withAlphaComponent(0.5))
        text("Lisbon", .systemFont(ofSize: 15), .black, at: CGPoint(x: field.minX + 10, y: field.minY + 8))
        box(CGRect(x: 380, y: 70, width: 90, height: 34), fill: .systemBlue, stroke: nil)
        text("Search", .systemFont(ofSize: 14, weight: .medium), .white, at: CGPoint(x: 400, y: 78))
        let window = makeWindow(page, dark: false, size: CGSize(width: 520, height: 200))
        let pointer = AgentPointerView()
        pointer.tab = tab.id
        pointer.frame = window.contentView?.bounds ?? .zero
        pointer.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(pointer)
        AgentPointers.shared.point(tab.id, AgentPointer(target: field, kind: .type, at: Date(), name: link.name, accent: link.accent))
        try await Task.sleep(for: .milliseconds(500))
        try await shoot(window, frames: 1, every: 0, to: folder.appendingPathComponent("pointer-typing"))
        AgentPointers.shared.point(tab.id, AgentPointer(target: CGRect(x: 380, y: 70, width: 90, height: 34), kind: .click, at: Date(), name: link.name, accent: link.accent))
        try await Task.sleep(for: .milliseconds(120))
        try await shoot(window, frames: 1, every: 0, to: folder.appendingPathComponent("pointer-click"))
    }

    private func shoot(_ window: NSWindow, frames count: Int, every: Double, to base: URL, columns: Int = 4) async throws {
        let film = WindowFilm(window: window)
        try await film.start()
        try await Task.sleep(for: .milliseconds(120))
        var kept: [WindowFilm.Frame] = []
        for index in 0..<count {
            if index > 0 { try await Task.sleep(for: .seconds(every)) }
            let all = try await film.peek()
            if let last = all.last { kept.append(last) }
        }
        _ = try await film.stop()
        try WindowFilm.write(kept, crop: CGRect(origin: .zero, size: window.frame.size), window: window, to: base, columns: min(columns, max(1, kept.count)))
    }

    private func makeWindow(view: NSView, dark: Bool, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }

    private func makeWindow(_ root: NSView, dark: Bool, size: CGSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = root
        window.orderFrontRegardless()
        windows.append(window)
        return window
    }
}

private final class FlippedPage: NSView {
    override var isFlipped: Bool { true }
}
