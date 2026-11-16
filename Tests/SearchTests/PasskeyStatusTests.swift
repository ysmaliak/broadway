import AuthenticationServices
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PasskeyStatusTests {
    @Test func aBuildWithoutThePermissionSaysSoWhateverTheMacSays() {
        let answers: [ASAuthorizationWebBrowserPublicKeyCredentialManager.AuthorizationState] = [.authorized, .denied, .notDetermined]

        let statuses = answers.map { PasskeyStatus.of(entitled: false, access: $0) }

        #expect(statuses == [.awaitingApple, .awaitingApple, .awaitingApple])
        #expect(!PasskeyStatus.awaitingApple.possible)
        #expect(PasskeyStatus.awaitingApple.detail == "Off for now, because this build doesn't have Apple's browser permission")
    }

    @Test func anEntitledBuildFollowsTheMacsAnswer() {
        #expect(PasskeyStatus.of(entitled: true, access: .authorized) == .ready)
        #expect(PasskeyStatus.of(entitled: true, access: .denied) == .refused)
        #expect(PasskeyStatus.of(entitled: true, access: .notDetermined) == .notAsked)
        #expect(PasskeyStatus.ready.detail == nil)
    }

    @Test func thisTestRunIsNotEntitled() {
        #expect(!Preferences.entitledToPasskeys)
        #expect(PasskeyStatus.current == .awaitingApple)
    }

    @Test func theEntitlementsNameNobodyElsesApp() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

        let text = try String(contentsOf: root.appendingPathComponent("Search.passkeys.entitlements"), encoding: .utf8)

        #expect(text.contains("com.apple.developer.web-browser.public-key-credential"))
        #expect(!text.contains("officecommun"))
        #expect(!text.contains("application-identifier"))
    }
}
