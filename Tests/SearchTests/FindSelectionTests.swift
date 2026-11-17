import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct FindSelectionTests {
    private let board = NSPasteboard(name: NSPasteboard.Name("com.ysmaliak.broadway.test.find-selection.\(UUID().uuidString)"))

    private func withBrowser(_ body: (Browser) throws -> Void) rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer {
            browser.closeAll()
            board.releaseGlobally()
        }
        try body(browser)
    }

    @Test func theSelectedWordsBecomeTheNeedleAndGoToTheFindBoard() {
        withBrowser { browser in
            browser.takeForFind("  river stones \n", board: board)

            #expect(browser.needle == "river stones")
            #expect(board.string(forType: .string) == "river stones")
        }
    }

    @Test func theFindBarDoesNotOpen() {
        withBrowser { browser in
            browser.takeForFind("river stones", board: board)

            #expect(!browser.finding)
        }
    }

    @Test func nothingSelectedChangesNothing() {
        withBrowser { browser in
            board.clearContents()
            board.setString("kept", forType: .string)

            browser.takeForFind("   ", board: board)

            #expect(browser.needle.isEmpty)
            #expect(board.string(forType: .string) == "kept")
        }
    }

    @Test func aTestRunNeverWritesTheMacsOwnFindBoard() {
        #expect(FindBoard.board.name != .find)
    }
}
