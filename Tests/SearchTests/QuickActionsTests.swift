import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class QuickActionsTests {
    private var folder: URL!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("quick-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        _ = NSApplication.shared
        Shared.history.forget()
    }

    private func tearDown() async {
        Shared.history.forget()
        try? FileManager.default.removeItem(at: folder)
    }

    private func store() -> QuickActions { QuickActions(file: folder.appendingPathComponent("quick.json")) }
    private func fresh() -> Browser { Browser(record: WindowRecord()) }

    private func visit(_ address: String, count: Int = 1) {
        Shared.history.take(URL(string: address)!, title: address, count: count, last: Date())
    }

    @Test func shortNamesPhrasesAndRussianReachTheBuiltIns() {
        let quick = store()

        for word in ["doc", "New Document", "новый документ"] {
            #expect(quick.matches(word, history: Shared.history).lead?.id == "doc", "\(word)")
        }
        for word in ["meet", "new meeting", "Новая встреча"] {
            #expect(quick.matches(word, history: Shared.history).lead?.id == "meet", "\(word)")
        }
        #expect(quick.matches("d", history: Shared.history).lead == nil)
    }

    @Test func builtInsFollowWhatYouUse() throws {
        let quick = store()
        let meet = try #require(QuickCatalog.slots.first { $0.id == "meet" })
        let doc = try #require(QuickCatalog.slots.first { $0.id == "doc" })
        #expect(quick.builtIn(meet, history: Shared.history).address == "meet.new")

        visit("https://zoom.us/j/123", count: 9)
        visit("https://www.notion.so/page", count: 4)
        visit("https://docs.google.com/document/d/1", count: 1)

        #expect(quick.builtIn(meet, history: Shared.history).address == "zoom.new")
        #expect(quick.builtIn(doc, history: Shared.history).address == "notion.new")
    }

    @Test func somethingYouKeepCreatingIsOfferedWithAReason() {
        let quick = store()
        for number in 1...4 { visit("https://docs.google.com/spreadsheets/d/\(number)/edit") }
        visit("https://docs.google.com/document/d/1/edit")

        let offers = quick.suggestions(history: Shared.history)

        #expect(offers.map(\.action.id) == ["sheet"])
        #expect(offers.first?.reason == "You opened 4 sheets this month")
    }

    @Test func twoAreNotEnoughAndOldVisitsDoNotCount() {
        let quick = store()
        visit("https://www.figma.com/design/1")
        visit("https://www.figma.com/design/2")
        let old = Date().addingTimeInterval(-60 * 86_400)
        for number in 3...6 {
            Shared.history.take(URL(string: "https://www.figma.com/design/\(number)")!, title: "F", count: 1, last: old)
        }

        let offers = quick.suggestions(history: Shared.history)

        #expect(offers.isEmpty)
    }

    @Test func keepingMovesASuggestionIntoTheListAndLetsItLead() {
        let quick = store()
        for number in 1...3 { visit("https://docs.google.com/spreadsheets/d/\(number)/edit") }
        #expect(quick.matches("sheet", history: Shared.history).lead == nil)

        quick.keep("sheet")

        #expect(quick.suggestions(history: Shared.history).isEmpty)
        #expect(quick.matches("sheet", history: Shared.history).lead?.id == "sheet")
        Disk.drain()
        #expect(store().saved.kept == ["sheet"])
    }

    @Test func dismissingStopsTheSuggestion() {
        let quick = store()
        for number in 1...3 { visit("https://docs.google.com/spreadsheets/d/\(number)/edit") }

        quick.dismiss("sheet")

        #expect(quick.suggestions(history: Shared.history).isEmpty)
    }

    @Test func customActionsAreChecked() {
        let taken = ["doc"]

        #expect(QuickActions.problem(alias: "cv", address: "example.com/new", among: taken) == nil)
        #expect(QuickActions.problem(alias: "", address: "example.com", among: taken) != nil)
        #expect(QuickActions.problem(alias: "Doc", address: "example.com", among: taken) != nil)
        #expect(QuickActions.problem(alias: "cv", address: "", among: taken) != nil)
        #expect(QuickActions.problem(alias: "cv", address: "ftp://example.com", among: taken) != nil)
    }

    @Test func aCustomActionIsReachedByItsAliasAndCanBeRemoved() throws {
        let quick = store()

        let action = try #require(quick.add(name: "Résumé", alias: "CV", address: "https://example.com/new"))

        #expect(quick.matches("cv", history: Shared.history).lead?.id == action.id)
        quick.remove(action.id)
        #expect(quick.matches("cv", history: Shared.history).lead == nil)
    }

    @Test func aFileFromBeforeThePageStillLoads() throws {
        let file = folder.appendingPathComponent("old.json")
        let old = #"{"custom":[{"id":"custom-1","name":"Résumé","aliases":["cv"],"address":"example.com/new"}],"kept":["sheet"],"dismissed":["zoom"]}"#
        try Data(old.utf8).write(to: file)

        let quick = QuickActions(file: file)

        #expect(quick.saved.custom.map(\.id) == ["custom-1"])
        #expect(quick.saved.kept == ["sheet"])
        #expect(quick.saved.dismissed == ["zoom"])
        #expect(quick.saved.hidden.isEmpty && quick.saved.order.isEmpty && quick.saved.changed.isEmpty)
        #expect(quick.shown(history: Shared.history).map(\.id) == ["doc", "meet", "sheet", "custom-1"])
    }

    @Test func editingKeepsShortNamesUniqueAndNonEmpty() throws {
        let quick = store()
        let cv = try #require(quick.add(name: "Résumé", alias: "cv", address: "example.com/cv"))
        let card = try #require(quick.add(name: "Card", alias: "card", address: "example.com/card"))

        #expect(quick.problem(editing: card.id, alias: "cv", address: "example.com/card") != nil)
        #expect(quick.problem(editing: card.id, alias: "doc", address: "example.com/card") != nil)
        #expect(quick.problem(editing: card.id, alias: "  ", address: "example.com/card") != nil)
        #expect(quick.problem(editing: card.id, alias: "card", address: "not an address") != nil)
        #expect(quick.problem(editing: card.id, alias: "card", address: "example.com/card") == nil)
        #expect(quick.problem(editing: cv.id, alias: "CV", address: "https://example.com/other") == nil)
        #expect(!quick.edit(card.id, name: "Card", alias: "cv", address: "example.com/card", history: Shared.history))
        #expect(quick.shown(history: Shared.history).first { $0.id == card.id }?.short == "card")
    }

    @Test func editingACustomActionChangesWhatTheFieldOpens() throws {
        let quick = store()
        let cv = try #require(quick.add(name: "Résumé", alias: "cv", address: "example.com/cv"))

        let done = quick.edit(cv.id, name: "", alias: "Resume", address: " https://example.org/new ", history: Shared.history)

        #expect(done)
        let edited = try #require(quick.shown(history: Shared.history).first { $0.id == cv.id })
        #expect(edited.name == "resume")
        #expect(edited.aliases == ["resume"])
        #expect(edited.address == "https://example.org/new")
        #expect(quick.matches("cv", history: Shared.history).lead == nil)
        #expect(quick.matches("resume", history: Shared.history).lead?.id == cv.id)
        Disk.drain()
        #expect(store().saved.custom.first?.address == "https://example.org/new")
    }

    @Test func editingABuiltInFixesItAndKeepsItsPhrases() {
        let quick = store()
        visit("https://zoom.us/j/1", count: 9)
        #expect(quick.shown(history: Shared.history).first { $0.id == "meet" }?.address == "zoom.new")

        let done = quick.edit("meet", name: "Team call", alias: "call", address: "meet.new", history: Shared.history)

        #expect(done)
        let meet = quick.shown(history: Shared.history).first { $0.id == "meet" }
        #expect(meet?.name == "Team call")
        #expect(meet?.short == "call")
        #expect(meet?.address == "meet.new")
        #expect(quick.matches("call", history: Shared.history).lead?.id == "meet")
        #expect(quick.matches("new meeting", history: Shared.history).lead?.id == "meet")
        #expect(quick.matches("meet", history: Shared.history).lead == nil)
        #expect(quick.builtInsChanged)
    }

    @Test func deletingABuiltInHidesItUntilRestored() {
        let quick = store()

        let deleted = quick.delete("doc", history: Shared.history)

        #expect(deleted)
        #expect(!quick.shown(history: Shared.history).contains { $0.id == "doc" })
        #expect(quick.matches("doc", history: Shared.history).lead == nil)
        #expect(quick.builtInsChanged)
        #expect(quick.problem(editing: nil, alias: "doc", address: "example.com") == nil)
        quick.restoreBuiltIns()
        #expect(quick.shown(history: Shared.history).first?.id == "doc")
        #expect(quick.matches("doc", history: Shared.history).lead?.id == "doc")
        #expect(!quick.builtInsChanged)
    }

    @Test func restoringPutsBuiltInsBackFirstAsTheyCame() {
        let quick = store()
        quick.keep("sheet")
        _ = quick.edit("doc", name: "Paper", alias: "paper", address: "example.com/paper", history: Shared.history)
        _ = quick.move("doc", by: 2, history: Shared.history)
        _ = quick.delete("meet", history: Shared.history)
        #expect(quick.shown(history: Shared.history).map(\.id) == ["sheet", "doc"])

        quick.restoreBuiltIns()

        let shown = quick.shown(history: Shared.history)
        #expect(shown.map(\.id) == ["doc", "meet", "sheet"])
        #expect(shown.first?.name == "New document")
        #expect(shown.first?.short == "doc")
    }

    @Test func aRestoredBuiltInLeavesAShortNameYouTookToYou() throws {
        let quick = store()
        _ = quick.delete("doc", history: Shared.history)
        let mine = try #require(quick.add(name: "My doc", alias: "doc", address: "example.com/doc"))

        quick.restoreBuiltIns()

        #expect(quick.matches("doc", history: Shared.history).lead?.id == mine.id)
        #expect(quick.matches("new document", history: Shared.history).lead?.id == "doc")
    }

    @Test func deletingAnActionTakesItsKeyAndLeavesTheRestInPlace() throws {
        let quick = store()
        let one = try #require(quick.add(name: "One", alias: "one", address: "example.com/1"))
        let two = try #require(quick.add(name: "Two", alias: "two", address: "example.com/2"))
        ShortcutStore.shared.assign(KeyCombo("1", option: true, control: true), to: "quick:" + one.id)
        defer { ShortcutStore.shared.clear("quick:" + one.id) }
        let before = quick.shown(history: Shared.history).map(\.id)

        let deleted = quick.delete(one.id, history: Shared.history)

        #expect(deleted)
        #expect(ShortcutStore.shared.key(for: "quick:" + one.id) == nil)
        #expect(quick.matches("one", history: Shared.history).lead == nil)
        #expect(quick.shown(history: Shared.history).map(\.id) == before.filter { $0 != one.id })
        #expect(quick.matches("two", history: Shared.history).lead?.id == two.id)
        #expect(!quick.delete(one.id, history: Shared.history))
    }

    @Test func deletingAKeptActionLetsItBeOfferedAgain() throws {
        let quick = store()
        for number in 1...3 { visit("https://docs.google.com/spreadsheets/d/\(number)/edit") }
        quick.keep("sheet")
        _ = quick.edit("sheet", name: "Budget", alias: "budget", address: "sheets.new", history: Shared.history)

        let deleted = quick.delete("sheet", history: Shared.history)

        #expect(deleted)
        #expect(quick.suggestions(history: Shared.history).map(\.action.id) == ["sheet"])
        #expect(quick.matches("budget", history: Shared.history).lead == nil)
    }

    @Test func orderIsKeptAndTheEmptyFieldFollowsIt() throws {
        let quick = store()
        let cv = try #require(quick.add(name: "Résumé", alias: "cv", address: "example.com/cv"))

        #expect(quick.move(cv.id, by: -1, history: Shared.history))
        #expect(!quick.move("doc", by: -1, history: Shared.history))
        quick.move(from: IndexSet(integer: 0), to: 3, history: Shared.history)

        #expect(quick.shown(history: Shared.history).map(\.id) == [cv.id, "meet", "doc"])
        Disk.drain()
        #expect(store().shown(history: Shared.history).map(\.id) == [cv.id, "meet", "doc"])
        let later = try #require(quick.add(name: "Later", alias: "later", address: "example.com/later"))
        #expect(quick.shown(history: Shared.history).last?.id == later.id)
    }

    @Test func theRowPreviewNamesAFewAndCountsTheRest() throws {
        let quick = store()

        let two = QuickActions.preview(quick.shown(history: Shared.history))
        _ = try #require(quick.add(name: "z", alias: "z0", address: "example.com/z"))
        let three = QuickActions.preview(quick.shown(history: Shared.history))
        for word in ["a1", "b2"] { _ = try #require(quick.add(name: word, alias: word, address: "example.com/" + word)) }
        let five = QuickActions.preview(quick.shown(history: Shared.history))

        #expect(two == "doc and meet")
        #expect(three == "doc, meet and z0")
        #expect(five == "doc, meet, z0 and 2 more")
        #expect(QuickActions.preview([]) == nil)
    }

    @Test func anAliasLeadsAndReturnOpensIt() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try #require(browser.active)

        browser.typed = "doc"

        #expect(browser.offers.first?.kind == .action("quick:doc"))
        #expect(browser.ending == nil)
        browser.submit()
        #expect(tab.shownURL?.host() == "docs.new")
        #expect(browser.typed == "")
    }

    @Test func anAliasBeatsTheAddressTheFieldWouldFinish() {
        visit("https://meet.google.com/", count: 30)
        let browser = fresh()
        defer { browser.closeAll() }

        browser.typed = "meet"

        #expect(browser.offers.first?.kind == .action("quick:meet"))
        #expect(browser.ending == nil)
    }

    @Test func overAPageAQuickActionGetsItsOwnTab() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.newTab()
        let page = try #require(browser.active)
        page.go(to: URL(string: "https://example.com/")!)
        let count = browser.tabs.count

        browser.runQuick("meet")

        #expect(browser.tabs.count == (count + 1))
        #expect(browser.activeID != page.id)
    }

    @Test func emptyFieldListsQuickActionsWithSuggestionsLast() {
        for number in 1...3 { visit("https://docs.google.com/spreadsheets/d/\(number)/edit") }
        let browser = fresh()
        defer { browser.closeAll() }

        let rows = browser.quickHomeRows()

        #expect(rows.first?.key == "New document")
        #expect(rows.last?.key == "New sheet")
        #expect(rows.last?.title == "You opened 3 sheets this month")
    }

    @Test func afterCommandLThePageHasItsActionsBeforeTyping() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try #require(browser.active)
        tab.go(to: URL(string: "https://example.com/page")!)
        let shown = try #require(tab.shownURL)

        browser.edit()

        #expect(browser.typed == shown.absoluteString)
        #expect(browser.fieldSections.map(\.title) == ["This Page"])
        #expect(browser.offers.map(\.key) == ["Copy Address", "Copy as Markdown Link", "Copy as Rich Link", "Copy Page as Markdown", "Duplicate Tab"])
        browser.typed = "something else"
        #expect(browser.fieldSections.isEmpty)
    }

    @Test func theActionsMenuListsWhatARowCanDo() {
        visit("https://example.com/deep")
        let browser = fresh()
        defer { browser.closeAll() }
        let row = Suggestion(key: "example.com/deep", title: "Deep", url: URL(string: "https://example.com/deep")!, kind: .visited)

        let titles = browser.fieldMenuItems(for: row).map(\.title)

        for title in ["Open", "Open in Background", "Open in New Tab", "Open in New Tab at the End", "Copy Link",
                      "Copy as Markdown Link", "Forget from History", "Forget example.com", "Forget the Last Hour",
                      "Forget Today", "Clear History…"] {
            #expect(titles.contains(title), "\(title)")
        }
    }

    @Test func anOpenTabRowOffersToSwitchAndClose() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.newTab()
        let tab = try #require(browser.active)
        tab.go(to: URL(string: "https://example.com/")!)
        let row = Suggestion(key: "Example", title: "example.com", url: URL(string: "https://example.com/")!, kind: .open, tab: tab.id)

        let titles = browser.fieldMenuItems(for: row).map(\.title)

        #expect(titles.contains("Switch to Tab"))
        #expect(titles.contains("Close Tab"))
        #expect(!titles.contains("Forget from History"))
    }

    @Test func theMenuHasItsOwnSearchAndKeys() {
        let menu = FieldMenu()
        var ran: [String] = []
        let items = ["Open", "Copy Link", "Copy as Markdown Link"].map { title in
            FieldMenuItem(id: title, title: title, symbol: "link") { ran.append(title) }
        }
        menu.open(heading: "Row", items: items)

        menu.query = "copy"
        menu.walk(1)
        menu.runPicked()

        #expect(ran == ["Copy as Markdown Link"])
        #expect(!menu.showing)
        #expect(menu.query == "")
    }

    @Test func aPartedRowSitsUnderARuleWithRoomAboveAndBelowIt() throws {
        let menu = FieldMenu()
        menu.open(heading: "Row", items: [FieldMenuItem(id: "a", title: "Forget Today", symbol: "calendar") {},
                                          FieldMenuItem(id: "b", title: "Clear History…", symbol: "trash", parted: true) {}])
        let list = FieldMenuListView(menu: menu, rowHeight: 38, headerHeight: 28)
        list.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        list.layoutSubtreeIfNeeded()

        let rows = list.kitSubviews(of: FieldMenuRowView.self).sorted { $0.frame.minY < $1.frame.minY }
        let rule = try #require(list.kitSubviews(of: KitBox.self).first { $0.superview === rows[0].superview && $0.frame.height <= 1 })

        #expect(rows[1].frame.minY - rows[0].frame.maxY == FieldMenuListView.part)
        #expect(rule.frame.minY - rows[0].frame.maxY >= 3)
        #expect(rows[1].frame.minY - rule.frame.maxY >= 3)
    }

    @Test func aPartedRowThatLeadsTheListGetsNoRule() {
        let menu = FieldMenu()
        menu.open(heading: "Row", items: [FieldMenuItem(id: "b", title: "Clear History…", symbol: "trash", parted: true) {}])
        let list = FieldMenuListView(menu: menu, rowHeight: 38, headerHeight: 28)
        list.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        list.layoutSubtreeIfNeeded()

        let rows = list.kitSubviews(of: FieldMenuRowView.self)

        #expect(rows.first?.frame.minY == 28)
        #expect(!list.kitSubviews(of: KitBox.self).contains { $0.superview === rows.first?.superview && $0.frame.height <= 1 })
    }

    private func fieldMenu(_ count: Int) throws -> (window: NSWindow, box: OmniboxView, browser: Browser) {
        let browser = fresh()
        let items = (0..<count).map { index in
            FieldMenuItem(id: "row\(index)", title: index == count - 1 ? "Clear History…" : "Action \(index)", symbol: "link",
                          parted: index == count - 1 && count > 1) {}
        }
        browser.edit()
        browser.fieldMenu.open(heading: "example.com", items: items)
        let size = NSSize(width: 760, height: 600)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let box = OmniboxView(browser: browser)
        window.contentView = box
        box.frame = NSRect(origin: .zero, size: size)
        box.needsLayout = true
        box.layoutSubtreeIfNeeded()
        return (window, box, browser)
    }

    private func clearOfTheFoot(_ box: OmniboxView) throws -> (rows: [Bool], last: Bool) {
        let bar = try #require(box.kitSubviews(of: FieldBarView.self).first)
        let list = try #require(box.kitSubviews(of: FieldMenuListView.self).first)
        let foot = bar.convert(bar.bounds, to: nil)
        let seen = list.convert(list.bounds, to: nil)
        let rows = list.kitSubviews(of: FieldMenuRowView.self).sorted { $0.frame.minY < $1.frame.minY }
        let shown = rows.map { $0.convert($0.bounds, to: nil) }.filter { $0.intersects(seen) }
        let last = try #require(rows.last).convert(try #require(rows.last).bounds, to: nil)
        return (shown.map { $0.minY >= foot.maxY }, last.minY >= foot.maxY && last.maxY <= seen.maxY)
    }

    @Test func aShortRowMenuOpensWithEveryRowClearOfTheFoot() throws {
        let (window, box, browser) = try fieldMenu(3)
        defer {
            window.contentView = nil
            browser.closeAll()
        }

        let clear = try clearOfTheFoot(box)

        #expect(clear.rows.count == 3)
        #expect(clear.rows.allSatisfy { $0 })
        #expect(clear.last)
    }

    @Test(arguments: [9, 12])
    func aLongRowMenuScrollsItsLastRowClearOfTheFoot(_ count: Int) throws {
        let (window, box, browser) = try fieldMenu(count)
        defer {
            window.contentView = nil
            browser.closeAll()
        }
        let list = try #require(box.kitSubviews(of: FieldMenuListView.self).first)
        let scroll = try #require(list.kitSubviews(of: NSScrollView.self).first)
        let atOpen = try clearOfTheFoot(box)

        let clip = scroll.contentView
        clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(x: 0, y: 100_000, width: clip.bounds.width, height: clip.bounds.height)).origin)
        scroll.reflectScrolledClipView(clip)
        let scrolled = try clearOfTheFoot(box)
        clip.setBoundsOrigin(.zero)
        browser.fieldMenu.picked = count - 1
        list.needsLayout = true
        box.layoutSubtreeIfNeeded()
        let walked = try clearOfTheFoot(box)

        #expect(!atOpen.last)
        #expect(scrolled.last)
        #expect(walked.last)
    }

    @Test func walkingWrapsAndAnEmptySearchRunsNothing() {
        let menu = FieldMenu()
        var ran = 0
        menu.open(heading: "Row", items: [FieldMenuItem(id: "a", title: "Alpha", symbol: "link") { ran += 1 },
                                          FieldMenuItem(id: "b", title: "Beta", symbol: "link") { ran += 1 }])

        menu.walk(-1)
        #expect(menu.picked == 1)
        menu.query = "zebra"
        menu.runPicked()

        #expect(ran == 0)
        #expect(menu.showing)
    }

    @Test func returnAndArrowsGoToTheMenuWhileItIsOpen() throws {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.newTab()
        browser.active?.go(to: URL(string: "https://example.com/")!)
        browser.edit()
        browser.typed = "example words"
        browser.picked = 0
        let word = browser.typed

        browser.fieldActions()
        #expect(browser.fieldMenu.showing)
        browser.walk(1)

        #expect(browser.fieldMenu.picked == 1)
        #expect(browser.typed == word)
        browser.fieldActions()
        #expect(!browser.fieldMenu.showing)
    }

    @Test func puttingTheFieldAwayClosesTheMenu() {
        let browser = fresh()
        defer { browser.closeAll() }
        browser.edit()
        browser.fieldActions()

        browser.dismiss()

        #expect(!browser.fieldMenu.showing)
    }

    @Test func forgettingASiteLeavesOtherSites() {
        visit("https://www.drop.example/one")
        visit("https://sub.drop.example/two")
        visit("https://stay.example/three")

        Shared.history.forget(site: "drop.example")

        #expect(!Shared.history.knows(History.identity(for: URL(string: "https://www.drop.example/one")!)))
        #expect(!Shared.history.knows(History.identity(for: URL(string: "https://sub.drop.example/two")!)))
        #expect(Shared.history.knows(History.identity(for: URL(string: "https://stay.example/three")!)))
    }

    @Test func forgettingSinceADateLeavesWhatIsOlder() {
        Shared.history.take(URL(string: "https://old.example/")!, title: "Old", count: 1, last: Date().addingTimeInterval(-7200))
        visit("https://new.example/")

        Shared.history.forget(since: Date().addingTimeInterval(-3600))

        #expect(Shared.history.knows(History.identity(for: URL(string: "https://old.example/")!)))
        #expect(!Shared.history.knows(History.identity(for: URL(string: "https://new.example/")!)))
    }

    @Test func draggingARowDownPutsItAfterTheNext() throws {
        let quick = store()
        let browser = fresh()
        let before = quick.shown(history: browser.history).map(\.id)
        let form = QuickActionsForm(browser: browser, store: quick)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 900), styleMask: .borderless, backing: .buffered, defer: false)
        form.frame = NSRect(x: 0, y: 0, width: 640, height: 900)
        window.contentView = form
        form.layoutSubtreeIfNeeded()
        func rows(_ view: NSView) -> [QuickActionRowView] {
            view.subviews.flatMap { ($0 as? QuickActionRowView).map { [$0] } ?? rows($0) }
        }
        let first = try #require(rows(form).first { $0.action.id == before[0] })
        let start = first.convert(NSPoint(x: first.bounds.midX, y: first.bounds.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ dy: CGFloat) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: NSPoint(x: start.x, y: start.y - dy), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let step = (first.superview?.frame.height ?? first.bounds.height) * 1.2

        first.mouseDown(with: event(.leftMouseDown, 0))
        first.mouseDragged(with: event(.leftMouseDragged, step / 2))
        first.mouseDragged(with: event(.leftMouseDragged, step))
        first.mouseUp(with: event(.leftMouseUp, step))

        let after = quick.shown(history: browser.history).map(\.id)
        #expect(after[0] == before[1])
        #expect(after[1] == before[0])
    }
}
