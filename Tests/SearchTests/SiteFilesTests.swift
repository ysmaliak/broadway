import Foundation
import Testing
import WebKit
@testable import Search

struct SiteFilesTests {
    private let file = URL(string: "https://files.example.com/report.zip")!
    private let plain = URL(string: "http://files.example.com/report.zip")!
    private let notLocal: (String) -> Bool = { _ in false }

    private func facts(_ start: FileStart = .page, clicked: Bool = false, agent: Bool = false, url: URL? = nil, secure: Bool = true) -> FileFacts {
        FileFacts(start: start, agent: agent, clicked: clicked, url: url ?? file, pageSecure: secure)
    }

    @Test func aClickedFileGoesAhead() {
        #expect(SiteFiles.verdict(facts(clicked: true), kept: nil) == .go)
    }

    @Test func aFileThePageStartedByItselfIsAsked() {
        #expect(SiteFiles.verdict(facts(), kept: nil) == .askSite)
    }

    @Test func whatThePersonAskedForGoesAhead() {
        for start in [FileStart.typed, .menu, .broadway] {
            #expect(SiteFiles.verdict(facts(start), kept: nil) == .go, "\(start)")
            #expect(SiteFiles.verdict(facts(start), kept: false) == .go, "\(start)")
        }
    }

    @Test func anAgentsFileIsNeverAsked() {
        #expect(SiteFiles.verdict(facts(agent: true), kept: nil) == .go)
        #expect(SiteFiles.verdict(facts(agent: true, url: plain), kept: false, local: notLocal) == .go)
    }

    @Test func aFileOnThisMacOpenedByItsAddressIsNeverAsked() {
        let here = URL(fileURLWithPath: "/tmp/site-files-test/blob.bin")
        #expect(SiteFiles.verdict(facts(url: here, secure: false), kept: nil) == .go)
        #expect(SiteFiles.verdict(facts(url: here, secure: false), kept: false) == .go)
    }

    @Test func aKeptAllowLetsTheSitesFilesThrough() {
        #expect(SiteFiles.verdict(facts(), kept: true) == .go)
    }

    @Test func aKeptDontAllowDropsTheSitesFilesButNotAClickedOne() {
        #expect(SiteFiles.verdict(facts(), kept: false) == .drop)
        #expect(SiteFiles.verdict(facts(clicked: true), kept: false) == .go)
    }

    @Test func aClickEarnsOneFile() {
        var clicks = FileClicks()
        clicks.clicked(1, at: 100)

        let first = clicks.take(at: 101)
        let second = clicks.take(at: 101.5)

        #expect(first)
        #expect(!second)
        #expect(clicks.spentLately(at: 102))
    }

    @Test func theNextClickEarnsOneAgain() {
        var clicks = FileClicks()
        clicks.clicked(1, at: 100)
        _ = clicks.take(at: 101)
        clicks.clicked(1, at: 102)
        let sameClick = clicks.take(at: 102)
        clicks.clicked(2, at: 103)
        let nextClick = clicks.take(at: 104)

        #expect(!sameClick)
        #expect(nextClick)
    }

    @Test func aClickLongAgoEarnsNothing() {
        var clicks = FileClicks()
        clicks.clicked(1, at: 100)

        let late = clicks.take(at: 100 + FileClicks.within + 1)

        #expect(!late)
    }

    @Test func aClickThatEndedInAPageEarnsNoFile() {
        var clicks = FileClicks()
        clicks.clicked(1, at: 100)
        clicks.committed()

        let taken = clicks.take(at: 101)

        #expect(!taken)
        #expect(!clicks.spentLately(at: 101))
    }

    @Test func noClickYetEarnsNothing() {
        var clicks = FileClicks()

        let taken = clicks.take(at: 1)

        #expect(!taken)
        #expect(!clicks.spentLately(at: 1))
    }

    @Test func answersAreKeptPerSiteAndPerStore() {
        var answers = SiteFileAnswers()
        answers.keep(true, site: "example.com", store: "one")
        answers.keep(false, site: "example.org", store: "one")

        #expect(answers.answer(site: "example.com", store: "one") == true)
        #expect(answers.answer(site: "EXAMPLE.com", store: "one") == true)
        #expect(answers.answer(site: "example.org", store: "one") == false)
        #expect(answers.answer(site: "example.com", store: "two") == nil)
        #expect(answers.answer(site: "example.net", store: "one") == nil)
    }

    @Test func forgettingAStoreLeavesTheOthers() {
        var answers = SiteFileAnswers()
        answers.keep(true, site: "example.com", store: "one")
        answers.keep(true, site: "example.com", store: "two")

        answers.forget(store: "one")

        #expect(answers.answer(site: "example.com", store: "one") == nil)
        #expect(answers.answer(site: "example.com", store: "two") == true)
    }

    @MainActor
    @Test func aDownloadAnswerBelongsToTheStoresHolderAndGoesWithIt() {
        let one = WKWebsiteDataStore.nonPersistent()
        let two = WKWebsiteDataStore.nonPersistent()
        #expect(SiteFileAsk.storeKey(one) == SiteFileAsk.storeKey(one))
        #expect(SiteFileAsk.storeKey(one) != SiteFileAsk.storeKey(two))
        #expect(SiteFileAsk.storeKey(one) == SiteFileAsk.key(CertificateTrust.holder(for: one)))

        let ask = SiteFileAsk()
        let space = UUID()
        ask.keep(true, site: "example.com", store: SiteFileAsk.storeKey(one))
        ask.keep(true, site: "example.com", store: SiteFileAsk.key(.space(space)))
        guard case .passing(let id) = CertificateTrust.holder(for: one) else {
            Issue.record("a private store is passing")
            return
        }

        ask.forget(.passing(id))
        #expect(ask.kept(site: "example.com", store: SiteFileAsk.storeKey(one)) == nil)
        #expect(ask.kept(site: "example.com", store: SiteFileAsk.key(.space(space))) == true)

        SiteFileAsk.shared.keep(true, site: "example.com", store: SiteFileAsk.key(.space(space)))
        CertificateTrust.forget(space: space)
        #expect(SiteFileAsk.shared.kept(site: "example.com", store: SiteFileAsk.key(.space(space))) == nil)
    }

    @Test func filesFromOneSiteWaitOnOneCard() {
        var cards = FileCards()
        let a = UUID(), b = UUID(), c = UUID()

        let first = cards.add(.askSite, file: a, name: "one.zip", site: "example.com", host: "example.com", more: false)
        let card = cards.front
        let second = cards.add(.askSite, file: b, name: "two.zip", site: "example.com", host: "example.com", more: false)
        let third = cards.add(.askSite, file: c, name: "three.zip", site: "example.com", host: "example.com", more: false)

        #expect(first == second && second == third)
        #expect(cards.cards.count == 1)
        #expect(card?.title == "\u{201C}example.com\u{201D} wants to download a file")
        #expect(card?.text == "one.zip")
        #expect(cards.front?.title == "\u{201C}example.com\u{201D} wants to download more files")
        #expect(cards.front?.text == nil)
        #expect(cards.front?.files == [a, b, c])
    }

    @Test func moreFilesAfterAClickAskWithTheMoreWords() {
        var cards = FileCards()

        cards.add(.askSite, file: UUID(), name: "two.zip", site: "example.com", host: "example.com", more: true)

        #expect(cards.front?.title == "\u{201C}example.com\u{201D} wants to download more files")
        #expect(cards.front?.text == nil)
        #expect(cards.front?.allow == "Allow")
        #expect(cards.front?.deny == "Don't Allow")
    }

    @Test func answeringACardAnswersEveryFileOnIt() {
        var cards = FileCards()
        let a = UUID(), b = UUID()
        let id = cards.add(.askSite, file: a, name: "one.zip", site: "example.com", host: "example.com", more: false)!
        cards.add(.askSite, file: b, name: "two.zip", site: "example.com", host: "example.com", more: false)

        let answered = cards.answer(id)

        #expect(answered?.files == [a, b])
        #expect(cards.isEmpty)
    }

    @Test func aFileThatEndsLeavesItsCard() {
        var cards = FileCards()
        let a = UUID(), b = UUID()
        cards.add(.askSite, file: a, name: "one.zip", site: "example.com", host: "example.com", more: false)
        cards.add(.askSite, file: b, name: "two.zip", site: "example.com", host: "example.com", more: false)

        let first = cards.leave(a)
        let last = cards.leave(b)

        #expect(first == nil)
        #expect(last != nil)
        #expect(cards.isEmpty)
    }

    @Test func anHttpsPageSendingAnHttpFileIsNotSecure() {
        let verdict = SiteFiles.verdict(facts(clicked: true, url: plain), kept: nil, local: notLocal)

        #expect(verdict == .askInsecure)
    }

    @Test func anHttpPageSendingAnHttpFileIsNotAsked() {
        #expect(SiteFiles.verdict(facts(clicked: true, url: plain, secure: false), kept: nil, local: notLocal) == .go)
        #expect(!SiteFiles.insecure(facts(url: plain, secure: false), local: notLocal))
    }

    @Test func aLocalHostIsNotAskedAbout() {
        for address in ["http://127.0.0.1:8080/report.zip", "http://localhost/report.zip", "http://printer.local/report.zip",
                        "http://192.168.1.20/report.zip", "http://[::1]:8080/report.zip"] {
            let url = URL(string: address)!

            #expect(!SiteFiles.insecure(facts(clicked: true, url: url)), "\(address)")
        }
        #expect(SiteFiles.insecure(facts(clicked: true, url: plain)))
    }

    @Test func aRedirectToHttpIsJudgedByTheLastAddress() {
        let ended = facts(clicked: true, url: URL(string: "http://mirror.example.net/report.zip")!)

        #expect(SiteFiles.verdict(ended, kept: nil, local: notLocal) == .askInsecure)
        #expect(SiteFiles.verdict(facts(clicked: true), kept: nil, local: notLocal) == .go)
    }

    @Test func anHttpAddressThePersonTypedIsTheirOwnChoice() {
        #expect(SiteFiles.verdict(facts(.typed, url: plain), kept: nil, local: notLocal) == .go)
    }

    @Test func aFileBothUnaskedAndNotSecureGetsTheSecureCardAlone() {
        var cards = FileCards()
        let verdict = SiteFiles.verdict(facts(url: plain), kept: nil, local: notLocal)
        cards.add(verdict, file: UUID(), name: "report.zip", site: "example.com", host: "files.example.com", more: false)

        #expect(verdict == .askInsecure)
        #expect(cards.cards.count == 1)
        #expect(cards.front?.title == "This file is not sent securely")
        #expect(cards.front?.text == "\u{201C}report.zip\u{201D} from \u{201C}files.example.com\u{201D} could be read or changed on the way")
        #expect(cards.front?.allow == "Download Anyway")
        #expect(cards.front?.deny == "Don't Download")
    }

    @Test func aFileNotSentSecurelyIsAskedEveryTimeEvenWhenTheSiteIsAllowed() {
        var cards = FileCards()
        let verdict = SiteFiles.verdict(facts(url: plain), kept: true, local: notLocal)
        cards.add(verdict, file: UUID(), name: "a.zip", site: "example.com", host: "files.example.com", more: false)
        cards.add(verdict, file: UUID(), name: "b.zip", site: "example.com", host: "files.example.com", more: false)

        #expect(verdict == .askInsecure)
        #expect(cards.cards.count == 2)
    }

    @Test func aSiteTheAnswerDroppedIsNotAskedAboutAgainEvenOverHttp() {
        #expect(SiteFiles.verdict(facts(url: plain), kept: false, local: notLocal) == .drop)
    }
}
