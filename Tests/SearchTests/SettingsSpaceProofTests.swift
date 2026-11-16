import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SettingsSpaceProofTests {
    private func world() -> (browser: Browser, shell: SettingsShell, page: SettingsPageView, work: Space) {
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.liveFolders, prefs.stackedSpaces)
        prefs.usesSpaces = true
        prefs.stackedSpaces = false
        let live = LiveFolders.shared
        for folder in live.folders { live.remove(folder.id) }
        let work = Space(id: UUID(), name: "Work", colour: 1, icon: TabIcon(symbol: "briefcase"))
        addTeardownBlock {
            for folder in live.folders { live.remove(folder.id) }
            StackedFolds.shared.forget(work.id)
            (prefs.usesSpaces, prefs.liveFolders, prefs.stackedSpaces) = previous
            browser.closeAll()
        }
        browser.spaces.append(work)
        let shell = SettingsShell()
        shell.go(to: .liveFolders)
        return (browser, shell, SettingsPageView(browser: browser, shell: shell), work)
    }

    private func heading(of page: SettingsPageView, _ shell: SettingsShell, _ browser: Browser) -> String? {
        SettingsStageWords.head(shell.trail.here, browser: browser, space: page.spaceID).title
    }

    private func row(_ id: String, in page: SettingsPageView) -> SettingsRowView? {
        page.kitSubviews(of: SettingsRowView.self).first { $0.rowID == id }
    }

    private func openSource(_ folder: LiveFolder, in browser: Browser) throws -> NSMenuItem {
        var group = TabGroup(id: folder.id, name: folder.name, collapsed: false)
        group.live = true
        let menu = FolderMenus.menu(browser: browser, group: group)
        return try #require(menu.items.first { $0.title == "Open Source" })
    }

    @Test func aLiveFoldersOwnPageNamesTheSpaceItLivesIn() throws {
        let (browser, shell, page, work) = world()
        let folder = LiveFolders.shared.add(name: "Pull Requests", source: .pullRequests, space: work.id)

        shell.openLiveFolder(folder.id)
        page.rebuild()
        let chip = try #require(row("live.space", in: page)?.kitSubviews(of: SettingsSpaceChip.self).first)
        let shown = (chip.accessibilityLabel(), chip.accessibilityValue() as? String)
        browser.spaces.removeAll { $0.id == work.id }
        page.rebuild()

        #expect(shown.0 == "Space")
        #expect(shown.1 == "Work")
        #expect(heading(of: page, shell, browser) == "Pull Requests")
        #expect(row("live.source", in: page) != nil)
        #expect(row("live.space", in: page) == nil)
    }

    @Test func aLiveFolderPageOpenedWithoutAFolderShowsThePickedSpacesFirst() {
        let (browser, shell, page, work) = world()
        let empty = Space(id: UUID(), name: "Empty", colour: 2, icon: nil)
        browser.spaces.append(empty)
        LiveFolders.shared.add(name: "Mine", source: .subscriptions, space: browser.spaceID)
        LiveFolders.shared.add(name: "Theirs", source: .pullRequests, space: work.id)
        LiveFolders.shared.add(name: "Second", source: .issues, space: work.id)

        shell.drill(.liveFolder)
        page.rebuild()
        let followed = heading(of: page, shell, browser)
        shell.space = work.id
        page.rebuild()
        let picked = (heading(of: page, shell, browser), row("live.space", in: page)?.kitSubviews(of: SettingsSpaceChip.self).first?.accessibilityValue() as? String)
        shell.space = empty.id
        page.rebuild()
        let none = (heading(of: page, shell, browser), row("live.source", in: page))

        #expect(followed == "Mine")
        #expect(picked.0 == "Theirs")
        #expect(picked.1 == "Work")
        #expect(none.0 == "Live Folder")
        #expect(none.1 == nil)
    }

    @Test func openOnALiveFoldersPageEntersItsSpace() throws {
        let (browser, shell, page, work) = world()
        let home = browser.spaceID
        let folder = LiveFolders.shared.add(name: "Pull Requests", source: .pullRequests, space: work.id)
        shell.openLiveFolder(folder.id)
        page.rebuild()
        let open = try #require(row("live.source", in: page)?.kitSubviews(of: SettingsPill.self).first)

        _ = open.accessibilityPerformPress()

        #expect(home != work.id)
        #expect(browser.spaceID == work.id)
        #expect(browser.stackedScroll.count == 0)
        #expect(browser.active?.address == folder.source.reading())
    }

    @Test func openSourceWithStackedSpacesJumpsToTheFoldersSpaceAndUnfoldsIt() throws {
        let (browser, _, _, work) = world()
        browser.prefs.stackedSpaces = true
        StackedFolds.shared.set(work.id, folded: true)
        let folder = LiveFolders.shared.add(name: "Pull Requests", source: .pullRequests, space: work.id)
        let before = browser.stackedScroll.count
        let item = try #require(try openSource(folder, in: browser))

        _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)

        #expect(browser.stacked)
        #expect(browser.spaceID == work.id)
        #expect(!StackedFolds.shared.isFolded(work.id))
        #expect(browser.stackedScroll == StackedScroll(space: work.id, count: before + 1))
        #expect(browser.active?.address == folder.source.reading())
    }

    @Test(arguments: [false, true])
    func openSourceInTheSidebarStaysInTheCurrentSpace(stacked: Bool) throws {
        let (browser, _, _, _) = world()
        browser.prefs.stackedSpaces = stacked
        let home = browser.spaceID
        let folder = LiveFolders.shared.add(name: "Subscriptions", source: .subscriptions, space: home)
        let before = browser.stackedScroll
        let item = try #require(try openSource(folder, in: browser))

        _ = NSApp.sendAction(try #require(item.action), to: item.target, from: item)

        #expect(browser.spaceID == home)
        #expect(browser.stackedScroll == before)
        #expect(browser.active?.address == folder.source.reading())
    }

}
