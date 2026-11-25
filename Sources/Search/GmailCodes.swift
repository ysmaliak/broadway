import Foundation
import WebKit

enum GmailAnswer: Equatable {
    case xml(String)
    case signedOut
    case failed
}

protocol GmailFeed: AnyObject {
    @MainActor func fetch() async -> GmailAnswer
}

enum GmailAccount {
    private static let path = try? NSRegularExpression(pattern: #"^/mail/u/(\d{1,2})(?:/|$)"#)

    static func index(among pages: [URL?]) -> Int {
        for case let page? in pages where page.host()?.lowercased() == "mail.google.com" {
            let text = page.path(percentEncoded: true)
            guard let match = path?.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
                  let index = Int((text as NSString).substring(with: match.range(at: 1)))
            else { continue }
            return index
        }
        return 0
    }

    static func feed(account: Int) -> URL? {
        URL(string: "https://mail.google.com/mail/u/\(account)/feed/atom")
    }

    static func signedIn(_ store: WKWebsiteDataStore) async -> Bool {
        let names: Set<String> = ["SID", "__Secure-1PSID", "__Secure-3PSID"]
        return await store.httpCookieStore.allCookies().contains { cookie in
            cookie.domain.hasSuffix("google.com") && names.contains(cookie.name)
        }
    }
}

enum GmailAtom {
    private final class Reader: NSObject, XMLParserDelegate {
        var entries: [(title: String, summary: String, name: String, stamp: String, email: String)] = []
        private var open: (title: String, summary: String, name: String, stamp: String, email: String)?
        private var path: [String] = []
        private var words = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            path.append(name)
            words = ""
            if name == "entry" { open = ("", "", "", "", "") }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { words += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            defer { path.removeLast() }
            if name == "entry" {
                if let open { entries.append(open) }
                open = nil
                return
            }
            guard open != nil else { return }
            switch (path.dropLast().last, name) {
            case ("entry", "title"): open?.title = words
            case ("entry", "summary"): open?.summary = words
            case ("entry", "modified"), ("entry", "issued"), ("entry", "updated"): open?.stamp = words
            case ("author", "name"): open?.name = words
            case ("author", "email"): open?.email = words
            default: break
            }
        }
    }

    static func codes(in xml: String, since: Date) -> [OneTimeCode] {
        guard let data = xml.data(using: .utf8) else { return [] }
        let parser = XMLParser(data: data)
        let reader = Reader()
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        parser.parse()
        let stamps = ISO8601DateFormatter()
        return reader.entries.compactMap { entry in
            guard let at = stamps.date(from: entry.stamp), at > since,
                  let code = CodeFinder.code(in: "\(entry.title). \(entry.summary)")
            else { return nil }
            return OneTimeCode(code: code, sender: entry.name, at: at, address: entry.email)
        }
    }
}

final class GmailCodes: CodeSource {
    private let feed: GmailFeed
    private let signedIn: @MainActor () async -> Bool
    private let told: @MainActor () -> Void
    private var said = false
    private var finished = false
    private var calls = 0

    init(feed: GmailFeed, signedIn: @escaping @MainActor () async -> Bool, told: @escaping @MainActor () -> Void) {
        self.feed = feed
        self.signedIn = signedIn
        self.told = told
    }

    @MainActor
    func read(since: Date) async -> CodeRead {
        calls += 1
        guard !finished, calls % 2 == 1 else { return .quiet }
        if !said {
            guard await signedIn() else {
                finished = true
                return .quiet
            }
            said = true
            told()
        }
        switch await feed.fetch() {
        case .xml(let xml):
            let codes = GmailAtom.codes(in: xml, since: since)
            return codes.isEmpty ? .nothing : .found(codes)
        case .signedOut:
            finished = true
            return .quiet
        case .failed:
            return .quiet
        }
    }
}

@MainActor
final class WebGmailFeed: NSObject, GmailFeed, WKNavigationDelegate {
    private let address: URL
    private let store: WKWebsiteDataStore
    private var web: WKWebView?
    private var waiting: CheckedContinuation<GmailAnswer, Never>?
    private var round = 0

    init(address: URL, store: WKWebsiteDataStore) {
        self.address = address
        self.store = store
    }

    deinit {
        MainActor.assumeIsolated { web?.navigationDelegate = nil }
    }

    func fetch() async -> GmailAnswer {
        finish(.failed)
        let view = web ?? makeView()
        web = view
        round += 1
        let now = round
        return await withCheckedContinuation { continuation in
            waiting = continuation
            view.load(URLRequest(url: address, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                if self?.round == now { self?.finish(.failed) }
            }
        }
    }

    private func makeView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.applicationNameForUserAgent = Web.userAgentName
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        return view
    }

    private func finish(_ answer: GmailAnswer) {
        guard let up = waiting else { return }
        waiting = nil
        up.resume(returning: answer)
    }

    private func isFeed(_ url: URL?) -> Bool {
        url?.host() == address.host() && url?.port == address.port && url?.path() == address.path()
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        if isFeed(action.request.url) { return .allow }
        finish(.signedOut)
        return .cancel
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        let status = (response.response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return .allow }
        finish(status == 401 || status == 403 ? .signedOut : .failed)
        return .cancel
    }

    func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        finish(.signedOut)
        return (.cancelAuthenticationChallenge, nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task {
            let reply = try? await webView.evaluateJavaScript("new XMLSerializer().serializeToString(document)") as? String
            finish(reply.map(GmailAnswer.xml) ?? .failed)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failed) }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failed) }
}
