import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SettingsSheetTests {
    private var folder: URL? {
        ProcessInfo.processInfo.environment["SEARCH_SHEET"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_SHEET"] != nil, "SEARCH_SHEET names a folder to draw the Settings sheet into"))
    func drawsSettingsWindows() async throws {
        let folder = try #require(self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        for page in ["privacy", "general"] {
            for dark in [true, false] {
                let window = SettingsWindow.frame(browser, asked: page)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(SettingsSize.opening)
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(1500))
                let view = try #require(window.contentView?.superview ?? window.contentView)
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent("settings-\(page)-\(dark ? "dark" : "light").png"))
                window.contentViewController = nil
                window.close()
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_SHEET"] != nil, "SEARCH_SHEET names a folder to draw the Settings sheet into"))
    func drawsTheQuickActionsPage() async throws {
        let folder = try #require(self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let store = QuickActions.shared
        let added = store.add(name: "Résumé", alias: "sheetcv", address: "https://example.com/cv/new")
        defer { if let added { store.remove(added.id) } }
        let views: [(String, () -> NSWindow, CGSize)] = [
            ("window", { SettingsWindow.frame(browser, asked: "quickactions") }, SettingsSize.opening),
            ("tab", { tabWindow(browser, asked: "quickactions") }, SettingsSize.opening),
        ]
        for (name, make, size) in views {
            for dark in [true, false] {
                let window = make()
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(size)
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(1500))
                let view = try #require(window.contentView?.superview ?? window.contentView)
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                let data = try #require(rep.representation(using: .png, properties: [:]))
                try data.write(to: folder.appendingPathComponent("quickactions-\(name)-\(dark ? "dark" : "light").png"))
                window.contentViewController = nil
                window.close()
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_SHEET"] != nil, "SEARCH_SHEET names a folder to draw the Settings sheet into"))
    func drawsYourPlans() async throws {
        let folder = try #require(self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.prefs.ai = true
        let plans = Plans.shared
        let claude = FakeProvider(plan: .claude)
        claude.fakeModels = ClaudeProvider().models()
        let codex = FakeProvider(plan: .chatGPT)
        codex.fakeModels = [PlanModel(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", efforts: [.low, .medium, .high, .xhigh], defaultEffort: .low,
                                      note: "Latest workhorse model for coding and everyday work"),
                            PlanModel(id: "gpt-6-astra", name: "GPT-6-Astra", efforts: [.low, .medium, .high, .xhigh], defaultEffort: .medium,
                                      note: "Frontier intelligence for the most demanding work")]
        let mac = FakeProvider(plan: .thisMac)
        defer {
            for plan in Plan.allCases { plans.standIn(nil, for: plan) }
        }
        let worlds: [(String, PlanStatus, PlanStatus, Bool)] = [
            ("ready", PlanStatus(path: "/fake/claude", connected: true, account: "Max plan"),
             PlanStatus(path: "/fake/codex", connected: true, account: "ChatGPT plan"), false),
            ("missing", PlanStatus(path: "/fake/claude"), PlanStatus(), true),
        ]
        for (name, claudeStatus, codexStatus, macReady) in worlds {
            claude.fakeStatus = claudeStatus
            codex.fakeStatus = codexStatus
            mac.fakeStatus = macReady ? PlanStatus(path: "Apple Intelligence", connected: true) : PlanStatus()
            plans.standIn(claude, for: .claude)
            plans.standIn(codex, for: .chatGPT)
            plans.standIn(mac, for: .thisMac)
            await plans.refresh()
            browser.prefs.aiPlan = name == "ready" ? .chatGPT : .claude
            for dark in [true, false] {
                try await drawWindow(browser, page: "ai", size: CGSize(width: 860, height: 1500), dark: dark,
                                     to: folder.appendingPathComponent("plans-\(name)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_SHEET"] != nil, "SEARCH_SHEET names a folder to draw the Settings sheet into"))
    func drawsTheGeneralPage() async throws {
        let folder = try #require(self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let sizes: [(String, CGSize)] = [("narrow", SettingsSize.minimum), ("opening", SettingsSize.opening), ("wide", CGSize(width: 1400, height: 820))]
        for (form, tab) in [("window", false), ("tab", true)] {
            for (named, size) in sizes {
                for dark in [true, false] {
                    try await drawWindow(browser, page: "general", size: size, dark: dark, tab: tab,
                                         to: folder.appendingPathComponent("general-\(form)-\(named)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_SHEET"] != nil, "SEARCH_SHEET names a folder to draw the Settings sheet into"))
    func drawsEveryPage() async throws {
        let folder = try #require(self.folder)
        let into = folder.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: into, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.prefs.ai = true
        let only = ProcessInfo.processInfo.environment["SEARCH_SHEET_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let places = SettingsPage.allCases.map(\.rawValue) + SettingsDetail.allCases.map(\.rawValue)
        let schemes = ProcessInfo.processInfo.environment["SEARCH_SHEET_LIGHT"] == nil ? [true] : [true, false]
        for place in places where only?.contains(place) ?? true {
            for (form, tab) in [("window", false), ("tab", true)] {
                for dark in schemes {
                    try await drawWindow(browser, page: place, size: CGSize(width: 860, height: 1000), dark: dark, tab: tab,
                                         to: into.appendingPathComponent("\(place)-\(form)-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }

    @Test(arguments: [
        ("keyboard", "shortcuts", SettingsPage.shortcuts),
        ("camera", "privacy.permissions", .websites),
        ("bang", "search.shortcuts", .field),
    ])
    func aFoundRowThatWasADrillInOpensItsPage(typed: String, id: String, page: SettingsPage) throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.go(to: .privacy)
        shell.query = typed
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        let row = try #require(view.kitSubviews(of: SettingsDrillRow.self).first { $0.rowID == id })

        _ = row.accessibilityPerformPress()

        #expect(shell.page == page)
        #expect(shell.trail.detail == nil)
        #expect(shell.query.isEmpty)
    }

    @Test(arguments: [
        ("page zoom", SettingsPage.websites, "pageZoom"),
        ("camera", .websites, "privacy.forget"),
        ("keyword", .field, "search.keywords"),
    ])
    func aSearchResultLandsOnItsRow(found: String, page: SettingsPage, row: String) async throws {
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        browser.settingsPage = .privacy
        let window = SettingsWindow.frame(browser, asked: "privacy", found: found)
        window.appearance = NSAppearance(named: .darkAqua)
        window.setContentSize(SettingsSize.opening)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        defer {
            window.contentViewController = nil
            window.close()
        }
        try await Task.sleep(for: .milliseconds(800))
        #expect(browser.settingsPage == .privacy)
        let content = try #require(window.contentView)
        let heading = try #require(content.kitSubviews(of: SettingsResultHeading.self).first)
        let spot = heading.convert(NSPoint(x: heading.bounds.midX, y: heading.bounds.midY), to: nil)

        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: spot, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(500))

        #expect(browser.settingsPage == page)
        let lit = content.kitSubviews(of: SettingsRowView.self).first { $0.rowID == row }
        #expect(lit?.lit == true)
        guard let folder else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("\(page.rawValue)-landed-dark.png"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_SHEET"] != nil, "SEARCH_SHEET names a folder to draw the Settings sheet into"))
    func drawsTheTabFormScrolledUnderItsHeader() async throws {
        let folder = try #require(self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        defer { NSApp.setActivationPolicy(policy) }
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        for dark in [true, false] {
            for (name, by) in [("nudged", CGFloat(27)), ("deep", CGFloat(240))] {
                let window = tabWindow(browser, asked: "privacy")
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.setContentSize(SettingsSize.opening)
                window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
                window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(800))
                let tab = try #require(window.contentViewController?.view as? SettingsTab)
                let paper = tab.split.paper

                paper.contentView.scroll(to: NSPoint(x: 0, y: paper.top + by))
                paper.reflectScrolledClipView(paper.contentView)
                tab.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))

                #expect(tab.split.pane.wellFrame.height == tab.split.pane.room)
                let view = try #require(window.contentView?.superview ?? window.contentView)
                let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: rep)
                try #require(rep.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent("privacy-tab-\(name)-\(dark ? "dark" : "light").png"))
                window.contentViewController = nil
                window.close()
            }
        }
    }

    private func drawWindow(_ browser: Browser, page: String, size: CGSize, dark: Bool, tab: Bool = false, to url: URL) async throws {
        let window = tab ? tabWindow(browser, asked: page) : SettingsWindow.frame(browser, asked: page)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(1500))
        let view = try #require(window.contentView?.superview ?? window.contentView)
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        window.contentViewController = nil
        window.close()
    }

    private func tabWindow(_ browser: Browser, asked: String) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsSize.opening),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        let holder = NSViewController()
        holder.view = SettingsTab(browser: browser, asked: asked)
        window.contentViewController = holder
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        return window
    }
}
