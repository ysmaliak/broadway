import Foundation
import Testing
@testable import Search

@Suite
struct StrongPasswordTests {
    private let lookAlikes: Set<Character> = ["l", "I", "O", "0", "1"]

    private func counting() -> (Int) -> Int {
        var next = 0
        return { bound in
            defer { next += 1 }
            return next % bound
        }
    }

    @Test func aPasswordIsThreeGroupsOfSixJoinedByTwoDashes() throws {
        let made = try #require(StrongPassword.make())
        #expect(made.count == 20)
        let groups = made.split(separator: "-", omittingEmptySubsequences: false)
        #expect(groups.count == 3)
        #expect(groups.allSatisfy { $0.count == 6 && $0.allSatisfy { $0.isLetter || $0.isNumber } })
    }

    @Test func everyPasswordHasACapitalASmallLetterAndADigit() throws {
        for _ in 0..<500 {
            let made = try #require(StrongPassword.make())
            #expect(made.contains { $0.isUppercase })
            #expect(made.contains { $0.isLowercase })
            #expect(made.contains { $0.isNumber })
        }
    }

    @Test func noPasswordHoldsALookAlike() throws {
        for _ in 0..<500 {
            let made = try #require(StrongPassword.make())
            #expect(!made.contains { lookAlikes.contains($0) })
        }
    }

    @Test func theAlphabetLeavesOutOnlyTheLookAlikes() {
        let every = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        #expect(Set(StrongPassword.alphabet) == every.subtracting(lookAlikes))
        #expect(StrongPassword.alphabet.count == 57)
    }

    @Test func aDrawMissingAKindOfCharacterIsDrawnAgain() throws {
        var draws = 0
        let made = try #require(StrongPassword.make { bound in
            draws += 1
            return draws <= 18 ? 0 : (draws * 7) % bound
        })
        #expect(draws > 18)
        #expect(made.contains { $0.isUppercase } && made.contains { $0.isNumber })
    }

    @Test func thePasswordComesFromTheRandomSourceItIsGiven() {
        #expect(StrongPassword.make(random: counting()) == StrongPassword.make(random: counting()))
    }

    @Test func theSecureSourceGivesDifferentPasswords() {
        let made = Set((0..<50).compactMap { _ in StrongPassword.make() })
        #expect(made.count == 50)
    }

    @Test func theSecureSourceStaysBelowItsBound() {
        for bound in [1, 2, 7, 57] {
            #expect((0..<200).allSatisfy { _ in (0..<bound).contains(StrongPassword.secure(below: bound)) })
        }
    }

    @Test func aBoxThatTakesFewerThanTwentyGetsOneThatLongWithNoDashes() throws {
        for limit in [8, 12, 19] {
            let made = try #require(StrongPassword.make(maxLength: limit))
            #expect(made.count == limit)
            #expect(!made.contains("-"))
            #expect(!made.contains { lookAlikes.contains($0) })
        }
    }

    @Test func aBoxThatTakesTwentyOrMoreGetsTheGroupedPassword() throws {
        for limit in [20, 64] {
            #expect(try #require(StrongPassword.make(maxLength: limit)).count == 20)
        }
    }

    @Test func aBoxThatTakesFewerThanEightGetsNothing() {
        #expect(StrongPassword.make(maxLength: 7) == nil)
        #expect(StrongPassword.make(maxLength: 1) == nil)
    }

    @Test func aBoxWithNoLimitGetsTheGroupedPassword() throws {
        #expect(try #require(StrongPassword.make(maxLength: 0)).count == 20)
    }
}

@Suite
struct StrongPasswordRuleTests {
    private let ask = StrongPasswordAsk(fresh: 0)
    private let keeping = StrongPasswordKeeping()

    @Test func anEmptyNewPasswordBoxIsOfferedOne() {
        #expect(StrongPasswordRule.offers(ask, keeping) == 20)
    }

    @Test func aBoxThatIsNotForANewPasswordIsOfferedNothing() {
        #expect(StrongPasswordRule.offers(StrongPasswordAsk(fresh: nil), keeping) == nil)
    }

    @Test func aBoxWithAShortLimitIsOfferedOneThatLong() {
        var short = ask
        short.fresh = 12
        #expect(StrongPasswordRule.offers(short, keeping) == 12)
    }

    @Test func aBoxThatTakesFewerThanEightIsOfferedNothing() {
        var short = ask
        short.fresh = 6
        #expect(StrongPasswordRule.offers(short, keeping) == nil)
    }

    @Test func nothingIsOfferedWithKeepingPasswordsOff() {
        #expect(StrongPasswordRule.offers(ask, StrongPasswordKeeping(saves: false)) == nil)
    }

    @Test func nothingIsOfferedInAPrivateWindow() {
        var shy = ask
        shy.shy = true
        #expect(StrongPasswordRule.offers(shy, keeping) == nil)
    }

    @Test func nothingIsOfferedInAnAgentsTab() {
        var agent = ask
        agent.agent = true
        #expect(StrongPasswordRule.offers(agent, keeping) == nil)
    }

    @Test func nothingIsOfferedWithApplePasswordsOn() {
        #expect(StrongPasswordRule.offers(ask, StrongPasswordKeeping(applePasswords: true)) == nil)
    }

    @Test func nothingIsOfferedWhenAnExtensionKeepsPasswords() {
        #expect(StrongPasswordRule.offers(ask, StrongPasswordKeeping(savingTakenByExtension: true)) == nil)
    }

    @Test func nothingIsOfferedOnASiteThatIsNeverAsked() {
        var never = ask
        never.never = true
        #expect(StrongPasswordRule.offers(never, keeping) == nil)
    }

    @Test func nothingIsOfferedInAFrameOfAnotherSite() {
        var framed = ask
        framed.mainFrame = false
        #expect(StrongPasswordRule.offers(framed, keeping) == nil)
    }

    @Test func nothingIsOfferedOnAnExtensionsPage() {
        var page = ask
        page.extensionPage = true
        #expect(StrongPasswordRule.offers(page, keeping) == nil)
    }
}

@Suite
struct StrongPasswordKeepTests {
    private let host = "join.example.test"
    private let strong = "Abcdef-ghjk23-Mnpqr4"

    private final class Keychain {
        var secrets: [String: String] = [:]
        var refuses = false

        func save(_ host: String, _ user: String, _ password: String, _ clear: Bool) -> Bool {
            guard !refuses else { return false }
            secrets[host + "/" + user] = password
            return true
        }

        func forget(_ host: String, _ user: String) { secrets[host + "/" + user] = nil }

        var kept: [Kept] {
            secrets.keys.map { key in
                let parts = key.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
                return Kept(host: String(parts[0]), user: String(parts[1]))
            }
        }
    }

    private func site(_ host: String) -> String { host.split(separator: ".").suffix(2).joined(separator: ".") }

    private func take(_ keychain: Keychain, user: String) -> StrongPasswordKeep.Take {
        StrongPasswordKeep.take(host: host, user: user, password: strong, clear: false, kept: keychain.kept, registrable: site, save: keychain.save)
    }

    private func sent(_ keychain: Keychain, keptUser: String, saved: Bool, sentUser: String, password: String? = nil) -> String? {
        StrongPasswordKeep.sent(host: host, keptUser: keptUser, saved: saved, sentUser: sentUser, password: password ?? strong, clear: false,
                                save: keychain.save, forget: keychain.forget)
    }

    private func taken(saved: Bool) -> StrongTaken {
        StrongTaken(host: host, user: "pat", password: strong, clear: false, saved: saved)
    }

    @Test func aNewNameIsKeptAtOnceWhenTaken() {
        let keychain = Keychain()
        #expect(take(keychain, user: "pat") == .kept)
        #expect(keychain.secrets["\(host)/pat"] == strong)
    }

    @Test func aLoginKeptUnderTheSameNameIsNotReplacedWhenTaken() {
        let keychain = Keychain()
        _ = keychain.save(host, "pat", "old-one", false)
        #expect(take(keychain, user: "pat") == .waits)
        #expect(keychain.secrets["\(host)/pat"] == "old-one")
    }

    @Test func aLoginKeptUnderTheSameNameOnAnotherHostOfTheSiteIsNotReplacedWhenTaken() {
        let keychain = Keychain()
        _ = keychain.save("www.example.test", "pat", "old-one", false)
        #expect(take(keychain, user: "pat") == .waits)
        #expect(keychain.secrets["\(host)/pat"] == nil)
    }

    @Test func aLoginKeptUnderAnotherNameDoesNotStopKeepingAtOnce() {
        let keychain = Keychain()
        _ = keychain.save(host, "sam", "old-one", false)
        #expect(take(keychain, user: "pat") == .kept)
        #expect(keychain.secrets["\(host)/sam"] == "old-one")
    }

    @Test func aKeychainThatRefusesIsSaidSo() {
        let keychain = Keychain()
        keychain.refuses = true
        #expect(take(keychain, user: "pat") == .refused)
    }

    @Test func theKeptLoginIsReplacedWhenTheFormIsSentWithTheTakenPassword() {
        let keychain = Keychain()
        _ = keychain.save(host, "pat", "old-one", false)
        #expect(take(keychain, user: "pat") == .waits)
        #expect(taken(saved: false).sent(host: host, password: strong))
        #expect(sent(keychain, keptUser: "pat", saved: false, sentUser: "pat") == "pat")
        #expect(keychain.secrets["\(host)/pat"] == strong)
    }

    @Test func theKeptLoginIsUntouchedWhenTheFormIsSentWithAnotherPassword() {
        let keychain = Keychain()
        _ = keychain.save(host, "pat", "old-one", false)
        #expect(take(keychain, user: "pat") == .waits)
        #expect(!taken(saved: false).sent(host: host, password: "typed-by-hand"))
        #expect(keychain.secrets["\(host)/pat"] == "old-one")
    }

    @Test func theKeptLoginIsUntouchedWhenTheFormIsNeverSent() {
        let keychain = Keychain()
        _ = keychain.save(host, "pat", "old-one", false)
        _ = take(keychain, user: "pat")
        #expect(keychain.secrets == ["\(host)/pat": "old-one"])
    }

    @Test func theLoginTakesTheNameSentWithTheForm() {
        let keychain = Keychain()
        #expect(take(keychain, user: "") == .kept)
        #expect(sent(keychain, keptUser: "", saved: true, sentUser: "pat@example.test") == "pat@example.test")
        #expect(keychain.secrets == ["\(host)/pat@example.test": strong])
    }

    @Test func aFormSentWithNoNameKeepsTheNameItWasKeptUnder() {
        let keychain = Keychain()
        _ = take(keychain, user: "pat")
        #expect(sent(keychain, keptUser: "pat", saved: true, sentUser: "  ") == nil)
        #expect(keychain.secrets == ["\(host)/pat": strong])
    }

    @Test func aSendWithTheSameNameChangesNothingMore() {
        let keychain = Keychain()
        _ = take(keychain, user: "pat")
        #expect(sent(keychain, keptUser: "pat", saved: true, sentUser: "pat") == nil)
        #expect(keychain.secrets == ["\(host)/pat": strong])
    }

    @Test func aWaitingPasswordSentWithAnotherNameIsKeptUnderThatName() {
        let keychain = Keychain()
        _ = keychain.save(host, "pat", "old-one", false)
        _ = take(keychain, user: "pat")
        #expect(sent(keychain, keptUser: "pat", saved: false, sentUser: "sam") == "sam")
        #expect(keychain.secrets == ["\(host)/pat": "old-one", "\(host)/sam": strong])
    }

    @Test func aRenameTheKeychainRefusesKeepsTheOldLogin() {
        let keychain = Keychain()
        _ = take(keychain, user: "")
        keychain.refuses = true
        #expect(sent(keychain, keptUser: "", saved: true, sentUser: "pat") == nil)
        #expect(keychain.secrets == ["\(host)/": strong])
    }

    @Test func theTakenPasswordSentToAnotherSiteIsNotTheTakenOne() {
        #expect(!taken(saved: true).sent(host: "elsewhere.test", password: strong))
    }
}
