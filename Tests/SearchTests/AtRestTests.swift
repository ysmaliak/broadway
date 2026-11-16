import Foundation
import Testing
@testable import Search

/// The address at rest on the tab you're on (AtRest.swift): the site it
/// names, and how a look-alike name is shown.
@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AtRestTests {
    private func rest(_ address: String) -> AtRest? {
        AtRest.make(URL(string: address)!)
    }

    @Test func registrableDomainInInkSubdomainDim() throws {
        let gist = try #require(rest("https://gist.github.com/someone/abc"))
        #expect(gist.kind == .secure)
        #expect(gist.lead == "gist.")
        #expect(gist.name == "github.com")
        #expect(gist.tail == "")
        #expect(gist.text == "gist.github.com")

        if AtRest.systemSuffix == nil { try Test.cancel("The Mac's public suffix list isn't reachable here") }
        let bbc = try #require(rest("https://www.bbc.co.uk/news"))
        #expect(bbc.lead == "")
        #expect(bbc.name == "bbc.co.uk")
        let deep = try #require(rest("https://a.b.someone.github.io/"))
        #expect(deep.name == "someone.github.io", "github.io is a suffix anyone registers under")
        #expect(deep.lead == "a.b.")
    }

    @Test func wwwIsLeftOff() throws {
        #expect(rest("https://www.apple.com/")?.text == "apple.com")
        #expect(rest("https://WWW.Apple.COM./mac")?.text == "apple.com", "case and a trailing dot don't change the site")
    }

    @Test func userinfoNeverPassesForTheSite() throws {
        let trick = try #require(rest("https://apple.com@evil.example/"))
        #expect(trick.text == "evil.example")
        let trick2 = try #require(rest("https://accounts.google.com.evil.example/login"))
        #expect(trick2.name == "evil.example")
        #expect(trick2.lead == "accounts.google.com.")
    }

    @Test func plainHttpIsMarked() throws {
        let plain = try #require(rest("http://neverssl.com/"))
        #expect(plain.kind == .notSecure)
        #expect(plain.text == "Not secure, neverssl.com")
        // This Mac is not a risk over http.
        #expect(rest("http://localhost:3000/")?.kind == .secure)
        #expect(rest("http://localhost:3000/")?.text == "localhost:3000")
        #expect(rest("http://127.0.0.1:8080/x")?.kind == .secure)
        #expect(rest("http://[::1]:5173/")?.text == "[::1]:5173")
        #expect(rest("http://192.168.1.10/")?.kind == .notSecure)
    }

    @Test func portsOnlyWhenNotTheSchemesOwn() throws {
        #expect(rest("https://example.com:443/")?.tail == "")
        #expect(rest("https://example.com:8443/")?.tail == ":8443")
        #expect(rest("http://example.com:80/")?.tail == "")
    }

    @Test func addressesStayWhole() throws {
        #expect(rest("https://8.8.8.8/")?.name == "8.8.8.8")
        #expect(rest("https://8.8.8.8/")?.lead == "")
    }

    @Test func filesByName() throws {
        let file = try #require(AtRest.make(URL(fileURLWithPath: "/Users/someone/Desktop/My report.pdf")))
        #expect(file.kind == .file)
        #expect(file.text == "My report.pdf")
    }

    @Test func notWebsites() throws {
        #expect(rest("about:blank") == nil)
        #expect(AtRest.of(nil) == nil)
        #expect(rest("data:text/html,hi")?.text == "Not a site")
        #expect(rest("data:text/html,hi")?.kind == .other)
        #expect(rest("webkit-extension://abc/popup.html")?.text == "Extension page")
    }

    // MARK: - look-alikes

    @Test func cyrillicLookalikeShowsPunycode() throws {
        // "аррӏе.com", every letter Cyrillic: Xudong Zheng's 2017 example.
        let fake = try #require(rest("https://xn--80ak6aa92e.com/"))
        #expect(fake.text == "xn--80ak6aa92e.com")
        // Written in its own letters, it is still shown as punycode.
        let typed = try #require(AtRest.make(URL(string: "https://xn--80ak6aa92e.com")!))
        #expect(typed.name == "xn--80ak6aa92e.com")
        #expect(Hosts.ascii("аррӏе.com") == "xn--80ak6aa92e.com")
    }

    @Test func mixedScriptLookalikeShowsPunycode() throws {
        // "аpple.com" with only the first letter Cyrillic.
        let ascii = Hosts.ascii("аpple.com")
        #expect(ascii.hasPrefix("xn--"), "\(ascii)")
        #expect(Hosts.display(ascii) == ascii)
        // Greek omicron in "gοοgle".
        let greek = Hosts.ascii("gοοgle.com")
        #expect(Hosts.display(greek) == greek)
        // Latin with a dot below, "ạpple".
        let dotted = Hosts.ascii("ạpple.com")
        #expect(Hosts.display(dotted) == dotted)
        // A punycode subdomain on a real domain is shown as punycode too.
        let sub = Hosts.ascii("аррӏе.github.io")
        #expect(Hosts.display(sub) == sub)
    }

    @Test func scriptsThatCantPassForLatinShowAsThemselves() throws {
        #expect(Hosts.display(Hosts.ascii("münchen.de")) == "münchen.de")
        #expect(Hosts.display(Hosts.ascii("例え.jp")) == "例え.jp")
        #expect(Hosts.display(Hosts.ascii("한국.kr")) == "한국.kr")
        #expect(Hosts.display(Hosts.ascii("bücher.example")) == "bücher.example")
        let japanese = try #require(AtRest.make(URL(string: "https://www." + Hosts.ascii("例え.jp") + "/")!))
        #expect(japanese.text == "例え.jp")
        // Arabic beside Latin is a mix that is shown as punycode.
        let mixed = Hosts.ascii("aمثال.example")
        #expect(Hosts.display(mixed) == mixed)
    }

    @Test func latinLookalikesAndCJKStrokesShowPunycode() throws {
        for name in ["gıthub.com", "þaypal.com", "ĸoogle.com", "app丨e.com", "goo一gle.com", "faceノbook.com", "appᅵe.com"] {
            let ascii = Hosts.ascii(name)
            #expect(Hosts.display(ascii) == ascii, "\(name)")
        }
        #expect(Hosts.display(Hosts.ascii("一番.jp")) == "一番.jp", "a stroke among ideographs alone is a word")
    }

    @Test func loopbackOnlyAsAnAddress() throws {
        #expect(rest("http://127.0.0.1.example.com/")?.kind == .notSecure)
        #expect(rest("http://127.0.0.1/")?.kind == .secure)
    }

    @Test func anXnLabelThatDecodesToAsciiStaysAsWritten() throws {
        #expect(Hosts.display("xn--google-.com") == "xn--google-.com")
        #expect(Hosts.display("xn--!!!.com") == "xn--!!!.com")
    }

    @Test func punycodeRoundTrips() throws {
        // RFC 3492's own sample strings and a few more.
        for (text, code) in [("münchen", "mnchen-3ya"), ("bücher", "bcher-kva"), ("例え", "r8jz45g"),
                             ("аррӏе", "80ak6aa92e"), ("한국", "3e0b707e")] {
            #expect(Punycode.encode(text) == code, "\(text)")
            #expect(Punycode.decode(code) == text, "\(code)")
        }
        #expect(Punycode.decode("ü") == nil)
        #expect(Punycode.decode("99999999999999999") == nil)
    }

    @Test func cachedAndSameAsMade() throws {
        let url = URL(string: "https://docs.github.com/en")!
        #expect(AtRest.of(url) == AtRest.make(url))
        #expect(AtRest.of(url) == AtRest.of(url))
    }

    /// The middle ground: with the setting off, only a warning is said.
    @Test func warningsAreSaidWithTheSettingOff() throws {
        #expect(try #require(rest("http://example.com/")).warns, "plain http")
        #expect(try #require(rest("https://xn--80ak6aa92e.com/")).warns, "a Cyrillic look-alike shown as punycode")
        #expect(try #require(rest("https://xn--80ak6aa92e.example.com/")).warns, "a look-alike subdomain")
        #expect(try !#require(rest("https://github.com/")).warns)
        #expect(try !#require(rest("http://localhost:3000/")).warns, "this Mac")
        #expect(try !#require(rest("https://xn--wgv71a119e.jp/")).warns, "日本語.jp is safe to show as itself")
        #expect(AtRest.said(URL(string: "https://github.com/"), always: false) == nil)
        #expect(AtRest.said(URL(string: "https://github.com/"), always: true) != nil)
        #expect(AtRest.said(URL(string: "http://example.com/"), always: false) != nil)
        #expect(AtRest.said(URL(string: "about:blank"), always: true) == nil)
    }
}
