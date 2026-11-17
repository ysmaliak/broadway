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
struct StrongPasswordNameTests {
    private func taken(_ user: String) -> StrongTaken {
        StrongTaken(host: "join.example.test", user: user, password: "Abcdef-ghijk2-mnopq3", clear: false)
    }

    @Test func theLoginTakesTheNameSentWithTheForm() {
        #expect(taken("").settle(sentUser: "pat@example.test") == .renamed(from: "", to: "pat@example.test"))
    }

    @Test func aNameKnownWhenTakenStaysWhenTheSameNameIsSent() {
        #expect(taken("pat").settle(sentUser: "pat") == .kept)
    }

    @Test func aFormSentWithNoNameKeepsTheNameItWasKeptUnder() {
        #expect(taken("pat").settle(sentUser: "") == .kept)
        #expect(taken("").settle(sentUser: "  ") == .kept)
    }

    @Test func aNameChangedBeforeSendingRenamesTheLogin() {
        #expect(taken("pat").settle(sentUser: "sam") == .renamed(from: "pat", to: "sam"))
    }

    @Test func theTakenPasswordIsKnownWhenSent() {
        #expect(taken("").sent(host: "join.example.test", password: "Abcdef-ghijk2-mnopq3"))
    }

    @Test func anotherPasswordSentIsNotTheTakenOne() {
        #expect(!taken("").sent(host: "join.example.test", password: "something-else"))
    }

    @Test func theTakenPasswordSentToAnotherSiteIsNotTheTakenOne() {
        #expect(!taken("").sent(host: "elsewhere.test", password: "Abcdef-ghijk2-mnopq3"))
    }

    @Test func aRenameKeepsTheNewNameAndForgetsTheOld() {
        var saved: [String] = []
        var forgotten: [String] = []
        let name = StrongPasswordKeep.rename(host: "join.example.test", from: "", to: "pat", password: "x", clear: false,
                                             save: { _, user, _, _ in saved.append(user); return true }, forget: { _, user in forgotten.append(user) })
        #expect(name == "pat")
        #expect(saved == ["pat"])
        #expect(forgotten == [""])
    }

    @Test func aRenameTheKeychainRefusesKeepsTheOldLogin() {
        var forgotten: [String] = []
        let name = StrongPasswordKeep.rename(host: "join.example.test", from: "", to: "pat", password: "x", clear: false,
                                             save: { _, _, _, _ in false }, forget: { _, user in forgotten.append(user) })
        #expect(name == "")
        #expect(forgotten.isEmpty)
    }
}
