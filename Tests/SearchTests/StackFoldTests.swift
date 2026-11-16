import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class StackFoldTests {
    private var browser: Browser!
    private var tabs: [Search.Tab] = []
    private var group = TabGroup(id: UUID(), name: "PRs", collapsed: false, live: true)

    init() {
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        for number in 0..<5 {
            if number > 0 { browser.newTab() }
            browser.tabs.last?.restore(url: URL(string: "https://github.com/acme/rocket/pull/\(number)")!, title: "PR \(number)")
        }
        tabs = browser.tabs
        for (tab, position) in zip(tabs, [nil, 3, 2, 1, nil]) {
            tab.liveItem = LiveItem(key: "pr-\(tab.title)", title: tab.title, author: "octo",
                                    stack: position.map { LiveStack(position: $0, count: 3) },
                                    branch: LiveBranch(repository: "acme/rocket", base: "b", head: "h"))
        }
        let browser = browser!
        addTeardownBlock { @MainActor in browser.closeAll() }
    }

    private func shown(front: Search.Tab.ID? = nil) -> [Search.Tab.ID] {
        Browser.unfoldedStacks(tabs, in: group, front: front).map(\.id)
    }

    private func toggle(_ top: Int) {
        group.foldedStacks = Browser.toggledStacks(tabs, in: group, top: tabs[top].id) ?? group.foldedStacks
    }

    @Test func aStacksTopRowCarriesTheFoldAndTheRestShowUntilFolded() {
        let tops = Browser.stackTops(tabs, in: group)

        #expect(tops == [tabs[1].id: false])
        #expect(shown() == tabs.map(\.id))
    }

    @Test func foldingAStackLeavesItsTopRowAndUnfoldingBringsTheRestBack() {
        toggle(1)

        #expect(shown() == [tabs[0], tabs[1], tabs[4]].map(\.id))
        #expect(Browser.stackTops(tabs, in: group) == [tabs[1].id: true])
        #expect(Set(group.foldedStacks) == ["pr-PR 1", "pr-PR 2", "pr-PR 3"])
        #expect(tabs[1].liveItem?.who == "octo 3/3", "the folded top row still says where it stands")

        toggle(1)

        #expect(shown() == tabs.map(\.id))
        #expect(group.foldedStacks.isEmpty)
    }

    @Test func onlyAStacksTopRowFoldsIt() {
        let fromMiddle = Browser.toggledStacks(tabs, in: group, top: tabs[2].id)
        let fromLoose = Browser.toggledStacks(tabs, in: group, top: tabs[0].id)

        #expect(fromMiddle == nil)
        #expect(fromLoose == nil)
    }

    @Test func theTabInFrontStaysInAFoldedStack() {
        toggle(1)

        let visible = shown(front: tabs[2].id)

        #expect(visible == [tabs[0], tabs[1], tabs[2], tabs[4]].map(\.id))
    }

    @Test func aPullRequestStackedOnAFoldedStackStaysFolded() {
        toggle(1)

        tabs[0].liveItem?.stack = LiveStack(position: 4, count: 4)
        for (tab, position) in zip(tabs[1...3], [3, 2, 1]) { tab.liveItem?.stack = LiveStack(position: position, count: 4) }

        #expect(Browser.stackTops(tabs, in: group) == [tabs[0].id: true])
        #expect(shown() == [tabs[0], tabs[4]].map(\.id))
    }

    @Test func aFolderThatIsNotLiveNeverFoldsStacks() {
        toggle(1)

        group.live = false

        #expect(Browser.stackTops(tabs, in: group).isEmpty)
        #expect(shown() == tabs.map(\.id))
    }

    @Test func foldedStacksAreSavedWithTheFolder() throws {
        toggle(1)

        let saved = try JSONDecoder().decode(TabGroup.self, from: JSONEncoder().encode(group))
        let older = try JSONDecoder().decode(TabGroup.self, from: Data(#"{"id":"00000000-0000-0000-0000-00000000000A","name":"PRs"}"#.utf8))

        #expect(saved.foldedStacks == group.foldedStacks)
        #expect(older.foldedStacks.isEmpty)
    }

    @Test func aClickOnTheChevronPressesItAndNotTheRowUnderIt() throws {
        let policy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 40), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let page = SideDocumentView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView = page
        let row = TabRowView.take(in: page)
        page.addSubview(row)
        row.frame = NSRect(x: 4, y: 3, width: 190, height: 34)
        row.show(tabs[1], in: browser, state: RowState())
        var pressed = 0
        StackFoldButton.dress(row, StackFoldButton.Dress(folded: false) { pressed += 1 }, lit: false, fades: false)
        let chevron = try #require(StackFoldButton.on(row))
        window.orderFrontRegardless()
        defer {
            window.contentView = nil
            window.close()
            NSApp.setActivationPolicy(policy)
        }
        let middle = chevron.convert(NSPoint(x: chevron.bounds.midX, y: chevron.bounds.midY), to: nil)

        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: middle, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            window.sendEvent(event)
        }

        #expect(page.superview?.hitTest(middle) === chevron)
        #expect(pressed == 1)
        #expect(!chevron.mouseDownCanMoveWindow)
    }

    @Test func theChevronIsAButtonNamedForWhatItDoes() {
        let chevron = StackFoldButton()
        var pressed = 0
        chevron.action = { pressed += 1 }

        let open = chevron.accessibilityLabel()
        chevron.folded = true
        let shut = chevron.accessibilityLabel()
        let took = chevron.accessibilityPerformPress()

        #expect(chevron.accessibilityRole() == .button)
        #expect(open == "Fold Stack")
        #expect(shut == "Unfold Stack")
        #expect(took && pressed == 1)
    }

    @Test func goingToAPRHiddenInAFoldedStackUnfoldsThatStack() {
        toggle(1)

        let opened = Browser.stacksOpened(tabs, in: group, for: tabs[3].id)

        #expect(opened == [])
    }

    @Test func goingToAFoldedStacksTopOrALooseRowLeavesTheFold() {
        toggle(1)

        let fromTop = Browser.stacksOpened(tabs, in: group, for: tabs[1].id)
        let fromLoose = Browser.stacksOpened(tabs, in: group, for: tabs[4].id)

        #expect(fromTop == nil)
        #expect(fromLoose == nil)
    }

    @Test func selectingAHiddenPRUnfoldsItsStackInTheBrowser() {
        browser.tabGroups = [group]
        for tab in tabs { tab.groupID = group.id }
        browser.toggleStack(tabs[1].id, in: group.id)
        let folded = browser.tabGroups.first?.foldedStacks ?? []

        browser.select(tabs[2])

        #expect(Set(folded) == ["pr-PR 1", "pr-PR 2", "pr-PR 3"])
        #expect(browser.tabGroups.first?.foldedStacks == [])
    }

    @Test func closingAStacksTopHandsTheChevronToTheNextRowAndKeepsTheFold() {
        let left = tabs.filter { $0.id != tabs[1].id }

        let open = Browser.stackTops(left, in: group)
        toggle(1)
        let shut = Browser.stackTops(left, in: group)

        #expect(open == [tabs[2].id: false])
        #expect(shut == [tabs[2].id: true])
    }

    @Test func theChevronIsDrawnAsAPathThatTurnsAboutTheChipsMiddle() throws {
        let chevron = StackFoldButton()
        chevron.frame = NSRect(x: 0, y: 0, width: StackFoldButton.width, height: StackFoldButton.width)
        chevron.layoutSubtreeIfNeeded()
        let arrow = try #require(chevron.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)

        let open = arrow.value(forKeyPath: "transform.rotation.z") as? CGFloat
        chevron.folded = true
        let shut = arrow.value(forKeyPath: "transform.rotation.z") as? CGFloat

        let box = try #require(arrow.path?.boundingBoxOfPath)
        #expect(abs((open ?? 0) - .pi / 2) < 0.001)
        #expect(abs(shut ?? 1) < 0.001)
        #expect(arrow.position == CGPoint(x: chevron.bounds.midX, y: chevron.bounds.midY))
        #expect(abs(box.midY - StackFoldButton.chip / 2) < 0.01)
        #expect(abs(box.midX - StackFoldButton.chip / 2) < 0.2)
        #expect(arrow.lineCap == .round && arrow.fillColor == nil)
    }

    @Test func theChevronLightsWhileItsRowIsHovered() {
        let chevron = StackFoldButton()
        let rest = chevron.tint

        chevron.lit = true
        let lit = chevron.tint
        chevron.lit = false

        #expect(lit == Palette.NS.ink)
        #expect(rest == Palette.NS.muted)
        #expect(chevron.tint == Palette.NS.muted)
    }

    private func subviews<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { sub -> [T] in (sub as? T).map { [$0] } ?? subviews(of: type, in: sub) }
    }
}
