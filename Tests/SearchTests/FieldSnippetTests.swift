import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class FieldSnippetTests {
    private var browser: Browser!
    private var snippet: Snippet!

    init() async throws {
        keepSetting(Shared.prefs, \.engine, "search.engine")
        keepSetting(Shared.prefs, \.customEngine, "search.custom")
        keepSetting(Shared.prefs, \.engineSuggests, "search.suggest")
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        let blank = Tab(configuration: Web.configuration(space: browser.spaceID))
        browser.showRow([blank], active: blank.id)
        snippet = Snippet(title: "Snippet \(UUID().uuidString)", keyword: "t_\(UUID().uuidString)", text: "Two lines\nДве строки\n")
        #expect(SnippetStore.shared.save(snippet) == nil)
        AnswerBoard.write("")
    }

    private func tearDown() async {
        SnippetStore.shared.delete(snippet.id)
        browser.closeAll()
        browser = nil
    }

    private func settle() async {
        for _ in 0..<100 {
            if browser.leadingSnippet != nil { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func returnWithoutAPageCopiesTheExactTextAndLeavesClipboardIsolated() async {
        browser.edit()
        browser.typed = ";" + snippet.keyword
        await settle()

        browser.submit()
        for _ in 0..<100 where browser.editing { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(AnswerBoard.written == snippet.text)
        #expect(AnswerBoard.board.name != NSPasteboard.general.name)
        #expect(!browser.editing)
        #expect(browser.announcement == "Copied snippet")
    }

    @Test func returnBeforeThePrivacyCheckFinishesWaitsInsteadOfSearching() async {
        browser.edit()
        browser.typed = ";" + snippet.keyword

        browser.submit()
        for _ in 0..<100 where browser.editing { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(AnswerBoard.written == snippet.text)
        #expect(!browser.editing)
        #expect(browser.active?.shownURL == nil)
    }

    @Test func unresponsivePrivacyCheckLetsReturnSearchAndDiscardsLateOffers() async throws {
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><textarea>Fixture</textarea>")])
        let engine = browser.prefs.engine
        let custom = browser.prefs.customEngine
        defer {
            browser.prefs.engine = engine
            browser.prefs.customEngine = custom
            server.stop()
        }
        browser.prefs.engine = .custom
        browser.prefs.customEngine = server.url("/search").absoluteString + "?q=%s"
        let tab = browser.benchOpen(server.url("/page"))
        for _ in 0..<300 where tab.loading || tab.committed == nil { try await Task.sleep(for: .milliseconds(10)) }
        browser.select(tab)
        browser.edit()
        _ = await PageSelection.run(tab, """
        Object.defineProperty(document, 'activeElement', { configurable: true, get: function () {
          delete document.activeElement;
          var until = Date.now() + 1200;
          while (Date.now() < until) {}
          return document.body;
        } });
        return true;
        """)
        browser.typed = ";" + snippet.keyword
        let destination = browser.destination(for: browser.typed)

        browser.submit()
        try await Task.sleep(for: .milliseconds(650))
        let editingAtDeadline = browser.editing
        let waitingAtDeadline = browser.snippetField.waiting
        try await Task.sleep(for: .milliseconds(900))

        #expect(!editingAtDeadline)
        #expect(!waitingAtDeadline)
        #expect(tab.address == destination)
        #expect(AnswerBoard.written == "")
        #expect(browser.snippetField.target == nil)
        #expect(browser.leadingSnippet == nil)
    }

    @Test func snippetLeadsWithASearchBelowAndHasOnlyItsOwnAction() async {
        browser.edit()
        browser.typed = snippet.title
        await settle()

        let items = browser.fieldMenuItems(for: browser.offers.first)

        #expect(browser.leadingSnippet?.id == snippet.id)
        #expect(browser.offers.dropFirst().contains { $0.kind == .search })
        #expect(browser.ending == nil)
        #expect(items.map(\.title) == ["Copy Snippet"])
    }

    @Test func slowPrivacyReadCanStillOfferWhenReturnHasNotBeenPressed() async throws {
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><p>Fixture</p>")])
        defer { server.stop() }
        let tab = browser.benchOpen(server.url("/page"))
        browser.select(tab)
        for _ in 0..<300 where tab.loading || tab.committed == nil { try await Task.sleep(for: .milliseconds(10)) }
        browser.edit()
        _ = await PageSelection.run(tab, """
        Object.defineProperty(document, 'activeElement', { configurable: true, get: function () {
          delete document.activeElement;
          var until = Date.now() + 900;
          while (Date.now() < until) {}
          return document.body;
        } });
        return true;
        """)

        browser.typed = ";" + snippet.keyword
        try await Task.sleep(for: .milliseconds(1300))

        #expect(!browser.snippetField.waiting)
        #expect(browser.leadingSnippet?.id == snippet.id)
        #expect(AnswerBoard.written == "")
        guard browser.leadingSnippet != nil else { return }
        browser.submit()
        for _ in 0..<100 where browser.editing { try await Task.sleep(for: .milliseconds(10)) }
        #expect(AnswerBoard.written == snippet.text)
    }

    @Test func frameEditorKeepsItsSelectionThroughPrivacyChecksAndInsertion() async throws {
        let server = try LocalPageServer([
            "/page": .init(type: "text/html", body: "<!doctype html><iframe src='/editor'></iframe>"),
            "/editor": .init(type: "text/html", body: "<!doctype html><textarea>Before</textarea>")
        ])
        defer { server.stop() }
        let tab = browser.benchOpen(server.url("/page"))
        browser.select(tab)
        for _ in 0..<300 where tab.loading || tab.fieldRelay.frames.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        _ = await PageSelection.run(tab, """
        var editor = document.querySelector('iframe').contentDocument.querySelector('textarea');
        editor.focus(); editor.setSelectionRange(6, 6);
        return true;
        """)
        for _ in 0..<100 where tab.snippetFrame == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(tab.snippetFrame != nil)
        await withCheckedContinuation { done in browser.rememberSnippetSelection { done.resume() } }

        browser.edit()
        browser.typed = ";" + snippet.keyword
        await settle()
        guard browser.leadingSnippet != nil else { Issue.record("The frame did not offer its snippet"); return }
        browser.submit()
        for _ in 0..<100 where browser.announcement != "Inserted snippet" { try await Task.sleep(for: .milliseconds(10)) }
        let value = await PageSelection.run(tab, "return document.querySelector('iframe').contentDocument.querySelector('textarea').value;") as? String

        #expect(value == ("Before" + snippet.text))
        #expect(AnswerBoard.written == "")
        #expect(browser.announcement == "Inserted snippet")
    }

    @Test func pickingAnExistingRowWhilePrivacyIsPendingPreventsLateInsertion() async throws {
        browser.edit()
        browser.typed = ";" + snippet.keyword
        let index = try #require(browser.offers.firstIndex { $0.kind == .search })
        let selected = browser.offers[index]

        browser.picked = index
        for _ in 0..<100 where browser.snippetField.waiting { try? await Task.sleep(for: .milliseconds(5)) }

        #expect(browser.picked == index)
        #expect(browser.pickedOffer?.id == selected.id)
        #expect(!browser.offers.contains { if case .snippet = $0.kind { return true }; return false })
    }

    @Test func snippetQueriesNeverReachTheEnabledSearchEngine() {
        let suggesting = browser.prefs.engineSuggests
        let engine = browser.prefs.engine
        defer {
            browser.prefs.engineSuggests = suggesting
            browser.prefs.engine = engine
        }
        browser.prefs.engineSuggests = true
        browser.prefs.engine = .google

        #expect(browser.engineQuestion(for: "weather forecast") != nil)
        for query in [";partial_unknown_keyword", snippet.title, String(snippet.title.prefix(8))] {
            #expect(browser.engineQuestion(for: query) == nil, "\(query)")
        }
    }

    @Test func summonDoesNotOfferSnippets() async {
        browser.summon()

        browser.typed = ";" + snippet.keyword
        try? await Task.sleep(for: .milliseconds(30))

        #expect(!browser.offers.contains { if case .snippet = $0.kind { return true }; return false })
    }

    @Test func aSiteChipKeepsItsOwnSearchInsteadOfOfferingSnippets() async {
        browser.edit()
        browser.siteChip = SiteSearch.builtIn[0]

        browser.typed = ";" + snippet.keyword
        try? await Task.sleep(for: .milliseconds(30))

        #expect(!browser.offers.contains { if case .snippet = $0.kind { return true }; return false })
        #expect(browser.offers.first?.kind == .search)
    }

    @Test func aDeletedOfferDoesNotCopyItsOldText() async {
        browser.edit()
        browser.typed = ";" + snippet.keyword
        await settle()
        let offer = browser.offers.first
        SnippetStore.shared.delete(snippet.id)

        if let offer { browser.take(offer) }
        try? await Task.sleep(for: .milliseconds(30))

        #expect(AnswerBoard.written == "")
        #expect(browser.leadingSnippet == nil)
    }
}
