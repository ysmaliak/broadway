import Foundation
import Testing
@testable import Search

@MainActor
struct LiveTrustTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pull(_ number: Int, _ lists: [PullList]? = nil) -> LiveItem {
        var item = LiveItem(key: "https://github.com/acme/rocket/pull/\(number)", title: "Pull \(number)")
        item.on = lists
        item.list = lists?.first
        return item
    }

    private func page(_ number: Int) -> LiveItem {
        LiveItem(key: "https://example.com/post/\(number)", title: "Post \(number)")
    }

    private func folder(_ items: [LiveItem], source: LiveSource = .pullRequests) -> LiveFolder {
        var made = LiveFolder(space: UUID(), name: "Folder", source: source)
        made.items = items
        made.state = .fine
        made.noticing = true
        return made
    }

    private func numbers(_ folder: LiveFolder) -> [Int] {
        folder.items.compactMap { Int($0.key.split(separator: "/").last ?? "") }
    }

    @Test func aWholeReadReplacesTheRows() {
        let before = folder([pull(1, [.reviewRequests]), pull(2, [.created])])

        let after = LiveTrust.after(before, .read(LiveRead(items: [pull(2), pull(3)], marked: true)), now: now)

        #expect(numbers(after) == [2, 3])
        #expect(after.state == .fine)
    }

    @Test func aListThatFailedKeepsItsRowsAndTheOthersAreTaken() {
        let before = folder([pull(1, [.reviewRequests]), pull(2, [.created]), pull(3, [.assigned])])
        let read = LiveRead(items: [pull(4, [.reviewRequests]), pull(3, [.assigned])], missed: [.created: LiveMiss()], marked: true)

        let after = LiveTrust.after(before, .read(read), now: now)

        #expect(Set(numbers(after)) == [2, 3, 4])
        #expect(after.state == .failed)
        #expect(after.note == .failed)
    }

    @Test func aRowOnTwoListsStaysWhileOneOfThemFailed() {
        let before = folder([pull(1, [.reviewRequests, .created])])
        let read = LiveRead(items: [], missed: [.created: LiveMiss()], marked: true)

        let after = LiveTrust.after(before, .read(read), now: now)

        #expect(numbers(after) == [1])
    }

    @Test func aRowSavedWithoutItsListsStaysWhileAnyListFailed() {
        let before = folder([pull(1)])
        let read = LiveRead(items: [pull(5, [.created])], missed: [.assigned: LiveMiss()], marked: true)

        let after = LiveTrust.after(before, .read(read), now: now)

        #expect(Set(numbers(after)) == [1, 5])
    }

    @Test func aListSignedOutKeepsItsRowsAndAsksToSignIn() {
        let before = folder([pull(1, [.reviewRequests]), pull(2, [.created])])
        let read = LiveRead(items: [pull(1, [.reviewRequests])], signedOut: [.created], marked: true)

        let after = LiveTrust.after(before, .read(read), now: now)

        #expect(numbers(after) == [1, 2])
        #expect(after.note == .signIn)
    }

    @Test func anEmptyPageWithTheSitesMarkerEmptiesTheFolder() {
        let before = folder([pull(1), pull(2)])

        let after = LiveTrust.after(before, .read(LiveRead(items: [], marked: true)), now: now)

        #expect(after.items.isEmpty)
        #expect(after.note == .empty)
    }

    @Test func anEmptyPageWithoutTheMarkerFailsAndTheRowsStay() {
        let before = folder([pull(1), pull(2)])

        let after = LiveTrust.after(before, .read(LiveRead(items: [])), now: now)

        #expect(numbers(after) == [1, 2])
        #expect(after.state == .failed)
    }

    @Test func anEmptyPageIsBelievedForAFolderThatHadNoRows() {
        let after = LiveTrust.after(folder([]), .read(LiveRead(items: [])), now: now)

        #expect(after.state == .fine)
        #expect(after.note == .empty)
    }

    @Test func aScanStillGrowingAddsRowsAndTakesNone() {
        let before = folder([pull(1), pull(2)])

        let after = LiveTrust.after(before, .read(LiveRead(items: [pull(3)], whole: false)), now: now)

        #expect(Set(numbers(after)) == [1, 2, 3])
    }

    @Test func theLastTwoScansTellWhetherAPageWasStillGrowing() {
        #expect(LiveReader.growing([0, 2, 5, 9]))
        #expect(!LiveReader.growing([0, 2, 5, 5]))
        #expect(!LiveReader.growing([4]))
        #expect(!LiveReader.growing([]))
    }

    @Test func aListMarkedEmptyTwiceInARowIsProvedEmpty() {
        #expect(LiveReader.provedEmpty([true, true]))
        #expect(LiveReader.provedEmpty([false, true, true]))
    }

    @Test func oneMarkedScanOrAnUnmarkedEmptyPageKeepsWaiting() {
        #expect(!LiveReader.provedEmpty([true]))
        #expect(!LiveReader.provedEmpty([true, false]))
        #expect(!LiveReader.provedEmpty([false, false, false]))
    }

    @Test func aRowLeavingOnceIsReadAgainAndStaysWhenTheSecondReadHasIt() async {
        let had = [pull(1), pull(2)]
        var answers: [LiveReader.Answer] = [.read(LiveRead(items: [pull(1)], marked: true)),
                                            .read(LiveRead(items: [pull(1), pull(2)], marked: true))]
        var asked = 0

        let answer = await LiveTrust.looked(had, known: [], pause: .zero) {
            asked += 1
            return answers.removeFirst()
        }

        #expect(asked == 2)
        #expect(answer.found?.map(\.key) == had.map(\.key))
    }

    @Test func aRowLeavingInBothReadsLeaves() async {
        let had = [pull(1), pull(2)]
        var answers: [LiveReader.Answer] = [.read(LiveRead(items: [pull(1)], marked: true)),
                                            .read(LiveRead(items: [pull(1), pull(3)], marked: true))]

        let answer = await LiveTrust.looked(had, known: [], pause: .zero) { answers.removeFirst() }

        #expect(Set(answer.found?.map(\.key) ?? []) == Set([pull(1), pull(3)].map(\.key)))
    }

    @Test func aRowThatLeavesForAKnownReasonCostsNoSecondRead() async {
        var asked = 0

        _ = await LiveTrust.looked([pull(1), pull(2)], known: [LiveIdentity.of(pull(2).key)], pause: .zero) {
            asked += 1
            return .read(LiveRead(items: [pull(1)], marked: true))
        }

        #expect(asked == 1)
    }

    @Test func aSecondReadThatFailsKeepsTheLeavingRows() async {
        var answers: [LiveReader.Answer] = [.read(LiveRead(items: [pull(1)], marked: true)), .failed]

        let answer = await LiveTrust.looked([pull(1), pull(2)], known: [], pause: .zero) { answers.removeFirst() }
        let after = LiveTrust.after(folder([pull(1), pull(2)]), answer, now: now)

        #expect(numbers(after) == [1, 2])
    }

    @Test func anEmptyPageWithoutTheMarkerIsReadOnceMoreAndFailsWhenStillEmpty() async {
        var asked = 0
        let before = folder([pull(1)])

        let answer = await LiveTrust.looked(before.items, known: [], pause: .zero) {
            asked += 1
            return .read(LiveRead(items: []))
        }
        let after = LiveTrust.after(before, answer, now: now)

        #expect(asked == 2)
        #expect(numbers(after) == [1])
        #expect(after.state == .failed)
    }

    @Test func aListReadEmptyTwiceWithoutTheMarkerCountsAsFailed() async {
        let before = [pull(1, [.reviewRequests]), pull(2, [.created])]
        var asked: [URL] = []

        let answer = await LiveReader.readLists(.pullRequests, before: before, pause: .zero) { url in
            asked.append(url)
            if url == PullList.created.page(hidingDrafts: false) { return .read(LiveRead(items: [])) }
            if url == PullList.reviewRequests.page(hidingDrafts: false) { return .read(LiveRead(items: [pull(1)], marked: true)) }
            return .read(LiveRead(items: [], marked: true))
        }

        guard case .read(let read) = answer else { Issue.record("not a read: \(answer)"); return }
        #expect(read.missed[.created]?.cause == .unread)
        #expect(asked.filter { $0 == PullList.created.page(hidingDrafts: false) }.count == 2)
        #expect(Set(numbers(LiveTrust.after(folder(before), answer, now: now))) == [1, 2])
    }

    @Test func listMembershipIsKeptForEveryListARowIsOn() {
        let merged = PullList.merged([(.reviewRequests, [pull(1)]), (.created, [pull(1), pull(2)])], keepsState: true)

        #expect(merged.first { $0.key == pull(1).key }?.on == [.reviewRequests, .created])
        #expect(merged.first { $0.key == pull(2).key }?.on == [.created])
    }

    @Test func aFeedStaysAFeedUntilThreeAnswersInARowAreNot() {
        let source = LiveSource(kind: .feed, address: "https://example.com/feed.xml")
        var shown = source
        shown.kind = .page
        var current = folder([page(1)], source: source)
        let notFeed = LiveReader.Answer.read(LiveRead(items: [page(9)], source: shown, feed: .notFeed))

        current = LiveTrust.after(current, notFeed, now: now)
        let first = current
        current = LiveTrust.after(current, notFeed, now: now)
        let second = current
        current = LiveTrust.after(current, notFeed, now: now)

        #expect(first.source.kind == .feed && first.state == .failed && first.items.map(\.key) == [page(1).key])
        #expect(second.source.kind == .feed && second.notFeeds == 2)
        #expect(current.source.kind == .page)
        #expect(current.items.map(\.key) == [page(9).key])
        #expect(current.notFeeds == nil)
    }

    @Test func aFeedBetweenNotFeedsStartsTheCountAgain() {
        let source = LiveSource(kind: .feed, address: "https://example.com/feed.xml")
        var current = folder([page(1)], source: source)
        let notFeed = LiveReader.Answer.read(LiveRead(items: [], feed: .notFeed))

        current = LiveTrust.after(current, notFeed, now: now)
        current = LiveTrust.after(current, notFeed, now: now)
        current = LiveTrust.after(current, .read(LiveRead(items: [page(1)], feed: .entries)), now: now)
        current = LiveTrust.after(current, notFeed, now: now)

        #expect(current.source.kind == .feed)
        #expect(current.notFeeds == 1)
    }

    @Test func aFeedCutShortIsAFailedRead() async {
        let data = Data("<rss version=\"2.0\"><channel><item><title>One</title><link>https://example.com/1</link></item><item><title>Tw".utf8)

        let answer = await LiveReader.feedAnswer(data, url: URL(string: "https://example.com/feed.xml")!,
                                                 source: LiveSource(kind: .feed, address: "https://example.com/feed.xml"),
                                                 fetch: { _ in nil }, page: { _ in .failed })

        #expect(answer == .missed(LiveMiss(cause: .unread)))
        #expect(FeedParser.parse(data) == nil)
    }

    @Test func anEmptyFeedWhereThereWereEntriesIsBelievedOnlyTheSecondTime() async {
        let data = Data("<rss version=\"2.0\"><channel><title>Feed</title></channel></rss>".utf8)
        let source = LiveSource(kind: .feed, address: "https://example.com/feed.xml")
        let answer = await LiveReader.feedAnswer(data, url: URL(string: source.address)!, source: source,
                                                 fetch: { _ in nil }, page: { _ in .failed })

        let once = LiveTrust.after(folder([page(1)], source: source), answer, now: now)
        let twice = LiveTrust.after(once, answer, now: now)
        let fresh = LiveTrust.after(folder([], source: source), answer, now: now)

        #expect(once.items.map(\.key) == [page(1).key] && once.state == .failed)
        #expect(twice.items.isEmpty && twice.state == .fine)
        #expect(fresh.state == .fine && fresh.items.isEmpty)
    }

    @Test func aPageThatIsNotAFeedIsReadAsAPageAndSaysSo() async {
        let source = LiveSource(kind: .feed, address: "https://example.com/blog")
        let answer = await LiveReader.feedAnswer(Data("<html><body>Hello</body></html>".utf8), url: URL(string: source.address)!,
                                                 source: source, fetch: { _ in nil },
                                                 page: { _ in .read(LiveRead(items: [self.page(3)])) })

        guard case .read(let read) = answer else { Issue.record("not a read: \(answer)"); return }
        #expect(read.feed == .notFeed)
        #expect(read.source?.kind == .page)
    }

    @Test func aFailedReadChangesNothingButTheNote() {
        let before = folder([pull(1), pull(2)])

        for answer in [LiveReader.Answer.failed, .missed(LiveMiss(cause: .unread)), .signIn] {
            let after = LiveTrust.after(before, answer, now: now)
            #expect(after.items == before.items)
            #expect(after.note != nil)
        }
    }

    @Test func aGitHubListKindKnowsItsEmptyMarkerOnAnyHost() {
        let enterprise = LiveSource(kind: .pullRequests, address: "https://git.example.com/pulls")

        #expect(LiveEmptyMarker.of(enterprise)?.words.contains("No results matched your search") == true)
        #expect(LiveEmptyMarker.of(.gitHubNotifications)?.words.contains("All caught up") == true)
        #expect(LiveEmptyMarker.of(LiveSource(kind: .feed, address: "https://example.com/feed")) == nil)
    }
}
