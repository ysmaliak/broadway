import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SettingsAccountsGoneTests {
    private func world() -> (browser: Browser, shell: SettingsShell, page: SettingsPageView, work: Space) {
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.liveFolders)
        prefs.usesSpaces = true
        let live = LiveFolders.shared
        for folder in live.folders { live.remove(folder.id) }
        browser.history.forget()
        addTeardownBlock {
            for folder in live.folders { live.remove(folder.id) }
            browser.history.forget()
            (prefs.usesSpaces, prefs.liveFolders) = previous
            browser.closeAll()
        }
        let work = Space(id: UUID(), name: "Work", colour: 1, icon: TabIcon(symbol: "briefcase"))
        browser.spaces.append(work)
        let shell = SettingsShell()
        shell.go(to: .liveFolders)
        return (browser, shell, SettingsPageView(browser: browser, shell: shell), work)
    }

    private func suggestion(_ id: String, _ source: LiveSource, title: String, name: String) -> LiveSuggestion {
        LiveSuggestion(id: id, title: title, name: name, source: source, visits: 4, details: [])
    }

    private func added(on page: SettingsPageView) -> [String] {
        page.kitSubviews(of: SettingsRowView.self).map(\.rowID).filter { $0.hasPrefix("live.add.") || $0.hasPrefix("live.suggest.") }
    }

    @Test func eachSourceIsOfferedOnce() {
        let suggestions = [
            suggestion("github", .pullRequests, title: "GitHub Pull Requests", name: LiveSource.pullRequestsName),
            suggestion("linear", .linear(.assigned), title: "Linear My Issues", name: "My Issues"),
            suggestion("youtube", .subscriptions, title: "YouTube Subscriptions", name: "Subscriptions"),
        ]

        let list = LiveAdd.list(suggestions: suggestions, folders: [])
        let sources = list.map(\.source)

        #expect(list.map(\.title) == [
            "GitHub Pull Requests", "Linear My Issues", "YouTube Subscriptions", "GitHub Assigned Issues", "GitHub Notifications",
            "Linear Mentions", "Linear Inbox", "Linear Created by Me",
        ])
        for (index, source) in sources.enumerated() {
            #expect(!sources[(index + 1)...].contains { LivePreset.same($0, source) }, "\(list[index].title)")
        }
        #expect(LiveAdd.list(suggestions: [], folders: []).map(\.title) == LivePreset.all.map(\.title))
        #expect(LivePreset.all.allSatisfy { !$0.detail.contains(";") && !$0.title.contains(":") })
    }

    @Test func anAddedSourceIsNotOfferedAndItsNeighboursStay() {
        let space = UUID()
        let folders = [
            LiveFolder(space: space, name: "Mentions", source: .linear(.mentions)),
            LiveFolder(space: space, name: "Inbox", source: .linear(.inbox, workspace: "acme")),
            LiveFolder(space: space, name: "Assigned Issues", source: .assignedIssues),
        ]

        let titles = LiveAdd.list(suggestions: [], folders: folders).map(\.title)

        #expect(titles == ["GitHub Pull Requests", "GitHub Notifications", "Linear My Issues", "Linear Created by Me", "YouTube Subscriptions"])
    }

    @Test func addPutsTheFolderInThePickedSpaceAndTheRowLeaves() throws {
        let (browser, shell, page, work) = world()
        shell.space = work.id
        page.rebuild()
        let before = added(on: page)
        let add = try #require(page.kitSubviews(of: SettingsPill.self).first { $0.accessibilityIdentifier() == "settings.live.add.linear.mentions" })

        #expect(add.accessibilityPerformPress())
        page.refresh()
        let after = added(on: page)
        let folders = page.kitSubviews(of: SettingsRowView.self).map(\.rowID).filter { $0.hasPrefix("live.folder.") }

        let made = try #require(LiveFolders.shared.folders.first { LivePreset.same($0.source, .linear(.mentions)) })
        #expect(made.space == work.id)
        #expect(made.name == "Mentions")
        #expect(before.contains("live.add.linear.mentions"))
        #expect(!after.contains("live.add.linear.mentions"))
        #expect(after.contains("live.add.linear.assigned"))
        #expect(folders == ["live.folder." + made.id.uuidString])
        #expect(LiveFolderRows.folders(of: browser, space: browser.spaceID).isEmpty)
    }

    @Test func whenEverythingIsAddedTheSectionSaysSo() {
        let (_, shell, page, work) = world()
        for preset in LivePreset.all { LiveFolders.shared.add(name: preset.name, source: preset.source, space: work.id) }
        shell.space = work.id

        page.rebuild()
        let words = page.kitSubviews(of: NSTextField.self).map(\.stringValue)

        #expect(added(on: page).isEmpty)
        #expect(words.contains("Everything is added in Work"))
    }

    @Test func theOldNamesOpenLiveFolders() {
        let names = ["integrations", "github", "linear", "accounts", "Accounts"]

        let pages = names.map(SettingsPage.named)
        let shell = SettingsShell()
        shell.go(to: .general)
        shell.follow("accounts")

        #expect(pages.allSatisfy { $0 == .liveFolders })
        #expect(shell.page == .liveFolders)
    }

    @Test func noPageIsNamedAccounts() {
        let pages = SettingsPage.allCases

        let titles = pages.map(\.title) + SettingsDetail.allCases.map(\.title) + SettingsIndex.groups.map(\.title)

        #expect(pages.count == 12)
        #expect(SettingsPage(rawValue: "accounts") == nil)
        #expect(!titles.contains("Accounts"))
        #expect(SettingsPage.blocks == [[.general, .field, .appearance, .websites, .links, .tabs, .shortcuts],
                                        [.agents, .liveFolders, .passwords, .privacy, .extensions]])
        #expect(SettingsIndex.item("integrations.previews") == nil)
        #expect(SettingsIndex.item("integrations.names") == nil)
        let moved = [IntegrationNow.key, "live.suggestions"]
        let said = moved.compactMap(SettingsIndex.item).flatMap { [$0.title, $0.detail, $0.more ?? ""] }
        #expect(said.count == 6)
        #expect(said.allSatisfy { !$0.contains(";") })
    }

    @Test func searchLandsOnTheRowsThatMoved() {
        _ = NSApplication.shared
        let (browser, _, _, _) = world()
        func rows(_ typed: String) -> [SettingsRowView] {
            let shell = SettingsShell()
            shell.query = typed
            let view = SettingsPageView(browser: browser, shell: shell)
            view.rebuild()
            return view.kitSubviews(of: SettingsRowView.self)
        }

        let now = rows("show in now").first { $0.rowID == IntegrationNow.key }

        #expect(now?.control is KitSwitch)
        #expect(SettingsIndex.item(IntegrationNow.key)?.page == .field)
        for word in ["github", "linear", "pull requests", "notifications", "inbox"] {
            #expect(SettingsIndex.find(word).contains { $0.id == "live.suggestions" }, "\(word)")
        }
    }

    @Test func showInNowSurvivesTheCut() {
        let name = "accounts-gone-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: IntegrationNow.key)

        SettingsCut.migrate(defaults, testing: false)

        #expect(defaults.object(forKey: IntegrationNow.key) as? Bool == false)
    }
}
