import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct SettingsStageTests {
    private func place(_ page: SettingsPage, _ detail: SettingsDetail? = nil) -> SettingsPlace {
        SettingsPlace(page: page, detail: detail, folder: nil, space: nil)
    }

    private func names(on page: SettingsPageView) -> [String?] {
        page.cards.flatMap { card in card.rows.map { card.name(of: $0) } }
    }

    private func held(_ browser: Browser, asked: String, size: NSSize = SettingsSize.opening) -> (NSWindow, SettingsSplit) {
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let tab = SettingsTab(browser: browser, asked: asked)
        let holder = NSViewController()
        holder.view = tab
        window.contentViewController = holder
        window.setContentSize(size)
        window.layoutIfNeeded()
        return (window, tab.split)
    }

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(80))
    }

    private var everywhere: [SettingsPlace] {
        SettingsPage.blocks.flatMap { $0 }.map { place($0) } + SettingsDetail.allCases.map { place($0.page, $0) }
    }

    private func standing(_ browser: Browser, asked: String) throws -> (SettingsFrame, SettingsSplit) {
        let window = SettingsWindow.frame(browser, asked: asked)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.layoutIfNeeded()
        return (window, try #require(window.contentViewController as? SettingsSplit))
    }

    private func walk(_ shell: SettingsShell, to place: SettingsPlace, rule: UUID, folder: UUID) {
        shell.query = ""
        shell.go(to: place.page)
        switch place.detail {
        case nil: break
        case .linkRule: shell.openLinkRule(rule)
        case .liveFolder: shell.openLiveFolder(folder)
        case .languages: shell.openLanguages(space: nil)
        case let detail?: shell.drill(detail)
        }
    }

    @Test func thePictureStaysOnlyWhereThePagesOwnSettingsChangeIt() {
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let shell = SettingsShell()
        let kept: [SettingsPlace] = [place(.appearance), place(.websites), place(.tabs), place(.agents), place(.passwords), place(.privacy)]

        let pictured = everywhere.filter(SettingsStageMap.pictured)
        var banded: [SettingsPlace] = []
        for at in everywhere {
            shell.go(to: at.page)
            if let detail = at.detail { shell.drill(detail) }
            if SettingsStageWords.facts(shell: shell, browser: browser, space: browser.spaceID) != nil { banded.append(at) }
        }
        let resting = everywhere.filter { SettingsStageMap.rest($0) != nil }

        #expect(everywhere.count == 15)
        #expect(pictured == kept)
        #expect(banded == kept)
        #expect(resting == kept)
    }

    @Test func everyPageThatKeepsThePictureHasASettingOfItsOwnThatChangesIt() {
        let prefs = Shared.prefs
        keepSetting(prefs, \.usesSpaces, "spaces")
        keepSetting(prefs, \.stackedSpaces, Preferences.stackedKey)
        keepSetting(prefs, \.sideButton, "sidebar.button")
        keepSetting(prefs, \.pageZoom, "pageZoom")
        keepSetting(prefs, \.fillsAndSavesPasswords, "passwords.fill")
        keepSetting(prefs, \.shielded, "shield")
        keepSettings("agents.on")
        prefs.usesSpaces = true
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        func scene(_ at: SettingsPlace) -> SettingsStageScene {
            SettingsStageWords.scene(at, browser: browser, space: browser.spaceID)
        }
        let flips: [(SettingsPlace, String, (Bool) -> Void)] = [
            (place(.appearance), "sidebar.button", { prefs.sideButton = $0 }),
            (place(.websites), "pageZoom", { prefs.pageZoom = $0 ? 1.5 : 1 }),
            (place(.tabs), "spaces.stacked", { prefs.stackedSpaces = $0 }),
            (place(.agents), "ai.agents", { prefs.agentsOn = $0 }),
            (place(.passwords), "passwords.fill", { prefs.fillsAndSavesPasswords = $0 }),
            (place(.privacy), "shield", { prefs.shielded = $0 }),
        ]

        var still: [String] = []
        var strangers: [String] = []
        for (at, row, set) in flips {
            set(false)
            let off = scene(at)
            set(true)
            let on = scene(at)
            if off == on, !(row == "shield" && Shield.shared.trouble != nil) { still.append(row) }
            guard let item = SettingsIndex.item(row) else { strangers.append(row); continue }
            let home = place(item.page)
            if home != at || SettingsStageMap.claim(row) == nil { strangers.append(row) }
        }

        #expect(flips.map(\.0) == everywhere.filter(SettingsStageMap.pictured))
        #expect(still.isEmpty)
        #expect(strangers.isEmpty)
    }

    @Test func aPageWithoutThePictureStartsWithItsTitleAndDescriptionAtOneDistanceFromTheBar() async throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let rule = LinkRules.shared.add(LinkRule(match: .site("stage.example"), target: .peek))
        let folder = LiveFolders.shared.add(name: "Stage", source: .pullRequests, space: browser.spaceID)
        defer {
            LinkRules.shared.remove(rule.id)
            LiveFolders.shared.remove(folder.id)
        }
        let (tabWindow, tab) = held(browser, asked: "general")
        let (window, stood) = try standing(browser, asked: "general")
        defer {
            tabWindow.close()
            window.close()
        }
        let plain = everywhere.filter { !SettingsStageMap.pictured($0) }

        var gaps: [String: Set<CGFloat>] = ["tab": [], "window": []]
        var wrong: [String] = []
        for at in plain {
            for (form, split, host) in [("tab", tab, tabWindow as NSWindow), ("window", stood, window as NSWindow)] {
                walk(split.shell, to: at, rule: rule.id, folder: folder.id)
                try await settle()
                host.layoutIfNeeded()
                let name = "\(form) \(at.detail?.rawValue ?? at.page.rawValue)"
                guard let head = split.page.heading else { wrong.append(name + ": no heading"); continue }
                let words = SettingsStageWords.head(split.shell.trail.here, browser: browser, space: split.page.spaceID)
                let pane = split.pane.convert(split.pane.bounds, to: nil)
                let bar = split.view.kitSubviews(of: SettingsTabBar.self).first.map { $0.convert($0.bounds, to: nil).minY }
                    ?? pane.maxY - split.pane.safeAreaInsets.top
                gaps[form]?.insert(bar - head.title.convert(head.title.bounds, to: nil).maxY)
                if !split.pane.folded || split.pane.room != 0 { wrong.append(name + ": a band") }
                if split.paper.contentInsets.top != 0 { wrong.append(name + ": an inset") }
                if form == "window", abs(split.paper.convert(split.paper.bounds, to: nil).maxY - bar) > 0.5 { wrong.append(name + ": not at the bar") }
                if head.title.stringValue != words.title || head.summary.stringValue != words.summary { wrong.append(name + ": words") }
                if head.crumb.isHidden != (at.detail == nil) { wrong.append(name + ": crumb") }
                if head.title.accessibilitySubrole()?.rawValue != "AXHeading" { wrong.append(name + ": heading") }
                if split.page.blocks.first?.subviews.first !== head { wrong.append(name + ": not first") }
            }
        }

        #expect(plain.count == 9)
        #expect(wrong.isEmpty)
        #expect(gaps["window"] == [SettingsMetrics.top + SettingsHead.above])
        #expect(gaps["tab"] == [10 + SettingsMetrics.top + SettingsHead.above])
    }

    @Test func aPageThatKeepsThePictureHasNoSecondHeadingAndTurningPagesFoldsAtOnce() async throws {
        _ = NSApplication.shared
        keepSettings("motion.testReduced")
        Store.settings.set(false, forKey: "motion.testReduced")
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "privacy")
        defer { window.close() }
        try await settle()
        let kept = (split.page.heading == nil, split.pane.folded, split.pane.band.facts?.title)
        let wide = split.pane.frame.width

        split.shell.go(to: .general)
        try await settle()
        let plain = (split.page.heading?.title.stringValue, split.pane.folded, split.pane.band.layer?.animation(forKey: "settings.fold") == nil,
                     split.paper.contentView.bounds.minY)
        let narrow = (split.pane.frame.width, split.page.heading?.frame.width ?? 0, split.page.heading?.summary.frame.width ?? 0)
        split.shell.go(to: .tabs)
        try await settle()
        let back = (split.page.heading == nil, split.pane.folded, split.pane.band.facts?.title,
                    split.pane.band.layer?.animation(forKey: "settings.fold") == nil, split.paper.contentInsets.top == split.pane.room)

        #expect(kept.0 && !kept.1 && kept.2 == "Privacy")
        #expect(plain.0 == "General" && plain.1 && plain.2 && plain.3 == 0)
        #expect(wide > 600 && narrow.0 == wide)
        #expect(narrow.1 == wide - 2 * (SettingsMetrics.margin + SettingsMetrics.inset) && narrow.2 > 100 && narrow.2 <= SettingsHead.words, "\(narrow)")
        #expect(back.0 && !back.1 && back.2 == "Tabs" && back.3 && back.4)
    }

    @Test func theBenchSaysAPlainPageHasNoBandAndNamesItsHeading() async throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = try standing(browser, asked: "privacy")
        defer { window.close() }
        try await settle()
        let pictured = split.benchStage()

        split.shell.go(to: .general)
        try await settle()
        let page = split.benchStage()
        split.shell.openLanguages(space: nil)
        try await settle()
        let detail = split.benchStage()
        split.shell.go(to: .agents)
        try await settle()
        let again = split.benchStage()

        func rests(_ reply: [String: Any]) -> Bool {
            abs((reply["offset"] as? Double ?? 1) + (reply["insetTop"] as? Double ?? 1)) < 0.5
        }
        #expect(pictured["folded"] as? Bool == false && pictured["title"] as? String == "Privacy" && pictured["heading"] as? String == "")
        #expect(page["folded"] as? Bool == true && page["height"] as? Double == 0 && rests(page))
        #expect(page["heading"] as? String == "General" && page["headingCrumb"] as? String == "")
        #expect(detail["folded"] as? Bool == true && detail["height"] as? Double == 0 && rests(detail))
        #expect(detail["heading"] as? String == "Languages" && detail["headingCrumb"] as? String == "General")
        #expect(again["folded"] as? Bool == false && again["title"] as? String == "Agents" && again["heading"] as? String == "" && rests(again))
    }

    @Test func everyRowInTheIndexHasAPlaceInThePictureOrSaysItHasNone() {
        let rows = SettingsIndex.items.filter { item in
            !item.findOnly && SettingsStageMap.pictured(place(item.page))
        }

        let unclaimed = rows.filter { SettingsStageMap.claim($0.id) == nil }.map(\.id)

        #expect(rows.count > 20)
        #expect(unclaimed.isEmpty)
    }

    @Test func everyRowAPageBuildsHasANameAndAClaim() throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        keepSetting(prefs, \.usesSpaces, "spaces")
        prefs.usesSpaces = true
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let rule = LinkRules.shared.add(LinkRule(match: .site("stage.example"), target: .peek))
        let folder = LiveFolders.shared.add(name: "Stage", source: .pullRequests, space: browser.spaceID)
        defer {
            LinkRules.shared.remove(rule.id)
            LiveFolders.shared.remove(folder.id)
        }
        let shell = SettingsShell()
        let page = SettingsPageView(browser: browser, shell: shell)
        page.frame = NSRect(x: 0, y: 0, width: 640, height: 1600)
        var walks: [(String, () -> Void)] = SettingsPage.blocks.flatMap { $0 }.map { page in (page.rawValue, { shell.go(to: page) }) }
        walks += [
            ("linkRule", { shell.openLinkRule(rule.id) }),
            ("liveFolder", { shell.openLiveFolder(folder.id) }),
            ("languages", { shell.go(to: .general); shell.openLanguages(space: nil) }),
        ]

        var unnamed: [String] = []
        var unclaimed: [String] = []
        var empty: [String] = []
        var pictured = 0
        for (name, walk) in walks {
            walk()
            page.rebuild()
            page.layoutSubtreeIfNeeded()
            let at = SettingsPlace(page: shell.trail.page, detail: shell.trail.detail, folder: shell.trail.folder, space: shell.trail.space)
            let found = names(on: page)
            if found.isEmpty { empty.append(name) }
            if found.contains(where: { $0 == nil }) { unnamed.append(name) }
            guard SettingsStageMap.pictured(at) else { continue }
            pictured += 1
            unclaimed += found.compactMap { $0 }.filter { SettingsStageMap.claim($0) == nil }.map { "\(name): \($0)" }
        }

        #expect(walks.count == 15)
        #expect(pictured == 6)
        #expect(empty.isEmpty)
        #expect(unnamed.isEmpty)
        #expect(unclaimed.isEmpty)
    }

    @Test func aRowTheTableDoesNotKnowRestsOnItsPagesOwnRegion() {
        let websites = place(.websites)
        let folders = place(.liveFolders)

        let video = (SettingsStageMap.spot("video.quality", at: websites), SettingsStageMap.spot("video.speed", at: websites))
        let unknown = (SettingsStageMap.spot("some.new.row", at: websites), SettingsStageMap.spot("some.new.row", at: folders))
        let none = SettingsStageMap.spot(nil, at: websites)

        #expect(video.0 == .page)
        #expect(video.1 == .page)
        #expect(unknown.0 == .page)
        #expect(unknown.1 == nil)
        #expect(none == .page)
    }

    @Test func rowsPointAtThePartOfTheWindowTheyChange() {
        let wanted: [(String, SettingsPage, SettingsStageSpot?)] = [
            ("look", .appearance, .window), ("sidebar.button", .appearance, .top), ("newtab.floating", .appearance, .page),
            ("app.icon", .appearance, nil), ("spaces.stacked", .tabs, .side), ("tabs.close.after", .tabs, .tabs),
            ("pageZoom", .websites, .page), ("shield", .privacy, .page), ("clear.history", .privacy, .field),
            ("ai.groups", .tabs, .tabs), ("ai.agents", .agents, .agents), ("passwords.fill", .passwords, .page),
            ("calendars", .general, nil), ("search.engine", .field, nil), ("links.open", .links, nil), ("live.add.github.pulls", .liveFolders, nil),
            ("command-newTab", .shortcuts, nil), ("extension-abc", .extensions, nil),
        ]

        let wrong = wanted.filter { SettingsStageMap.spot($0.0, at: place($0.1)) != $0.2 }.map(\.0)

        #expect(wrong.isEmpty)
    }

    @Test func everyRegionHasAFrameInsideThePictureInEveryScene() {
        let rect = NSRect(x: 0, y: 0, width: 196, height: 120)
        var scenes = [SettingsStageScene()]
        var right = SettingsStageScene()
        right.right = true
        right.agents = true
        right.stacked = true
        right.sideButton = false
        scenes.append(right)

        var outside: [String] = []
        for scene in scenes {
            let layout = SettingsStageLayout(scene, in: rect)
            for spot in SettingsStageSpot.allCases {
                let frame = layout.frame(spot)
                if frame.isEmpty || !rect.insetBy(dx: -0.5, dy: -0.5).contains(frame) { outside.append(spot.rawValue) }
            }
        }
        let left = SettingsStageLayout(scenes[0], in: rect)
        let mirrored = SettingsStageLayout(right, in: rect)

        #expect(outside.isEmpty)
        #expect(left.frame(.side).midX < left.frame(.page).midX)
        #expect(mirrored.frame(.side).midX > mirrored.frame(.page).midX)
    }

    @Test func thePictureFollowsTheSettingsItCanShow() {
        let prefs = Shared.prefs
        keepSetting(prefs, \.sideButton, "sidebar.button")
        keepSetting(prefs, \.floatingNewTab, "newtab.floating")
        keepSetting(prefs, \.shielded, "shield")
        keepSetting(prefs, \.pageZoom, "pageZoom")
        keepSetting(prefs, \.fillsAndSavesPasswords, "passwords.fill")
        keepSetting(prefs, \.usesSpaces, "spaces")
        keepSetting(prefs, \.stackedSpaces, Preferences.stackedKey)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        func scene(_ page: SettingsPage, _ detail: SettingsDetail? = nil) -> SettingsStageScene {
            SettingsStageWords.scene(place(page, detail), browser: browser, space: browser.spaceID)
        }

        prefs.sideButton = false
        prefs.floatingNewTab = true
        prefs.shielded = false
        prefs.pageZoom = 1.5
        prefs.fillsAndSavesPasswords = false
        prefs.usesSpaces = false
        let first = (scene(.appearance), scene(.privacy), scene(.websites), scene(.passwords), scene(.tabs))
        prefs.sideButton = true
        prefs.floatingNewTab = false
        prefs.shielded = true
        prefs.fillsAndSavesPasswords = true
        prefs.usesSpaces = true
        prefs.stackedSpaces = true
        let second = (scene(.appearance), scene(.privacy), scene(.websites), scene(.passwords), scene(.tabs))

        #expect(!first.0.sideButton && first.0.floating && first.0.content == .article)
        #expect(second.0.sideButton && !second.0.floating && second.0.content == .newTab)
        #expect(first.1.ads == .shown)
        #expect(second.1.ads == (Shield.shared.trouble == nil ? .marked : .shown))
        #expect(second.2.ads == (Shield.shared.trouble == nil ? .gone : .shown))
        #expect(first.2.zoom == 1.5)
        #expect(first.3.content == .signIn(fills: false))
        #expect(second.3.content == .signIn(fills: true))
        #expect(first.4.stacked == nil)
        #expect(second.4.stacked == true)
    }

    @Test func websitesShowsAVideoAtTheQualityChosen() {
        let prefs = Shared.prefs
        keepSetting(prefs, \.videoQuality, VideoQuality.key)
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        func scene(_ page: SettingsPage) -> SettingsStageScene {
            SettingsStageWords.scene(place(page), browser: browser, space: browser.spaceID)
        }

        prefs.videoQuality = .site
        let left = scene(.websites)
        prefs.videoQuality = .height(1080)
        let chosen = scene(.websites)
        prefs.videoQuality = .height(2160)
        let sharp = scene(.websites)
        let elsewhere = scene(.privacy)
        let rows = ["video.quality", "video.speed", "video.site.youtube.com"].map { SettingsStageMap.claim($0) }

        #expect(left.video && left.quality == nil)
        #expect(chosen.video && chosen.quality == "1080p")
        #expect(sharp.quality == "4K")
        #expect(!elsewhere.video && elsewhere.quality == nil)
        #expect(rows == [.spot(.page), .spot(.page), .spot(.page)])
    }

    @Test func aPicturedPageHasItsBandAndASearchOrAPlainDetailHasNone() {
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let shell = SettingsShell()

        shell.go(to: .agents)
        let page = SettingsStageWords.facts(shell: shell, browser: browser, space: browser.spaceID)
        shell.query = "dark"
        let searching = SettingsStageWords.facts(shell: shell, browser: browser, space: browser.spaceID)
        shell.query = ""
        shell.go(to: .general)
        shell.openLanguages(space: nil)
        let plain = SettingsStageWords.facts(shell: shell, browser: browser, space: browser.spaceID)

        #expect(page?.title == "Agents" && page?.crumb == nil)
        #expect(searching == nil)
        #expect(plain == nil)
    }

    @Test func theBandFoldsAwayForASearchAndComesBackAfter() async throws {
        _ = NSApplication.shared
        keepSettings("motion.testReduced")
        Store.settings.set(true, forKey: "motion.testReduced")
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "privacy")
        defer { window.close() }
        try await settle()
        let open = (split.pane.folded, split.pane.room, split.paper.contentInsets.top, split.pane.band.facts?.title)

        split.shell.query = "dark"
        try await settle()
        let found = (split.pane.folded, split.pane.room, split.paper.contentInsets.top, split.pane.folds)
        split.shell.query = ""
        try await settle()
        let back = (split.pane.folded, split.pane.room, split.paper.contentInsets.top, split.pane.band.facts?.title)

        #expect(!open.0 && open.1 > SettingsStageLook.picture.height && open.2 == open.1 && open.3 == "Privacy")
        #expect(found.0 && found.1 == 0 && found.2 == 0 && found.3 == 1)
        #expect(!back.0 && back.1 == open.1 && back.2 == open.1 && back.3 == "Privacy")
    }

    @Test func theRingFollowsThePointerAndTheKeyboardAndRestsBetween() async throws {
        _ = NSApplication.shared
        keepSettings("motion.testReduced")
        Store.settings.set(false, forKey: "motion.testReduced")
        let prefs = Shared.prefs
        keepSetting(prefs, \.sideButton, "sidebar.button")
        prefs.sideButton = true
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "appearance")
        defer { window.close() }
        try await settle()
        let picture = split.pane.band.picture
        let rest = (picture.marked, picture.moves)

        let pointed = split.benchPoint("newtab.floating")
        let onPage = (picture.marked, picture.moves, picture.ringFrame, SettingsStageLayout(picture.scene, in: picture.bounds).frame(.page))
        let focused = split.benchFocus("sidebar.button")
        let onTop = picture.marked
        _ = split.benchPoint("app.icon")
        let nowhere = (picture.marked, picture.ringFrame)
        _ = split.benchPoint("")
        let afterPointer = picture.marked
        _ = split.benchFocus("")
        let atRest = picture.marked

        #expect(rest.0 == .window)
        #expect(pointed && onPage.0 == .page && onPage.1 > rest.1)
        #expect(onPage.2 == onPage.3)
        #expect(focused && onTop == .top)
        #expect(nowhere.0 == nil && nowhere.1 == nil)
        #expect(afterPointer == .top)
        #expect(atRest == .window)
    }

    @Test func theMouseGoesThroughTheSameDoorAndTheBandCoversWhatIsUnderIt() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "appearance")
        defer { window.close() }
        try await settle()
        let page = split.page
        let picture = split.pane.band.picture
        let row = try #require(page.named("newtab.floating"))
        let spot = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let moved = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: spot, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
        let band = split.pane.band
        let over = band.convert(NSPoint(x: band.bounds.midX, y: band.bounds.midY), to: nil)

        let watches = page.trackingAreas.contains { $0.options.contains([.mouseMoved, .mouseEnteredAndExited, .inVisibleRect]) }
        page.mouseMoved(with: moved)
        let onRow = (page.markedRow, picture.marked)
        let underBand = page.point(at: over)
        let covered = picture.marked
        page.mouseMoved(with: moved)
        page.mouseExited(with: moved)
        let left = (page.markedRow, picture.marked)

        #expect(watches)
        #expect(onRow.0 == "newtab.floating" && onRow.1 == .page)
        #expect(underBand == nil && covered == .window)
        #expect(left.0 == nil && left.1 == .window)
    }

    @Test func backAndForwardTakeTheBandAlong() async throws {
        _ = NSApplication.shared
        let prefs = Shared.prefs
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "agents")
        defer { window.close() }
        try await settle()
        let band = split.pane.band

        split.shell.go(to: .privacy)
        try await settle()
        let moved = (band.facts?.title, band.facts?.crumb, band.crumb.isHidden)
        _ = split.shell.back()
        try await settle()
        let back = (band.facts?.title, band.facts?.crumb, band.crumb.isHidden)
        _ = split.shell.forward()
        try await settle()
        let forward = (band.facts?.title, band.facts?.crumb)

        #expect(moved.0 == "Privacy" && moved.1 == nil && moved.2)
        #expect(back.0 == "Agents" && back.1 == nil && back.2)
        #expect(forward.0 == "Privacy" && forward.1 == nil)
        #expect(band.crumb.action == nil)
    }

    @Test func underReduceMotionTheRingJumps() async throws {
        _ = NSApplication.shared
        keepSettings("motion.testReduced")
        Store.settings.set(true, forKey: "motion.testReduced")
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "appearance")
        defer { window.close() }
        try await settle()
        let picture = split.pane.band.picture
        let before = picture.moves

        let pointed = split.benchPoint("newtab.floating")

        #expect(pointed && picture.marked == .page)
        #expect(picture.moves == before)
    }

    @Test func aShortPaneGetsTheSmallBandAndATallOneTheFullBand() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "tabs", size: NSSize(width: 720, height: 480))
        defer { window.close() }
        try await settle()
        let pane = split.pane
        let short = (pane.compact, pane.room, pane.band.summary.isHidden, pane.wellFrame.height, split.paper.contentInsets.top)

        window.setContentSize(NSSize(width: 720, height: 700))
        window.layoutIfNeeded()
        try await settle()
        let tall = (pane.compact, pane.room, pane.band.summary.isHidden, pane.wellFrame.height, split.paper.contentInsets.top)

        #expect(short.0 && short.1 > SettingsStageLook.smallPicture.height && short.2)
        #expect(short.3 == short.1 && short.4 == short.1)
        #expect(!tall.0 && tall.1 > short.1 && !tall.2)
        #expect(tall.3 == tall.1 && tall.4 == tall.1)
        #expect(pane.band.frame.contains(pane.band.picture.frame))
        #expect(pane.band.picture.frame.size == SettingsStageLook.picture)
    }

    @Test func theHeaderStaysWholeAndTheScrollStaysPutWhenAScrolledPaneGrowsTall() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "privacy", size: NSSize(width: 860, height: 560))
        defer { window.close() }
        try await settle()
        let pane = split.pane
        let paper = split.paper
        paper.contentView.scroll(to: NSPoint(x: 0, y: paper.top + 230))
        paper.reflectScrolledClipView(paper.contentView)
        split.view.layoutSubtreeIfNeeded()
        let short = (pane.compact, pane.room, pane.wellFrame.height, pane.band.picture.frame.size)

        window.setContentSize(NSSize(width: 860, height: 700))
        window.layoutIfNeeded()
        try await settle()
        split.view.layoutSubtreeIfNeeded()
        let tall = (pane.compact, pane.room, pane.wellFrame.height, pane.band.picture.frame.size, paper.contentView.bounds.minY - paper.top)

        #expect(short.0 && short.2 == short.1 && short.3 == SettingsStageLook.smallPicture)
        #expect(!tall.0 && tall.2 == tall.1 && tall.3 == SettingsStageLook.picture)
        #expect(paper.contentInsets.top == tall.1)
        #expect(tall.4 == 230)
    }

    @Test func theHeaderIsOneCentredColumnOnThePagesOwnGround() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "tabs")
        defer { window.close() }
        try await settle()
        let band = split.pane.band

        split.view.layoutSubtreeIfNeeded()
        band.displayIfNeeded()
        let column = [band.picture, band.title, band.summary] as [NSView]
        let middles = column.map { abs($0.frame.midX - band.bounds.midX) }
        let order = zip(column, column.dropFirst()).map { $0.frame.maxY <= $1.frame.minY }
        let ground = band.layer?.backgroundColor
        let page = SettingsMetrics.cg(SettingsMetrics.ground, dark: band.kitDark)

        #expect(middles.allSatisfy { $0 <= 1 })
        #expect(order.allSatisfy { $0 })
        #expect(ground == page)
        #expect(band.subviews.count == 4)
        #expect(band.picture.frame.width > 250)
    }

    @Test(arguments: [0, 1])
    func theLineSitsAtTheHeadersBottomEdgeOnlyWhileRowsAreScrolledUnderIt(form: Int) async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let made = try both(browser, asked: "privacy")
        defer { made.forEach { $0.window.close() } }
        let (window, split) = made[form]
        try await settle()
        let pane = split.pane
        let paper = split.paper
        func scroll(_ by: CGFloat) -> Bool {
            paper.contentView.scroll(to: NSPoint(x: 0, y: paper.top + by))
            paper.reflectScrolledClipView(paper.contentView)
            split.view.layoutSubtreeIfNeeded()
            return pane.lined
        }

        let rest = scroll(0)
        let touched = scroll(1)
        let moved = scroll(2)
        let far = scroll(400)
        let line = pane.lineFrame
        let pulled = scroll(-30)
        let back = scroll(0)

        let hair = 1 / window.backingScaleFactor
        #expect(!rest && !touched && moved && far && !pulled && !back)
        #expect(abs(line.maxY - pane.wellFrame.maxY) < 0.01 && line.minX == 0 && line.width == pane.bounds.width)
        #expect(line.height == hair && line.minY > paper.frame.minY + 100)
        #expect(pane.hitTest(NSPoint(x: line.midX, y: line.midY)) !== pane.subviews.last)
    }

    @Test(arguments: [0, 1])
    func theScrollerAFocusedRowAndTheWheelKeepToTheRoomUnderTheHeader(form: Int) async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let made = try both(browser, asked: "privacy")
        defer { made.forEach { $0.window.close() } }
        let split = made[form].split
        try await settle()
        let pane = split.pane
        let paper = split.paper
        split.view.layoutSubtreeIfNeeded()
        let foot = pane.wellFrame.maxY
        let scroller = try #require(paper.verticalScroller)
        let track = pane.convert(scroller.frame, from: paper)
        let row = try #require(split.page.cards.first?.rows.first)

        paper.contentView.scroll(to: NSPoint(x: 0, y: paper.top + 200))
        paper.reflectScrolledClipView(paper.contentView)
        split.view.layoutSubtreeIfNeeded()
        let hidden = pane.convert(row.bounds, from: row).minY < foot
        row.scrollToVisible(row.bounds)
        split.view.layoutSubtreeIfNeeded()
        let shown = pane.convert(row.bounds, from: row)
        let before = paper.contentView.bounds.minY
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -40, wheel2: 0, wheel3: 0))
        pane.band.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        split.view.layoutSubtreeIfNeeded()
        let after = paper.contentView.bounds.minY

        #expect(track.minY >= foot - 0.5, "\(track) \(foot)")
        #expect(hidden && shown.minY >= foot - 0.5 && shown.maxY <= pane.bounds.maxY + 0.5, "\(shown) \(foot)")
        #expect(after > before)
    }

    @Test func onAPageWithoutThePictureTheLineSitsAtTheBarsBottomEdge() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "general")
        defer { window.close() }
        try await settle()
        let pane = split.pane
        let paper = split.paper
        split.view.layoutSubtreeIfNeeded()
        let rest = pane.lined

        paper.contentView.scroll(to: NSPoint(x: 0, y: paper.top + 60))
        paper.reflectScrolledClipView(paper.contentView)
        split.view.layoutSubtreeIfNeeded()

        #expect(pane.folded && !rest && pane.lined)
        #expect(pane.lineFrame.minY == paper.frame.minY && pane.lineFrame.width == pane.bounds.width)
        #expect(pane.lineFrame.height == 1 / window.backingScaleFactor)
        #expect(pane.subviews.filter { $0 is SettingsStageEdge }.count == 1)
    }

    @Test func theLineShowsOverScrolledSearchResultsToo() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "privacy")
        defer { window.close() }
        try await settle()
        let pane = split.pane
        let paper = split.paper

        split.shell.query = "tab"
        try await settle()
        split.view.layoutSubtreeIfNeeded()
        let rest = pane.lined
        paper.contentView.scroll(to: NSPoint(x: 0, y: paper.top + 60))
        paper.reflectScrolledClipView(paper.contentView)
        let scrolled = pane.lined

        #expect(pane.folded && !rest && scrolled)
    }

    @Test func inTheWindowTheScrollViewEndsAtTheBarAndThePaneIsThePagesGround() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let window = SettingsWindow.frame(browser, asked: "appearance")
        defer { window.close() }
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.layoutIfNeeded()
        try await settle()
        let split = try #require(window.contentViewController as? SettingsSplit)
        let pane = split.pane
        let paper = split.paper

        split.view.layoutSubtreeIfNeeded()
        let bar = pane.safeAreaInsets.top

        #expect(bar > 0 && paper.frame.minY == bar && pane.wellFrame.minY == bar)
        #expect(!pane.folded && paper.contentInsets.top == pane.room && pane.wellFrame.height == pane.room)
        #expect(!paper.automaticallyAdjustsContentInsets)
        #expect(pane.layer?.backgroundColor == SettingsMetrics.cg(SettingsMetrics.ground, dark: pane.kitDark))
        #expect(abs(pane.lineFrame.maxY - pane.wellFrame.maxY) < 0.01 && !pane.lined)
    }

    @Test(arguments: SettingsPage.allCases)
    func everyPageEndsWithTheSameAirUnderItsLastThing(page: SettingsPage) throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let shell = SettingsShell()
        shell.go(to: page)
        let view = SettingsPageView(browser: browser, shell: shell)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 650).isActive = true

        view.rebuild()
        view.layoutSubtreeIfNeeded()
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let last = try #require(view.last)

        let foot = view.bounds.maxY - last.convert(last.bounds, to: view).maxY
        #expect(abs(foot - SettingsMetrics.foot) < 0.5, "\(page.rawValue): \(foot)")
    }

    @Test func theRowsKeepRoomUnderTheHeaderAtTheMinimumAndOpeningSizes() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (stood, window) = try standing(browser, asked: "appearance")
        let (held, tab) = held(browser, asked: "appearance")
        defer { [stood, held].forEach { $0.close() } }

        var rooms: [String: CGFloat] = [:]
        for (form, frame, split) in [("window", stood as NSWindow, window), ("tab", held, tab)] {
            for (size, named) in [(SettingsSize.minimum, "minimum"), (SettingsSize.opening, "opening")] {
                for page in SettingsPage.allCases where SettingsStageMap.pictured(place(page)) {
                    frame.setContentSize(size)
                    split.shell.go(to: page)
                    frame.layoutIfNeeded()
                    try await settle()
                    split.view.layoutSubtreeIfNeeded()
                    let key = "\(form) \(named) \(split.pane.compact ? "compact" : "full")"
                    rooms[key] = min(rooms[key] ?? .infinity, split.paper.frame.height - split.paper.contentInsets.top)
                }
            }
        }
        print("settings stage rooms", rooms.sorted { $0.key < $1.key })

        #expect(rooms.count == 4)
        #expect(rooms.values.allSatisfy { $0 >= 160 }, "\(rooms)")
    }

    private func both(_ browser: Browser, asked: String) throws -> [(window: NSWindow, split: SettingsSplit)] {
        let (stood, standing) = try standing(browser, asked: asked)
        let (tab, holding) = held(browser, asked: asked)
        return [(stood, standing), (tab, holding)]
    }

    @Test(arguments: [0, 1])
    func theHeaderStaysWholeAtEveryScrollOffset(form: Int) async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let made = try both(browser, asked: "privacy")
        defer { made.forEach { $0.window.close() } }
        let split = made[form].split
        try await settle()
        let pane = split.pane
        let paper = split.paper
        let band = pane.band
        let full = pane.room
        func scroll(_ by: CGFloat) -> (well: NSRect, band: NSRect, picture: NSRect, alphas: [CGFloat], inset: CGFloat) {
            paper.contentView.scroll(to: NSPoint(x: 0, y: paper.top + by))
            paper.reflectScrolledClipView(paper.contentView)
            split.view.layoutSubtreeIfNeeded()
            let blocks = [band.picture, band.title, band.summary] as [NSView]
            return (pane.wellFrame, band.frame, band.picture.frame, blocks.map(\.alphaValue), paper.contentInsets.top)
        }

        let rest = scroll(0)
        let moved = [12, 40, 120, 400].map { scroll(CGFloat($0)) }
        let back = scroll(0)

        #expect(rest.well.height == full && rest.picture.size == SettingsStageLook.picture)
        #expect(rest.alphas.allSatisfy { $0 == 1 })
        for at in moved + [back] {
            #expect(at.well == rest.well && at.band == rest.band && at.picture == rest.picture)
            #expect(at.alphas == rest.alphas && at.inset == full)
        }
        #expect(band.picture.marked == band.facts?.rest)
    }

    @Test func voiceOverReadsTheTitleAndWhatThePictureMarks() async throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }
        let (window, split) = held(browser, asked: "privacy")
        defer { window.close() }
        try await settle()
        let band = split.pane.band

        let picture = (band.picture.isAccessibilityElement(), band.picture.accessibilityRole(), band.picture.accessibilityValue() as? String)
        let children = band.picture.accessibilityChildren()?.count ?? 0
        let title = (band.title.stringValue, band.title.accessibilitySubrole()?.rawValue)
        _ = split.benchPoint("history.pageText")
        let pointed = band.picture.accessibilityValue() as? String

        #expect(picture.0 && picture.1 == .image && picture.2 == "Marks the page")
        #expect(children == 0)
        #expect(title.0 == "Privacy" && title.1 == "AXHeading")
        #expect(pointed == "Marks the address field")
    }
}
