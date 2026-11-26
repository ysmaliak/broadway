import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct MovedTabQuestionTests {
    private func browsers(_ body: (Browser, Browser, [Tab]) async throws -> Void) async rethrows {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let from = Browser(record: WindowRecord())
        let to = Browser(record: WindowRecord())
        defer {
            from.closeAll()
            to.closeAll()
        }
        from.tabs.last?.restore(url: URL(string: "about:blank#1")!, title: "Tab 1")
        from.newTab()
        from.tabs.last?.restore(url: URL(string: "about:blank#2")!, title: "Tab 2")
        from.select(from.tabs[0])
        try await body(from, to, from.tabs)
    }

    @Test func aQuestionAskedInTheBackgroundShowsInTheWindowTheTabMovedTo() async {
        await browsers { from, to, tabs in
            var shown = false, dropped = false
            from.heldDialogs[tabs[1].id] = [HeldQuestion(show: { shown = true }, drop: { dropped = true })]

            from.moveToWindow(tabs[1], to)
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(50))

            #expect(to.activeID == tabs[1].id)
            #expect(shown)
            #expect(!dropped)
            #expect(from.heldDialogs[tabs[1].id] == nil)
        }
    }

    @Test func aQuestionOfATabThatIsNotInFrontWaitsInItsNewWindow() async {
        await browsers { from, to, tabs in
            var shown = false
            let question = HeldQuestion(show: { shown = true }, drop: {})
            from.heldDialogs[tabs[1].id] = [question]

            from.handQuestions(of: [tabs[1]], to: to)

            #expect(!shown)
            #expect(to.heldDialogs[tabs[1].id]?.first === question)
            #expect(from.heldDialogs[tabs[1].id] == nil)
        }
    }
}
