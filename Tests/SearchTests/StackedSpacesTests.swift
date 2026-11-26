import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct StackedSpacesTests {
    private func fresh(_ body: () -> Void) {
        let keys = [StackedFolds.key, Preferences.stackedKey, "spaces", "spaces.orderKept"]
        let saved = keys.map { ($0, Store.settings.object(forKey: $0)) }
        defer { for (key, value) in saved { Store.settings.set(value, forKey: key) } }
        keys.forEach(Store.settings.removeObject(forKey:))
        body()
    }

    @Test func stackedIsOffByDefaultAndNeedsSpaces() {
        fresh {
            let prefs = Preferences()

            let untouched = (prefs.stackedSpaces, prefs.stacksSpaces)
            prefs.stackedSpaces = true
            let withoutSpaces = prefs.stacksSpaces
            prefs.usesSpaces = true

            #expect(!untouched.0)
            #expect(!untouched.1)
            #expect(!withoutSpaces)
            #expect(prefs.stacksSpaces)
        }
    }

    @Test func theChoiceIsKeptAcrossLaunches() {
        fresh {
            let before = Preferences()

            before.stackedSpaces = true
            let after = Preferences()

            #expect(after.stackedSpaces)
            #expect((Store.settings.object(forKey: Preferences.stackedKey) as? Bool) == true)
        }
    }

    @Test func stackingIsASettingOnTheTabsPage() {
        let row = SettingsIndex.item("spaces.stacked")

        #expect(row?.findOnly == false)
        #expect(row?.page == .tabs)
        #expect(SettingsIndex.find("all spaces").contains { $0.id == "spaces.stacked" })
    }

    @Test func foldsAreRememberedPerSpace() {
        fresh {
            let work = UUID()
            let travel = UUID()
            let folds = StackedFolds()

            folds.set(work, folded: true)
            folds.toggle(travel)
            folds.toggle(travel)
            let later = StackedFolds()

            #expect(later.isFolded(work))
            #expect(!later.isFolded(travel))
            #expect(Store.settings.stringArray(forKey: StackedFolds.key) == [work.uuidString])
        }
    }

    @Test func forgettingASpaceUnfoldsIt() {
        fresh {
            let gone = UUID()
            let folds = StackedFolds()
            folds.set(gone, folded: true)

            folds.forget(gone)

            #expect(!StackedFolds().isFolded(gone))
        }
    }

    @Test func sharedPinsAreDrawnOnceAndEachSectionKeepsItsOwn() {
        let shared = UUID()
        let own = UUID()
        let pins: [(name: String, id: UUID?)] = [("mail", shared), ("linear", own), ("old", nil)]

        let top = StackedSpaces.shared(pins, id: \.id, shared: [shared]).map(\.name)
        let section = StackedSpaces.own(pins, id: \.id, shared: [shared]).map(\.name)

        #expect(top == ["mail"])
        #expect(section == ["linear", "old"])
    }

    @Test func aFoldedSectionKeepsOnlyTheTabInFrontWhenItIsActive() {
        let total = 7

        let open = StackedSpaces.shownTabs(total: total, folded: false, active: false)
        let foldedActive = StackedSpaces.shownTabs(total: total, folded: true, active: true)
        let foldedParked = StackedSpaces.shownTabs(total: total, folded: true, active: false)
        let foldedEmpty = StackedSpaces.shownTabs(total: 0, folded: true, active: true)

        #expect(open == 7)
        #expect(foldedActive == 1)
        #expect(foldedParked == 0)
        #expect(foldedEmpty == 0)
    }

    @Test func theFoldedCountReads() {
        #expect(StackedSpaces.count(1) == "1 tab")
        #expect(StackedSpaces.count(3) == "3 tabs")
    }

    @Test func aTabCarriedOverAnotherSectionFindsThatSpace() {
        let here = UUID()
        let work = UUID()
        let heads = [here: CGRect(x: 0, y: 0, width: 200, height: 30), work: CGRect(x: 0, y: 200, width: 200, height: 30)]
        let bodies = [here: CGRect(x: 0, y: 30, width: 200, height: 170), work: CGRect(x: 0, y: 230, width: 200, height: 100)]

        let onHeader = StackedSpaces.section(at: CGPoint(x: 50, y: 210), heads: heads, bodies: bodies, except: here)
        let onRows = StackedSpaces.section(at: CGPoint(x: 50, y: 300), heads: heads, bodies: bodies, except: here)
        let ownRows = StackedSpaces.section(at: CGPoint(x: 50, y: 100), heads: heads, bodies: bodies, except: here)
        let ownHeaderOverWork = StackedSpaces.section(at: CGPoint(x: 50, y: 240),
                                                      heads: [here: CGRect(x: 0, y: 230, width: 200, height: 30)],
                                                      bodies: bodies, except: here)
        let outside = StackedSpaces.section(at: CGPoint(x: 50, y: 900), heads: heads, bodies: bodies, except: here)

        #expect(onHeader == work)
        #expect(onRows == work)
        #expect(ownRows == nil)
        #expect(ownHeaderOverWork == nil)
        #expect(outside == nil)
    }

    @Test func aHeaderCarriedDownTakesTheSlotItCrossesHalfOf() {
        let (one, two, three) = (UUID(), UUID(), UUID())
        var reorder = StackedReorder(space: one, ids: [one, two, three], step: 58)!

        let short = reorder.carry(28)
        let shortOrder = reorder.order
        let past = reorder.carry(30)
        let pastOrder = reorder.order
        let shift = reorder.shift
        reorder.carry(500)

        #expect(!short)
        #expect(shortOrder == [one, two, three])
        #expect(past)
        #expect(pastOrder == [two, one, three])
        #expect(shift == CGFloat(30 - 58))
        #expect(reorder.index == 2)
        #expect(reorder.order == [two, three, one])
    }

    @Test func aHeaderCarriedUpStopsAtTheTop() {
        let (one, two, three) = (UUID(), UUID(), UUID())
        var reorder = StackedReorder(space: three, ids: [one, two, three], step: 58)!

        reorder.carry(-60)
        let once = reorder.order
        reorder.carry(-900)

        #expect(once == [one, three, two])
        #expect(reorder.order == [three, one, two])
        #expect(reorder.index == 0)
        #expect(reorder.moved)
    }

    @Test func aHeaderOnlyLiftsForASpaceInTheList() {
        #expect(StackedReorder(space: UUID(), ids: [UUID()], step: 58) == nil)
        #expect(StackedReorder(space: UUID(), ids: [], step: 58) == nil)
    }

    @Test func lettingGoKeepsTheOrderTheDragShowed() {
        fresh {
            let browser = Browser(record: WindowRecord())
            browser.prefs.usesSpaces = true
            let ids = [browser.spaceID, UUID(), UUID(), UUID()]
            browser.spaces = ids.enumerated().map { Space(id: $1, name: "S\($0)", colour: $0) }
            var down = StackedReorder(space: ids[0], ids: ids, step: 58)!
            down.carry(120)
            var up = StackedReorder(space: ids[3], ids: down.order, step: 58)!
            up.carry(-175)

            browser.moveSpace(down.space, to: down.index)
            let afterDown = browser.spaces.map(\.id)
            browser.moveSpace(up.space, to: up.index)

            #expect(afterDown == down.order)
            #expect(afterDown == [ids[1], ids[2], ids[0], ids[3]])
            #expect(browser.spaces.map(\.id) == up.order)
            #expect(browser.spaces.map(\.id) == [ids[3], ids[1], ids[2], ids[0]])
        }
    }

    @Test func theColumnScrollsOnlyNearItsEdges() {
        let height: CGFloat = 600

        let middle = StackedSpaces.edgeSpeed(y: 300, height: height)
        let nearTop = StackedSpaces.edgeSpeed(y: 10, height: height)
        let pastTop = StackedSpaces.edgeSpeed(y: -40, height: height)
        let nearBottom = StackedSpaces.edgeSpeed(y: 590, height: height)
        let tooShort = StackedSpaces.edgeSpeed(y: 5, height: 50)

        #expect(middle == 0)
        #expect(nearTop < 0)
        #expect(pastTop == -StackedSpaces.fastest)
        #expect(nearBottom > 0)
        #expect(abs(nearTop) < StackedSpaces.fastest)
        #expect(tooShort == 0)
    }

    @Test func thePageStageHasNoNeighbourWhileStacked() {
        let next = 1

        let stacked = SpaceLane.stage(next, stacked: true)
        let apart = SpaceLane.stage(next, stacked: false)
        let resting = SpaceLane.stage(nil, stacked: false)

        #expect(stacked == nil)
        #expect(apart == next)
        #expect(resting == nil)
    }

    @Test func choosingInTheSidebarGoesQuietlyAndAJumpIsAnnounced() {
        fresh {
            let browser = Browser(record: WindowRecord())
            let previous = (browser.prefs.usesSpaces, browser.prefs.stackedSpaces)
            defer { (browser.prefs.usesSpaces, browser.prefs.stackedSpaces) = previous }
            browser.prefs.usesSpaces = true
            browser.prefs.stackedSpaces = true
            let home = browser.spaceID
            let work = UUID()
            browser.spaces = [Space(id: home, name: "Personal", colour: 0), Space(id: work, name: "Work", colour: 1)]

            browser.stackedNewTab(in: work)
            let afterNewTab = (browser.spaceID, browser.announcement, browser.stageNext, browser.stageSliding)
            browser.stackedJump(to: home)
            let afterJump = (browser.spaceID, browser.announcement)

            #expect(afterNewTab.0 == work)
            #expect(afterNewTab.1 == nil)
            #expect(afterNewTab.2 == nil)
            #expect(!afterNewTab.3)
            #expect(afterJump.0 == home)
            #expect(afterJump.1 == "Personal")
        }
    }

    @Test func aFoldedSpaceGivenANewTabFromItsHeadingIsUnfolded() {
        fresh {
            let browser = Browser(record: WindowRecord())
            let previous = (browser.prefs.usesSpaces, browser.prefs.stackedSpaces)
            defer { (browser.prefs.usesSpaces, browser.prefs.stackedSpaces) = previous }
            browser.prefs.usesSpaces = true
            browser.prefs.stackedSpaces = true
            let home = browser.spaceID
            let work = UUID()
            browser.spaces = [Space(id: home, name: "Personal", colour: 0), Space(id: work, name: "Work", colour: 1)]
            StackedFolds.shared.set(work, folded: true)
            StackedFolds.shared.set(home, folded: true)
            defer { StackedFolds.shared.forget(work); StackedFolds.shared.forget(home) }

            browser.stackedNewTab(in: work)
            let away = (browser.spaceID, StackedFolds.shared.isFolded(work))
            browser.stackedNewTab(in: work)
            let here = StackedFolds.shared.isFolded(work)

            #expect(away.0 == work)
            #expect(!away.1)
            #expect(!here)
            #expect(StackedFolds.shared.isFolded(home))
        }
    }
}
