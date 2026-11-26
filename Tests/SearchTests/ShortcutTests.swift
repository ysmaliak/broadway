import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class ShortcutTests {
    init() async throws {
        keepSettings("links.peek", "links.peekClick")
        addTeardownBlock { await self.tearDown() }
        Store.settings.removeObject(forKey: "shortcuts")
        Store.settings.removeObject(forKey: "links.peekClick")
    }

    private func tearDown() async {
        Store.settings.removeObject(forKey: "shortcuts")
        Store.settings.removeObject(forKey: "links.peekClick")
    }

    @Test func noTwoCommandsShareADefaultKey() {
        let keyed = Command.all.compactMap { command in command.defaultKey.map { ($0, command.id) } }

        let holders = Dictionary(grouping: keyed, by: \.0).filter { $0.value.count > 1 }

        #expect(holders.values.map { $0.map(\.1) } == [])
    }

    @Test func spaceKeysCanMoveClearResetAndReload() {
        let store = ShortcutStore()
        let original = KeyCombo("1", command: false, control: true)
        let replacement = KeyCombo("1", option: true)
        #expect(store.customCommand(on: original)?.id == "spaces.1")
        store.assign(replacement, to: "spaces.1")
        #expect(store.customCommand(on: original) == nil)
        #expect(store.isFreed(original))
        #expect(ShortcutStore().customCommand(on: replacement)?.id == "spaces.1")
        store.clear("spaces.1")
        #expect(store.key(for: "spaces.1") == nil)
        #expect(ShortcutStore().key(for: "spaces.1") == nil)
        store.reset("spaces.1")
        #expect(store.customCommand(on: original)?.id == "spaces.1")
        #expect(!store.anyChanged)
    }

    /// ⌃Tab's switcher on a key of its own, as Arc allows: ⇧ walks back,
    /// its modifiers hold it up, and ⌃Tab can go to another command.
    @Test func recentTabsSwitcherCanBeRebound() {
        let store = ShortcutStore()
        let controlTab = KeyCombo("tab", command: false, control: true)
        let back = KeyCombo("tab", command: false, shift: true, control: true)
        #expect(store.key(for: Command.recentTabs) == controlTab)
        #expect(KeyCombo.recentSwitch(controlTab, key: controlTab) == false)
        #expect(KeyCombo.recentSwitch(back, key: controlTab) == true)
        #expect(store.recentHold == .control)

        // Tab with ⌃ or ⌥ is a key to give; alone, with ⇧ or with ⌘ it isn't.
        #expect(!KeyCombo.isReserved(controlTab))
        #expect(!KeyCombo.isReserved(KeyCombo("tab", command: false, option: true)))
        #expect(KeyCombo.isReserved(KeyCombo("tab", command: false)))
        #expect(KeyCombo.isReserved(KeyCombo("tab", command: false, shift: true)))
        #expect(KeyCombo.isReserved(KeyCombo("tab")))

        let optionE = KeyCombo("e", command: false, option: true)
        store.assign(optionE, to: Command.recentTabs)
        #expect(ShortcutStore().key(for: Command.recentTabs) == optionE)
        #expect(KeyCombo.recentSwitch(optionE, key: optionE) == false)
        #expect(KeyCombo.recentSwitch(KeyCombo("e", command: false, shift: true, option: true), key: optionE) == true)
        #expect(KeyCombo.recentSwitch(controlTab, key: optionE) == nil)
        #expect(store.recentHold == .option)
        #expect(store.recentHeld([.option, .shift]))
        #expect(!store.recentHeld([.control]))
        // ⌃Tab, freed, goes to the page — or to the command it is given.
        #expect(store.isFreed(controlTab))
        store.assign(controlTab, to: "tabs.next")
        #expect(store.customCommand(on: controlTab)?.id == "tabs.next")
        #expect(store.key(for: Command.recentTabs) == optionE)
        store.resetAll()
        #expect(store.key(for: Command.recentTabs) == controlTab)
    }

    @Test func keysBroadwayHandlesByHandAreReserved() {
        #expect(KeyCombo.isReserved(KeyCombo("[", shift: true)))
        #expect(KeyCombo.isReserved(KeyCombo("]", shift: true)))
        #expect(KeyCombo.isReserved(KeyCombo("left")))
        #expect(KeyCombo.isReserved(KeyCombo("right")))
        #expect(KeyCombo.isReserved(KeyCombo("v", shift: true, option: true)))
        #expect(Command.all.allSatisfy { $0.defaultKey.map { !KeyCombo.isReserved($0) } ?? true })
    }

    @Test func aReservedKeySaysWhoseItIs() {
        #expect(KeyCombo.reserved(KeyCombo("q")) == "macOS uses this key")
        #expect(KeyCombo.reserved(KeyCombo("c")) == "macOS uses this key")
        #expect(KeyCombo.reserved(KeyCombo("1")) == "Tabs 1 to 9 use this key")
        #expect(KeyCombo.reserved(KeyCombo("escape", command: false)) == "Escape and Tab can't be shortcuts")
        #expect(KeyCombo.reserved(KeyCombo("tab")) == "Escape and Tab can't be shortcuts")
        #expect(KeyCombo.reserved(KeyCombo("tab", command: false, control: true)) == nil)
        #expect(KeyCombo.reserved(KeyCombo("d")) == nil)
    }

    @Test func resetToDefaultSaysWhichCommandItTookTheKeyFrom() {
        let store = ShortcutStore()
        store.assign(KeyCombo("d"), to: "view.reload")

        let said = ShortcutsList.resetToDefault(store: store, id: "tabs.duplicate")

        #expect(said == "⌘D moved from Reload Page")
        #expect(store.key(for: "view.reload") == nil)
        #expect(ShortcutsList.resetToDefault(store: store, id: "view.reload") == nil)
        store.resetAll()
    }

    @Test func conflictsWithSpaceKeysUseExistingReassignmentAndReset() {
        let store = ShortcutStore()
        let original = KeyCombo("2", command: false, control: true)
        #expect(!KeyCombo.isReserved(original))
        #expect(KeyCombo.isReserved(KeyCombo("2")))
        #expect(KeyCombo.isReserved(KeyCombo("c")))
        #expect(store.owner(of: original, except: "tabs.next")?.id == "spaces.2")
        store.assign(original, to: "tabs.next")
        #expect(store.key(for: "spaces.2") == nil)
        #expect(store.customCommand(on: original)?.id == "tabs.next")
        #expect(ShortcutStore().customCommand(on: original)?.id == "tabs.next")
        store.reset("spaces.2")
        #expect(store.customCommand(on: original)?.id == "spaces.2")
        #expect(store.key(for: "tabs.next") == nil)
        #expect(ShortcutStore().customCommand(on: original)?.id == "spaces.2")
        store.resetAll()
        #expect(store.customCommand(on: original)?.id == "spaces.2")
        #expect(Store.settings.data(forKey: "shortcuts") == nil)
    }

    @Test func spaceKeysReadPhysicalDigitsOnOtherLayouts() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.control], timestamp: 0, windowNumber: 0, context: nil,
            characters: "&", charactersIgnoringModifiers: "&", isARepeat: false, keyCode: 18))
        #expect(KeyCombo(event: event) == KeyCombo("1", command: false, control: true))
    }

    @Test func theCutFixesPeekToShift() {
        let saved = Store.settings.object(forKey: "links.peekClick")
        defer { Store.settings.set(saved, forKey: "links.peekClick") }
        Store.settings.set(PeekClick.optionShift.rawValue, forKey: "links.peekClick")

        let prefs = Preferences()

        #expect(prefs.peekClick == .shift)
    }

    @Test func navigationUsesChosenPeekClickAndKeepsOtherActions() async throws {
        _ = NSApplication.shared
        let server = try LocalDownloadServer()
        defer { server.stop() }
        let browser = Browser(record: WindowRecord())
        let tab = browser.benchOpen(server.url("page"))
        browser.activeID = tab.id
        let peeks = browser.prefs.peeksLinks, click = browser.prefs.peekClick
        browser.prefs.peeksLinks = true
        defer {
            browser.closePeek()
            browser.closeAll()
            browser.prefs.peeksLinks = peeks
            browser.prefs.peekClick = click
        }
        let target = server.url("destination")

        func policy(_ flags: NSEvent.ModifierFlags, type: WKNavigationType = .linkActivated,
                    download: Bool = false) async -> WKNavigationActionPolicy {
            await withCheckedContinuation { continuation in
                browser.webView(tab.web, decidePolicyFor: LinkAction(target, flags, type, download),
                                preferences: WKWebpagePreferences()) { answer, _ in
                    continuation.resume(returning: answer)
                }
            }
        }

        for choice in PeekClick.allCases {
            browser.prefs.peekClick = choice
            let result = await policy(choice.flags)
            #expect(result == .cancel)
            for _ in 0..<50 where browser.peekTab == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(browser.peekTab?.address == target)
            browser.closePeek()
        }
        browser.prefs.peekClick = .optionShift
        let ordinary = await policy([])
        #expect(ordinary == .allow)
        let old = await policy(.shift)
        #expect(old == .allow)
        let script = await policy([.option, .shift], type: .other)
        #expect(script == .allow)
        let download = await policy([.option, .shift], download: true)
        #expect(download == .download)
        #expect(browser.peekTab == nil)
        let count = browser.tabs.count
        let command = await policy(.command)
        #expect(command == .cancel)
        #expect(browser.tabs.count == (count + 1))
        #expect(browser.peekTab == nil)
        browser.prefs.peeksLinks = false
        let disabled = await policy([.option, .shift])
        #expect(disabled == .allow)
        #expect(browser.peekTab == nil)
    }
}

private final class LinkAction: WKNavigationAction {
    private let url: URL
    private let flags: NSEvent.ModifierFlags
    private let kind: WKNavigationType
    private let download: Bool

    init(_ url: URL, _ flags: NSEvent.ModifierFlags, _ kind: WKNavigationType, _ download: Bool) {
        self.url = url
        self.flags = flags
        self.kind = kind
        self.download = download
        super.init()
    }

    override var request: URLRequest { URLRequest(url: url) }
    override var navigationType: WKNavigationType { kind }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var buttonNumber: Int { 1 }
    override var targetFrame: WKFrameInfo? { nil }
    override var shouldPerformDownload: Bool { download }

    func testOptionCommandArrowsStepThroughTabs() {
        let next = Command.all.first { $0.id == "tabs.next" }
        let previous = Command.all.first { $0.id == "tabs.previous" }

        #expect(next?.defaultKey == KeyCombo("down", option: true))
        #expect(previous?.defaultKey == KeyCombo("up", option: true))
    }
}
