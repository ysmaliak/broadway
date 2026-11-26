import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PublicSuffixTests {
    @Test func passwordsPasskeysAndTheAddressReadOneSuffixList() throws {
        if AtRest.systemSuffix == nil { try Test.cancel("The Mac's public suffix list isn't reachable here") }
        #expect(Vault.registrable("www.example.co.uk") == "example.co.uk")
        #expect(Vault.registrable("login.shop.example.com") == "example.com")
        #expect(Vault.registrable("a.b.someone.github.io") == "someone.github.io")
        #expect(Passkeys.fits("example.com", "login.example.com"))
        #expect(Passkeys.fits("example.com", "example.com"))
        #expect(!Passkeys.fits("com", "example.com"))
        #expect(!Passkeys.fits("co.uk", "example.co.uk"))
        #expect(!Passkeys.fits("github.io", "someone.github.io"))
        #expect(!Passkeys.fits("0.0.1", "127.0.0.1"))
        #expect(Registrable.sameSite("login.example.com", "example.com", isSuffix: AtRest.systemSuffix))
        #expect(!Registrable.sameSite("one.github.io", "two.github.io", isSuffix: AtRest.systemSuffix))
    }
}
