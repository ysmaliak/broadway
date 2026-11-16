import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class SettingsLinkRuleEditorTests {
    private var browser: Browser!
    private var first = UUID()
    private var second = UUID()
    private let store = LinkRules.shared
    private let slack = LinkSender(bundleID: "com.tinyspeck.slackmacgap", name: "Slack")

    init() async throws {
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "1", 1)
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        browser.prefs.usesSpaces = true
        first = browser.spaceID
        browser.addSpace(named: "Work")
        second = browser.spaceID
        browser.switchSpace(to: first)
        store.replaceAll([])
    }

    private func tearDown() async {
        store.replaceAll([])
        if let space = browser.spaces.first(where: { $0.id == second }) {
            browser.spaces.removeAll { $0.id == space.id }
            Spaces.write(browser.spaces)
        }
        browser.closeAll()
        browser = nil
    }

    private var world: LinkWorld { Browsers.linkWorld(from: browser) }

    private func editor(_ rule: LinkRule) -> SettingsPageView {
        let shell = SettingsShell()
        shell.openLinkRule(rule.id)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        return view
    }

    private func rows(_ view: SettingsPageView) -> [String] {
        view.cards.flatMap { card in card.rows.compactMap { card.name(of: $0) } }
    }

    private func says(_ view: SettingsPageView) throws -> String {
        try #require(view.kitSubviews(of: SettingsFooter.self).first { $0.accessibilityIdentifier() == "settings.link.says" }).words.text
    }

    private func menu(_ view: SettingsPageView, _ id: String) throws -> NSPopUpButton {
        try #require(view.kitSubviews(of: NSPopUpButton.self).first { $0.accessibilityIdentifier() == "settings." + id })
    }

    private func pick(_ menu: NSPopUpButton, _ title: String) {
        menu.selectItem(withTitle: title)
        menu.sendAction(menu.action, to: menu.target)
    }

    private func type(_ text: String, in view: SettingsPageView) throws {
        let label = LinkRuleWords.field
        let field = try #require(view.kitSubviews(of: NSTextField.self).first { $0.isEditable && $0.accessibilityLabel() == label })
        field.stringValue = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    @Test func whatIsTypedDecidesHowTheAddressIsRead() {
        let typed = ["github.com", "https://github.com/", "github.com/apple", "github.com/*/pull/*", "*.zoom.us", "github.com?tab=stars"]

        let read = typed.map(LinkRuleEditor.reading)

        #expect(read == [.site, .site, .starts, .pattern, .pattern, .starts])
    }

    @Test func anEmptyFieldIsEveryLinkOnlyOnceASourceIsChosen() {
        let app = LinkRule.From.app(bundleID: slack.bundleID, name: slack.name)

        let nowhere = LinkRuleEditor.match(typed: " ", kind: nil, from: .anywhere)
        let fromApp = LinkRuleEditor.match(typed: "", kind: nil, from: app)
        let fromApps = LinkRuleEditor.match(typed: "", kind: .regex, from: .otherApps)
        let site = LinkRuleEditor.match(typed: "github.com", kind: nil, from: app)

        #expect(nowhere == .site(""))
        #expect(fromApp == .pattern("*"))
        #expect(fromApps == .pattern("*"))
        #expect(site == .site("github.com"))
        #expect(LinkRuleEditor.isBlank(LinkRule(match: nowhere, target: .peek)))
        #expect(LinkRouter.broken(LinkRule(match: fromApp, from: app, target: .peek)) == nil)
        #expect(LinkRouter.matches(fromApp, URL(string: "https://example.com/a?b=c")!))
        #expect(LinkRuleEditor.shown(LinkRule(match: fromApp, from: app, target: .peek)) == "")
        #expect(LinkRuleEditor.shown(LinkRule(match: .pattern("*"), target: .peek)) == "*")
    }

    @Test func aKindSomeoneChoseIsKeptAndOneThatWasReadFollowsTheText() {
        let chosen: [LinkRule.Match] = [.host("docs.google.com"), .contains("/pull/"), .regex("zoom\\.us"), .starts("github.com"),
                                        .site("github.com/apple"), .regex("")]
        let read: [LinkRule.Match] = [.site("github.com"), .starts("github.com/apple"), .pattern("github.com/*"), .pattern("*"), .site("")]

        let kept = chosen.map(LinkRuleEditor.kept)
        let followed = read.map(LinkRuleEditor.kept)

        #expect(kept == [.host, .contains, .regex, .starts, .site, .regex])
        #expect(followed == [nil, nil, nil, nil, nil])
        #expect(LinkRuleEditor.match(typed: "zoom\\.us/j", kind: kept[2], from: .anywhere) == .regex("zoom\\.us/j"))
    }

    @Test func deletingARuleNamesItEvenWithNoSite() {
        let app = LinkRule.From.app(bundleID: slack.bundleID, name: slack.name)
        let rules = [LinkRule(match: .pattern("*"), from: app, target: .peek), LinkRule(match: .pattern("*"), target: .peek),
                     LinkRule(match: .site("github.com"), from: app, target: .peek), LinkRule(match: .site(""), target: .peek)]

        let titles = rules.map { SettingsQuestion.linkRule(LinkRuleWords.named($0)).title }

        #expect(titles == ["Delete the rule for every link from Slack?", "Delete the rule for every link?",
                           "Delete the rule for github.com?", "Delete this rule?"])
    }

    @Test func aRuleReadsAsOneSentence() {
        let app = LinkRule.From.app(bundleID: slack.bundleID, name: slack.name)
        let rules = [
            LinkRule(match: .pattern("*"), from: app, target: .space(second, folder: nil)),
            LinkRule(match: .site("github.com"), from: app, target: .space(second, folder: nil)),
            LinkRule(match: .site("figma.com"), target: .window(nil)),
            LinkRule(match: .pattern("github.com/*/pull/*"), target: .space(second, folder: nil), background: true),
            LinkRule(match: .starts("github.com/apple"), from: .otherApps, target: .peek),
            LinkRule(match: .contains("/pull/"), from: .insideBroadway, target: .ask),
            LinkRule(match: .host("docs.google.com"), target: .frontSpace),
            LinkRule(match: .pattern("*"), from: .otherApps, target: .ask),
        ]

        let said = rules.map { LinkRuleWords.says($0, world: world) }
        let listed = LinkRuleWords.sentence(rules[0], world: world) + " | " + LinkRuleWords.line(rules[0], world: world)

        #expect(said == [
            "Every link from Slack opens in Work.",
            "Links from Slack to github.com open in Work.",
            "Links to figma.com open in a new window.",
            "Links like github.com/*/pull/* open in Work, in the background.",
            "Links from other apps that start with github.com/apple open in a peek.",
            "Links from pages in Broadway with “/pull/” in the address ask where to open.",
            "Links to exactly docs.google.com open in the space in front.",
            "Every link from other apps asks where to open.",
        ])
        #expect(listed == "Links from Slack → Work | Any site")
    }

    @Test func aNewRuleIsThreeRowsAndOneLineOfWhatItNeeds() throws {
        let rule = store.add(LinkRule(match: .site(""), target: .space(first, folder: nil)))

        let view = editor(rule)

        #expect(rows(view) == ["link.from", "field.That go to", "link.target", "link.more"])
        #expect(try says(view) == "Choose where links come from, or type a site")
        #expect(try menu(view, "link.from").titleOfSelectedItem == "Anywhere")
        #expect(try menu(view, "link.target").titleOfSelectedItem == browser.spaces.first { $0.id == first }?.name)
    }

    @Test func addRuleOpensANewRuleForTheSpaceYouAreIn() throws {
        let shell = SettingsShell()
        shell.go(to: .links)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.rebuild()
        let add = try #require(view.kitSubviews(of: SettingsPill.self).first { $0.accessibilityIdentifier() == "settings.links.add" })

        #expect(add.accessibilityPerformPress())

        let made = try #require(store.rules.first)
        #expect(store.rules.count == 1)
        #expect(made.target == .space(first, folder: nil))
        #expect(made.from == .anywhere)
        #expect(LinkRuleEditor.isBlank(made))
        #expect(shell.trail.detail == .linkRule)
        #expect(shell.trail.folder == made.id)
    }

    @Test func choosingAnAppIsAlreadyAWholeRule() throws {
        store.saw(slack)
        let rule = store.add(LinkRule(match: .site(""), target: .space(first, folder: nil)))
        let view = editor(rule)

        pick(try menu(view, "link.from"), "Slack")
        pick(try menu(view, "link.target"), "Work")
        view.refresh()

        let made = try #require(store.rule(rule.id))
        #expect(made.from == .app(bundleID: slack.bundleID, name: slack.name))
        #expect(made.match == .pattern("*"))
        #expect(made.target == .space(second, folder: nil))
        #expect(LinkRouter.problem(made, world: world) == nil)
        #expect(try says(view) == "Every link from Slack opens in Work.")
        #expect(rows(view).contains("link.try"))
        #expect(rows(view).contains("link.delete"))
        #expect(!rows(view).contains("link.order"))
    }

    @Test func typingASiteAPathOrAStarMakesTheRightKindOfRule() throws {
        let rule = store.add(LinkRule(match: .site(""), target: .space(second, folder: nil)))
        let view = editor(rule)

        let field = try #require(view.kitSubviews(of: NSTextField.self).first { $0.isEditable && $0.accessibilityLabel() == LinkRuleWords.field })

        try type("figma.com", in: view)
        view.refresh()
        let site = store.rule(rule.id)?.match
        try type("github.com/apple", in: view)
        view.refresh()
        let path = store.rule(rule.id)?.match
        try type("github.com/*/pull/*", in: view)
        view.refresh()
        let star = store.rule(rule.id)?.match
        let kept = field.isDescendant(of: view)
        let said = try says(view)
        try type("", in: view)
        let emptied = store.rule(rule.id)?.match

        #expect(site == .site("figma.com"))
        #expect(path == .starts("github.com/apple"))
        #expect(star == .pattern("github.com/*/pull/*"))
        #expect(kept)
        #expect(said == "Links like github.com/*/pull/* open in Work.")
        #expect(emptied == .site(""))
        #expect(!rows(view).contains("link.kind"))
    }

    @Test func goingBackToAnywhereWithNoSiteLeavesTheRuleUnfinished() throws {
        let rule = store.add(LinkRule(match: .pattern("*"), from: .otherApps, target: .space(second, folder: nil)))
        let view = editor(rule)

        pick(try menu(view, "link.from"), "Anywhere")
        view.refresh()

        #expect(store.rule(rule.id)?.match == .site(""))
        #expect(try says(view) == "Choose where links come from, or type a site")
    }

    @Test func anOldRuleOpensWithItsOptionsShownAndKeepsItsKindWhileTyped() throws {
        let rule = store.add(LinkRule(match: .regex("^https://.*\\.zoom\\.us/j/"), from: .otherApps, target: .space(second, folder: nil),
                                      background: true, rewrite: LinkRule.Rewrite(find: "^https://zoom\\.us/j/(\\d+)", replace: "https://zoom.us/wc/$1"),
                                      note: "Calls"))
        store.add(LinkRule(match: .site("linear.app"), target: .peek))

        let view = editor(rule)
        let kind = try menu(view, "link.kind").titleOfSelectedItem
        try type("zoom\\.us", in: view)

        #expect(rows(view) == ["link.from", "field.That go to", "link.target", "link.more", "link.kind", "link.background", "field.Note",
                               "field.Find", "field.Replace", "link.rewrite.result", "link.try", "link.try.answer", "link.order", "link.delete"])
        #expect(kind == "A Regular Expression")
        #expect(store.rule(rule.id)?.match == .regex("zoom\\.us"))
        #expect(store.rule(rule.id)?.rewrite?.replace == "https://zoom.us/wc/$1")
        #expect(store.rule(rule.id)?.note == "Calls")
    }

    @Test func anOldRuleWithNoAddressSaysWhatItNeedsAndPickingItsSourceAgainFinishesIt() throws {
        store.saw(slack)
        let rule = store.add(LinkRule(match: .site(""), from: .app(bundleID: slack.bundleID, name: slack.name), target: .space(second, folder: nil)))
        let view = editor(rule)
        let field = try #require(view.kitSubviews(of: NSTextField.self).first { $0.isEditable && $0.accessibilityLabel() == LinkRuleWords.field })
        let needed = try says(view)
        let prompted = field.placeholderString

        pick(try menu(view, "link.from"), "Other Apps")
        view.refresh()
        let again = try #require(view.kitSubviews(of: NSTextField.self).first { $0.isEditable && $0.accessibilityLabel() == LinkRuleWords.field })

        #expect(needed == "Type a site to finish this rule")
        #expect(prompted == "github.com")
        #expect(rows(view).contains("link.delete"))
        #expect(store.rule(rule.id)?.match == .pattern("*"))
        #expect(try says(view) == "Every link from other apps opens in Work.")
        #expect(again.placeholderString == "Any site")
    }

    @Test func aSavedSiteRuleOpensWithMoreOptionsFoldedAndPressingUnfoldsThem() throws {
        let rule = store.add(LinkRule(match: .site("linear.app"), from: .otherApps, target: .space(second, folder: nil)))
        let view = editor(rule)
        let folded = rows(view)

        let more = try #require(view.kitSubviews(of: NSButton.self).first { $0.accessibilityIdentifier() == "settings.link.more" })
        more.performClick(nil)

        #expect(folded == ["link.from", "field.That go to", "link.target", "link.more", "link.try", "link.try.answer", "link.delete"])
        #expect(rows(view).contains("link.kind"))
        #expect(rows(view).contains("field.Find"))
        #expect(try menu(view, "link.kind").titleOfSelectedItem == "A Site and Its Subdomains")
    }

    @Test func aKindPickedUnderMoreOptionsStaysWhileTheAddressIsTyped() throws {
        let rule = store.add(LinkRule(match: .site("github.com"), target: .peek))
        let shell = SettingsShell()
        shell.openLinkRule(rule.id)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.linkDraft.more[rule.id] = true
        view.rebuild()

        pick(try menu(view, "link.kind"), "Exactly This Host")
        try type("docs.github.com/*", in: view)

        #expect(store.rule(rule.id)?.match == .host("docs.github.com/*"))
    }

    @Test func aRuleLeftWithNothingSaidIsDroppedFromTheList() throws {
        let blank = store.add(LinkRule(match: .site(""), target: .space(first, folder: nil)))
        let kept = store.add(LinkRule(match: .site("linear.app"), target: .peek))
        let unfinished = store.add(LinkRule(match: .regex("(broken"), target: .peek))
        let shell = SettingsShell()
        shell.go(to: .links)
        let view = SettingsPageView(browser: browser, shell: shell)

        view.rebuild()

        #expect(store.rule(blank.id) == nil)
        #expect(store.rules.map(\.id) == [kept.id, unfinished.id])
    }
}
