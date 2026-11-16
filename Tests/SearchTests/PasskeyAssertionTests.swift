import AuthenticationServices
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PasskeyAssertionTests {
    @Test func securityKeyCanOmitUserHandle() throws {
        let reply = reply(from: Assertion())
        #expect(reply["userHandle"] is NSNull)
        #expect((reply["kind"] as? String) == "get")
        #expect((reply["id"] as? String) == "AQ")
        #expect((reply["clientDataJSON"] as? String) == "Ag")
        #expect((reply["authenticatorData"] as? String) == "Aw")
        #expect((reply["signature"] as? String) == "BA")
        #expect((reply["attachment"] as? String) == "cross-platform")
        #expect(throws: Never.self) { try JSONSerialization.data(withJSONObject: reply) }
    }

    @Test func returnedUserHandleIsPreserved() {
        let assertion = Assertion()
        assertion.userID = Data([0xfb, 0xff])
        #expect((reply(from: assertion)["userHandle"] as? String) == "-_8")
        assertion.userID = Data()
        #expect((reply(from: assertion)["userHandle"] as? String) == "")
    }

    private func reply(from got: ASAuthorizationPublicKeyCredentialAssertion) -> [String: Any] {
        // Exercise the native protocol's implicitly unwrapped userID, as the delegate does.
        Passkeys.assertionReply(
            id: got.credentialID, clientData: got.rawClientDataJSON, authenticatorData: got.rawAuthenticatorData,
            signature: got.signature, user: got.userID, attachment: "cross-platform"
        )
    }
}

@objc(SearchTestPasskeyAssertion)
private final class Assertion: NSObject, ASAuthorizationPublicKeyCredentialAssertion {
    var credentialID = Data([1])
    var rawClientDataJSON = Data([2])
    var rawAuthenticatorData: Data! = Data([3])
    var signature: Data! = Data([4])
    var userID: Data!
    static var supportsSecureCoding: Bool { true }
    override init() { super.init() }
    required init?(coder: NSCoder) { nil }
    func encode(with coder: NSCoder) {}
    func copy(with zone: NSZone? = nil) -> Any { self }
}
