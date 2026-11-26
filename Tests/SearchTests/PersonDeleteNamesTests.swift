import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PersonDeleteNamesTests {
    private func call(_ noun: String, _ verb: String, _ arguments: [String: Any], _ browser: Browser) -> PersonCall {
        let socket = AgentSocket()
        socket.box.browser = browser
        return PersonCall(noun: noun, verb: verb, arguments: arguments, browser: browser, box: socket.box)
    }

    private func browser() -> Browser {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        return Browser(record: WindowRecord())
    }

    @Test func everyQuestionThatDeletesSomethingByItsIdNamesIt() {
        let unnamed = PersonCommands.table.filter { verb in
            (["delete", "remove", "forget"].contains(verb.verb) || verb.name == "shortcuts clear")
                && !["history delete", "folders remove"].contains(verb.name) && verb.names == nil
        }
        #expect(unnamed.map(\.name) == [])
    }

    @Test func aBookmarkIsNamedByItsTitleAndHost() throws {
        let browser = browser()
        defer { browser.closeAll() }
        let made = browser.bookmarks.insert(Bookmark.site("Garden plan", URL(string: "https://www.example.com/garden")!), into: nil)
        defer { browser.bookmarks.remove(made.id) }

        let named = PersonAsk.named(call("bookmarks", "delete", ["id": made.id.uuidString], browser))

        #expect(named == "Garden plan · example.com")
    }

    @Test func aFolderIsNamedByItsNameAndHowManyTabsItHolds() throws {
        let browser = browser()
        defer { browser.closeAll() }
        let tabs = (1...4).map { number in
            let tab = Tab(configuration: Web.configuration(space: browser.spaceID))
            tab.restore(url: URL(string: "https://example.com/\(number)")!, title: "Page \(number)")
            return tab
        }
        browser.showRow(tabs, active: tabs[0].id)
        _ = try #require(browser.newFolder(with: tabs, named: "Reading", editing: false))

        let named = PersonAsk.named(call("folders", "delete", ["folder": "Reading"], browser))

        #expect(named == "Reading · 4 tabs")
    }

    @Test func theNameIsOneLineThatTruncatesInTheMiddle() {
        let line = AgentCardView.oneLine()
        #expect(line.maximumNumberOfLines == 1)
        #expect(line.lineBreakMode == .byTruncatingMiddle)
    }
}
