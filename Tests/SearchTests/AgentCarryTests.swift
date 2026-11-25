import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AgentSecretPolicyTests {
    @Test func typingASecretFollowsTheMode() {
        #expect(AgentSecretPolicy.typing(mode: .ask, rule: nil, alwaysAsk: false) == .ask(always: false))
        #expect(AgentSecretPolicy.typing(mode: .ask, rule: .always, alwaysAsk: false) == .ask(always: false))
        #expect(AgentSecretPolicy.typing(mode: .auto, rule: nil, alwaysAsk: false) == .ask(always: true))
        #expect(AgentSecretPolicy.typing(mode: .auto, rule: .always, alwaysAsk: false) == .go)
        #expect(AgentSecretPolicy.typing(mode: .bypass, rule: nil, alwaysAsk: false) == .go)
        #expect(AgentSecretPolicy.typing(mode: .bypass, rule: .never, alwaysAsk: false) == .refuse)
        #expect(AgentSecretPolicy.typing(mode: .bypass, rule: nil, alwaysAsk: true) == .ask(always: false))
    }

    @Test func carryingAsksInEveryModeAndNeverHereOnEitherEndRefuses() {
        #expect(AgentSecretPolicy.carrying([nil, nil]) == .ask(always: false))
        #expect(AgentSecretPolicy.carrying([.always, .always]) == .ask(always: false))
        #expect(AgentSecretPolicy.carrying([.always, .never]) == .refuse)
        #expect(AgentSecretPolicy.carrying([.never, nil]) == .refuse)
    }

    @Test func aCodeAsksUnlessThisAgentSignedInThereLately() {
        #expect(AgentSecretPolicy.code(mode: .ask, rule: nil, alwaysAsk: false, signedInLately: true) == .go)
        #expect(AgentSecretPolicy.code(mode: .ask, rule: nil, alwaysAsk: false, signedInLately: false) == .ask(always: false))
        #expect(AgentSecretPolicy.code(mode: .auto, rule: .always, alwaysAsk: false, signedInLately: false) == .ask(always: false))
        #expect(AgentSecretPolicy.code(mode: .bypass, rule: nil, alwaysAsk: false, signedInLately: false) == .go)
        #expect(AgentSecretPolicy.code(mode: .bypass, rule: nil, alwaysAsk: true, signedInLately: false) == .ask(always: false))
        #expect(AgentSecretPolicy.code(mode: .bypass, rule: .never, alwaysAsk: false, signedInLately: true) == .refuse)
    }

    @Test func aSignInIsLateAfterFiveMinutesAndBelongsToItsAgent() {
        let one = UUID()
        let other = UUID()
        AgentSignInRecord.note(one, site: "example.com")

        #expect(AgentSignInRecord.lately(one, site: "example.com"))
        #expect(!AgentSignInRecord.lately(other, site: "example.com"))
        #expect(!AgentSignInRecord.lately(one, site: "example.org"))
        #expect(!AgentSignInRecord.lately(one, site: "example.com", within: 0))
    }
}

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct AgentCodeFitTests {
    private func code(_ digits: String = "482913", sender: String = "", address: String = "", at: Date = Date()) -> OneTimeCode {
        OneTimeCode(code: digits, sender: sender, at: at, address: address)
    }

    @Test func aCodeFitsTheSiteItWasMailedFrom() {
        #expect(AgentCodeFit.fits(code(address: "noreply@shop.example"), site: "shop.example"))
        #expect(AgentCodeFit.fits(code(address: "noreply@mail.shop.example"), site: "shop.example"))
        #expect(AgentCodeFit.fits(code(sender: "Shop"), site: "shop.example"))
        #expect(!AgentCodeFit.fits(code(sender: "Store", address: "noreply@store.example"), site: "shop.example"))
        #expect(!AgentCodeFit.fits(code(sender: "Mailer", address: "shop.example@evil.example"), site: "shop.example"))
        #expect(!AgentCodeFit.fits(code(sender: "127 Club"), site: "127.0.0.1"))
        #expect(!AgentCodeFit.fits(code(sender: "PayPal"), site: "pay.xyz"))
        #expect(!AgentCodeFit.fits(code(sender: "Shop"), site: "git.io"))
        #expect(AgentCodeFit.fits(code(sender: "Google Accounts"), site: "google.com"))
        #expect(AgentCodeFit.fits(code(address: "noreply@127.0.0.1"), site: "127.0.0.1"))
    }

    @Test func theNewestFittingCodeAfterTheAskIsTaken() {
        let asked = Date().addingTimeInterval(-60)
        let codes = [code("111111", address: "a@shop.example", at: asked.addingTimeInterval(-30)),
                     code("222222", address: "a@shop.example", at: asked.addingTimeInterval(10)),
                     code("333333", address: "a@shop.example", at: asked.addingTimeInterval(20)),
                     code("444444", address: "a@other.example", at: asked.addingTimeInterval(30))]

        let picked = AgentCodeFit.pick(codes, site: "shop.example", since: asked)

        #expect(picked.code?.code == "333333")
        #expect(picked.strangers == 1)
    }

    @Test func codesAreFilledOnlyOnSafePagesOfOrdinaryTabs() {
        #expect(AgentCodeFit.allowed(URL(string: "https://shop.example/login"), privateTab: false))
        #expect(AgentCodeFit.allowed(URL(string: "http://127.0.0.1:8080/code"), privateTab: false))
        #expect(!AgentCodeFit.allowed(URL(string: "http://shop.example/login"), privateTab: false))
        #expect(!AgentCodeFit.allowed(URL(string: "https://shop.example/login"), privateTab: true))
    }
}
