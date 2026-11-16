import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class IntegrationPreviewTests {
    private let github = "https://github.com/acme/rocket/pull/412"
    private let linear = "https://linear.app/acme/issue/ENG-231/a-title"
    private var asked: [URLRequest] = []
    private let session = LinearSessionFake()

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "integration-previews-\(getpid())", 1)
        asked = []
        IntegrationPreviews.shared.clear()
        IntegrationReader.cookies = { _ in [] }
    }

    private func tearDown() async {
        IntegrationPreviews.shared.clear()
        IntegrationReader.cookies = { await Spaces.store(for: $0).httpCookieStore.allCookies() }
    }

    private func fixture(_ name: String) throws -> Data {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("IntegrationFixtures/\(name)"))
    }

    private func service(_ name: String, status: Int = 200) throws -> Integrations {
        let data = try fixture(name)
        let service = Integrations()
        service.transport = { [weak self] request in
            guard let self else { return nil }
            asked.append(request)
            return LinearSessionFake.handles(request) ? session.answer(request) { _ in (data, status) } : (data, status)
        }
        return service
    }

    @Test func onlyRecognizedHTTPSServiceLinksAreRead() throws {
        let ref = try #require(IntegrationLink(github + "/files?diff=split#here"))

        #expect(ref.url.absoluteString == github)
        #expect(ref.identity == IntegrationLink("https://www.github.com/Acme/Rocket/issues/412")?.identity)
        #expect(IntegrationLink(linear)?.number == "ENG-231")
        for address in ["http://github.com/acme/rocket/pull/412", "https://github.com.evil.test/acme/rocket/pull/412",
                        "https://github.com:8443/acme/rocket/pull/412", "https://person:@github.com/acme/rocket/pull/412",
                        "https://linear.app/acme/issue/ENG-0", "https://github.com/acme/rocket/pulls", "https://github.com/acme/rocket/issues/0"] {
            #expect(IntegrationLink(address) == nil, "\(address)")
        }
    }

    @Test func linearKeepsWorkflowStateAndCreatorAndRejectsAnotherWorkspace() throws {
        let data = try fixture("linear-preview.json")

        let link = try #require(IntegrationLink(linear))
        let preview = try #require(IntegrationPreview.parse(data, for: link))

        #expect(preview.state == "In Progress")
        #expect(preview.author == "Sam Octo")
        #expect(preview.reference == "ENG-231")
        #expect(preview.checks == nil)
        #expect(IntegrationPreview.parse(data, for: try #require(IntegrationLink("https://linear.app/other/issue/ENG-231"))) == nil)
    }

    @Test func sessionHTMLUsesOnlyStateItFinds() throws {
        let html = String(decoding: try fixture("github-preview.html"), as: UTF8.self)
        let ref = try #require(IntegrationLink(github))

        let preview = try #require(IntegrationPreview.page(html, for: ref))
        let thin = try #require(IntegrationPreview.page("<bdi class='js-issue-title'>Just the title</bdi><p>Open Approved FAILURE</p>", for: ref))

        #expect(preview.title == "Keep the upload & retry alive")
        #expect(preview.state == "Open")
        #expect(preview.checks == .failing)
        #expect(preview.review == "Changes requested")
        #expect(preview.author == "dana")
        #expect(preview.updated != nil)
        #expect(thin.state == nil)
        #expect(thin.checks == nil)
        #expect(thin.review == nil)
        #expect(IntegrationPreview.page("<bdi class='markdown-title'>Title</bdi><relative-time datetime='2026-11-04T03:00:00Z'>created</relative-time>", for: ref)?.updated == nil)
        #expect(IntegrationPreview.page("<title>Sign in to GitHub</title><input type=password>", for: ref) == nil)
    }

    @Test func aPreviewIsKeptPerSpaceForOneMinute() async throws {
        let integration = try service("github-preview.html")
        IntegrationReader.cookies = { _ in
            [HTTPCookie(properties: [.domain: ".github.com", .path: "/", .name: "fixture", .value: "github"])!]
        }
        let previews = IntegrationPreviews()
        let space = UUID()
        let now = Date()

        let first = await previews.read(github, space: space, with: integration, now: now)
        let second = await previews.read(github + "#discussion", space: space, with: integration, now: now.addingTimeInterval(59))

        #expect(first != nil)
        #expect(first == second)
        #expect(asked.count == 1)
        #expect(asked[0].url?.host() == "github.com")
        #expect(asked[0].value(forHTTPHeaderField: "Authorization") == nil)
        let expired = await previews.read(github, space: space, with: integration, now: now.addingTimeInterval(61))
        #expect(expired != nil)
        let other = await previews.read(github, space: UUID(), with: integration, now: now.addingTimeInterval(61))
        #expect(other != nil)
        #expect(asked.count == 3)
    }

    @Test func signedOutAndUnrecognizedLinksMakeNoRequests() async throws {
        let integration = try service("github-preview.html")
        let previews = IntegrationPreviews()

        let signedOut = await previews.read(github, space: UUID(), with: integration)
        let unrelated = await previews.read("https://example.com/acme/rocket/pull/412", space: UUID(), with: integration)

        #expect(signedOut == nil)
        #expect(unrelated == nil)
        #expect(asked.isEmpty)
    }

    @Test func sessionReadSendsOnlyMatchingCookiesAndNeverAnAuthorizationHeader() async throws {
        let integration = try service("github-preview.html")
        IntegrationReader.cookies = { _ in
            [HTTPCookie(properties: [.domain: ".github.com", .path: "/", .name: "fixture", .value: "github"])!,
             HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "other", .value: "linear"])!]
        }

        let preview = await IntegrationPreviews().read(github, space: UUID(), with: integration)

        #expect(preview?.state == "Open")
        #expect(asked.count == 1)
        #expect(asked.first?.url?.host() == "github.com")
        #expect(asked.first?.value(forHTTPHeaderField: "Cookie") == "fixture=github")
        #expect(asked.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func linearSessionSaysWhoIsAskingForTheLinkWorkspace() async throws {
        let integration = try service("linear-preview.json")
        IntegrationReader.cookies = { _ in
            [HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "fixture", .value: "linear"])!]
        }

        let preview = await IntegrationPreviews().read(linear, space: UUID(), with: integration)

        #expect(preview?.state == "In Progress")
        #expect(asked.count == 2)
        #expect(asked.allSatisfy { $0.url?.host() == "client-api.linear.app" })
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "Origin") == "https://linear.app" })
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "fixture=linear" })
        #expect(asked.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        #expect(session.lookups.count == 1)
        #expect(session.real.first?.value(forHTTPHeaderField: "user") == "u-acme")
        #expect(session.real.first?.value(forHTTPHeaderField: "organization") == "o-acme")
    }

    @Test func linearSessionWithNobodyBehindItShowsNoPreview() async throws {
        let integration = try service("linear-preview.json")
        IntegrationReader.cookies = { _ in
            [HTTPCookie(properties: [.domain: ".linear.app", .path: "/", .name: "fixture", .value: "linear"])!]
        }
        session.users = []

        let preview = await IntegrationPreviews().read(linear, space: UUID(), with: integration)

        #expect(preview == nil)
        #expect(session.lookups.count == 1)
        #expect(session.real.isEmpty)
    }

    @Test func concurrentHoversShareOneRequest() async throws {
        let data = try fixture("github-preview.html")
        let integration = Integrations()
        IntegrationReader.cookies = { _ in
            [HTTPCookie(properties: [.domain: ".github.com", .path: "/", .name: "fixture", .value: "github"])!]
        }
        var count = 0
        integration.transport = { _ in
            count += 1
            try? await Task.sleep(for: .milliseconds(30))
            return (data, 200)
        }
        let previews = IntegrationPreviews()
        let space = UUID()

        let first = Task { await previews.read(github, space: space, with: integration) }
        let second = Task { await previews.read(github, space: space, with: integration) }
        let answer = await first.value
        let duplicate = await second.value

        #expect(answer != nil)
        #expect(answer == duplicate)
        #expect(count == 1)
    }

    @Test func clearingWhileARequestIsPendingDiscardsItsAnswer() async throws {
        let data = try fixture("github-preview.html")
        let integration = Integrations()
        IntegrationReader.cookies = { _ in
            [HTTPCookie(properties: [.domain: ".github.com", .path: "/", .name: "fixture", .value: "github"])!]
        }
        integration.transport = { _ in
            try? await Task.sleep(for: .milliseconds(100))
            return (data, 200)
        }
        let previews = IntegrationPreviews()
        let space = UUID()
        let first = Task { await previews.read(github, space: space, with: integration) }
        await Task.yield()
        let second = Task { await previews.read(github, space: space, with: integration) }
        try await Task.sleep(for: .milliseconds(10))

        previews.clear()

        let answer = await first.value
        let duplicate = await second.value
        #expect(answer == nil)
        #expect(duplicate == nil)
    }

    @Test func leavingOrPrivateBrowsingCannotPublishALatePreview() async throws {
        let integration = Integrations.shared
        let transport = integration.transport
        let dwell = HoverCards.dwell
        defer {
            integration.transport = transport
            HoverCards.dwell = dwell
        }
        HoverCards.dwell = 0.001
        let data = try fixture("github-preview.html")
        var count = 0
        IntegrationReader.cookies = { _ in
            [HTTPCookie(properties: [.domain: ".github.com", .path: "/", .name: "fixture", .value: "github"])!]
        }
        integration.transport = { _ in
            count += 1
            try? await Task.sleep(for: .milliseconds(70))
            return (data, 200)
        }
        let status = LinkStatus()
        let space = UUID()
        status.show(github, over: nil, space: space)
        try await Task.sleep(for: .milliseconds(15))

        status.dismiss()
        try await Task.sleep(for: .milliseconds(90))

        #expect(status.preview == nil)
        #expect(status.destination == nil)
        #expect(count == 1)
        status.show(github, over: nil, space: space, privateTab: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(status.preview == nil)
        #expect(count == 1)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_FILM"] != nil, "SEARCH_FILM names the preview render folder"))
    func rendersPreviewDetailsInBothAppearances() async throws {
        let folder = try #require(ProcessInfo.processInfo.environment["SEARCH_FILM"])
        let link = try #require(IntegrationLink(github))
        let preview = try #require(IntegrationPreview.page(String(decoding: try fixture("github-preview.html"), as: UTF8.self), for: link))
        _ = NSApplication.shared
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)

        for (width, label) in [(CGFloat(252), "sidebar"), (CGFloat(320), "page")] {
            for dark in [false, true] {
                let host = KitFlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 148))
                host.wantsLayer = true
                host.layer?.backgroundColor = (dark ? NSColor.black : NSColor.white).cgColor
                let details = IntegrationPreviewDetailsView(preview: preview)
                details.frame = NSRect(x: 12, y: 12, width: width - 24, height: details.height(for: width - 24))
                host.addSubview(details)
                let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: 148), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("integration-preview-\(label)-\(dark ? "dark" : "light").png"))
                #expect(host.frame.size == CGSize(width: width, height: 148))
                #expect(details.frame.height > 0 && details.frame.maxY <= 148)
                window.contentView = nil
                window.close()
            }
        }
    }

}
