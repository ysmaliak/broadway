import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SpacePicturesTests {
    private func tab() -> Search.Tab {
        _ = NSApplication.shared
        let tab = Search.Tab(configuration: Web.configuration(space: Space.firstID))
        tab.restore(url: URL(string: "http://127.0.0.1:9/picture")!, title: "Local picture")
        return tab
    }

    private func makePictures(_ preview: @escaping SpacePictures.Preview) -> SpacePictures {
        SpacePictures(presentation: { _, done in done() }, preview: preview)
    }

    private func attach(_ tab: Search.Tab) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 160), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(tab.web)
        return window
    }

    @Test func anOlderSnapshotCannotReplaceTheLatestDeparture() {
        var replies: [(NSImage?) -> Void] = []
        let pictures = makePictures { _, reply in replies.append(reply) }
        let space = UUID(), tab = tab()
        let older = NSImage(size: NSSize(width: 16, height: 16))
        let latest = NSImage(size: NSSize(width: 32, height: 32))
        pictures.capture(space, tabs: [tab])
        pictures.capture(space, tabs: [tab])

        replies[1](latest)
        replies[0](older)

        #expect(pictures.image(for: tab, in: space) === latest)
    }

    @Test func aBackgroundNavigationDoesNotShowThePreviousPagePicture() {
        let pictures = makePictures { _, reply in reply(NSImage(size: NSSize(width: 16, height: 16))) }
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])
        #expect(pictures.image(for: tab, in: space) != nil)

        tab.restore(url: URL(string: "http://127.0.0.1:9/another")!, title: "Another local page")

        #expect(pictures.image(for: tab, in: space) == nil)
    }

    @Test func aFailedRecaptureDoesNotKeepThePreviousDeparture() {
        var replies: [(NSImage?) -> Void] = []
        let pictures = makePictures { _, reply in replies.append(reply) }
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])
        replies[0](NSImage(size: NSSize(width: 16, height: 16)))
        #expect(pictures.image(for: tab, in: space) != nil)

        pictures.capture(space, tabs: [tab])
        replies[1](nil)

        #expect(pictures.image(for: tab, in: space) == nil)
    }

    @Test func clearingInvalidatesEveryPendingPicture() {
        var reply: ((NSImage?) -> Void)?
        let pictures = makePictures { _, done in reply = done }
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])

        pictures.clear()
        reply?(NSImage(size: NSSize(width: 16, height: 16)))

        #expect(pictures.images.isEmpty)
    }

    @Test func landingKeepsItsCoverUntilTheAttachedPageIsPresented() async throws {
        var presented: [() -> Void] = []
        let pictures = SpacePictures(presentation: { _, done in presented.append(done) },
                                     preview: { _, done in done(NSImage(size: NSSize(width: 16, height: 16))) })
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])

        pictures.coverForLanding(tab, in: space)
        #expect(tab.cover != nil)
        #expect(pictures.landingImage(for: tab, in: space) != nil)
        try await Task.sleep(for: .milliseconds(20))
        #expect(presented.count == 0)
        let window = attach(tab)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(40))
        presented[0]()

        #expect(tab.cover == nil)
        #expect(pictures.landingImage(for: tab, in: space) == nil)
    }

    @Test func landingDoesNotReplaceAnExistingWakeCover() {
        let pictures = makePictures { _, reply in reply(NSImage(size: NSSize(width: 16, height: 16))) }
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])
        let waking = NSImage(size: NSSize(width: 32, height: 32))
        tab.cover(with: waking)

        pictures.coverForLanding(tab, in: space)

        #expect(tab.cover === waking)
    }

    @Test func anEarlierLandingReplyCannotRemoveANewerCover() async throws {
        var presented: [() -> Void] = []
        let pictures = SpacePictures(presentation: { _, done in presented.append(done) },
                                     preview: { _, done in done(NSImage(size: NSSize(width: 16, height: 16))) })
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])
        let window = attach(tab)
        defer { window.close() }
        pictures.coverForLanding(tab, in: space)
        let first = tab.cover
        try await Task.sleep(for: .milliseconds(20))
        pictures.coverForLanding(tab, in: space)
        let latest = tab.cover
        try await Task.sleep(for: .milliseconds(20))

        presented[0]()

        #expect(latest != nil)
        #expect(!(first === latest))
        #expect(tab.cover === latest)
        #expect(pictures.landingImage(for: tab, in: space) === latest)
        presented[1]()
        #expect(tab.cover == nil)
    }

    @Test func discardingASpaceAlsoInvalidatesItsPendingSnapshot() {
        var reply: ((NSImage?) -> Void)?
        let pictures = makePictures { _, done in reply = done }
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])

        pictures.discard(space)
        reply?(NSImage(size: NSSize(width: 16, height: 16)))

        #expect(pictures.images[space] == nil)
    }

    @Test func aParkedPagePictureIsRetakenWhenItsPageChanges() async throws {
        let first = NSImage(size: NSSize(width: 16, height: 16))
        let second = NSImage(size: NSSize(width: 32, height: 32))
        var shots = [first, second]
        let pictures = makePictures { _, reply in reply(shots.isEmpty ? nil : shots.removeFirst()) }
        pictures.settle = 0.02
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])
        pictures.follow(space, tabs: [tab])
        #expect(pictures.image(for: tab, in: space) === first)

        tab.restore(url: URL(string: "http://127.0.0.1:9/picture")!, title: "Inbox (2)")
        for _ in 0..<50 where pictures.image(for: tab, in: space) !== second {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(pictures.image(for: tab, in: space) === second)
    }

    @Test func aNeighbourPictureIsRetakenWhenFollowingResumes() async throws {
        let first = NSImage(size: NSSize(width: 16, height: 16))
        let second = NSImage(size: NSSize(width: 32, height: 32))
        var shots = [first, second]
        let pictures = makePictures { _, reply in reply(shots.isEmpty ? nil : shots.removeFirst()) }
        pictures.settle = 0.02
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])
        pictures.follow(space, tabs: [tab])
        pictures.keepFollowing([])
        #expect(pictures.following.isEmpty)

        pictures.followPictured(space, tabs: [tab])
        for _ in 0..<50 where pictures.image(for: tab, in: space) !== second {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(pictures.following == [tab.id])
        #expect(pictures.image(for: tab, in: space) === second)
    }

    @Test func aFarSpaceStopsBeingFollowed() async throws {
        var asked = 0
        let pictures = makePictures { _, reply in asked += 1; reply(NSImage(size: NSSize(width: 16, height: 16))) }
        pictures.settle = 0.02
        let space = UUID(), tab = tab()
        pictures.capture(space, tabs: [tab])
        pictures.follow(space, tabs: [tab])

        pictures.keepFollowing([UUID()])
        tab.restore(url: URL(string: "http://127.0.0.1:9/picture")!, title: "Inbox (3)")
        try await Task.sleep(for: .milliseconds(150))

        #expect(asked == 1)
    }
}
