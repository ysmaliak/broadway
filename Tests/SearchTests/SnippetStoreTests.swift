import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SnippetStoreTests {
    private var folder: URL!
    private var file: URL!
    private var store: SnippetStore!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("snippets-\(UUID().uuidString)")
        file = folder.appendingPathComponent("snippets.json")
        store = SnippetStore(url: file)
    }

    private func tearDown() async {
        Disk.drain()
        try? FileManager.default.removeItem(at: folder)
        store = nil
    }

    @Test func createEditReloadAndDeleteKeepTheIdentityAndExactText() throws {
        var snippet = Snippet(title: " Address ", keyword: " HOME ", text: "  First line\nSecond line\n")
        #expect(store.save(snippet) == nil)

        snippet.title = "Mailing address"
        snippet.text = "Updated\nАдрес\n"
        #expect(store.save(snippet) == nil)
        Disk.drain()
        let reloaded = SnippetStore(url: file)

        #expect(reloaded.snippets == [Snippet(id: snippet.id, title: "Mailing address", keyword: "home", text: snippet.text)])
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        #expect(reloaded.delete(snippet.id) == nil)
        Disk.drain()
        #expect(SnippetStore(url: file).snippets.isEmpty)
    }

    @Test func englishAndRussianQueriesAreExplicitAndCaseInsensitive() {
        let english = Snippet(title: "Mailing address", keyword: "home", text: "One Street")
        let russian = Snippet(title: "Домашний адрес", keyword: "дом", text: "Первая улица")
        #expect(store.save(english) == nil)
        #expect(store.save(russian) == nil)
        let cases: [(String, [UUID])] = [
            (";home", [english.id]), (" ;HO ", [english.id]), ("Mailing address", [english.id]),
            ("mailing", [english.id]), (";ДОМ", [russian.id]), ("ДОМАШНИЙ АДРЕС", [russian.id]),
            ("домашний", [russian.id]), ("home", []), ("please ;home", []),
            ("address", []), (";", []), ("", []), ("m", []), (";unknown", [])
        ]

        for (query, expected) in cases { #expect(store.matches(query).map(\.id) == expected, "\(query)") }
    }

    @Test func duplicateKeywordsAreRejectedAcrossCaseAndCanonicalUnicode() {
        let original = Snippet(title: "Café", keyword: "café", text: "one")
        #expect(store.save(original) == nil)

        let problem = store.save(Snippet(title: "Another", keyword: "CAFE\u{301}", text: "two"))

        #expect(problem != nil)
        #expect(store.snippets == [original])
    }

    @Test func validationDoesNotReplaceASavedSnippet() {
        let original = Snippet(title: "Saved", keyword: "saved", text: "Text")
        #expect(store.save(original) == nil)
        let cases = [
            Snippet(title: "", keyword: "word", text: "text"),
            Snippet(title: "Title", keyword: ";word", text: "text"),
            Snippet(title: "Title", keyword: "two words", text: "text"),
            Snippet(title: "Title", keyword: "word", text: " \n"),
            Snippet(title: "Title", keyword: "word", text: String(repeating: "x", count: 100_001))
        ]

        for snippet in cases { #expect(store.save(snippet) != nil) }
        #expect(store.snippets == [original])
    }

    @Test func exactMatchLeadsAndTheListIsBounded() {
        for index in 0..<8 {
            #expect(store.save(Snippet(title: "Address \(index)", keyword: "word\(index)", text: "Text")) == nil)
        }
        let exact = Snippet(title: "ZZ exact", keyword: "word", text: "Text")
        #expect(store.save(exact) == nil)

        let matches = store.matches(";word")

        #expect(matches.first?.id == exact.id)
        #expect(matches.count == 5)
    }

    @Test func partialKeywordsAndMatchingTitlesStayLocal() {
        #expect(store.save(Snippet(title: "Домашний адрес", keyword: "дом", text: "Text")) == nil)

        for query in [";", ";unknown", ";д", "Домашний", "дом"] { #expect(store.isQuery(query), "\(query)") }
        for query in ["weather tomorrow", "x"] { #expect(!store.isQuery(query), "\(query)") }
    }

    @Test func anUnreadableStoreIsKeptBeforeSavingAgain() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bytes = Data("broken json".utf8)
        try bytes.write(to: file)

        let reloaded = SnippetStore(url: file)
        #expect(reloaded.save(Snippet(title: "New", keyword: "new", text: "Text")) == nil)
        Disk.drain()

        let aside = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("snippets.unreadable-") }
        #expect(try Data(contentsOf: #require(aside)) == bytes)
        #expect(SnippetStore(url: file).snippets.count == 1)
    }
}
