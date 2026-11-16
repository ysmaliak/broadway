import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct LocalNetworkTests {
    private let table: [(host: String, reach: LocalNetwork.Reach)] = [
        ("localhost", .loopback), ("app.localhost", .loopback), ("localhost.", .loopback),
        ("127.0.0.1", .loopback), ("127.1.2.3", .loopback), ("0.0.0.0", .loopback),
        ("[::1]", .loopback), ("[::]", .loopback), ("[::ffff:7f00:1]", .loopback), ("[::ffff:0:0]", .loopback),
        ("10.0.0.1", .lan), ("10.255.255.255", .lan),
        ("172.16.0.1", .lan), ("172.24.9.9", .lan), ("172.31.255.1", .lan),
        ("192.168.1.20", .lan), ("169.254.10.1", .lan),
        ("100.64.0.1", .lan), ("100.100.100.100", .lan), ("100.127.255.255", .lan),
        ("[fd12:3456::1]", .lan), ("[fc00::1]", .lan), ("[fe80::1]", .lan), ("[febf::1]", .lan),
        ("[::ffff:c0a8:114]", .lan), ("[::ffff:a00:1]", .lan), ("[::ffff:ac10:1]", .lan),
        ("[::ffff:a9fe:1]", .lan), ("[::ffff:6440:1]", .lan),
        ("printer.local", .lan), ("myapp.test", .lan), ("db.internal", .lan), ("router.home.arpa", .lan),
        ("nas", .lan), ("devbox", .lan),
        ("example.com", .internet), ("8.8.8.8", .internet), ("172.15.0.1", .internet), ("172.32.0.1", .internet),
        ("192.169.0.1", .internet), ("100.63.0.1", .internet), ("100.128.0.1", .internet),
        ("11.0.0.1", .internet), ("128.0.0.1", .internet), ("[2001:db8::1]", .internet), ("[fec0::1]", .internet),
        ("[::ffff:808:808]", .internet), ("localhost.example.com", .internet), ("local.example.com", .internet),
        ("example.localdomain.com", .internet), ("test.com", .internet), ("127.example.com", .internet),
        ("10.0.0.1.nip.io", .internet), ("mylocal", .lan),
    ]

    @Test @MainActor func classifierSortsHosts() {
        let hosts = table

        let found = hosts.map { LocalNetwork.reach($0.host) }

        for (row, reach) in zip(hosts, found) {
            #expect(reach == row.reach, "\(row.host)")
        }
    }

    @Test @MainActor func filtersAgreeWithTheClassifier() throws {
        let filters = try LocalNetwork.filters.map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let urls = table.flatMap { row in
            ["http://\(row.host)/", "https://\(row.host):8443/x?y=1", "ws://\(row.host):3000/socket", "http://user:pw@\(row.host)/"]
                .map { ($0, row.reach != .internet) }
        }

        let matched = urls.map { url, _ in
            filters.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }

        for ((url, local), hit) in zip(urls, matched) {
            #expect(hit == local, "\(url)")
        }
    }

    @Test @MainActor func filtersLeaveLookalikesAlone() throws {
        let filters = try LocalNetwork.filters.map { try NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        let urls = [
            "https://example.com/?next=http://localhost:3000/", "https://example.com/127.0.0.1/",
            "https://user:123@example.com/", "https://localhost.example.com/", "https://a.local.example.com/",
            "https://evil.com/#http://192.168.1.1/", "https://example.com:8080/localhost/",
        ]

        let matched = urls.filter { url in
            filters.contains { $0.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil }
        }

        #expect(matched == [])
    }

    @Test @MainActor func developerModeLocalPagesAreLocalHere() {
        let pages = ["http://localhost:3000/", "http://127.0.0.1:8080/", "https://shop.test/", "http://app.localhost:5173/x"]

        let local = pages.map { LocalServer.isLocal(URL(string: $0)) && LocalNetwork.isLocal(URL(string: $0)) }
        let publicPages = pages.filter { LocalNetwork.isPublicPage(URL(string: $0)) }

        #expect(local == [true, true, true, true])
        #expect(publicPages == [])
    }

    @MainActor
    @Test func webKitCompilesTheList() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-local-network-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try #require(WKContentRuleListStore(url: folder))
        let json = try #require(LocalNetwork.encodedRules)

        let list = try await store.compileContentRuleList(forIdentifier: LocalNetwork.identifier, encodedContentRuleList: json)

        #expect(list?.identifier == LocalNetwork.identifier)
        #expect(LocalNetwork.rules.count == LocalNetwork.hostPatterns.count)
    }

    @Test @MainActor func onlyPublicPagesAreGuarded() {
        let page = URL(string: "https://example.com/a")
        let local = URL(string: "http://localhost:3000/")
        let file = URL(string: "file:///tmp/a.html")

        let guarded = LocalNetwork.guards(page: page, on: true, answer: nil, developer: false)
        let refused = LocalNetwork.guards(page: page, on: true, answer: false, developer: false)
        let allowed = LocalNetwork.guards(page: page, on: true, answer: true, developer: false)
        let off = LocalNetwork.guards(page: page, on: false, answer: nil, developer: false)
        let developer = LocalNetwork.guards(page: page, on: true, answer: nil, developer: true)
        let localPage = LocalNetwork.guards(page: local, on: true, answer: nil, developer: false)
        let filePage = LocalNetwork.guards(page: file, on: true, answer: nil, developer: false)

        #expect(guarded)
        #expect(refused)
        #expect(!allowed)
        #expect(!off)
        #expect(!developer)
        #expect(!localPage)
        #expect(!filePage)
    }

    @Test @MainActor func scriptNavigationToLocalAsks() {
        let page = URL(string: "https://example.com")
        let target = URL(string: "http://localhost:8085/callback")
        func step(from source: URL? = page, to url: URL? = target, user: Bool = false, redirect: Bool = false,
                  type: WKNavigationType = .other, on: Bool = true, answer: Bool? = nil, developer: Bool = false) -> LocalNetwork.Step {
            LocalNetwork.step(source: source, target: url, userInitiated: user, redirect: redirect, type: type,
                              on: on, answer: answer, developer: developer)
        }

        let script = step()
        let refused = step(answer: false)
        let allowed = step(answer: true)
        let clicked = step(user: true, type: .linkActivated)
        let redirected = step(redirect: true)
        let back = step(type: .backForward)
        let reload = step(type: .reload)
        let typed = step(from: nil)
        let off = step(on: false)
        let developer = step(developer: true)
        let fromLocal = step(from: URL(string: "http://localhost:3000"))
        let toPublic = step(to: URL(string: "https://example.org/"))

        #expect(script == .ask)
        #expect(refused == .stop)
        #expect(allowed == .go)
        #expect([clicked, redirected, back, reload, typed, off, developer, fromLocal, toPublic] == Array(repeating: .go, count: 9))
    }

    @Test @MainActor func originsMatchTheOtherPermissions() {
        let urls = ["https://Example.com/a?b", "http://example.com:80/", "https://example.com:8443/", "http://[::1]:3000/"]

        let origins = urls.map { LocalNetwork.origin(URL(string: $0)) }
        let key = LocalNetwork.key("https://example.com")

        #expect(origins == ["https://example.com", "http://example.com", "https://example.com:8443", "http://[::1]:3000"])
        #expect(key == "capture.https://example.com|localnetwork")
    }

    @Test @MainActor func theQuestionNamesWhereItGoes() {
        let mac = URL(string: "http://localhost:3000/api")!
        let lan = URL(string: "http://192.168.1.20/")!

        let shown = [LocalNetwork.shown(mac), LocalNetwork.shown(lan)]

        #expect(shown == ["localhost:3000", "192.168.1.20"])
    }
}
