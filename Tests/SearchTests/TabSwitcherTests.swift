import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TabSwitcherTests {
    @Test func resetCancelsDelayedRevealAndDiscardsPictures() async throws {
        let switcher = TabSwitcher()
        let first = UUID(), second = UUID()
        let address = try #require(URL(string: "https://example.test"))
        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.cachePreview(NSImage(size: NSSize(width: 1, height: 1)), for: first, address: address)
        #expect(switcher.preview(for: first, address: address) != nil)

        switcher.reset()
        #expect(switcher.preview(for: first, address: address) == nil)
        // A result arriving after reset cannot repopulate the cache.
        switcher.cachePreview(NSImage(size: NSSize(width: 1, height: 1)), for: first, address: address)
        #expect(switcher.preview(for: first, address: address) == nil)

        switcher.step(row: [first, second], current: first, backwards: false)
        switcher.reset()
        try await Task.sleep(for: .milliseconds(250))
        #expect(!switcher.visible)
        #expect(!switcher.active)
        #expect(switcher.selectedID == nil)
    }
}
