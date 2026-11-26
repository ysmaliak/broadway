import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class SettingsConfirmTests {
    private var browser: Browser!
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("settings-confirm-\(UUID().uuidString)")
    private let languages = LanguagePrefs.shared.chosen
    private let keywords: [Keyword]
    private let popups: Set<String>
    private let never = Vault.never

    init() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        keywords = browser.prefs.keywords
        popups = browser.prefs.popupSites
        addTeardownBlock { await self.tearDown() }
        Ask.asked = []
        LinkRules.shared.replaceAll([])
        LinkRules.shared.clearRecent()
    }

    private func tearDown() async {
        Ask.testing = nil
        Ask.asked = []
        browser.prefs.keywords = keywords
        browser.prefs.popupSites = popups
        Vault.never = never
        LanguagePrefs.shared.chosen = languages
        LinkRules.shared.replaceAll([])
        LinkRules.shared.clearRecent()
        for key in Store.settings.dictionaryRepresentation().keys where key.hasPrefix("capture.https://confirm.example") {
            Store.settings.removeObject(forKey: key)
        }
        VideoSpeed.forget("confirm.example")
        ExtensionCapture.forget("confirm-recorder")
        FormAnswers.shared.forgetAll()
        Store.settings.removeObject(forKey: "extensions.granted.confirm-extension")
        let book = AutofillBook.shared
        book.editing = nil
        book.cards.forEach { book.forget(card: $0.id) }
        book.addresses.forEach { book.forget(address: $0.id) }
        for snippet in SnippetStore.shared.snippets where snippet.keyword == "confirm" { _ = SnippetStore.shared.delete(snippet.id) }
        try? FileManager.default.removeItem(at: folder)
        browser.closeAll()
        browser = nil
    }

    private func page(_ go: (SettingsShell) -> Void) -> SettingsPageView {
        let shell = SettingsShell()
        go(shell)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        return view
    }

    private func row(_ id: String, in view: NSView) throws -> SettingsRowView {
        try #require(view.kitSubviews(of: SettingsRowView.self).first { $0.rowID == id })
    }

    private func pill(_ title: String, in view: NSView) throws -> KitBroadwayButton {
        try #require(view.kitSubviews(of: KitBroadwayButton.self).first { ($0.content as? KitLabel)?.text == title })
    }

    private func answer(_ yes: Bool, _ press: () -> Void) {
        Ask.testing = yes
        press()
    }

    private func item(_ title: String, in menu: NSMenu?) throws -> () -> Void {
        let menu = try #require(menu)
        let at = try #require(menu.items.firstIndex { $0.title == title })
        return { menu.performActionForItem(at: at) }
    }

    private var click: NSEvent {
        NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    @Test func removingASiteShortcutAsksFirst() throws {
        let prefs = browser.prefs
        let entry = Keyword(keyword: "yt", template: "https://www.youtube.com/results?search_query=%s")
        prefs.keywords = [entry]
        let view = page { $0.go(to: .field) }
        let remove = try #require(try row("keyword." + entry.id.uuidString, in: view).kitSubviews(of: NSButton.self).first)

        answer(false) { remove.sendAction(remove.action, to: remove.target) }
        let kept = prefs.keywords
        answer(true) { remove.sendAction(remove.action, to: remove.target) }

        #expect(kept == [entry])
        #expect(prefs.keywords.isEmpty)
        #expect(Ask.asked == ["Remove the shortcut “yt”?", "Remove the shortcut “yt”?"])
    }

    @Test func removingALanguageAsksFirst() throws {
        LanguagePrefs.shared.chosen = ["en-US", "de-DE"]
        let view = page { $0.openLanguages(space: nil) }
        let remove = try #require(view.kitSubviews(of: NSButton.self).first {
            $0.accessibilityIdentifier() == "settings.languages.remove.de-DE"
        })

        answer(false) { remove.sendAction(remove.action, to: remove.target) }
        let kept = LanguagePrefs.shared.chosen
        answer(true) { remove.sendAction(remove.action, to: remove.target) }

        #expect(kept == ["en-US", "de-DE"])
        #expect(LanguagePrefs.shared.chosen == ["en-US"])
        #expect(Ask.asked.first == "Remove \(PreferredLanguages.name("de-DE"))?")
    }

    @Test func forgettingEverySitesChoicesAsksFirst() throws {
        let key = SiteNotifications.key("https://confirm.example")
        Store.settings.set(true, forKey: key)
        let view = page { $0.go(to: .websites) }
        let forget = try pill("Forget Choices…", in: try row("privacy.forget", in: view))

        answer(false) { _ = forget.accessibilityPerformPress() }
        let kept = Store.settings.object(forKey: key) != nil
        answer(true) { _ = forget.accessibilityPerformPress() }

        #expect(kept)
        #expect(Store.settings.object(forKey: key) == nil)
        #expect(Ask.asked == ["Forget what every site was allowed?", "Forget what every site was allowed?"])
    }

    @Test func removingASitesNotificationChoiceAsksFirst() throws {
        let origin = "https://confirm.example"
        Store.settings.set(true, forKey: SiteNotifications.key(origin))
        let view = page { $0.go(to: .websites) }
        let remove = try pill("Remove…", in: try row("site.notify." + origin, in: view))

        answer(false) { _ = remove.accessibilityPerformPress() }
        let kept = SiteNotifications.allowed
        answer(true) { _ = remove.accessibilityPerformPress() }

        #expect(kept.contains(origin))
        #expect(!SiteNotifications.allowed.contains(origin))
        #expect(Ask.asked.first == "Remove the notification choice for confirm.example?")
    }

    @Test func removingASitesLocalNetworkChoiceAsksFirst() throws {
        let origin = "https://confirm.example"
        Store.settings.set(true, forKey: LocalNetwork.key(origin))
        let view = page { $0.go(to: .websites) }
        let remove = try pill("Remove…", in: try row("site.network." + origin, in: view))

        answer(false) { _ = remove.accessibilityPerformPress() }
        let kept = LocalNetworkGuard.sites.map(\.origin)
        answer(true) { _ = remove.accessibilityPerformPress() }

        #expect(kept.contains(origin))
        #expect(!LocalNetworkGuard.sites.map(\.origin).contains(origin))
        #expect(Ask.asked.first == "Remove the local network choice for confirm.example?")
    }

    @Test func removingAPopUpSiteAsksFirst() throws {
        let prefs = browser.prefs
        prefs.popupSites = ["confirm.example"]
        let view = page { $0.go(to: .websites) }
        let remove = try pill("Remove…", in: try row("site.popup.confirm.example", in: view))

        answer(false) { _ = remove.accessibilityPerformPress() }
        let kept = prefs.popupSites
        answer(true) { _ = remove.accessibilityPerformPress() }

        #expect(kept == ["confirm.example"])
        #expect(prefs.popupSites.isEmpty)
        #expect(Ask.asked.first == "Remove the pop-up choice for confirm.example?")
    }

    @Test func removingAVideoSpeedAsksFirst() throws {
        browser.prefs.remembersSpeed = true
        VideoSpeed.keep(1.5, for: "confirm.example", shy: false)
        VideoSpeedBook.shared.changed()
        let view = page { $0.go(to: .websites) }
        let remove = try pill("Remove…", in: try row("video.site.confirm.example", in: view))

        answer(false) { _ = remove.accessibilityPerformPress() }
        let kept = VideoSpeed.sites().map(\.site)
        answer(true) { _ = remove.accessibilityPerformPress() }

        #expect(kept.contains("confirm.example"))
        #expect(!VideoSpeed.sites().map(\.site).contains("confirm.example"))
        #expect(Ask.asked.first == "Remove the video speed for confirm.example?")
    }

    @Test func forgettingTheSitesNeverAskedAsksFirst() throws {
        Vault.never = ["a.example", "b.example"]
        let view = page { $0.go(to: .passwords) }
        let forget = try pill("Forget…", in: try row("passwords.never", in: view))

        answer(false) { _ = forget.accessibilityPerformPress() }
        let kept = Vault.never
        answer(true) { _ = forget.accessibilityPerformPress() }

        #expect(kept == ["a.example", "b.example"])
        #expect(Vault.never.isEmpty)
        #expect(Ask.asked.first == "Forget the 2 sites told to stop offering?")
    }

    @Test func forgettingACardAsksFirst() throws {
        let book = AutofillBook.shared
        let expiry = try #require(CardExpiry("12/40"))
        #expect(book.save(card: CardSecret(number: "4242424242424242", expiry: expiry), label: "Confirm"))
        let card = try #require(book.cards.first { $0.label == "Confirm" })
        let view = page { $0.go(to: .passwords) }
        let forget = try pill("Forget…", in: try row("autofill.card." + card.id, in: view))

        answer(false) { _ = forget.accessibilityPerformPress() }
        let kept = book.cards.map(\.id)
        answer(true) { _ = forget.accessibilityPerformPress() }

        #expect(kept.contains(card.id))
        #expect(!book.cards.map(\.id).contains(card.id))
        #expect(Ask.asked.first == "Forget “\(card.title)”?")
    }

    @Test func forgettingAnAddressAsksFirst() throws {
        let book = AutofillBook.shared
        var address = AutofillAddress()
        address.label = "Confirm"
        address.line1 = "1 Main Street"
        #expect(book.save(address: address))
        let saved = try #require(book.addresses.first { $0.id == address.id })
        book.editing = .address(address.id)
        let view = page { $0.go(to: .passwords) }
        let forget = try pill("Forget…", in: try row("editor.buttons", in: view))

        answer(false) { _ = forget.accessibilityPerformPress() }
        let kept = book.addresses.map(\.id)
        answer(true) { _ = forget.accessibilityPerformPress() }

        #expect(kept.contains(address.id))
        #expect(!book.addresses.map(\.id).contains(address.id))
        #expect(Ask.asked.first == "Forget “\(saved.note)”?")
    }

    @Test func forgettingEveryRememberedAnswerAsksFirst() async throws {
        let answers = FormAnswers.shared
        let field = FormField(index: 0, name: "project", label: "Project", count: 3)
        let meaning = try #require(FormMemory.meaning(field))
        await answers.remember([meaning: FormAnswer(value: "APX-7", text: "APX-7")], on: URL(string: "https://confirm.example/join"))
        #expect(answers.siteCount == 1)
        let view = page { $0.go(to: .passwords) }
        let forget = try pill("Forget All…", in: try row("autofill.remembered", in: view))
        forget.isEnabled = true

        answer(false) { _ = forget.accessibilityPerformPress() }
        let kept = answers.siteCount
        answer(true) { _ = forget.accessibilityPerformPress() }

        #expect(kept == 1)
        #expect(answers.siteCount == 0)
        #expect(Ask.asked.first == "Forget the answers remembered for forms on 1 site?")
    }

    @Test func deletingASnippetAsksFirst() throws {
        let store = SnippetStore.shared
        let snippet = Snippet(title: "Standup notes", keyword: "confirm", text: "Good morning")
        #expect(store.save(snippet) == nil)
        let view = page { $0.go(to: .field) }
        let delete = try pill("Delete…", in: try row("snippet.\(snippet.id)", in: view))

        answer(false) { _ = delete.accessibilityPerformPress() }
        let kept = store.snippets.map(\.id)
        answer(true) { _ = delete.accessibilityPerformPress() }

        #expect(kept.contains(snippet.id))
        #expect(!store.snippets.map(\.id).contains(snippet.id))
        #expect(Ask.asked.first == "Delete “Standup notes”?")
    }

    @Test func clearingRecentLinksAsksFirst() throws {
        let store = LinkRules.shared
        store.note(LinkRecent(site: "confirm.example", from: "Slack", went: "Work"))
        let view = page { $0.go(to: .links) }
        let clear = try pill("Clear…", in: try row("links.recent.clear", in: view))

        answer(false) { _ = clear.accessibilityPerformPress() }
        let kept = store.recent.count
        answer(true) { _ = clear.accessibilityPerformPress() }

        #expect(kept == 1)
        #expect(store.recent.isEmpty)
        #expect(Ask.asked.first == "Clear recent links?")
    }

    @Test func deletingALinkRuleAsksFirst() throws {
        let store = LinkRules.shared
        let rule = store.add(LinkRule(match: .site("linear.app"), target: .peek))
        let view = page { $0.openLinkRule(rule.id) }
        let delete = try #require(view.kitSubviews(of: SettingsDangerRow.self).first { $0.rowID == "link.delete" })

        answer(false) { delete.press?() }
        let kept = store.rule(rule.id)
        answer(true) { delete.press?() }

        #expect(delete.title.stringValue == "Delete Rule…")
        #expect(kept != nil)
        #expect(store.rule(rule.id) == nil)
        #expect(Ask.asked.first == "Delete the rule for \(LinkRouter.words(rule.match))?")
    }

    @Test func removingAnExtensionAsksFirst() throws {
        let key = "extensions.granted.confirm-extension"
        Store.settings.set(["tabs"], forKey: key)
        let installed = Installed(id: "confirm-extension", name: "Confirm", version: "1", enabled: false, fromStore: true, permissions: [])
        let remove = try item("Remove…", in: KitMenu.make(ExtensionsLogic.actions(installed, nil, Extensions.shared)))

        answer(false, remove)
        let kept = Store.settings.object(forKey: key) != nil
        answer(true, remove)

        #expect(kept)
        #expect(Store.settings.object(forKey: key) == nil)
        #expect(Ask.asked.first == "Remove “Confirm”?")
    }

    @Test func onlyAnExtensionFromAFolderOffersReload() {
        let store = Installed(id: "store-extension", name: "Store", version: "1", enabled: false, fromStore: true, permissions: [])
        let folder = Installed(id: "folder-extension", name: "Folder", version: "1", enabled: false, fromStore: false, permissions: [])

        let storeTitles = KitMenu.make(ExtensionsLogic.actions(store, nil, Extensions.shared)).items.map(\.title)
        let folderTitles = KitMenu.make(ExtensionsLogic.actions(folder, nil, Extensions.shared)).items.map(\.title)

        #expect(!storeTitles.contains("Reload"))
        #expect(folderTitles.contains("Reload"))
        #expect(storeTitles.contains("Remove…"))
    }

    @Test func theToolbarButtonOffersNothingForAnExtensionThatIsNotInstalled() {
        #expect(ExtensionsLogic.actions(of: "not-installed-extension", Extensions.shared, over: nil).isEmpty)
    }

    @Test func removingAScreenRecorderAsksFirst() throws {
        Store.settings.set(true, forKey: "extensions.capture.confirm-recorder")
        let line = ExtensionsLogic.recorder("confirm-recorder")
        let remove = try pill("Remove…", in: line)

        answer(false) { _ = remove.accessibilityPerformPress() }
        let kept = ExtensionCapture.allowed("confirm-recorder")
        answer(true) { _ = remove.accessibilityPerformPress() }

        #expect(kept)
        #expect(!ExtensionCapture.allowed("confirm-recorder"))
        #expect(Ask.asked.first == SettingsQuestion.recorder(Browser.extensionName("confirm-recorder")).title)
    }

    @Test func deletingAQuickActionAsksFirst() throws {
        let store = QuickActions(file: folder.appendingPathComponent("quick.json"))
        let action = try #require(store.add(name: "Standup", alias: "su", address: "https://confirm.example/standup"))
        let line = QuickActionRowView(browser: browser, store: store, action: action, first: true, last: true)
        let delete = try item("Delete…", in: line.menu(for: click))

        answer(false, delete)
        let kept = store.shown(history: browser.history).map(\.id)
        answer(true, delete)

        #expect(kept.contains(action.id))
        #expect(!store.shown(history: browser.history).map(\.id).contains(action.id))
        #expect(Ask.asked.first == "Delete “Standup”?")
    }

    @Test func restoringEditedBuiltInsAsksFirst() throws {
        let store = QuickActions(file: folder.appendingPathComponent("restore.json"))
        #expect(store.edit("doc", name: "Paper", alias: "paper", address: "https://confirm.example/new", history: browser.history))
        let restore = try pill("Restore…", in: QuickActionsLogic.restoreRow(store: store))

        answer(false) { _ = restore.accessibilityPerformPress() }
        let kept = store.builtInsEdited
        answer(true) { _ = restore.accessibilityPerformPress() }

        #expect(kept)
        #expect(!store.builtInsEdited)
        #expect(Ask.asked.first == "Restore doc and meet?")
    }

    @Test func restoringBuiltInsThatWereOnlyDeletedDoesNotAsk() throws {
        let store = QuickActions(file: folder.appendingPathComponent("hidden.json"))
        _ = store.delete("meet", history: browser.history)
        let restore = try pill("Restore", in: QuickActionsLogic.restoreRow(store: store))

        answer(false) { _ = restore.accessibilityPerformPress() }

        #expect(!store.builtInsChanged)
        #expect(Ask.asked.isEmpty)
    }

    @Test func resettingEveryShortcutAsksFirst() throws {
        let saved = Store.settings.data(forKey: "shortcuts")
        defer { Store.settings.set(saved, forKey: "shortcuts") }
        let store = ShortcutStore()
        store.resetAll()
        store.assign(KeyCombo("j", command: true, shift: true, option: true), to: "file.newPrivateWindow")
        let reset = try pill("Reset All to Defaults…", in: ShortcutsResetRow(store: store, prefs: browser.prefs))

        answer(false) { _ = reset.accessibilityPerformPress() }
        let kept = store.anyChanged
        answer(true) { _ = reset.accessibilityPerformPress() }

        #expect(kept)
        #expect(!store.anyChanged)
        #expect(Ask.asked.first == "Reset every shortcut?")
    }

    @Test func aQuestionSaysWhatIsLostAndRepeatsItsVerb() {
        let asked: [(String, SettingsQuestion)] = [
            ("Remove", .keyword("yt")), ("Remove", .language("German")), ("Forget", .siteChoices),
            ("Remove", .notifications("a.example")), ("Remove", .localNetwork("a.example")), ("Remove", .popups("a.example")),
            ("Remove", .videoSpeed("a.example")), ("Forget", .neverSave(1)), ("Forget", .card("Visa ···· 4242")),
            ("Forget", .address("Home")), ("Forget", .answers(1)), ("Delete", .snippet("Standup notes", keyword: "standup")),
            ("Disconnect", .applePasswords), ("Clear", .recentLinks), ("Delete", .linkRule("github.com")),
            ("Remove", .extension("uBlock", fromStore: true)), ("Remove", .recorder("Loom")), ("Delete", .quickAction("Standup")),
            ("Remove", .liveFolder("Pull Requests", site: "GitHub")), ("Restore", .builtInActions), ("Reset", .shortcuts),
            ("Remove", .agentCommand), ("Disconnect", .agent("Claude Code")), ("Remove", .agentSite("a.example", never: true)),
        ]

        let broken = asked.filter { verb, question in
            !question.title.hasPrefix(verb) || !question.title.hasSuffix("?") || !question.confirm.hasPrefix(verb)
                || question.detail.isEmpty || question.detail.hasSuffix(".") != question.detail.contains(". ") || question.title.contains("Are you sure")
        }

        #expect(broken.map(\.1.title).isEmpty)
        #expect(SettingsQuestion.answers(1).title == "Forget the answers remembered for forms on 1 site?")
        #expect(SettingsQuestion.neverSave(1).title == "Forget the site told to stop offering?")
        #expect(SettingsQuestion.linkRule("").title == "Delete this rule?")
        #expect(SettingsQuestion.address("").title == "Forget this address?")
    }

    @Test func returnCancelsEveryQuestion() {
        let asked: [SettingsQuestion] = [.keyword("yt"), .language("German"), .siteChoices, .notifications("a.example"),
                                         .localNetwork("a.example"), .popups("a.example"), .videoSpeed("a.example"), .neverSave(2),
                                         .card("Visa"), .address("Home"), .answers(2), .snippet("Sign-off", keyword: "so"),
                                         .applePasswords, .recentLinks, .linkRule("a.example"), .extension("uBlock", fromStore: false),
                                         .recorder("Loom"), .quickAction("Standup"), .liveFolder("Pull Requests", site: "GitHub"),
                                         .builtInActions, .shortcuts, .agentCommand, .agent("Claude Code"),
                                         .agentSite("a.example", never: false)]

        let keys = asked.map { question in question.alert.buttons.map(\.keyEquivalent) }

        #expect(keys.allSatisfy { $0 == ["", "\r"] })
        #expect(SettingsQuestion.quickAction("Standup").detail == "Its short name no longer opens it. This can't be undone.")
    }
}
