import Foundation
import Testing
@testable import Search

/// Nothing here touches the keychain: every CSV row below is one that is
/// skipped, so nothing is ever saved.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct VaultAndUpdaterTests {
    @Test func hostIsTheSiteWithoutWWW() {
        #expect(Vault.host(of: "https://www.example.com/login?next=/") == "example.com")
        #expect(Vault.host(of: "  Example.COM  ") == "example.com")
        #expect(Vault.host(of: "http://accounts.example.com") == "accounts.example.com")
    }

    @Test func hostIsEmptyForAnythingButAWebsite() {
        #expect(Vault.host(of: "android://hash@com.vendor.app/") == "")
        #expect(Vault.host(of: "ftp://example.com") == "")
        #expect(Vault.host(of: "") == "")
    }

    private let suffixes: Set<String> = ["com", "uk", "co.uk", "github.io"]

    private func domain(_ host: String) -> String {
        Registrable.domain(of: host, isSuffix: { self.suffixes.contains($0) })
    }

    @Test func registrableDomainIsTheSiteAboveASuffix() {
        #expect(domain("accounts.example.com") == "example.com")
        #expect(domain("www.bbc.co.uk") == "bbc.co.uk")
        #expect(domain("bbc.co.uk") == "bbc.co.uk")
    }

    @Test func registrableDomainNeverSpansTenantsOfASuffix() {
        #expect(domain("alice.github.io") == "alice.github.io")
        #expect(domain("alice.github.io") != domain("bob.github.io"))
        #expect(domain("github.io") == "github.io")
    }

    @Test func registrableDomainLeavesAddressesWhole() {
        #expect(domain("192.168.1.10") == "192.168.1.10")
        #expect(domain("[::1]") == "[::1]")
    }

    @Test func registrableDomainWithoutASuffixListIsTheHost() {
        #expect(Registrable.domain(of: "accounts.example.com", isSuffix: nil) == "accounts.example.com")
    }

    @Test func exportWithoutAPasswordColumnIsSkippedWhole() {
        let result = Vault.take(csv: "url,username\nhttps://example.com,me\nhttps://example.org,you\n")
        #expect(result.kept == 0)
        #expect(result.skipped == 2)
    }

    @Test func emptyExportKeepsAndSkipsNothing() {
        let result = Vault.take(csv: "")
        #expect(result.kept == 0)
        #expect(result.skipped == 0)
    }

    @Test func rowsThatCannotBeKeptAreCountedAsSkipped() {
        let csv = """
        name,url,username,password,note
        no password,https://example.com,me,,
        no site,,me,secret,
        an app,android://hash@com.vendor.app/,me,secret,
        too short,https://example.com
        """
        let result = Vault.take(csv: csv)
        #expect(result.kept == 0)
        #expect(result.skipped == 4)
    }

    @Test func quotedFieldsWithNewlinesAndQuotesStayOneRow() {
        // If the newline inside the quotes split the row, this would count
        // two skipped, not one.
        let csv = "url,username,password\nandroid://hash@com.vendor.app/,\"a \"\"quoted\"\"\nname\",secret\n"
        let result = Vault.take(csv: csv)
        #expect(result.kept == 0)
        #expect(result.skipped == 1)
    }

    @Test func windowsLineEndingsAndBlankLinesDoNotAddRows() {
        let csv = "url,username,password\r\nandroid://x@com.app/,me,secret\r\n\r\n"
        #expect(Vault.take(csv: csv).skipped == 1)
    }
}
