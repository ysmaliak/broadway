import Foundation
import Security
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(1)))
struct ConsentMarkTests {
    @Test func onlyAMarkReadBackCountsAsConsent() {
        let mark = ConsentMark.mark

        #expect(ConsentMark.granted(errSecSuccess, mark))
        #expect(!ConsentMark.granted(errSecSuccess, Data("yes".utf8)))
        #expect(!ConsentMark.granted(errSecSuccess, nil))
        #expect(!ConsentMark.granted(errSecMissingEntitlement, mark))
        #expect(!ConsentMark.granted(errSecItemNotFound, nil))
        #expect(!ConsentMark.granted(errSecAuthFailed, nil))
        #expect(!ConsentMark.granted(errSecInteractionNotAllowed, nil))
    }

    @Test func eachSignatureKeepsItsOwnSlot() {
        let development = ConsentMark.fingerprint(#"identifier "com.ysmaliak.broadway" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Jane Appleseed (ABCDE12345)""#)
        let release = ConsentMark.fingerprint(#"identifier "com.ysmaliak.broadway" and anchor apple generic and certificate leaf[subject.OU] = ABCDE12345"#)

        let mine = ConsentMark.account("consent", signature: development, world: nil)
        let theirs = ConsentMark.account("consent", signature: release, world: nil)
        let tested = ConsentMark.account("bypass", signature: development, world: "probe")

        #expect(development.count == 12)
        #expect(development == ConsentMark.fingerprint(#"identifier "com.ysmaliak.broadway" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Jane Appleseed (ABCDE12345)""#))
        #expect(mine == "consent \(development)")
        #expect(mine != theirs)
        #expect(tested == "bypass \(development) (probe)")
    }

    @Test func anUnsignedBuildHasNoSlot() {
        let signature: String? = nil

        let account = ConsentMark.account("consent", signature: signature, world: nil)

        #expect(account == nil)
    }
}
