import Foundation
import Testing
@testable import Search

@Suite
struct SavedAlreadyTests {
    private func site(_ host: String) -> String {
        host.split(separator: ".").suffix(2).joined(separator: ".")
    }

    private func kept(_ host: String, _ user: String, _ ago: TimeInterval? = nil) -> Kept {
        Kept(host: host, user: user, used: ago.map { Date(timeIntervalSinceNow: -$0) })
    }

    private final class Keychain {
        var secrets: [String: String] = [:]
        var reads: [String] = []

        func keep(_ login: Kept, _ password: String) -> Kept {
            secrets[login.id] = password
            return login
        }

        func read(_ login: Kept) -> String? {
            reads.append(login.id)
            return secrets[login.id]
        }
    }

    private func verdict(_ sent: SentSignIn, _ kept: [Kept], _ keychain: Keychain) -> SavedAlready.Verdict {
        SavedAlready.verdict(sent, kept: kept, registrable: site, read: keychain.read)
    }

    @Test func aSaveRecordsThePortWhenItIsNotTheSchemesOwn() {
        #expect(SentSignIn.port(of: URL(string: "http://localhost:3000/login")) == 3000)
        #expect(SentSignIn.port(of: URL(string: "https://example.com:8443/")) == 8443)
        #expect(SentSignIn.port(of: URL(string: "https://example.com/")) == nil)
        #expect(SentSignIn.port(of: URL(string: "https://example.com:443/")) == nil)
        #expect(SentSignIn.port(of: URL(string: "http://example.com:80/")) == nil)
        #expect(SentSignIn.port(of: nil) == nil)

        let sent = SentSignIn(host: "localhost", user: "pat", password: "sa-made-up-1", port: 3000)
        #expect(SavedAlready.login(for: sent, clear: true).port == 3000)
        #expect(SavedAlready.login(for: SentSignIn(host: "example.com", user: "pat", password: "sa-made-up-1"), clear: false).port == nil)
        let kept = Kept(host: "localhost", user: "pat", used: nil, clear: true, port: 3000)
        #expect(SavedAlready.touched(kept, by: sent, clear: true).port == 3000)
    }

    @Test func noNameAndTheSamePasswordKeptIsAlreadySaved() {
        let keychain = Keychain()
        let pat = keychain.keep(kept("id.example.test", "pat"), "sa-made-up-1")
        let sent = SentSignIn(host: "id.example.test", user: "", password: "sa-made-up-1")
        #expect(verdict(sent, [pat], keychain) == .kept(pat))
    }

    @Test func noNameAndAnotherPasswordIsOfferedToSave() {
        let keychain = Keychain()
        let pat = keychain.keep(kept("id.example.test", "pat"), "sa-made-up-1")
        let sent = SentSignIn(host: "id.example.test", user: "", password: "sa-other")
        #expect(verdict(sent, [pat], keychain) == .offer(changed: false))
    }

    @Test func theSameNameAndTheSamePasswordIsAlreadySaved() {
        let keychain = Keychain()
        let pat = keychain.keep(kept("id.example.test", "pat"), "sa-made-up-1")
        let sent = SentSignIn(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        #expect(verdict(sent, [pat], keychain) == .kept(pat))
    }

    @Test func theSameNameWithAnotherPasswordIsOfferedAsAnUpdate() {
        let keychain = Keychain()
        let pat = keychain.keep(kept("id.example.test", "pat"), "sa-made-up-1")
        let sent = SentSignIn(host: "id.example.test", user: "pat", password: "sa-other")
        #expect(verdict(sent, [pat], keychain) == .offer(changed: true))
    }

    @Test func anotherNameWithTheSamePasswordIsOfferedToSave() {
        let keychain = Keychain()
        let pat = keychain.keep(kept("id.example.test", "pat"), "sa-made-up-1")
        let sent = SentSignIn(host: "id.example.test", user: "sam", password: "sa-made-up-1")
        #expect(verdict(sent, [pat], keychain) == .offer(changed: false))
        #expect(keychain.reads.isEmpty)
    }

    @Test func aLoginKeptForAnotherHostOfTheSameSiteIsAlreadySaved() {
        let keychain = Keychain()
        let pat = keychain.keep(kept("example.test", "pat"), "sa-made-up-1")
        #expect(verdict(SentSignIn(host: "id.example.test", user: "pat", password: "sa-made-up-1"), [pat], keychain) == .kept(pat))
        #expect(verdict(SentSignIn(host: "id.example.test", user: "", password: "sa-made-up-1"), [pat], keychain) == .kept(pat))
    }

    @Test func aLoginKeptForAnotherSiteIsOfferedToSave() {
        let keychain = Keychain()
        let pat = keychain.keep(kept("id.other.test", "pat"), "sa-made-up-1")
        let sent = SentSignIn(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        #expect(verdict(sent, [pat], keychain) == .offer(changed: false))
        #expect(keychain.reads.isEmpty)
    }

    @Test func theSameNameIsReadOnThisHostFirstThenTheSite() {
        let keychain = Keychain()
        let wide = keychain.keep(kept("example.test", "pat", 10), "sa-made-up-1")
        let exact = keychain.keep(kept("id.example.test", "pat", 1000), "sa-old")
        let sent = SentSignIn(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        #expect(verdict(sent, [wide, exact], keychain) == .kept(wide))
        #expect(keychain.reads == [exact.id, wide.id])
    }

    @Test func noNameReadsAtMostThreeMostRecentlyUsedFirst() {
        let keychain = Keychain()
        let logins = (1...5).map { keychain.keep(kept("id.example.test", "user\($0)", TimeInterval($0) * 60), "sa-\($0)") }
        let sent = SentSignIn(host: "id.example.test", user: "", password: "sa-5")
        #expect(verdict(sent, logins.reversed(), keychain) == .offer(changed: false))
        #expect(keychain.reads == logins.prefix(3).map(\.id))
    }

    @Test func noNameStopsAtTheFirstMatch() {
        let keychain = Keychain()
        let logins = (1...3).map { keychain.keep(kept("id.example.test", "user\($0)", TimeInterval($0) * 60), "sa-\($0)") }
        let sent = SentSignIn(host: "id.example.test", user: "", password: "sa-2")
        #expect(verdict(sent, logins, keychain) == .kept(logins[1]))
        #expect(keychain.reads == [logins[0].id, logins[1].id])
    }

    @Test func noNameReadsTheLoginKeptWithoutANameOnThisHostFirst() {
        let keychain = Keychain()
        let named = (1...3).map { keychain.keep(kept("id.example.test", "user\($0)", TimeInterval($0) * 60), "sa-\($0)") }
        let nameless = keychain.keep(kept("id.example.test", "", 10_000), "sa-code")
        let sent = SentSignIn(host: "id.example.test", user: "", password: "sa-code")
        #expect(verdict(sent, named + [nameless], keychain) == .kept(nameless))
        #expect(keychain.reads == [nameless.id])
    }

    @Test func noNameWithAnotherPasswordWhereOneIsKeptWithoutANameIsAnUpdate() {
        let keychain = Keychain()
        let nameless = keychain.keep(kept("id.example.test", ""), "sa-code")
        let sent = SentSignIn(host: "id.example.test", user: "", password: "sa-new-code")
        #expect(verdict(sent, [nameless], keychain) == .offer(changed: true))
    }

    private func judged(_ sent: SentSignIn, _ marks: [FillMark?], _ keychain: Keychain) -> (SavedAlready.Verdict, Int) {
        var listed = 0
        let pat = keychain.keep(kept("id.example.test", "pat"), "sa-made-up-1")
        let verdict = SavedAlready.verdict(sent, marks: marks, registrable: site, kept: {
            listed += 1
            return [pat]
        }, read: keychain.read)
        return (verdict, listed)
    }

    @Test func aFillFromTheListThenASubmitWithTheNameReadsNothing() {
        let keychain = Keychain()
        let mark = FillMark(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        let (verdict, listed) = judged(SentSignIn(host: "id.example.test", user: "pat", password: "sa-made-up-1"), [nil, mark], keychain)
        #expect(verdict == .marked)
        #expect(listed == 0)
        #expect(keychain.reads.isEmpty)
    }

    @Test func aFillFromTheListThenASubmitWithNoNameReadsNothing() {
        let keychain = Keychain()
        let mark = FillMark(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        let (verdict, listed) = judged(SentSignIn(host: "id.example.test", user: "", password: "sa-made-up-1"), [nil, mark], keychain)
        #expect(verdict == .marked)
        #expect(listed == 0)
        #expect(keychain.reads.isEmpty)
    }

    @Test func aFillFromApplePasswordsThenASubmitWithNoNameReadsNothing() {
        let keychain = Keychain()
        let apple = AppleFill(host: "www.example.test", user: "pat", password: "sa-made-up-1")
        let (verdict, listed) = judged(SentSignIn(host: "id.example.test", user: "", password: "sa-made-up-1"), [apple, nil], keychain)
        #expect(verdict == .marked)
        #expect(listed == 0)
        #expect(keychain.reads.isEmpty)
    }

    @Test func aSubmitNoMarkMatchesFallsBackToReadingTheKeychain() {
        let keychain = Keychain()
        let mark = FillMark(host: "id.other.test", user: "pat", password: "sa-made-up-1")
        let (verdict, listed) = judged(SentSignIn(host: "id.example.test", user: "", password: "sa-made-up-1"), [mark, nil], keychain)
        #expect(verdict == .kept(kept("id.example.test", "pat")))
        #expect(listed == 1)
        #expect(keychain.reads.count == 1)
    }

    @Test func aMarkDoesNotMatchAnotherNameOrPassword() {
        let mark = FillMark(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        #expect(!mark.matches(host: "id.example.test", user: "sam", password: "sa-made-up-1", registrable: site))
        #expect(!mark.matches(host: "id.example.test", user: "", password: "sa-other", registrable: site))
        #expect(!String(describing: mark).contains("sa-made-up-1"))
    }

    @Test func aMarkNeverMatchesAnotherSite() {
        let mark = FillMark(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        #expect(!mark.matches(host: "id.other.test", user: "pat", password: "sa-made-up-1", registrable: site))
        #expect(!mark.matches(host: "id.other.test", user: "", password: "sa-made-up-1", registrable: site))
        #expect(!mark.covers("id.other.test", registrable: site))
        #expect(mark.covers("www.example.test", registrable: site))
    }

    @Test func aLoginKeptFromHttpsStaysSoWhenSentOverHttpFromAnotherHostOfTheSite() {
        let pat = Kept(host: "example.test", user: "pat", used: nil, clear: false)
        let sent = SentSignIn(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        let touched = SavedAlready.touched(pat, by: sent, clear: true)
        #expect(touched.clear == false)
        #expect(touched.host == "example.test" && touched.user == "pat")
    }

    @Test func aLoginKeptFromHttpsStaysSoWhenSentOverHttpWithNoName() {
        let pat = Kept(host: "id.example.test", user: "pat", used: nil, clear: false)
        let sent = SentSignIn(host: "id.example.test", user: "", password: "sa-made-up-1")
        let touched = SavedAlready.touched(pat, by: sent, clear: true)
        #expect(touched.clear == false)
        #expect(touched.user == "pat")
    }

    @Test func aLoginSentFromItsOwnHostWithItsOwnNameIsWrittenAsSent() {
        let pat = Kept(host: "id.example.test", user: "pat", used: nil, clear: false)
        let sent = SentSignIn(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        #expect(SavedAlready.touched(pat, by: sent, clear: true).clear == true)
    }

    @Test func aLoginKeptFromHttpStaysSoWhenSentOverHttpsFromAnotherHostOfTheSite() {
        let pat = Kept(host: "example.test", user: "pat", used: nil, clear: true)
        let sent = SentSignIn(host: "id.example.test", user: "pat", password: "sa-made-up-1")
        #expect(SavedAlready.touched(pat, by: sent, clear: false).clear == true)
    }
}
