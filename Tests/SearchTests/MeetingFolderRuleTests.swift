import Foundation
import Testing
@testable import Search

@Suite
struct MeetingFolderRuleTests {
    private let design = MeetingFolderCall(key: "meet:qwe-rtyu-iop", name: "Design review")
    private let callID = UUID()
    private let docID = UUID()
    private let linkID = UUID()

    private func pages(_ list: [MeetingFolderPage]) -> [UUID: MeetingFolderPage] {
        Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { one, _ in one })
    }

    private func plan(_ opened: MeetingFolderPage, call: MeetingFolderPage? = nil, others: [MeetingFolderPage] = [],
                      on: Bool = true, isPrivate: Bool = false, declined: Set<String> = [],
                      folders: [String: UUID] = [:]) -> MeetingFolderPlan? {
        let call = call ?? MeetingFolderPage(id: callID, call: design)
        return MeetingFolderRule.plan(for: opened, pages: pages([call, opened] + others), on: on, isPrivate: isPrivate,
                                      declined: declined, folders: folders)
    }

    @Test func aPageOpenedFromTheCallGoesInWithTheCall() {
        let made = plan(MeetingFolderPage(id: docID, from: callID))

        #expect(made == MeetingFolderPlan(call: design, callTab: callID, moving: [callID, docID], folder: nil))
    }

    @Test func aPageOpenedFromAPageThatCameFromTheCallGoesInToo() {
        let doc = MeetingFolderPage(id: docID, from: callID)

        let made = plan(MeetingFolderPage(id: linkID, from: docID), others: [doc])

        #expect(made?.callTab == callID)
        #expect(made?.moving == [callID, linkID])
    }

    @Test func aTabOpenedByHandIsLeftWhereItIs() {
        #expect(plan(MeetingFolderPage(id: docID)) == nil)
    }

    @Test func aPageOpenedFromATabThatIsNotOnACallIsLeftAlone() {
        let call = MeetingFolderPage(id: callID)

        #expect(plan(MeetingFolderPage(id: docID, from: callID), call: call) == nil)
    }

    @Test func aPinnedTabStaysAPin() {
        #expect(plan(MeetingFolderPage(id: docID, from: callID, pinned: true)) == nil)
    }

    @Test func aPinnedCallKeepsItsPinAndItsPagesGatherWithoutIt() {
        let call = MeetingFolderPage(id: callID, pinned: true, call: design)

        let made = plan(MeetingFolderPage(id: docID, from: callID), call: call)

        #expect(made?.moving == [docID])
        #expect(made?.call.name == "Design review")
    }

    @Test func anAgentsTabNeverGoesIn() {
        #expect(plan(MeetingFolderPage(id: docID, from: callID, agent: true)) == nil)
    }

    @Test func aPageOpenedFromAnAgentsTabIsNotTraced() {
        let agent = MeetingFolderPage(id: docID, from: callID, agent: true)

        #expect(plan(MeetingFolderPage(id: linkID, from: docID), others: [agent]) == nil)
    }

    @Test func aPopupWindowIsLeftAlone() {
        #expect(plan(MeetingFolderPage(id: docID, from: callID, popup: true)) == nil)
    }

    @Test func nothingHappensInAPrivateWindow() {
        #expect(plan(MeetingFolderPage(id: docID, from: callID), isPrivate: true) == nil)
    }

    @Test func nothingHappensWithTheSwitchOff() {
        #expect(plan(MeetingFolderPage(id: docID, from: callID), on: false) == nil)
    }

    @Test func aCallUndoneOnceMakesNoFolderAgain() {
        #expect(plan(MeetingFolderPage(id: docID, from: callID), declined: [design.key]) == nil)
    }

    @Test func theSameMeetingUsesItsFolderStill() {
        let folder = UUID()

        let made = plan(MeetingFolderPage(id: docID, from: callID), folders: [design.key: folder])

        #expect(made?.folder == folder)
        #expect(made?.moving == [callID, docID])
    }

    @Test func aPageAlreadyInTheMeetingsFolderAsksForNothing() {
        let folder = UUID()
        let call = MeetingFolderPage(id: callID, group: folder, call: design)

        #expect(plan(MeetingFolderPage(id: docID, from: callID, group: folder), call: call, folders: [design.key: folder]) == nil)
    }

    @Test func aCallAlreadyInItsFolderStaysAndOnlyTheNewPageMoves() {
        let folder = UUID()
        let call = MeetingFolderPage(id: callID, group: folder, call: design)

        #expect(plan(MeetingFolderPage(id: docID, from: callID), call: call, folders: [design.key: folder])?.moving == [docID])
    }

    @Test func aChainThatLoopsEndsWithoutAFolder() {
        let one = MeetingFolderPage(id: callID, from: docID)
        let two = MeetingFolderPage(id: docID, from: callID)

        #expect(MeetingFolderRule.plan(for: two, pages: pages([one, two]), on: true, isPrivate: false, declined: [], folders: [:]) == nil)
    }

    @Test func joiningTheSameMeetingAgainUsesItsFolder() {
        let folder = UUID()
        let call = MeetingFolderPage(id: callID, call: design)

        #expect(MeetingFolderRule.joining(call, folders: [design.key: folder], declined: [], on: true, isPrivate: false) == folder)
        #expect(MeetingFolderRule.joining(call, folders: [:], declined: [], on: true, isPrivate: false) == nil)
        #expect(MeetingFolderRule.joining(call, folders: [design.key: folder], declined: [design.key], on: true, isPrivate: false) == nil)
        #expect(MeetingFolderRule.joining(call, folders: [design.key: folder], declined: [], on: false, isPrivate: false) == nil)
        #expect(MeetingFolderRule.joining(call, folders: [design.key: folder], declined: [], on: true, isPrivate: true) == nil)
    }

    @Test func theNameIsTheEventsTitleOrElseTheService() {
        #expect(MeetingFolderRule.name(event: "Design review", service: .meet) == "Design review")
        #expect(MeetingFolderRule.name(event: nil, service: .zoom) == "Zoom")
        #expect(MeetingFolderRule.name(event: "  ", service: .teams) == "Microsoft Teams")
        #expect(MeetingFolderRule.name(event: nil, service: .slack) == "Slack huddle")
    }

    @Test func theSameMeetingHasTheSameKeyWhateverItsAddressCarries() {
        let one = URL(string: "https://example.zoom.us/j/81234567890?pwd=abc")!
        let two = URL(string: "https://example.zoom.us/j/81234567890")!
        let other = URL(string: "https://example.zoom.us/j/81234567891")!

        #expect(MeetingFolderRule.key(one) == MeetingFolderRule.key(two))
        #expect(MeetingFolderRule.key(one) != MeetingFolderRule.key(other))
        #expect(MeetingFolderRule.key(URL(string: "https://news.example.test/today")!) == nil)
    }

    @Test func aTabOpenedByHandFromTheFolderStaysOutWhileTheCallLasts() {
        #expect(MeetingFolderRule.keepsLoose(byHand: true, meetingLive: true))
        #expect(!MeetingFolderRule.keepsLoose(byHand: true, meetingLive: false))
        #expect(!MeetingFolderRule.keepsLoose(byHand: false, meetingLive: true))
    }

    @Test func undoPutsTheRowBackAndKeepsLaterTabsBesideTheirNeighbours() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), later = UUID()

        #expect(MeetingFolderRule.restoredRow([c, d, a, b], before: [a, b, c, d]) == [a, b, c, d])
        #expect(MeetingFolderRule.restoredRow([c, d, later, a, b], before: [a, b, c, d]) == [a, b, c, d, later])
        #expect(MeetingFolderRule.restoredRow([later, a, b], before: [a, b]) == [later, a, b])
    }

    @Test func theSwitchIsOnUnlessTurnedOff() {
        let store = UserDefaults(suiteName: "meeting-folder-rule-\(UUID().uuidString)")!

        #expect(Preferences.meetingFoldersOn(store))
        store.set(false, forKey: Preferences.meetingFoldersKey)
        #expect(!Preferences.meetingFoldersOn(store))
    }
}
