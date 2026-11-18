import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class FieldSplitWorldTests {
    private var browser: Browser!
    private var window: NSWindow!
    private var server: LocalPageServer!
    private var saved: Bool = true

    init() async throws {
        keepSetting(Shared.prefs, \.engine, "search.engine")
        keepSetting(Shared.prefs, \.customEngine, "search.custom")
        keepSetting(Shared.prefs, \.engineSuggests, "search.suggest")
        keepSettings("newtab.floating")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        server = try LocalPageServer([
            "/one": .init(type: "text/html", body: "<title>One</title><p>one</p>"),
            "/two": .init(type: "text/html", body: "<title>Two</title><p>two</p>"),
            "/three": .init(type: "text/html", body: "<title>Three</title><p>three</p>"),
            "/search": .init(type: "text/html", body: "<title>Found</title><p>found</p>"),
        ])
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        saved = browser.prefs.splitView
        browser.prefs.splitView = true
        window = shown(browser)
    }

    private func tearDown() async {
        browser.prefs.splitView = saved
        ContentView.forget(browser)
        window.contentView = nil
        window.close()
        browser.closeAll()
        browser = nil
        server = nil
    }

    private func shown(_ browser: Browser) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = ContentView(browser: browser)
        window.orderFrontRegardless()
        return window
    }

    private func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func field(in view: NSView?) -> AddressTextField? {
        guard let view else { return nil }
        if let field = view as? AddressTextField, !field.isHiddenOrHasHiddenAncestor { return field }
        return view.subviews.lazy.compactMap { self.field(in: $0) }.first
    }

    private func page(_ path: String) async throws -> Tab {
        let tab = browser.open(server.url(path), foreground: true)
        #expect(await until { tab.web.window === self.window && tab.committed != nil })
        return tab
    }

    private func editor(in window: NSWindow) async throws -> NSTextView {
        #expect(await until { (self.field(in: window.contentView)?.currentEditor() as? NSTextView).map { window.firstResponder === $0 } ?? false })
        return try #require(field(in: window.contentView)?.currentEditor() as? NSTextView)
    }

    @discardableResult
    private func type(_ text: String, into other: Browser? = nil, in place: NSWindow? = nil) async throws -> NSTextView {
        let browser = other ?? self.browser!
        let window = place ?? self.window!
        browser.edit()
        let editor = try await editor(in: window)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        #expect(await until { browser.typed == text })
        return editor
    }

    @discardableResult
    private func press(_ flags: NSEvent.ModifierFlags, to other: Browser? = nil, in place: NSWindow? = nil) throws -> Bool {
        let browser = other ?? self.browser!
        let window = place ?? self.window!
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        let taken = ContentView.keyHooks[ObjectIdentifier(browser)]?(event) == nil
        if !taken, let editor = window.firstResponder as? NSTextView { editor.keyDown(with: event) }
        return taken
    }

    private func beside(_ tab: Tab, in other: Browser? = nil) -> Tab? {
        let browser = other ?? self.browser!
        guard let pair = browser.split(for: tab) else { return nil }
        let id = pair.left == tab.id ? pair.right : pair.left
        return browser.tabs.first { $0.id == id }
    }

    @Test func anAddressTypedWithOptionReturnOpensBesideThePageOnScreen() async throws {
        let one = try await page("/one")
        try await type("127.0.0.1:\(server.port)/two")
        let count = browser.tabs.count

        let taken = try press([.option])

        #expect(taken)
        #expect(await until { self.beside(one)?.address?.path == "/two" })
        #expect(browser.tabs.count == count + 1)
        #expect(one.address?.path == "/one")
        #expect(browser.split(for: one)?.left == one.id)
        #expect(!browser.editing)
        #expect(browser.typed.isEmpty)
    }

    @Test func overHalfOfAPairTheNewTabTakesTheOtherHalf() async throws {
        let a = try await page("/one")
        let b = try await page("/three")
        browser.select(a)
        browser.openInSplit(b)
        #expect(await until { self.beside(a)?.id == b.id })
        browser.focusPane(a)
        #expect(await until { self.browser.activeID == a.id })
        let count = browser.tabs.count
        try await type("127.0.0.1:\(server.port)/two")

        try press([.option])

        #expect(await until { self.beside(a)?.address?.path == "/two" })
        #expect(browser.split(for: b) == nil)
        #expect(browser.tabs.contains { $0.id == b.id })
        #expect(b.address?.path == "/three")
        #expect(browser.tabs.count == count + 1)
        #expect(a.address?.path == "/one")
    }

    @Test func aPairMadeWithOptionReturnMarksSplitViewAsKnown() async throws {
        keepSetting(Shared.prefs, \.hints, Preferences.hintsKey)
        browser.prefs.hints = true
        HintBook.shared.forget()
        defer { HintBook.shared.forget() }
        let one = try await page("/one")
        _ = browser.hints
        #expect(!HintBook.shared.record.used.contains(.split))
        try await type("127.0.0.1:\(server.port)/two")

        try press([.option])

        #expect(await until { self.beside(one) != nil })
        #expect(await until { HintBook.shared.record.used.contains(.split) })
    }

    @Test func aSearchWithOptionReturnOpensBesideThePageOnScreen() async throws {
        browser.prefs.engineSuggests = false
        browser.prefs.engine = .custom
        browser.prefs.customEngine = "http://127.0.0.1:\(server.port)/search?q=%s"
        let one = try await page("/one")
        try await type("split view words")

        try press([.option])

        #expect(await until { self.beside(one)?.address?.path == "/search" })
        #expect(beside(one)?.address?.query?.contains("split") == true)
        #expect(one.address?.path == "/one")
        #expect(!browser.editing)
    }

    @Test func aQuickActionRowDoesWhatReturnDoes() async throws {
        let alias = "fs" + String(UUID().uuidString.lowercased().filter(\.isLetter).prefix(6))
        let action = try #require(QuickActions.shared.add(name: "Third page", alias: alias, address: "http://127.0.0.1:\(server.port)/three"))
        defer { QuickActions.shared.remove(action.id) }
        let one = try await page("/one")
        try await type(alias)
        #expect(await until { if case .action = self.browser.offers.first?.kind { return true }; return false })
        let count = browser.tabs.count

        try press([.option])

        #expect(await until { self.browser.active?.address?.path == "/three" })
        #expect(browser.tabs.count == count + 1)
        #expect(browser.split(for: one) == nil)
        #expect(browser.activeSplit == nil)
        #expect(one.address?.path == "/one")
    }

    @Test func withSplitViewOffOptionReturnDoesWhatReturnDoes() async throws {
        browser.prefs.splitView = false
        let one = try await page("/one")
        try await type("127.0.0.1:\(server.port)/two")
        let count = browser.tabs.count

        let taken = try press([.option])

        #expect(taken)
        #expect(await until { one.address?.path == "/two" })
        #expect(browser.tabs.count == count)
        #expect(browser.activeSplit == nil)
        #expect(!browser.editing)
    }

    @Test func overAnEmptyTabOptionReturnDoesWhatReturnDoes() async throws {
        browser.newTab()
        let blank = try #require(browser.active)
        #expect(blank.isBlank)
        try await type("127.0.0.1:\(server.port)/two")

        try press([.option])

        #expect(await until { blank.address?.path == "/two" })
        #expect(browser.activeSplit == nil)
        #expect(browser.split(for: blank) == nil)
    }

    @Test func theFloatingFieldOverAPageOpensBesideIt() async throws {
        browser.prefs.floatingNewTab = true
        let one = try await page("/one")
        browser.launch()
        #expect(await until { self.browser.launching })
        let editor = try await editor(in: window)
        editor.insertText("127.0.0.1:\(server.port)/two", replacementRange: editor.selectedRange())
        #expect(await until { self.browser.typed.hasSuffix("/two") })

        try press([.option])

        #expect(await until { self.beside(one)?.address?.path == "/two" })
        #expect(!browser.launching)
        #expect(!browser.editing)
        #expect(one.address?.path == "/one")
    }

    @Test func optionReturnWithNothingToOpenNeverReachesTheField() async throws {
        _ = try await page("/one")
        let editor = try await type("")

        let taken = try press([.option])

        #expect(taken)
        #expect(!editor.string.contains("\n"))
        #expect(browser.activeSplit == nil)
    }

    @Test func aPrivateWindowPairsInsideItself() async throws {
        let secret = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        secret.closeAll()
        let place = shown(secret)
        defer {
            ContentView.forget(secret)
            place.contentView = nil
            place.close()
            secret.closeAll()
        }
        let one = secret.open(server.url("/one"), foreground: true)
        #expect(await until { one.web.window === place && one.committed != nil })
        let count = browser.tabs.count
        try await type("127.0.0.1:\(server.port)/two", into: secret, in: place)

        let taken = try press([.option], to: secret, in: place)

        #expect(taken)
        #expect(await until { self.beside(one, in: secret)?.address?.path == "/two" })
        #expect(beside(one, in: secret)?.shy == true)
        #expect(browser.tabs.count == count)
    }
}
