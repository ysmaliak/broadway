import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct LoopbackTests {
    @Test func thisMacIsLocalhostItsSubdomainsAndTheLoopbackAddresses() {
        for host in ["localhost", "LOCALHOST", "localhost.", "app.localhost", "www.localhost", "127.0.0.1", "127.0.0.2",
                     "127.255.255.254", "::1", "[::1]"] {
            #expect(Hosts.isLoopback(host), "\(host)")
        }
    }

    @Test func aNameThatOnlyLooksLikeThisMacIsAWebsite() {
        for host in ["127.0.0.1.example.com", "localhost.example.com", "notlocalhost", "0.0.0.0", "10.0.0.1",
                     "192.0.2.1", "128.0.0.1", "example.com", ""] {
            #expect(!Hosts.isLoopback(host), "\(host)")
        }
    }

    @Test func withoutSubdomainsOnlyTheNameLocalhostAndTheAddressesAreThisMac() {
        #expect(Hosts.isLoopback("localhost", subdomains: false))
        #expect(Hosts.isLoopback("127.0.0.2", subdomains: false))
        #expect(Hosts.isLoopback("[::1]", subdomains: false))
        #expect(!Hosts.isLoopback("app.localhost", subdomains: false))
    }

    @Test func fileQuestionsCountThisMacAndTheLocalNetworkAsLocal() {
        for host in ["localhost", "app.localhost", "127.0.0.2", "[::1]", "::1", "printer.local", "192.168.1.2", "0.0.0.0"] {
            #expect(SiteFiles.local(host), "\(host)")
        }
        #expect(!SiteFiles.local("example.com"))
        #expect(!SiteFiles.local("127.0.0.1.example.com"))
    }

    @Test func theLocalNetworkGuardSortsNamesAsBefore() {
        #expect(LocalNetwork.reach("localhost") == .loopback)
        #expect(LocalNetwork.reach("app.localhost") == .loopback)
        #expect(LocalNetwork.reach("localhost.") == .loopback)
        #expect(LocalNetwork.reach("127.0.0.2") == .loopback)
        #expect(LocalNetwork.reach("[::1]") == .loopback)
        #expect(LocalNetwork.reach("0.0.0.0") == .loopback)
        #expect(LocalNetwork.reach("127.0.0.0001") == .loopback)
        #expect(LocalNetwork.reach("printer.local") == .lan)
        #expect(LocalNetwork.reach("127.0.0.1.example.com") == .internet)
        #expect(LocalNetwork.reach("example.com") == .internet)
    }

    @Test func anAgentSignInKeptWithNoPortFitsAnyPortOnEveryLoopbackAddress() {
        let kept = Kept(host: "127.0.0.2", user: "sam", used: nil, clear: true, port: nil)
        #expect(AgentSignInMatch.fits(kept, page: URL(string: "http://127.0.0.2:5173/login")!))
        let site = Kept(host: "127.0.0.1.example.com", user: "sam", used: nil, clear: true, port: nil)
        #expect(!AgentSignInMatch.fits(site, page: URL(string: "http://127.0.0.1.example.com:5173/login")!))
    }
}
