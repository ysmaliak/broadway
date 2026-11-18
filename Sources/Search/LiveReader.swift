import Foundation
import WebKit

final class FeedParser: NSObject, XMLParserDelegate {
    struct Entry: Equatable {
        var title = ""
        var link = ""
        var author = ""
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""
    private var sawFeed = false

    enum Outcome: Equatable {
        case feed([Entry])
        case broken
        case notFeed
    }

    static func read(_ data: Data) -> Outcome {
        let reader = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        let whole = parser.parse()
        guard reader.sawFeed else { return .notFeed }
        return whole ? .feed(reader.entries) : .broken
    }

    static func parse(_ data: Data) -> [Entry]? {
        guard case .feed(let entries) = read(data) else { return nil }
        return entries
    }

    private func bare(_ name: String) -> String {
        (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let element = bare(name)
        if element == "rss" || element == "feed" || element == "rdf" { sawFeed = true }
        if element == "item" || element == "entry" { current = Entry() }
        text = ""
        guard element == "link", current != nil, let href = attributes["href"] else { return }
        let relation = attributes["rel"] ?? "alternate"
        if relation == "alternate" || current?.link.isEmpty == true { current?.link = href }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) {
        text += String(data: block, encoding: .utf8) ?? ""
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let element = bare(name)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch element {
        case "item", "entry":
            if let current, !current.link.isEmpty { entries.append(current) }
            current = nil
        case "title":
            if current?.title.isEmpty == true { current?.title = value }
        case "link":
            if current?.link.isEmpty == true, !value.isEmpty { current?.link = value }
        case "guid":
            if current?.link.isEmpty == true, value.hasPrefix("http") { current?.link = value }
        case "creator", "name", "author":
            if current?.author.isEmpty == true, !value.isEmpty { current?.author = value }
        default:
            break
        }
        text = ""
    }

    static func discover(_ html: String, base: URL) -> URL? {
        guard let tag = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: .caseInsensitive) else { return nil }
        let whole = NSRange(html.startIndex..., in: html)
        for match in tag.matches(in: html, range: whole) {
            guard let range = Range(match.range, in: html) else { continue }
            let link = String(html[range])
            let lower = link.lowercased()
            guard lower.contains("alternate"),
                  lower.contains("application/rss+xml") || lower.contains("application/atom+xml") else { continue }
            guard let href = attribute("href", in: link) else { continue }
            return URL(string: href, relativeTo: base)?.absoluteURL
        }
        return nil
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*[\"']([^\"']+)[\"']", options: .caseInsensitive),
              let match = pattern.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag) else { return nil }
        return String(tag[range]).replacingOccurrences(of: "&amp;", with: "&")
    }
}

enum LiveLabels {
    static func pullRequest(row: String, draft: Bool = false, merged: Bool = false, closed: Bool = false) -> String? {
        let text = row.lowercased()
        if merged { return PullState.merged }
        if closed { return PullState.closed }
        if text.contains("merge conflict") || text.contains("conflicting") { return PullState.conflict }
        if text.contains("changes requested") { return PullState.changes }
        if draft || text.contains("draft") { return PullState.draft }
        if text.contains("approved") { return PullState.approved }
        return nil
    }

    static func needsSignIn(asked: URL, landed: URL?, password: Bool, found: Int, status: Int? = nil, user: String? = nil,
                            signInLink: Bool = false, personal: Bool = false, hidesPrivate: Bool = false) -> Bool {
        if found > 0 { return false }
        if password { return true }
        if status == 401 || status == 403 { return true }
        if let user, !user.isEmpty { return false }
        if user == "", personal || status == 404 { return true }
        if status == 404, personal || hidesPrivate { return true }
        if personal, signInLink { return true }
        guard let landed else { return false }
        let path = landed.path().lowercased()
        let words = ["login", "signin", "sign_in", "sign-in", "session", "oauth", "accounts"]
        return landed.host() != asked.host() || words.contains { path.contains($0) }
    }

    static func broken(status: Int?, found: Int) -> Bool {
        guard found == 0, let status else { return false }
        return status >= 400
    }
}

final class LiveRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        var next = request
        if request.url?.host() != task.originalRequest?.url?.host() || request.url?.scheme != task.originalRequest?.url?.scheme {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return next
    }
}

@MainActor
final class LiveReader: NSObject, WKNavigationDelegate {
    enum Answer: Equatable {
        case items([LiveItem], LiveSource?)
        case signIn
        case sso(LiveSSO, [LiveItem])
        case failed
        case read(LiveRead)
        case missed(LiveMiss)
    }

    private struct Scan: Decodable {
        struct Link: Decodable {
            let url: String
            let title: String
            let row: String
            let failing: Bool
            var author: String? = nil
            var checks: String? = nil
            var said: String? = nil
            var updated: String? = nil
            var draft: Bool? = nil
            var merged: Bool? = nil
            var closed: Bool? = nil
        }

        let links: [Link]
        let password: Bool
        let href: String
        var user: String? = nil
        var signInLink: Bool? = nil
        var pending: Int? = nil
        var sso: LiveSSO? = nil
        var nothing: Bool? = nil
        var limit: Bool? = nil
        var more: Bool? = nil
    }

    static let script = #"""
    (function (pattern, cap, marker) {
      const re = pattern ? new RegExp(pattern) : null;
      const here = location.host, seen = {}, links = [], stamps = {};
      let pending = 0;
      for (const s of document.querySelectorAll('script[type="application/json"][data-target$="embeddedData"]')) {
        try {
          (function walk(v, depth) {
            if (!v || typeof v !== 'object' || depth > 14) return;
            if (Array.isArray(v)) { for (const x of v) walk(x, depth + 1); return; }
            if (typeof v.permalink === 'string' && typeof v.updatedAt === 'string') {
              try { stamps[new URL(v.permalink, location.href).pathname] = v.updatedAt; } catch (e) {}
            }
            for (const k in v) walk(v[k], depth + 1);
          })(JSON.parse(s.textContent), 0);
        } catch (e) {}
      }
      for (const a of document.querySelectorAll('a[href]')) {
        let u; try { u = new URL(a.href, location.href); } catch (e) { continue; }
        if (!/^https?:$/.test(u.protocol)) continue;
        if (re ? !re.test(u.pathname) : u.host !== here || u.pathname.length < 2) continue;
        const key = re && u.pathname !== '/watch' ? u.origin + u.pathname : u.href.split('#')[0];
        if (seen[key]) continue;
        const title = (a.getAttribute('title') || a.textContent || a.getAttribute('aria-label') || '').replace(/\s+/g, ' ').trim();
        if (!title || (!re && title.length < 16)) continue;
        seen[key] = true;
        const row = a.closest('li, tr, article, [role=row], [role=listitem], .js-issue-row, ytd-rich-item-renderer, ytd-video-renderer');
        const has = (selector) => !!(row && row.querySelector(selector));
        const said = row ? (a.innerText.trim() ? row.innerText.split(a.innerText).join(' ') : row.innerText).slice(0, 400) : '';
        if (row && row.querySelector('[data-testid^="deferred-"][data-testid$="-skeleton"]')) pending++;
        const by = row && row.querySelector('[data-testid=author-filter-link], .opened-by a, a[data-hovercard-type=user], ytd-channel-name a, [data-testid=author]');
        const stamp = row && row.querySelector('relative-time[datetime]');
        links.push({ url: key, title, row: row ? row.innerText.slice(0, 400) : '', said,
                     failing: has('.octicon-x, [aria-label*="fail" i]'),
                     author: by ? by.textContent.trim() : '',
                     updated: stamps[u.pathname] || (stamp ? stamp.getAttribute('datetime') : null),
                     draft: has('.octicon-git-pull-request-draft, svg[aria-label^="Draft" i]'),
                     merged: has('.octicon-git-merge, svg[aria-label^="Merged" i]'),
                     closed: has('.octicon-git-pull-request-closed, svg[aria-label^="Closed" i]'),
                     checks: !row ? null : has('.octicon-x, [aria-label*="fail" i]') ? 'failing'
                       : has('.octicon-dot-fill, [aria-label*="pending" i]') ? 'pending'
                       : has('.octicon-check, [aria-label*="success" i]') ? 'passing' : null });
        if (links.length >= cap) break;
      }
      let sso = null;
      for (const el of document.querySelectorAll('a[href*="/sso"], form[action*="/sso"]')) {
        let u; try { u = new URL(el.getAttribute('href') || el.getAttribute('action'), location.href); } catch (e) { continue; }
        const m = u.pathname.match(/^\/(?:orgs|enterprises)\/([^\/]+)\/sso\/?$/);
        if (!m) continue;
        let box = el, words = '';
        for (let up = 0; box && up < 6; up++, box = box.parentElement) {
          const text = (box.innerText || box.textContent || '').replace(/\s+/g, ' ').trim();
          if (text.length > 600) break;
          if (/single sign-on/i.test(text)) { words = text; if (/organi[sz]ation|enterprise/i.test(text)) break; }
        }
        if (!words) continue;
        const said = words.match(/results in the (.+?) (?:organi[sz]ation|enterprise)/i);
        let org = said ? said[1].trim() : '';
        try { org = org || decodeURIComponent(m[1]); } catch (e) { org = org || m[1]; }
        sso = { org, url: u.href };
        break;
      }
      let nothing = false;
      if (marker) {
        for (const el of document.querySelectorAll(marker.selector)) {
          const text = (el.innerText || el.textContent || '').replace(/\s+/g, ' ').trim();
          if (!marker.words || new RegExp(marker.words, 'i').test(text)) { nothing = true; break; }
        }
      }
      const limit = !links.length && /rate limit|too many requests/i.test(((document.body && document.body.innerText) || '').slice(0, 4000));
      const more = !!document.querySelector('a[rel="next"], a.next_page, a[aria-label="Next Page" i], a[aria-label="Next" i][href*="page="]');
      const login = document.querySelector('meta[name="user-login"]');
      const signInLink = !!document.querySelector('a[href*="ServiceLogin"], a[href*="/login"], a[href*="/signin"], a[href*="/sign_in"]');
      return JSON.stringify({ links, password: !!document.querySelector('input[type=password]'), href: location.href,
                              user: login ? login.getAttribute('content') || '' : null, signInLink, pending, sso, nothing, limit, more });
    })
    """#

    private var view: WKWebView?
    private var status: Int?
    private var headers: [String: String] = [:]
    private var finished: CheckedContinuation<Bool, Never>?
    private static var running: [LiveReader] = []

    static func read(_ folder: LiveFolder) async -> Answer {
        if let answer = await IntegrationReader.read(folder) { return answer }
        if let answer = await LiveDrive.read(folder) { return answer }
        guard let asked = folder.source.reading() else { return .failed }
        let store = Spaces.store(for: folder.space)
        if folder.source.kind == .feed {
            return await readFeed(asked, source: folder.source, store: store)
        }
        let url = staged(asked)
        let known = LiveFolders.shared.explained(folder)
        let answer = folder.source.pullLists != nil
            ? await readLists(folder.source, before: folder.items, known: known) { await readPage(staged($0), source: folder.source, store: store) }
            : await LiveTrust.looked(folder.items, known: known) { await readPage(url, source: folder.source, store: store) }.more(asked)
        guard folder.source.kind == .pullRequests || folder.source.kind == .repository, let items = answer.found else { return answer }
        let page = folder.source.pullLists?.first.map { staged($0.page) } ?? url
        let root = Integrations.fixture(.gitHub)
        let fetch = await branchFetch(page, store: store, staging: root)
        let also = root == nil ? nil : (folder.source.pullLists?.first?.page ?? asked).host()
        let branched = await LiveRefs.filled(items, previous: folder.items, space: folder.space, host: page.host(), also: also, limit: folder.source.cap,
                                             again: LiveFolders.shared.rereads, fetch: fetch)
        LiveFolders.shared.pagesRead()
        switch answer {
        case .read(var read):
            read.items = LiveStacks.arranged(branched)
            return .read(read)
        case .items(_, let moved):
            return .items(LiveStacks.arranged(branched), moved)
        default:
            return answer
        }
    }

    @MainActor static func staged(_ url: URL) -> URL {
        guard let root = Integrations.fixture(.gitHub), url.host()?.lowercased() == "github.com" else { return url }
        let query = url.query(percentEncoded: true).map { "?" + $0 } ?? ""
        return URL(string: root.absoluteString + "/page" + url.path(percentEncoded: true) + query) ?? url
    }

    static func branchFetch(_ page: URL, store: WKWebsiteDataStore, staging root: URL? = nil) async -> @Sendable (URL) async -> (Data, Int)? {
        let all = await store.httpCookieStore.allCookies()
        let host = page.host()
        let fields = HTTPCookie.requestHeaderFields(with: cookies(all, for: page))
        return { asked in
            var url = asked
            if let root, asked.host()?.lowercased() == "github.com",
               let moved = URL(string: root.absoluteString + "/page" + asked.path(percentEncoded: true)) {
                url = moved
            }
            guard url.host() == host else { return nil }
            var request = URLRequest(url: url, timeoutInterval: LiveRefs.budget)
            request.httpShouldHandleCookies = false
            for (field, value) in fields { request.setValue(value, forHTTPHeaderField: field) }
            let session = URLSession(configuration: .ephemeral)
            defer { session.finishTasksAndInvalidate() }
            guard let (data, response) = try? await session.data(for: request, delegate: LiveRedirects()) else { return nil }
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 200)
        }
    }

    static func readLists(_ source: LiveSource, before: [LiveItem] = [], known: Set<String> = [], pause: Duration = LiveTrust.pause,
                          page: (URL) async -> Answer) async -> Answer {
        var found: [(PullList, [LiveItem])] = []
        var missed: [PullList: LiveMiss] = [:]
        var signedOut: Set<PullList> = []
        var whole = true
        var more: String?
        var sso: LiveSSO?
        let lists = source.pullLists ?? []
        for list in lists {
            let had = before.filter { LiveTrust.on($0, list) }
            switch await LiveTrust.looked(had, known: known, pause: pause, read: { await page(list.page) }) {
            case .items(let items, _): found.append((list, items))
            case .read(let read):
                if LiveTrust.unproved(had, read) {
                    missed[list] = LiveMiss(cause: .unread)
                } else {
                    found.append((list, read.items))
                    whole = whole && read.whole
                    if read.more != nil, more == nil { more = list.page.absoluteString }
                }
            case .signIn: signedOut.insert(list)
            case .sso(let asked, let items):
                sso = sso ?? asked
                found.append((list, items))
            case .failed: missed[list] = LiveMiss()
            case .missed(let miss): missed[list] = miss
            }
            if !signedOut.isEmpty, found.isEmpty, sso == nil { return .signIn }
        }
        if let sso { return .sso(sso, PullList.merged(found, keepsState: true)) }
        if found.isEmpty {
            if !signedOut.isEmpty { return .signIn }
            return .missed(lists.lazy.compactMap { missed[$0] }.first ?? LiveMiss())
        }
        let shared = PullList.shared(found, cap: source.cap)
        if more == nil, let cut = shared.cut.first { more = cut.page.absoluteString }
        return .read(LiveRead(items: PullList.merged(shared.answers, keepsState: true), missed: missed, signedOut: signedOut, whole: whole,
                              marked: true, more: more))
    }

    private static func readFeed(_ url: URL, source: LiveSource, store: WKWebsiteDataStore) async -> Answer {
        guard let (data, status, headers) = await exchange(url, store: store) else { return .failed }
        if let miss = LiveLimit.miss(status: status, headers: headers, page: false) { return .missed(miss) }
        if status == 401 || status == 403 { return .signIn }
        if status >= 400 { return .failed }
        return await feedAnswer(data, url: url, source: source,
                                fetch: { await fetch($0, store: store).map { $0.0 } },
                                page: { await readPage(url, source: $0, store: store) })
    }

    static func feedAnswer(_ data: Data, url: URL, source: LiveSource, fetch: (URL) async -> Data?,
                           page: (LiveSource) async -> Answer) async -> Answer {
        switch FeedParser.read(data) {
        case .feed(let entries): return feedRead(entries, base: url, source: nil)
        case .broken: return .missed(LiveMiss(cause: .unread))
        case .notFeed: break
        }
        let html = String(decoding: data, as: UTF8.self)
        if let found = FeedParser.discover(html, base: url), let next = await fetch(found) {
            var moved = source
            moved.address = found.absoluteString
            switch FeedParser.read(next) {
            case .feed(let entries): return feedRead(entries, base: found, source: moved)
            case .broken: return .missed(LiveMiss(cause: .unread))
            case .notFeed: break
            }
        }
        var shown = source
        shown.kind = .page
        switch await page(shown) {
        case .items(let items, _): return .read(LiveRead(items: items, source: shown, feed: .notFeed))
        case .read(var read):
            read.source = shown
            read.feed = .notFeed
            return .read(read)
        case let other: return other
        }
    }

    private static func feedRead(_ entries: [FeedParser.Entry], base: URL, source: LiveSource?) -> Answer {
        let found = items(entries, base: base)
        return .read(LiveRead(items: found, source: source, feed: entries.isEmpty ? .empty : .entries))
    }

    static func items(_ entries: [FeedParser.Entry], base: URL) -> [LiveItem] {
        entries.compactMap { entry in
            guard let url = URL(string: entry.link, relativeTo: base)?.absoluteURL,
                  url.scheme == "https" || url.scheme == "http" else { return nil }
            let key = url.absoluteString
            return LiveItem(key: key, title: entry.title.isEmpty ? key : entry.title,
                            author: entry.author.isEmpty ? nil : entry.author)
        }
    }

    static func cookies(_ all: [HTTPCookie], for url: URL) -> [HTTPCookie] {
        let host = url.host()?.lowercased() ?? ""
        let path = url.path().isEmpty ? "/" : url.path()
        return all.filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return (host == domain || host.hasSuffix("." + domain))
                && path.hasPrefix(cookie.path)
                && (!cookie.isSecure || url.scheme == "https")
        }
    }

    private static func fetch(_ url: URL, store: WKWebsiteDataStore) async -> (Data, Int)? {
        await exchange(url, store: store).map { ($0.0, $0.1) }
    }

    private static func exchange(_ url: URL, store: WKWebsiteDataStore) async -> (Data, Int, [String: String])? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        if url.scheme?.hasPrefix("http") == true {
            let all = await store.httpCookieStore.allCookies()
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies(all, for: url)) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }
        return await LiveConditional.exchange(request, delegate: LiveRedirects())
    }

    static func readPage(_ url: URL, source: LiveSource, store: WKWebsiteDataStore) async -> Answer {
        let reader = LiveReader()
        running.append(reader)
        defer { running.removeAll { $0 === reader } }
        return await reader.load(url, source: source, store: store)
    }

    private func load(_ url: URL, source: LiveSource, store: WKWebsiteDataStore) async -> Answer {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        web.navigationDelegate = self
        view = web
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
            view = nil
        }
        let loaded = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            finished = done
            web.load(URLRequest(url: url, timeoutInterval: 25))
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.finish(false) }
        }
        guard loaded else { return .failed }
        var found = 0
        var last: Scan?
        var counts: [Int] = []
        for wait in [0.4, 1.2, 2.5, 4.0] {
            try? await Task.sleep(for: .seconds(wait))
            guard let scan = await scan(web, source: source) else { continue }
            let again = last != nil
            last = scan
            counts.append(scan.links.count)
            if scan.sso != nil, again, scan.links.count == found, (scan.pending ?? 0) == 0 { break }
            if scan.limit == true || signedOut(scan, asked: url, source: source) || LiveLabels.broken(status: status, found: scan.links.count) { break }
            if !scan.links.isEmpty, scan.links.count == found, (scan.pending ?? 0) == 0 { break }
            found = scan.links.count
        }
        guard let last else { return .failed }
        return LiveReader.answer(last, asked: url, status: status, headers: headers, source: source, growing: LiveReader.growing(counts))
    }

    static func growing(_ counts: [Int]) -> Bool {
        guard counts.count >= 2 else { return false }
        return counts[counts.count - 1] > counts[counts.count - 2]
    }

    private static func answer(_ scan: Scan, asked: URL, status: Int?, headers: [String: String] = [:], source: LiveSource,
                               growing: Bool = false) -> Answer {
        let pulls = source.kind == .pullRequests || source.kind == .repository
        let items = scan.links.map { item(from: $0, pulls: pulls) }
        if let sso = scan.sso { return .sso(sso, items) }
        if items.isEmpty, let miss = LiveLimit.miss(status: status, headers: headers, page: scan.limit == true) { return .missed(miss) }
        if signedOut(scan, asked: asked, status: status, source: source) { return .signIn }
        if LiveLabels.broken(status: status, found: scan.links.count) { return .failed }
        return .read(LiveRead(items: items, whole: !growing, marked: scan.nothing == true, more: scan.more == true ? asked.absoluteString : nil))
    }

    static func answer(scanned json: String, asked: URL, status: Int? = 200, headers: [String: String] = [:], source: LiveSource,
                       growing: Bool = false) -> Answer? {
        guard let scan = try? JSONDecoder().decode(Scan.self, from: Data(json.utf8)) else { return nil }
        return answer(scan, asked: asked, status: status, headers: headers, source: source, growing: growing)
    }

    private static func item(from link: Scan.Link, pulls: Bool) -> LiveItem {
        let draft = pulls && link.draft == true && link.merged != true && link.closed != true
        return LiveItem(key: link.url, title: link.title,
                        label: pulls ? LiveLabels.pullRequest(row: link.said ?? link.row, draft: link.draft == true,
                                                              merged: link.merged == true, closed: link.closed == true) : nil,
                        author: link.author?.isEmpty == false ? link.author : nil,
                        checks: link.checks.flatMap(LiveChecks.init(rawValue:)),
                        updated: pulls ? link.updated.flatMap(GitHubAPI.date) : nil, draft: draft ? true : nil)
    }

    static func items(scanned json: String, pulls: Bool) -> [LiveItem]? {
        guard let scan = try? JSONDecoder().decode(Scan.self, from: Data(json.utf8)) else { return nil }
        return scan.links.map { item(from: $0, pulls: pulls) }
    }

    private func signedOut(_ scan: Scan, asked: URL, source: LiveSource) -> Bool {
        LiveReader.signedOut(scan, asked: asked, status: status, source: source)
    }

    private static func signedOut(_ scan: Scan, asked: URL, status: Int?, source: LiveSource) -> Bool {
        LiveLabels.needsSignIn(asked: asked, landed: URL(string: scan.href), password: scan.password, found: scan.links.count,
                               status: status, user: scan.user, signInLink: scan.signInLink == true,
                               personal: source.personal, hidesPrivate: source.hidesPrivate)
    }

    private func scan(_ web: WKWebView, source: LiveSource) async -> Scan? {
        let pattern = source.pattern.map { #"'\#($0.replacingOccurrences(of: #"\"#, with: #"\\"#))'"#} ?? "null"
        let call = "\(LiveReader.script)(\(pattern), \(source.cap * 3), \(LiveEmptyMarker.json(for: source)))"
        guard let text = try? await web.evaluateJavaScript(call, contentWorld: .defaultClient) as? String else { return nil }
        return try? JSONDecoder().decode(Scan.self, from: Data(text.utf8))
    }

    private func finish(_ worked: Bool) {
        finished?.resume(returning: worked)
        finished = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            status = http.statusCode
            headers = Dictionary(http.allHeaderFields.compactMap { key, value in (key as? String).map { ($0, "\(value)") } },
                                 uniquingKeysWith: { a, _ in a })
        } else if navigationResponse.isForMainFrame {
            status = nil
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}
