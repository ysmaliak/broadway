import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SettingsSpacePickerTests {
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
        var work = Space(id: UUID(), name: "Work", colour: 1, icon: TabIcon(symbol: "briefcase"))
        work.look = SpaceLook(colour: "ember")
        browser.spaces.append(work)
        let shell = SettingsShell()
        shell.go(to: .liveFolders)
        return (browser, shell, SettingsPageView(browser: browser, shell: shell), work)
    }

    private func popUp(in page: SettingsPageView) -> NSPopUpButton? {
        page.kitSubviews(of: NSPopUpButton.self).first { $0.accessibilityIdentifier() == "settings.space" }
    }

    private func plate(of space: Space, dark: Bool) -> NSColor? {
        let side = Int(Space.settingsBadgeSide)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let image = space.settingsBadge
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
            NSGraphicsContext.restoreGraphicsState()
        }
        return bitmap.colorAt(x: side / 2, y: 2)
    }

    @Test func nothingPickedFollowsTheWindowsSpaceAndAPickWins() {
        let home = UUID()
        let work = UUID()

        #expect(SettingsSpaceChoice.resolve(picked: nil, current: home, spaces: [home, work]) == home)
        #expect(SettingsSpaceChoice.resolve(picked: nil, current: work, spaces: [home, work]) == work)
        #expect(SettingsSpaceChoice.resolve(picked: work, current: home, spaces: [home, work]) == work)
        #expect(SettingsSpaceChoice.resolve(picked: home, current: work, spaces: [home, work]) == home)
    }

    @Test func aPickedSpaceThatIsGoneOrNotOfferedFallsBackToTheWindows() {
        let home = UUID()
        let work = UUID()

        #expect(SettingsSpaceChoice.resolve(picked: UUID(), current: home, spaces: [home, work]) == home)
        #expect(SettingsSpaceChoice.resolve(picked: work, current: home, spaces: [home, work], offered: false) == home)
    }

    @Test func thePickerIsOfferedOnlyWithSpacesToChooseBetween() {
        #expect(SettingsSpaceChoice.offered(spaces: 2, usesSpaces: true, isPrivate: false))
        #expect(!SettingsSpaceChoice.offered(spaces: 1, usesSpaces: true, isPrivate: false))
        #expect(!SettingsSpaceChoice.offered(spaces: 3, usesSpaces: false, isPrivate: false))
        #expect(!SettingsSpaceChoice.offered(spaces: 3, usesSpaces: true, isPrivate: true))
    }

    @Test func aSpacesFoldersComeInItsSidebarOrderAndNoOtherSpaces() {
        let home = UUID()
        let work = UUID()
        let feed = LiveSource(kind: .feed, address: "https://example.com/feed.xml")
        let all = [
            LiveFolder(space: work, name: "One", source: .pullRequests),
            LiveFolder(space: home, name: "Mine", source: .subscriptions),
            LiveFolder(space: work, name: "Two", source: feed),
            LiveFolder(space: work, name: "Three", source: .assignedIssues),
        ]

        let ordered = LiveFolderRows.folders(all, space: work, order: [all[3].id, all[0].id])
        let unknown = LiveFolderRows.folders(all, space: work, order: [])
        let mine = LiveFolderRows.folders(all, space: home, order: [all[3].id])

        #expect(ordered.map(\.name) == ["Three", "One", "Two"])
        #expect(unknown.map(\.name) == ["One", "Two", "Three"])
        #expect(mine.map(\.name) == ["Mine"])
    }

    @Test func theWordsNameTheSpaceOnlyWhenItIsNotTheWindows() {
        let work = Space(id: UUID(), name: "Work", colour: 1)

        #expect(SettingsSpaceChoice.added("My Issues", to: work, current: UUID()) == "Added My Issues to Work")
        #expect(SettingsSpaceChoice.added("My Issues", to: work, current: work.id) == "Added My Issues")
        #expect(SettingsSpaceChoice.added("My Issues", to: nil, current: work.id) == "Added My Issues")
        #expect(LiveFolderRows.none(in: work, offered: true) == "No live folders in Work yet")
        #expect(LiveFolderRows.none(in: work, offered: false) == "No live folders yet")
        #expect(LiveFolderRows.tabs(1) == "1 tab")
        #expect(LiveFolderRows.tabs(3) == "3 tabs")
        #expect(LiveFolderRows.tabs(nil) == nil)
    }

    @Test func eachSpacesBadgeIsPaintedInItsOwnColourInLightAndDark() throws {
        var sky = Space(id: UUID(), name: "Personal", colour: 0)
        sky.look = SpaceLook(colour: "sky")
        var ember = Space(id: UUID(), name: "Work", colour: 1, icon: TabIcon(symbol: "briefcase"))
        ember.look = SpaceLook(colours: ["FB3A4D"], intensity: 1)
        let plain = Space(id: UUID(), name: "Plain", colour: 2)

        let plates = try [true, false].map { dark in
            try [sky, ember, plain].map { try #require(plate(of: $0, dark: dark)) }
        }

        #expect(sky.settingsBadge.size == NSSize(width: Space.settingsBadgeSide, height: Space.settingsBadgeSide))
        #expect(SpaceLook(colour: "sky").settingsSwatch.count == 1)
        #expect(SpaceLook(colours: ["FF89B3", "FF8A1F"], intensity: 0.75).settingsSwatch.count == 2)
        #expect(SpaceLook().settingsSwatch.isEmpty)
        for row in plates {
            #expect(row[0].blueComponent > row[0].redComponent + 0.1)
            #expect(row[1].redComponent > row[1].blueComponent + 0.3)
            #expect(row[0].alphaComponent > 0.9)
            #expect(row[2].alphaComponent < 0.5)
        }
        #expect(abs(plates[0][0].blueComponent - plates[1][0].blueComponent) < 0.02)
    }

    @Test func liveFoldersOpensOnTheWindowsSpaceAndListsTheSpacesByName() throws {
        let (browser, _, page, work) = world()

        page.rebuild()
        let pop = try #require(popUp(in: page))

        #expect(pop.itemTitles == browser.spaces.map(\.name))
        #expect(pop.indexOfSelectedItem == browser.spaces.firstIndex { $0.id == browser.spaceID })
        #expect(pop.itemArray.allSatisfy { $0.image != nil })
        #expect(pop.itemArray.last?.representedObject as? UUID == work.id)
        #expect(page.kitSubviews(of: SettingsRowView.self).first?.rowID == "settings.space")
    }

    @Test func pickingASpaceShowsThatSpacesFoldersAndAddPutsAFolderThere() throws {
        let (browser, shell, page, work) = world()
        let live = LiveFolders.shared
        let mine = live.add(name: "Subscriptions", source: .subscriptions, space: browser.spaceID)
        let theirs = live.add(name: "Pull Requests", source: .pullRequests, space: work.id)
        page.rebuild()
        let before = page.kitSubviews(of: SettingsRowView.self).map(\.rowID)

        let pop = try #require(popUp(in: page))
        pop.selectItem(at: try #require(browser.spaces.firstIndex { $0.id == work.id }))
        _ = pop.sendAction(pop.action, to: pop.target)
        page.refresh()
        let after = page.kitSubviews(of: SettingsRowView.self).map(\.rowID)
        let made = browser.addLivePreset("My Issues", .linear(.assigned), space: page.spaceID)

        #expect(shell.space == work.id)
        #expect(page.spaceID == work.id)
        #expect(before.contains("live.folder." + mine.id.uuidString))
        #expect(!before.contains("live.folder." + theirs.id.uuidString))
        #expect(after.contains("live.folder." + theirs.id.uuidString))
        #expect(!after.contains("live.folder." + mine.id.uuidString))
        #expect(popUp(in: page)?.titleOfSelectedItem == "Work")
        #expect(made.space == work.id)
        #expect(live.folder(made.id)?.space == work.id)
        #expect(LiveFolderRows.folders(of: browser, space: work.id).map(\.name) == ["Pull Requests", "My Issues"])
        #expect(LiveFolderRows.folders(of: browser).map(\.name) == ["Subscriptions"])
        #expect(browser.spaceID != work.id)
        #expect(browser.prefs.liveFolders)
    }

    @Test func withoutAPickAddGoesToTheWindowsSpaceAndAGonePickDoesToo() {
        let (browser, shell, page, work) = world()

        let followed = browser.addLivePreset("Subscriptions", .subscriptions, space: page.spaceID)
        shell.space = UUID()
        let gone = browser.addLivePreset("My Issues", .linear(.assigned), space: shell.space)

        #expect(followed.space == browser.spaceID)
        #expect(gone.space == browser.spaceID)
        #expect(page.spaceID == browser.spaceID)
        #expect(LiveFolderRows.folders(of: browser, space: work.id).isEmpty)
    }

    @Test func theAddListOffersAFolderOnlyWhereThePickedSpaceLacksIt() throws {
        let (browser, shell, page, work) = world()
        LiveFolders.shared.add(name: "PRs", source: .pullRequests, space: work.id)
        func offered() -> [String] { page.kitSubviews(of: SettingsRowView.self).map(\.rowID).filter { $0.hasPrefix("live.add.") } }

        page.rebuild()
        let here = offered()
        shell.space = work.id
        page.refresh()
        let there = offered()

        #expect(page.spaceID == work.id)
        #expect(here.contains("live.add.github.pulls"))
        #expect(!there.contains("live.add.github.pulls"))
        #expect(there.contains("live.add.github.assigned"))
        #expect(popUp(in: page)?.titleOfSelectedItem == "Work")
        #expect(browser.spaceID != work.id)
    }

    @Test func pagesThatAreTheSameInEverySpaceHaveNoPicker() {
        let (_, shell, page, _) = world()
        let wide: [SettingsPage] = [.general, .field, .appearance, .websites, .links, .tabs, .agents, .passwords, .privacy]

        for other in wide {
            shell.go(to: other)
            page.rebuild()
            #expect(popUp(in: page) == nil, "\(other.rawValue)")
        }
        shell.go(to: .liveFolders)
        page.rebuild()
        #expect(popUp(in: page) != nil)
    }

    @Test func linksShowsEachSpaceWithTheSameBadge() throws {
        let (browser, shell, page, _) = world()
        shell.go(to: .links)

        page.rebuild()
        let open = try #require(page.kitSubviews(of: NSPopUpButton.self).first { $0.accessibilityIdentifier() == "settings.links.open" })

        #expect(open.itemTitles == ["The Space in Front"] + browser.spaces.map(\.name) + ["Ask Every Time"])
        #expect(open.itemArray.map { $0.image != nil } == [false] + browser.spaces.map { _ in true } + [false])
        #expect(popUp(in: page) == nil)
    }

    @Test func withOneSpaceThereIsNothingToPick() {
        let (browser, _, page, work) = world()
        browser.spaces.removeAll { $0.id == work.id }

        page.rebuild()

        #expect(popUp(in: page) == nil)
        #expect(page.spaceID == browser.spaceID)
    }
}
