import AppKit
import Testing
import WebKit
@testable import Search

@Suite(.sharedWorld)
@MainActor
final class LiveSSOTests {
    private var holding: [AnyObject] = []
    private let asked = URL(string: "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")!
    private let source = LiveSource(kind: .pullRequests, address: "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me")

    init() {
        addTeardownBlock { await self.tearDown() }
        setenv("SEARCH_PROBE", "live-sso-\(getpid())", 1)
    }

    private func tearDown() async {
        holding = []
        for folder in LiveFolders.shared.folders { LiveFolders.shared.remove(folder.id) }
    }

    private func banner() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("IntegrationFixtures/github-sso-banner.html"), encoding: .utf8)
    }

    private func scanned(_ html: String) async throws -> String {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        let loaded = Loaded()
        holding += [loaded, web]
        web.navigationDelegate = loaded
        web.loadHTMLString(html, baseURL: asked)
        try await loaded.wait()
        let pattern = try #require(source.pattern).replacingOccurrences(of: #"\"#, with: #"\\"#)
        let json = try await web.evaluateJavaScript("\(LiveReader.script)('\(pattern)', 90)", contentWorld: .defaultClient) as? String
        return try #require(json)
    }

    private let row = """
    <ul><li class="js-issue-row"><a href="/sam/notes/pull/7">Keep notes in sync with the cloud</a>
    <span>#7 opened today by <a data-testid="author-filter-link" href="/sam">sam</a></span></li></ul>
    """

    private func pull(_ number: Int, _ title: String) -> LiveItem {
        LiveItem(key: "https://github.com/octocorp/ios/pull/\(number)", title: title)
    }

    @Test func theBannerOnAnEmptyListAsksForSingleSignOnWithItsLink() async throws {
        let json = try await scanned(try banner())

        let answer = LiveReader.answer(scanned: json, asked: asked, source: source)

        let sso = LiveSSO(org: "Octo Corp", url: "https://github.com/orgs/octocorp/sso?return_to=%2Fpulls%3Fq%3Dis%253Aopen%2Bis%253Apr%2Bauthor%253A%2540me")
        #expect(answer == LiveReader.Answer.sso(sso, []))
    }

    @Test func theBannerBesideOtherRowsStillAsksAndKeepsThoseRows() async throws {
        let html = try banner().replacingOccurrences(of: "<main>", with: "<main>\(row)")
        let json = try await scanned(html)

        let answer = LiveReader.answer(scanned: json, asked: asked, source: source)

        guard case .sso(let sso, let items) = answer else { Issue.record("not single sign-on: \(String(describing: answer))"); return }
        #expect(sso.org == "Octo Corp")
        #expect(items.map(\.key) == ["https://github.com/sam/notes/pull/7"])
    }

    @Test func anEmptySignedInListWithNoBannerIsEmpty() async throws {
        let html = try banner().replacing(#/<div class="js-flash-container"[\s\S]*?</div>\s*</div>\s*</div>/#, with: "")
        let json = try await scanned(html)

        let answer = LiveReader.answer(scanned: json, asked: asked, source: source)

        #expect(!html.contains("Single sign-on"))
        #expect(answer == LiveReader.Answer.items([], nil))
    }

    @Test func anOrganisationLinkWithoutTheBannerIsNotSingleSignOn() async throws {
        let html = "<!doctype html><meta name=\"user-login\" content=\"octo-sam\"><nav><a href=\"/orgs/acme/sso\">acme</a></nav>\(row)"
        let json = try await scanned(html)

        let answer = LiveReader.answer(scanned: json, asked: asked, source: source)

        guard case .items(let items, _) = answer else { Issue.record("not items: \(String(describing: answer))"); return }
        #expect(items.count == 1)
    }

    @Test func everyProblemKeepsTheLastItemsAndNotesItAbove() {
        let kept = [pull(1, "Audio: model"), pull(2, "Audio: recorder")]
        let sso = LiveSSO(org: "Octo Corp", url: "https://github.com/orgs/octocorp/sso")
        let answers: [(LiveReader.Answer, LiveFolder.Note)] = [
            (.sso(sso, []), .sso(sso)), (.signIn, .signIn), (.failed, .failed),
        ]
        let sources: [LiveSource] = [source, .linear(.assigned), .gitHubNotifications, .subscriptions]

        for source in sources {
            for (answer, note) in answers {
                let made = LiveFolders.shared.add(name: "Kept", source: source, space: UUID())
                LiveFolders.shared.apply(.items(kept, nil), to: made.id)
                LiveFolders.shared.apply(answer, to: made.id)
                let folder = LiveFolders.shared.folder(made.id)

                #expect(folder?.items.map(\.key) == kept.map(\.key), "\(source.kind) \(answer)")
                #expect(folder?.note == note, "\(source.kind) \(answer)")
                LiveFolders.shared.remove(made.id)
            }
        }
    }

    @Test func singleSignOnBesideFreshRowsKeepsTheHiddenOnes() {
        let made = LiveFolders.shared.add(name: "PRs", source: source, space: UUID())
        LiveFolders.shared.apply(.items([pull(1, "Audio: model"), pull(2, "Audio: recorder")], nil), to: made.id)
        let sso = LiveSSO(org: "Octo Corp", url: "https://github.com/orgs/octocorp/sso")

        LiveFolders.shared.apply(.sso(sso, [LiveItem(key: "https://github.com/sam/notes/pull/7", title: "Notes")]), to: made.id)

        let folder = LiveFolders.shared.folder(made.id)
        #expect(folder?.items.map(\.title) == ["Notes", "Audio: model", "Audio: recorder"])
        #expect(folder?.state == .signIn)
        #expect(folder?.signInPage == URL(string: sso.url))
        #expect(folder?.signInWords == "Single sign-on for Octo Corp")
    }

    @Test func aGoodReadClearsTheNoteAndRefreshes() {
        let made = LiveFolders.shared.add(name: "PRs", source: source, space: UUID())
        LiveFolders.shared.apply(.items([pull(1, "Audio: model")], nil), to: made.id)
        LiveFolders.shared.apply(.sso(LiveSSO(org: "Octo Corp", url: "https://github.com/orgs/octocorp/sso"), []), to: made.id)

        LiveFolders.shared.apply(.items([pull(1, "Audio: model"), pull(3, "Audio: upload")], nil), to: made.id)

        let folder = LiveFolders.shared.folder(made.id)
        #expect(folder?.note == nil)
        #expect(folder?.sso == nil)
        #expect(folder?.items.map(\.title) == ["Audio: model", "Audio: upload"])
        #expect(folder?.signInPage == source.signInPage())
    }

    @Test func onlyAGoodEmptyReadSaysNoPullRequests() {
        let made = LiveFolders.shared.add(name: "PRs", source: source, space: UUID())
        LiveFolders.shared.apply(.items([pull(1, "Audio: model")], nil), to: made.id)

        LiveFolders.shared.apply(.sso(LiveSSO(org: "Octo Corp", url: "https://github.com/orgs/octocorp/sso"), []), to: made.id)
        let hidden = LiveFolders.shared.folder(made.id)?.note
        LiveFolders.shared.apply(.items([], nil), to: made.id)
        let empty = LiveFolders.shared.folder(made.id)?.note

        #expect(hidden != .empty)
        #expect(empty == .empty)
    }

    @Test func aSavedFolderFromBeforeSingleSignOnStillLoads() throws {
        let old = #"{"id":"6B1F1E4C-8B8A-4F4B-9C55-6C0D7C0B9A11","space":"0F4C7A39-3C1E-4C0B-8E1A-9B2B2C4D5E6F","name":"PRs","source":{"kind":"pullRequests","address":"https://github.com/pulls"},"paused":false,"state":"signIn","items":[],"hidden":[]}"#

        let folder = try JSONDecoder().decode(LiveFolder.self, from: Data(old.utf8))

        #expect(folder.sso == nil)
        #expect(folder.note == .signIn)
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func wait() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}
