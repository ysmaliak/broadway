import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
struct FootRowTests {
    init() {
        _ = NSApplication.shared
    }

    static let rooms: [CGFloat] = [200, 258, 440].map { $0 - 2 * (SpaceFootView.lead + SpaceFootView.side + SpaceFootView.gap) + SpaceFootView.gap }

    @Test func theRoomsBetweenTheKeysAreTheOnesTheSidebarGives() {
        #expect(Self.rooms == [124, 182, 364])
    }

    @Test func aRowThatFitsIsLaidAsItAlwaysWas() {
        for room in Self.rooms {
            for count in 1...4 {
                let row = FootRow.lay(count: count, room: room, focus: 0)
                #expect(!row.many && row.pitch == 30 && row.scroll == 0 && row.before == 0 && row.after == 0)
                let total = CGFloat(count) * 28 + CGFloat(count - 1) * 2
                for (index, mark) in row.marks.enumerated() {
                    let old = 1 + (room - 2 - total) / 2 + CGFloat(index) * 30
                    #expect(abs(mark.middle - 14 - old) < 0.0001, "\(count) at \(room)")
                    #expect(mark.size == 1 && mark.share == 1 && mark.dot == 0 && mark.alpha == 1)
                }
            }
        }
    }

    @Test func whatFitsAtEachWidth() {
        let fits: [(CGFloat, Int, Int)] = [(124, 4, 6), (182, 6, 9), (364, 12, 18)]
        for (room, whole, tight) in fits {
            #expect(FootRow.lay(count: whole, room: room, focus: 0).pitch == 30)
            #expect(FootRow.lay(count: whole + 1, room: room, focus: 0).pitch < 30)
            let squeezed = FootRow.lay(count: tight, room: room, focus: 0)
            #expect(!squeezed.many && squeezed.pitch >= FootRow.tight)
            #expect(squeezed.marks.allSatisfy { $0.share == 1 && $0.dot == 0 && $0.alpha == 1 && $0.size >= FootRow.tight / FootRow.cell })
            #expect(squeezed.marks.first!.from >= 0 && squeezed.marks.last!.to <= room + 0.0001)
            #expect(FootRow.lay(count: tight + 1, room: room, focus: 0).many)
        }
    }

    @Test func theCountsAskedForAtEachWidth() {
        let wanted: [(Int, CGFloat, Bool, CGFloat)] = [
            (3, 124, false, 30), (3, 182, false, 30), (3, 364, false, 30),
            (9, 124, true, 20), (9, 182, false, 182.0 / 9), (9, 364, false, 30),
            (12, 124, true, 20), (12, 182, true, 20), (12, 364, false, 30),
            (30, 124, true, 20), (30, 182, true, 20), (30, 364, true, 20),
        ]
        for (count, room, many, pitch) in wanted {
            let row = FootRow.lay(count: count, room: room, focus: 0)
            #expect(row.many == many, "\(count) at \(room)")
            #expect(abs(row.pitch - pitch) < 0.0001, "\(count) at \(room)")
        }
    }

    @Test func everyMarkStaysInTheRoomAndInOrder() {
        for room in Self.rooms {
            for count in [3, 9, 12, 30, 60] {
                for step in 0...((count - 1) * 4) {
                    let focus = CGFloat(step) / 4
                    for pan in [-400, -30, 0, 30, 400] as [CGFloat] {
                        let row = FootRow.lay(count: count, room: room, focus: focus, pan: pan)
                        #expect(row.marks.count == count)
                        #expect(row.scroll >= 0 && row.scroll <= row.range)
                        var last: CGFloat = 0
                        for mark in row.marks {
                            #expect(mark.from >= last - 0.0001 && mark.to >= mark.from && mark.to <= room + 0.0001)
                            #expect(mark.share >= 0 && mark.share <= 1 && mark.size <= 1)
                            last = mark.to
                        }
                    }
                }
            }
        }
    }

    @Test func theSpaceInFrontIsWholeAtTheStartTheMiddleAndTheEnd() {
        for room in Self.rooms {
            for count in [12, 30] {
                let whole = FootRow.lay(count: count, room: room, focus: 0)
                guard whole.many else { continue }
                for front in [0, 1, count / 2, count - 2, count - 1] {
                    let row = FootRow.lay(count: count, room: room, focus: CGFloat(front))
                    let mark = row.marks[front]
                    #expect(mark.share == 1 && mark.dot == 0 && mark.alpha == 1, "\(count) at \(room), front \(front)")
                    #expect(mark.size == row.marks.map(\.size).max())
                    #expect(mark.from >= row.before - 0.0001 && mark.to <= room - row.after + 0.0001)
                    if row.scroll > 0, row.scroll < row.range {
                        #expect(abs(mark.middle - room / 2) < 0.0001)
                    }
                }
            }
        }
    }

    @Test func anEndWithNothingBeyondIsWholeAndAnEndWithMoreTapers() {
        for room in Self.rooms {
            let start = FootRow.lay(count: 30, room: room, focus: 0)
            #expect(start.before == 0 && start.after > 0)
            #expect(start.marks[0].from == 0 && start.marks[0].share == 1)
            #expect(start.marks.last!.alpha == 0)
            let shown = start.marks.filter { $0.alpha > 0 }
            #expect(shown.last!.share < shown.first!.share && shown.last!.dot == 1)
            let sizes = shown.map(\.size)
            #expect(sizes == sizes.sorted(by: >))

            let end = FootRow.lay(count: 30, room: room, focus: 29)
            #expect(end.after == 0 && end.before > 0)
            #expect(abs(end.marks[29].to - room) < 0.0001 && end.marks[29].share == 1)
            #expect(end.marks[0].alpha == 0)

            let middle = FootRow.lay(count: 30, room: room, focus: 15)
            #expect(middle.before == FootRow.reach(pitch: 20, room: room) && middle.after == middle.before)
            let seen = middle.marks.enumerated().filter { $0.element.alpha > 0 }.map(\.offset)
            #expect(seen.first! > 0 && seen.last! < 29 && seen.contains(15))
            let small = middle.marks.filter { $0.alpha > 0 && $0.small }.count
            #expect(small >= 2)
        }
    }

    @Test func whichMarksShowForThirtyAtEachWidth() {
        let wanted: [(CGFloat, Int, Int)] = [(124, 3, 9), (182, 5, 13), (364, 15, 21)]
        for (room, whole, shown) in wanted {
            let row = FootRow.lay(count: 30, room: room, focus: 15)
            #expect(row.marks.filter { $0.share == 1 }.count == whole, "\(room): \(row.marks.filter { $0.share == 1 }.count)")
            #expect(row.marks.filter { $0.alpha > 0 }.count == shown, "\(room): \(row.marks.filter { $0.alpha > 0 }.count)")
        }
    }

    @Test func theRowMovesWithoutAJumpAsTheFocusTheRoomThePanAndTheDraftChange() {
        func apart(_ a: FootRow, _ b: FootRow) -> (move: CGFloat, size: CGFloat) {
            var move: CGFloat = 0, size: CGFloat = 0
            for (one, other) in zip(a.marks, b.marks) {
                move = max(move, abs(one.middle - other.middle))
                size = max(size, abs(one.size - other.size))
            }
            return (move, size)
        }
        for room in Self.rooms {
            for count in [9, 12, 30] {
                var before = FootRow.lay(count: count, room: room, focus: 0)
                for step in 1...((count - 1) * 50) {
                    let row = FootRow.lay(count: count, room: room, focus: CGFloat(step) / 50)
                    let gap = apart(before, row)
                    #expect(gap.move <= 1.2 && gap.size <= 0.05, "focus \(step) of \(count) at \(room): \(gap)")
                    before = row
                }
                before = FootRow.lay(count: count, room: room, focus: CGFloat(count / 2), pan: -300)
                for step in -299...300 {
                    let row = FootRow.lay(count: count, room: room, focus: CGFloat(count / 2), pan: CGFloat(step))
                    let gap = apart(before, row)
                    #expect(gap.move <= 2.5 && gap.size <= 0.08, "pan \(step) of \(count) at \(room): \(gap)")
                    before = row
                }
                before = FootRow.lay(count: count, draft: 0, room: room, focus: CGFloat(count - 1))
                for step in 1...50 {
                    let share = CGFloat(step) / 50
                    let row = FootRow.lay(count: count, draft: share, room: room, focus: CGFloat(count - 1) + share)
                    let gap = apart(before, row)
                    #expect(gap.move <= 1.2 && gap.size <= 0.05, "draft \(step) of \(count) at \(room): \(gap)")
                    before = row
                }
            }
        }
        for count in 1...40 {
            for front in [0, count / 2, count - 1] {
                var before = FootRow.lay(count: count, room: 124, focus: CGFloat(front))
                for room in 125...364 {
                    let row = FootRow.lay(count: count, room: CGFloat(room), focus: CGFloat(front))
                    let gap = apart(before, row)
                    #expect(gap.move <= 1.6 && gap.size <= 0.05, "room \(room) for \(count), front \(front): \(gap)")
                    before = row
                }
            }
        }
    }

    @Test func theFocusLiesBetweenTheSpaceHereAndTheOneComing() {
        #expect(FootRow.focus([0, 1, 0]) == 1)
        #expect(FootRow.focus([0.75, 0, 0, 0.25]) == 0.75)
        #expect(FootRow.focus([0, 0, 0]) == nil)
        let going = [FootLight(here: true, next: false, going: true, progress: 0.4).lit,
                     FootLight(here: false, next: false, going: true, progress: 0.4).lit,
                     FootLight(here: false, next: true, going: true, progress: 0.4).lit]
        #expect(abs((FootRow.focus(going) ?? 0) - 0.8) < 0.0001)
    }

    @Test func aPanIsHeldToTheRowAndAPageKeepsOneMarkInView() {
        for room in Self.rooms {
            let row = FootRow.lay(count: 30, room: room, focus: 0, pan: 10_000)
            #expect(row.scroll == row.range && row.pan == row.range - row.rest)
            #expect(row.marks[29].share == 1 && abs(row.marks[29].to - room) < 0.0001)
            let back = FootRow.lay(count: 30, room: room, focus: 29, pan: -10_000)
            #expect(back.scroll == 0 && back.marks[0].share == 1)
            #expect(row.page >= row.pitch && row.page <= room - row.pitch)
            #expect(Int((row.range / row.page).rounded(.up)) <= 12)
        }
    }

    @Test func aNewSpaceWearsTheIconFewestSpacesWear() {
        var spaces = [Space.first()]
        #expect(Spaces.leastWorn(in: spaces) == "briefcase")
        for index in 0..<40 {
            spaces.append(Space(id: UUID(), name: "S\(index)", colour: 0, icon: TabIcon(symbol: Spaces.leastWorn(in: spaces))))
        }
        #expect(Set(spaces.prefix(24).map(\.symbol)).count == 24)
        let worn = Dictionary(grouping: spaces, by: \.symbol).mapValues(\.count)
        #expect(worn.values.max() == 2 && worn.count == 24)
        #expect(worn["briefcase"] == 2)
        let plain = (0..<5).map { Space(id: UUID(), name: "Old \($0)", colour: 0) }
        #expect(Spaces.leastWorn(in: plain) == "building.2")
        #expect(Spaces.leastWorn(in: [Space(id: UUID(), name: "E", colour: 0, icon: TabIcon(emoji: "🌱"))]) == "briefcase")
    }

    private func foot(_ browser: Browser, spaces count: Int, width: CGFloat) -> (SpaceFootView, NSWindow) {
        let prefs = browser.prefs
        prefs.usesSpaces = true
        prefs.stackedSpaces = false
        browser.spaces = [browser.spaces[0]] + (1..<count).map { Space(id: UUID(), name: "S\($0)", colour: 0, icon: TabIcon(symbol: Spaces.icons[$0 % 24])) }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: SpaceFootView.height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        browser.window = window
        let made = SpaceFootView(browser: browser)
        made.fetch = FetchDoorView(browser: browser, fetches: browser.fetches, always: true)
        made.frame = NSRect(x: 0, y: 0, width: width, height: SpaceFootView.height)
        window.contentView = made
        made.layoutSubtreeIfNeeded()
        return (made, window)
    }

    @Test func withManySpacesNothingLiesOverTheKeysAndTheKeysStillTakeThePress() throws {
        for width in [200, 258, 440] as [CGFloat] {
            for count in [3, 9, 12, 30] {
                let browser = Browser(record: WindowRecord())
                browser.leaveFiles()
                let prefs = browser.prefs
                let previous = (prefs.usesSpaces, prefs.stackedSpaces)
                let (view, window) = foot(browser, spaces: count, width: width)
                defer {
                    window.contentView = nil
                    window.close()
                    browser.closeAll()
                    (prefs.usesSpaces, prefs.stackedSpaces) = previous
                }
                let downloads = try #require(view.kitSubviews(of: FetchDoorView.self).first)
                let plus = try #require(view.kitSubviews(of: DoorView.self).first)
                let spots = view.kitSubviews(of: SpaceSpotView.self)
                #expect(spots.count == count)
                for key in [downloads, plus] as [NSView] {
                    let hit = view.hitTest(NSPoint(x: key.frame.midX, y: key.frame.midY))
                    #expect(hit != nil && (hit === key || hit?.isDescendant(of: key) == true), "\(count) at \(width)")
                }
                let strip = try #require(view.kitSubviews(of: FootStripView.self).first)
                #expect(strip.frame.minX >= downloads.frame.maxX && strip.frame.maxX <= plus.frame.minX)
                #expect(strip.clipsToBounds)
                for spot in spots where spot.alphaValue > 0 {
                    #expect(spot.frame.minX >= strip.frame.minX - 0.01 && spot.frame.maxX <= strip.frame.maxX + 0.01, "\(count) at \(width): \(spot.frame)")
                }
                let front = try #require(spots.first { $0.accessibilityIdentifier() == "space-" + browser.spaceID.uuidString })
                #expect(front.alphaValue == 1 && !front.small)
                #expect(front.frame.width == spots.map(\.frame.width).max())
                #expect(view.pans == (view.row.range > 0))
                if count == 3 {
                    #expect(spots.allSatisfy { $0.frame.size == NSSize(width: 28, height: 28) })
                    #expect(abs(spots.map(\.frame.midX).reduce(0, +) / 3 - width / 2) < 0.01)
                }
                if view.pans {
                    let hidden = spots.filter { $0.alphaValue == 0 }
                    #expect(!hidden.isEmpty)
                    for spot in hidden {
                        #expect(view.hitTest(NSPoint(x: spot.frame.midX, y: spot.frame.midY)) !== spot)
                    }
                }
            }
        }
    }

    @Test func aScrollOverTheFootBringsEverySpaceIntoViewAndTheRowComesBack() throws {
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.stackedSpaces)
        let (view, window) = foot(browser, spaces: 30, width: 200)
        defer {
            window.contentView = nil
            window.close()
            browser.closeAll()
            (prefs.usesSpaces, prefs.stackedSpaces) = previous
        }
        let spots = view.kitSubviews(of: SpaceSpotView.self)
        func whole(_ index: Int) -> Bool {
            let wanted = "space-" + browser.spaces[index].id.uuidString
            guard let spot = spots.first(where: { $0.accessibilityIdentifier() == wanted }) else { return false }
            return spot.alphaValue == 1 && !spot.small && view.hitTest(NSPoint(x: spot.frame.midX, y: spot.frame.midY)) === spot
        }
        #expect(whole(0) && !whole(29))
        #expect(SpaceSwipe.shared.foot(at: view.convert(NSPoint(x: 100, y: 18), to: nil), in: browser, window: window) === view)
        var reached: Set<Int> = [0]
        for _ in 0..<80 {
            #expect(view.wheel(dx: -12, dy: 0, precise: true))
            for index in 0..<30 where whole(index) { reached.insert(index) }
        }
        #expect(reached == Set(0..<30))
        #expect(view.row.scroll == view.row.range)
        #expect(view.wheel(dx: 0, dy: 3, precise: false))
        #expect(view.row.scroll == view.row.range - 3 * view.row.pitch)
        view.page(-1)
        view.comeBack(after: 0)
        let few = foot(browser, spaces: 3, width: 258)
        defer {
            few.1.contentView = nil
            few.1.close()
        }
        #expect(!few.0.wheel(dx: -12, dy: 0, precise: true))
        #expect(SpaceSwipe.shared.foot(at: few.0.convert(NSPoint(x: 100, y: 18), to: nil), in: browser, window: few.1) == nil)
    }

    @Test func aSmallMarkKeepsItsNameAndItsMenuAndANewSpaceShowsWholeAtTheEnd() throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        let prefs = browser.prefs
        let previous = (prefs.usesSpaces, prefs.stackedSpaces)
        let (view, window) = foot(browser, spaces: 30, width: 258)
        defer {
            window.contentView = nil
            window.close()
            browser.closeAll()
            (prefs.usesSpaces, prefs.stackedSpaces) = previous
        }
        let strip = try #require(view.kitSubviews(of: FootStripView.self).first)
        let plus = try #require(view.kitSubviews(of: DoorView.self).first)
        let small = try #require(view.kitSubviews(of: SpaceSpotView.self).first { $0.small && $0.alphaValue > 0.05 })
        #expect(!small.name.isEmpty && small.toolTip == small.name && small.accessibilityLabel() == small.name)
        #expect(view.hitTest(NSPoint(x: small.frame.midX, y: small.frame.midY)) === small)
        let press = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let titles = small.menu(for: press)?.items.map(\.title) ?? []
        #expect(titles.contains("Rename “\(small.name)”…") && titles.contains("Change Icon…") && !titles.contains("Open Space Menu"))

        browser.makingSpace = true
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let spots = view.kitSubviews(of: SpaceSpotView.self)
        #expect(spots.count == 31)
        let draft = try #require(spots.first { $0.kind == .draft })
        #expect(draft.alphaValue == 1 && !draft.small)
        #expect(draft.frame.minX >= strip.frame.minX - 0.01 && draft.frame.maxX <= strip.frame.maxX + 0.01)
        #expect(draft.frame.width == spots.map(\.frame.width).max())
        #expect(view.row.scroll == view.row.range && view.row.after == 0 && view.row.before > 0)
        let hit = view.hitTest(NSPoint(x: plus.frame.midX, y: plus.frame.midY))
        #expect(hit != nil && (hit === plus || hit?.isDescendant(of: plus) == true))

        browser.makingSpace = false
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        #expect(view.kitSubviews(of: SpaceSpotView.self).count == 30)
        #expect(view.row.scroll == 0)
    }
}
