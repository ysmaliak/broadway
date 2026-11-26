import Foundation
import Testing
@testable import Search

/// Translate Page's sentence marks and language checks (Translate.swift):
/// pure functions, no page and no translator.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct TranslateTests {
    @Test func joinedMarksEachPartButTheFirst() {
        #expect(PageTranslator.joined(["Visit", "the museum", "today."], gaps: [false, true, true]) == "Visit [1]the museum [2]today.")
        #expect(PageTranslator.joined(["un", "deux"], gaps: [false, false]) == "un[1]deux")
        #expect(PageTranslator.joined(["seul"], gaps: [false]) == "seul")
    }

    @Test func joinedRefusesTextThatLooksLikeAMark() {
        #expect(PageTranslator.joined(["See note", "[3]", "below"], gaps: [false, true, true]) == nil)
        #expect(PageTranslator.joined(["Paris[12] is", "big"], gaps: [false, true]) == nil)
        #expect(PageTranslator.joined(["Paris [a] is", "big"], gaps: [false, true]) != nil)
    }

    @Test func splitBackIntoPieces() {
        #expect(PageTranslator.split("Visitez [1]le musée [2]aujourd'hui.", count: 3) == ["Visitez", "le musée", "aujourd'hui."])
        #expect(PageTranslator.split("a[1][2]c", count: 3) == ["a", "", "c"])
        #expect(PageTranslator.split("seul", count: 1) == ["seul"])
    }

    @Test func splitRefusesLostMovedOrExtraMarks() {
        #expect(PageTranslator.split("Visitez le musée [2]aujourd'hui.", count: 3) == nil, "a mark lost")
        #expect(PageTranslator.split("Visitez [2]le musée [1]aujourd'hui.", count: 3) == nil, "out of order")
        #expect(PageTranslator.split("Visitez [1]le [1]musée [2]aujourd'hui.", count: 3) == nil, "one twice")
        #expect(PageTranslator.split("[1]a[2]b[3]c", count: 3) == nil, "one more")
    }

    @Test func roundTripThroughAStandIn() {
        let parts = ["Le", "Louvre", "est à", "Paris", "."]
        let gaps = [false, true, true, true, false]
        guard let line = PageTranslator.joined(parts, gaps: gaps) else { Issue.record("no line"); return }
        #expect(PageTranslator.split("[fr→en] " + line, count: parts.count) == ["[fr→en] Le", "Louvre", "est à", "Paris", "."])
    }

    @Test func blocksKeepTheirOwnLanguageOnlyWhenClear() {
        let english = "The quick brown fox jumps over the lazy dog while the band plays on the square."
        let german = "Der schnelle braune Fuchs springt über den faulen Hund, während die Kapelle auf dem Platz spielt."
        let short = "OK merci"
        #expect(PageTranslator.languages(of: [english, german, short], page: "fr") == ["en", "de", "fr"])
    }

    @Test func pageLanguageFallsBackToTheLangAttribute() {
        #expect(PageTranslator.detect("", hint: "fr-FR").map(PageTranslator.code) == "fr")
        #expect(PageTranslator.detect("Bonjour à tous, voici la page d'accueil du musée du Louvre à Paris.", hint: "en").map(PageTranslator.code) == "fr")
        #expect(PageTranslator.detect("", hint: nil) == nil)
    }

    @Test func codesAndNames() {
        #expect(PageTranslator.code(Locale.Language(identifier: "fr-FR")) == "fr")
        #expect(PageTranslator.code(Locale.Language(identifier: "zh-Hant")) == "zh-Hant")
        #expect(PageTranslator.name("fr") == "French")
        #expect(PageTranslator.same(Locale.Language(identifier: "en-US"), Locale.Language(identifier: "en")))
        #expect(!PageTranslator.same(Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "zh-Hant")))
    }

    @Test func aPrivateTabTurnsASavedLanguageOffForItselfOnly() {
        let was = Shared.prefs.translateAlways
        defer { Shared.prefs.translateAlways = was }
        Shared.prefs.translateAlways = ["fr"]
        let tab = Tab(shy: true, configuration: Web.configuration(shy: true))
        let other = Tab(shy: true, configuration: Web.configuration(shy: true))

        tab.setAlwaysTranslates("fr", false)

        #expect(!tab.alwaysTranslates("fr"))
        #expect(other.alwaysTranslates("fr"))
        #expect(Shared.prefs.translateAlways == ["fr"])
        tab.setAlwaysTranslates("fr", true)
        #expect(tab.alwaysTranslates("fr"))
        tab.setAlwaysTranslates("de", true)
        #expect(tab.alwaysTranslates("de"))
        #expect(!other.alwaysTranslates("de"))
    }

    @Test func translatingATabWithNoPageSaysThereIsNoPage() {
        let tab = Tab()
        var said: [String: Any] = [:]

        let started = PageTranslator.start(tab) { said = $0 }

        #expect(started == nil)
        #expect(said["error"] as? String == "no page")
    }
}
