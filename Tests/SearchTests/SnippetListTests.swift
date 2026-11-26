import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SnippetListTests {
    private var browser: Browser!
    private var saved: [Snippet] = []
    private var made: [Snippet] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        saved = SnippetStore.shared.snippets
        for snippet in saved { SnippetStore.shared.delete(snippet.id) }
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        let blank = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.showRow([blank], active: blank.id)
        AnswerBoard.write("")
    }

    private func tearDown() async {
        for snippet in SnippetStore.shared.snippets { SnippetStore.shared.delete(snippet.id) }
        for snippet in saved { SnippetStore.shared.save(snippet) }
        AnswerBoard.write("")
        browser.closeAll()
        browser = nil
    }

    @discardableResult
    private func add(_ title: String, _ keyword: String, _ text: String, uses: Int = 0) -> Snippet {
        let snippet = Snippet(title: title, keyword: keyword, text: text)
        #expect(SnippetStore.shared.save(snippet) == nil)
        for _ in 0..<uses { SnippetStore.shared.used(snippet.id) }
        made.append(snippet)
        return snippet
    }

    private var titles: [String] {
        browser.offers.compactMap { offer in
            if case .snippet(let snippet) = offer.kind { return snippet.title }
            return nil
        }
    }

    @Test func insertSnippetIsAnEditCommandOnCommandSemicolon() throws {
        let command = try #require(Command.named("edit.snippets"))

        let key = ShortcutStore().key(for: command.id)

        #expect(command.title == "Insert Snippet…")
        #expect(command.section == .edit)
        #expect(command.defaultKey == KeyCombo(";"))
        #expect(key == KeyCombo(";"))
    }

    @Test func insertSnippetIsOnTheShortcutsPageAndFoundInTheField() {
        let title = "Insert Snippet…"

        let listed = ShortcutsList.commands(in: .edit, hunt: "", browser: browser, store: ShortcutStore.shared, prefs: browser.prefs)
        let rows = FieldCommands.rows(for: FieldName.plain(title), in: browser, limit: 8)

        #expect(listed.contains { $0.id == "edit.snippets" })
        #expect(rows.contains { row in
            if case .action(let id) = row.kind { return id == "command:edit.snippets" }
            return false
        })
    }

    @Test func theCommandOpensTheFieldWithEverySnippetMostUsedFirstThenByTitle() throws {
        add("Zebra", "zebra", "z", uses: 1)
        add("Banana", "banana", "b")
        add("Apple", "apple", "a")
        add("Mango", "mango", "m", uses: 3)
        add("Cherry", "cherry", "c")
        add("Date", "date", "d")
        let command = try #require(Command.named("edit.snippets"))

        command.run(browser)

        #expect(browser.fieldShowing)
        #expect(browser.fieldPlace == .snippets)
        #expect(titles == ["Mango", "Zebra", "Apple", "Banana", "Cherry", "Date"])
        #expect(browser.picked == 0)
    }

    @Test func typingFiltersTheListByTitleOrKeyword() {
        add("Mailing address", "home", "One Street")
        add("Work address", "office", "Two Street")
        add("Signature", "sig", "Best")
        browser.enterPlace(.snippets)

        browser.typed = "addr"
        let byTitle = titles
        browser.typed = "sig"
        let byKeyword = titles
        browser.typed = ";offi"
        let bySemicolon = titles

        #expect(byTitle == ["Mailing address", "Work address"])
        #expect(byKeyword == ["Signature"])
        #expect(bySemicolon == ["Work address"])
    }

    @Test func aFilterThatMatchesNothingSaysSo() {
        add("Signature", "sig", "Best")
        browser.enterPlace(.snippets)

        browser.typed = "zzz"

        #expect(browser.offers.isEmpty)
        #expect(FieldPlace.snippets.empty(for: browser.typed) == "No snippets match")
        #expect(browser.returnIsIdle)
    }

    @Test func returnPutsTheChosenSnippetInAtTheCaretLeftInThePage() async throws {
        add("Alpha", "alpha", "AAA")
        add("Beta", "beta", "BBB", uses: 2)
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><textarea>Start </textarea>")])
        defer { server.stop() }
        let tab = browser.benchOpen(server.url("/page"))
        browser.select(tab)
        for _ in 0..<300 where tab.loading || tab.committed == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = await PageSelection.run(tab, "var box = document.querySelector('textarea'); box.focus(); box.setSelectionRange(6, 6); return true;")
        await withCheckedContinuation { done in browser.rememberSnippetSelection { done.resume() } }
        browser.enterPlace(.snippets)

        browser.walk(1)
        browser.submit()
        for _ in 0..<200 where browser.announcement != "Inserted snippet" { try await Task.sleep(for: .milliseconds(10)) }
        let value = await PageSelection.run(tab, "return document.querySelector('textarea').value;") as? String

        #expect(value == "Start AAA")
        #expect(!browser.editing)
        #expect(AnswerBoard.written == "")
    }

    @Test func withoutAPageReturnCopiesTheChosenSnippet() async throws {
        add("Signature", "sig", "Best {cursor}regards")
        browser.enterPlace(.snippets)

        browser.submit()
        for _ in 0..<200 where browser.announcement != "Copied snippet" { try await Task.sleep(for: .milliseconds(5)) }

        #expect(AnswerBoard.written == "Best regards")
        #expect(browser.announcement == "Copied snippet")
    }

    @Test func aSnippetPutInCountsAsUsedAndMovesUpTheList() async throws {
        add("Alpha", "alpha", "AAA")
        let beta = add("Beta", "beta", "BBB")
        browser.enterPlace(.snippets)
        browser.walk(1)

        browser.submit()
        for _ in 0..<200 where browser.announcement != "Copied snippet" { try await Task.sleep(for: .milliseconds(5)) }
        browser.enterPlace(.snippets)

        #expect(SnippetStore.shared.uses[beta.id] == 1)
        #expect(titles == ["Beta", "Alpha"])
    }

    @Test func withNoSnippetsTheListSaysSoAndReturnOpensTheSnippetsPage() {
        browser.enterPlace(.snippets)
        let rows = browser.offers
        let empty = FieldPlace.snippets.empty(for: browser.typed)
        let idle = browser.returnIsIdle

        browser.submit()

        #expect(rows.isEmpty)
        #expect(empty == "No snippets yet")
        #expect(!idle)
        #expect(browser.fieldPlace == nil)
        #expect(browser.pageTab(.settings)?.page?.detail == "snippets")
    }

    @Test func theSnippetListIsNotOfferedAmongThePlaces() {
        add("Signature", "sig", "Best")

        let offered = ["snip", "snippets", "фраг"].compactMap(FieldPlace.offered(for:))

        #expect(offered.isEmpty)
        #expect(!FieldPlace.browsable.contains(.snippets))
    }
}

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SnippetUseCountTests {
    private var folder: URL!
    private var file: URL!

    init() {
        addTeardownBlock { await self.tearDown() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-uses-\(UUID().uuidString)")
        file = folder.appendingPathComponent("snippets.json")
    }

    private func tearDown() async {
        Disk.drain()
        try? FileManager.default.removeItem(at: folder)
    }

    @Test func useCountsSurviveAReloadWithoutChangingTheSnippetsFile() throws {
        let store = SnippetStore(url: file)
        let snippet = Snippet(title: "Saved", keyword: "saved", text: "Text")
        #expect(store.save(snippet) == nil)
        Disk.drain()
        let before = try Data(contentsOf: file)

        store.used(snippet.id)
        store.used(snippet.id)
        Disk.drain()
        let reloaded = SnippetStore(url: file)

        #expect(reloaded.uses[snippet.id] == 2)
        let uses = folder.appendingPathComponent("snippet-uses.json")
        #expect((try FileManager.default.attributesOfItem(atPath: uses.path)[.posixPermissions] as? Int) == 0o600)
        #expect(reloaded.snippets == [snippet])
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func deletingASnippetForgetsItsCount() {
        let store = SnippetStore(url: file)
        let snippet = Snippet(title: "Saved", keyword: "saved", text: "Text")
        #expect(store.save(snippet) == nil)
        store.used(snippet.id)

        store.delete(snippet.id)
        Disk.drain()

        #expect(store.uses[snippet.id] == nil)
        #expect(SnippetStore(url: file).uses.isEmpty)
    }
}
