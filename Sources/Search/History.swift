import Combine
import Observation
import Foundation

// Where you have been, so the field can finish the address for you. Kept in one
// small file next to the app's own settings, written a moment after a visit
// rather than on every keystroke.

struct Suggestion: Identifiable, Equatable {
    /// What you could type to get here, kept reversible for completion.
    let key: String
    let title: String
    let url: URL
    let kind: Kind
    /// Set when this is a page you already have open somewhere.
    var tab: UUID?
    var note = ""
    var keys = ""
    var symbol = ""
    var leads = false

    enum Kind: Equatable {
        /// A page that is open right now.
        case open
        /// Somewhere you have actually been.
        case visited
        case bookmark
        /// One of the well-known addresses the field knows from the start.
        case known
        /// Not a place at all — words, and an engine to ask.
        case search
        /// Words the engine itself suggested, from what was typed so far
        /// (Settings › General › Suggestions from your search engine).
        case suggested
        /// Not a place either: something the app itself does.
        case command(AddressCommand)
        case passage
        case action(String)
        case answer(FieldAnswer)
        case snippet(Snippet)
        case placed(FieldPlaceItem)

        var isCommand: Bool { if case .command = self { return true }; return false }
    }

    /// A command's row can read the same as the search for the same word
    /// ("Settings" typed with its capital), and two rows can't share a name.
    var id: String {
        if kind.isCommand { return "command " + key }
        if case .suggested = kind { return "suggested " + key }
        if case .passage = kind { return "passage " + History.identity(for: url) }
        if case .action(let action) = kind { return "action " + action }
        if case .answer = kind { return "answer" }
        if case .snippet(let snippet) = kind { return "snippet " + snippet.id.uuidString }
        if case .placed(let item) = kind { return "placed \(item.place.rawValue) \(item.id)" }
        if case .visited = kind { return History.identity(for: url) }
        if case .bookmark = kind { return History.identity(for: url) }
        return key
    }

    /// A command goes nowhere, but the field still needs *a* URL to carry;
    /// `take` and `submit` read the kind first and never follow this one.
    @MainActor
    static func command(_ command: AddressCommand) -> Suggestion {
        Suggestion(key: command.title, title: "", url: URL(string: "about:blank")!, kind: .command(command))
    }
}

private struct Visit: Codable {
    var url: String
    var key: String
    var title: String
    var count: Int
    var last: Date
    var from: String?
    var spaces: [String: Seen]?
    var placed: Bool? = true

    struct Seen: Codable {
        var count: Int
        var last: Date
    }
}

@MainActor
final class ForgottenPage {
    fileprivate let visit: Visit
    let name: String
    fileprivate(set) var text: PageIndex.Kept?

    fileprivate init(visit: Visit, name: String) {
        self.visit = visit
        self.name = name
    }
}

private struct PageText {
    let address: String
    let searchable: String
    let host: String
    let homepage: Bool
}

@MainActor
@Observable
final class History {
    private(set) var revision = 0

    @ObservationIgnored private var visits: [String: Visit] = [:] {
        didSet {
            recentCache = nil
            frequentCache = nil
            revision &+= 1
        }
    }
    /// The last few places, as the History menu lists them. The menu bar is
    /// drawn again whenever anything in the window changes — every key typed
    /// into the address field included — and sorting the whole history for
    /// it each time cost more than everything else a key press does.
    @ObservationIgnored private var recentCache: [Trace]?
    @ObservationIgnored private var frequentCache: [Trace]?
    @ObservationIgnored private var saving = false
    /// Visits counted at most: far more than anyone makes, and room to add.
    static let mostVisits = 1_000_000_000
    nonisolated static let mostKept = 2_000
    /// These are derived once when a visit enters memory. Suggestions run on
    /// every keystroke, so neither URL parsing nor address formatting belongs
    /// in that loop.
    @ObservationIgnored private var pageText: [String: PageText] = [:]
    @ObservationIgnored private var visitedHosts: Set<String> = []
    let pages: PageIndex
    @ObservationIgnored private var textTaken: [String: Date] = [:]
    @ObservationIgnored private var moved: [String: String] = [:]
    @ObservationIgnored private(set) var hasUnplaced = false

    init(file: URL? = nil, pages: URL? = nil) {
        self.file = file ?? Store.file("history.json")
        self.pages = PageIndex(file: pages ?? Store.file("pagetext.sqlite"))
        load()
    }

    /// URL identity ignores fragments, normalizes only the scheme and host,
    /// and keeps the spelling and encoding of the path and query intact.
    nonisolated static func identity(for url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        // An absent path and a lone slash have always meant the same home page.
        if parts.percentEncodedPath.isEmpty { parts.percentEncodedPath = "/" }
        return parts.string ?? url.absoluteString
    }

    /// A page as it is kept: without a name and password written into its
    /// address. They were never part of which page it is, and the history
    /// file is no place for a password. Nil if they can't be taken off.
    nonisolated static func kept(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        guard parts.user != nil || parts.password != nil else { return url }
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    private static func isWeb(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
    }

    private static func pageText(for url: URL) -> PageText {
        var shownURL = url
        if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            parts.fragment = nil
            shownURL = parts.url ?? url
        }
        let address = Address.editable(shownURL)
        let searchable = stripped(address)
        let host = (shownURL.host()?.lowercased() ?? "")
        let bareHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let path = shownURL.path()
        return PageText(
            address: address,
            searchable: searchable,
            host: bareHost,
            homepage: path.isEmpty || path == "/"
        )
    }

    static func stripped(_ address: String) -> String {
        var text = address.trimmingCharacters(in: .whitespaces).lowercased()
        for scheme in ["https://", "http://"] where text.hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        return text
    }

    private func remember(_ visit: Visit, url: URL? = nil) {
        if let from = visit.from { moved[from] = visit.key }
        guard let page = url ?? URL(string: visit.url) else { return }
        let text = History.pageText(for: page)
        pageText[visit.key] = text
        frequentCache = nil
        if !text.host.isEmpty { visitedHosts.insert(text.host) }
    }

    private func forgetText(for key: String) {
        let host = pageText.removeValue(forKey: key)?.host
        guard let host, !host.isEmpty,
              !pageText.values.contains(where: { $0.host == host })
        else { return }
        visitedHosts.remove(host)
    }

    nonisolated private static func homepage(of url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.user = nil
        parts.password = nil
        parts.percentEncodedPath = "/"
        parts.percentEncodedQuery = nil
        parts.fragment = nil
        return parts.url
    }

    // MARK: - writing

    func title(for url: URL) -> String? {
        let key = History.identity(for: url)
        if let seen = visits[key], !seen.title.isEmpty { return seen.title }
        if let target = moved[key], let seen = visits[target], !seen.title.isEmpty { return seen.title }
        return nil
    }

    private static func tally(_ visit: inout Visit, in space: UUID?, at date: Date) {
        guard let space else { return }
        var seen = visit.spaces?[space.uuidString] ?? Visit.Seen(count: 0, last: date)
        seen.count = min(History.mostVisits, seen.count + 1)
        seen.last = date
        visit.spaces = (visit.spaces ?? [:]).merging([space.uuidString: seen]) { $1 }
    }

    private static func joined(_ a: [String: Visit.Seen]?, _ b: [String: Visit.Seen]?) -> [String: Visit.Seen]? {
        guard let a else { return b }
        guard let b else { return a }
        return a.merging(b) { one, other in
            let sum = one.count.addingReportingOverflow(other.count)
            return Visit.Seen(count: sum.overflow ? History.mostVisits : min(History.mostVisits, sum.partialValue),
                              last: max(one.last, other.last))
        }
    }

    func record(_ url: URL, title: String, from asked: URL? = nil, space: UUID? = nil) {
        guard History.isWeb(url), let url = History.kept(url) else { return }
        let key = History.identity(for: url)
        guard !key.isEmpty else { return }
        let from = asked.flatMap(History.kept).map(History.identity(for:)).flatMap { $0 == key || $0.isEmpty ? nil : $0 }
        let text = History.pageText(for: url)

        // Reading a deep page is also, in the way that matters here, another
        // visit to the site. Without this, typing three letters offers the
        // article you happened to open last week rather than the front page —
        // and nobody types a domain meaning to land halfway down it.
        if !text.homepage, let homeURL = History.homepage(of: url) {
            let root = History.identity(for: homeURL)
            var home = visits[root] ?? Visit(
                url: homeURL.absoluteString, key: root, title: "", count: 0, last: Date()
            )
            home.count = min(History.mostVisits, home.count + 1)
            home.last = Date()
            History.tally(&home, in: space, at: home.last)
            visits[root] = home
            remember(home, url: homeURL)
        }

        if var seen = visits[key] {
            seen.count = min(History.mostVisits, seen.count + 1)
            seen.last = Date()
            seen.url = url.absoluteString
            if !title.isEmpty { seen.title = title }
            if let from { seen.from = from }
            History.tally(&seen, in: space, at: seen.last)
            visits[key] = seen
        } else {
            var made = Visit(
                url: url.absoluteString,
                key: key,
                title: title,
                count: 1,
                last: Date(),
                from: from
            )
            History.tally(&made, in: space, at: made.last)
            visits[key] = made
        }
        if let seen = visits[key] { remember(seen, url: url) }
        save()
    }

    /// Somewhere another browser has been. Counted as it was counted there,
    /// so a site visited daily for a year outranks one seen once — the day
    /// you switch, the field already knows you.
    @discardableResult
    func take(_ url: URL, title: String, count: Int, last: Date) -> Bool? {
        guard History.isWeb(url), let url = History.kept(url) else { return nil }
        let key = History.identity(for: url)
        guard !key.isEmpty else { return nil }
        if var seen = visits[key] {
            // The larger of the two, not their sum: the same browser brought
            // in again must not count every visit twice.
            seen.count = min(History.mostVisits, max(seen.count, count))
            if last > seen.last { seen.last = last }
            if seen.title.isEmpty { seen.title = title }
            visits[key] = seen
            return false
        }
        let visit = Visit(url: url.absoluteString, key: key, title: title, count: min(max(count, 0), History.mostVisits), last: last)
        visits[key] = visit
        remember(visit, url: url)
        return true
    }

    /// After a batch of `take`s.
    func settle() { save() }

    /// A page's title usually lands a beat after the page does.
    func retitle(_ url: URL, _ title: String) {
        let key = History.identity(for: url)
        guard !title.isEmpty, var seen = visits[key], seen.title != title else { return }
        seen.title = title
        visits[key] = seen
        save()
    }

    func forget() {
        visits = [:]
        moved = [:]
        pageText = [:]
        frequentCache = nil
        visitedHosts = []
        textTaken = [:]
        pages.removeAll()
        save()
    }

    func knows(_ key: String) -> Bool { visits[key] != nil }

    func wantsText(of key: String, now: Date = Date()) -> Bool {
        guard let taken = textTaken[key] else { return true }
        return now.timeIntervalSince(taken) > 600
    }

    func keepText(key: String, url: URL, title: String, text: String) {
        guard visits[key] != nil else { return }
        textTaken[key] = Date()
        pages.add(key: key, url: url, title: title, text: text)
    }

    /// Everywhere you have been, newest first, for the window that shows it.
    struct Trace: Identifiable, Equatable {
        let key: String
        /// A reversible address for display; `key` is the stable URL identity.
        let address: String
        let title: String
        let url: URL
        let last: Date
        let count: Int

        var id: String { key }
    }

    func everything(matching typed: String = "") -> [Trace] {
        let words = FieldPlace.words(typed)
        return visits.values
            // Every visit to a page also credits its domain, so the address
            // field can offer the front door. Those credits have no title of
            // their own, and in a list of where you have been they are a second
            // copy of every line.
            .filter { visit in
                !(visit.title.isEmpty && pageText[visit.key]?.homepage == true)
            }
            .filter { holds($0, words) }
            .sorted { $0.last > $1.last }
            .compactMap { visit in
                URL(string: visit.url).map {
                    Trace(
                        key: visit.key,
                        address: pageText[visit.key]?.address ?? visit.key,
                        title: visit.title,
                        url: $0,
                        last: visit.last,
                        count: visit.count
                    )
                }
            }
    }

    func everything(in space: UUID) -> [Trace] {
        let id = space.uuidString
        return visits.values
            .compactMap { visit -> Trace? in
                guard let seen = visit.spaces?[id], !(visit.title.isEmpty && pageText[visit.key]?.homepage == true),
                      let url = URL(string: visit.url) else { return nil }
                return Trace(key: visit.key, address: pageText[visit.key]?.address ?? visit.key, title: visit.title,
                             url: url, last: seen.last, count: seen.count)
            }
            .sorted { $0.last > $1.last }
    }

    func placeOldVisits(in spaces: [UUID], held rows: [UUID: [String]]) {
        guard hasUnplaced, !spaces.isEmpty else { return }
        hasUnplaced = false
        let only = spaces.count == 1 ? spaces.first : nil
        let sites = LinkRules.sites(rows.filter { spaces.contains($0.key) })
        visits = visits.mapValues { visit in
            var visit = visit
            if visit.placed == nil, visit.spaces == nil {
                let site = LinkRouter.site(of: URL(string: visit.url)).flatMap { sites[$0] }
                if let owner = only ?? site.flatMap({ $0.count == 1 ? $0.keys.first : nil }) {
                    visit.spaces = [owner.uuidString: Visit.Seen(count: visit.count, last: visit.last)]
                }
            }
            visit.placed = true
            return visit
        }
        save()
    }

    func placeOldVisits(for browser: Browser) {
        guard hasUnplaced, !browser.isPrivate else { return }
        let spaces = browser.prefs.usesSpaces ? browser.spaces.map(\.id) : [Space.firstID]
        guard spaces.count > 1 else { return placeOldVisits(in: spaces, held: [:]) }
        placeOldVisits(in: spaces, held: History.held(
            in: spaces,
            tabs: LinkRules.rows(spaces, leaving: Set(Pins.shared().map(\.id))),
            pins: Dictionary(spaces.map { ($0, Pins.defs($0).map(\.home)) }, uniquingKeysWith: { a, _ in a }),
            folders: LiveFolders.shared.folders,
            rules: LinkRules.shared.rules
        ))
    }

    static func held(in spaces: [UUID], tabs: [UUID: [String]], pins: [UUID: [String]] = [:], folders: [LiveFolder] = [],
                     rules: [LinkRule] = []) -> [UUID: [String]] {
        var rows = tabs.merging(pins) { $0 + $1 }
        for folder in folders { rows[folder.space, default: []].append(folder.source.address) }
        for rule in rules where rule.on {
            guard case .space(let space, _) = rule.target else { continue }
            switch rule.match {
            case .site(let text), .host(let text):
                rows[space, default: []].append("https://\(LinkRouter.plainSite(text, keepsWWW: true))/")
            case .starts, .contains, .pattern, .regex:
                continue
            }
        }
        return rows.filter { spaces.contains($0.key) }
    }

    func forget(space: UUID) {
        let id = space.uuidString
        guard visits.values.contains(where: { $0.spaces?[id] != nil }) else { return }
        visits = visits.mapValues { visit in
            var visit = visit
            visit.spaces?[id] = nil
            if visit.spaces?.isEmpty == true { visit.spaces = nil }
            return visit
        }
        save()
    }

    func newest(matching typed: String, limit: Int) -> [Trace] {
        let words = FieldPlace.words(typed)
        var best: [Visit] = []
        for visit in visits.values {
            if best.count == limit, let last = best.last, visit.last <= last.last { continue }
            let text = pageText[visit.key]
            if visit.title.isEmpty && text?.homepage == true { continue }
            guard holds(visit, words) else { continue }
            let at = best.firstIndex { visit.last > $0.last } ?? best.endIndex
            best.insert(visit, at: at)
            if best.count > limit { best.removeLast() }
        }
        return best.compactMap(trace)
    }

    func trace(_ key: String) -> Trace? {
        visits[key].flatMap(trace)
    }

    private func holds(_ visit: Visit, _ words: [String]) -> Bool {
        guard !words.isEmpty else { return true }
        let address = pageText[visit.key]?.searchable ?? visit.key
        let title = visit.title.lowercased()
        return words.allSatisfy { address.contains($0) || title.contains($0) }
    }

    private func trace(_ visit: Visit) -> Trace? {
        URL(string: visit.url).map {
            Trace(key: visit.key, address: pageText[visit.key]?.address ?? visit.key, title: visit.title,
                  url: $0, last: visit.last, count: visit.count)
        }
    }

    func forget(_ key: String) {
        // Its page's icon is a trace of the visit too.
        if let url = visits[key].flatMap({ URL(string: $0.url) }) { Favicons.shared.forget(url) }
        visits[key] = nil
        forgetText(for: key)
        textTaken[key] = nil
        pages.remove(key: key)
        save()
    }

    func forgetPage(_ key: String) -> ForgottenPage? {
        guard let visit = visits[key], let trace = trace(visit) else { return nil }
        let gone = ForgottenPage(visit: visit, name: trace.title.isEmpty ? trace.address : trace.title)
        if let url = URL(string: visit.url) { Favicons.shared.forget(url) }
        visits[key] = nil
        forgetText(for: key)
        textTaken[key] = nil
        pages.remove(key: key) { kept in Task { @MainActor in gone.text = kept } }
        save()
        return gone
    }

    func restore(_ gone: ForgottenPage) {
        let visit = gone.visit
        visits[visit.key] = visits[visit.key].map { History.merged($0, visit) } ?? visit
        remember(visit)
        if let kept = gone.text {
            pages.add(key: kept.key, url: kept.url, title: kept.title, text: kept.body, visited: kept.visited)
        }
        save()
    }

    func forget(site host: String) {
        let bare = PageIndex.bare(host.lowercased())
        for key in visits.keys {
            guard let site = pageText[key]?.host, site == bare || site.hasSuffix("." + bare) else { continue }
            forget(key)
        }
    }

    func forget(since date: Date) {
        for (key, visit) in visits where visit.last >= date { forget(key) }
    }

    /// The last eight places, newest first; worked out again only once the
    /// history has changed.
    func recent() -> [Trace] {
        if let recentCache { return recentCache }
        let made = Array(everything().prefix(8))
        recentCache = made
        return made
    }

    func frequent(limit: Int, skipping: Set<String>) -> [Trace] {
        let ranked = frequentCache ?? everything()
            .filter { !$0.title.isEmpty }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
        frequentCache = ranked
        return Array(ranked.lazy.filter { !skipping.contains($0.key) }.prefix(limit))
    }

    // MARK: - reading

    /// Best matches first. A place you have been always beats a place the app
    /// merely knows the name of, and among places you have been, one you go to
    /// often and recently beats one you saw once in March.
    func suggestions(for typed: String, limit: Int = 5) -> [Suggestion] {
        let needle = strip(typed)
        // An empty field proposes nothing. A list of guesses in front of
        // someone who has not yet said what they want is noise, and it is in
        // the way of the one thing they came here to do.
        guard !needle.isEmpty else { return [] }

        let bytes = Array(needle.utf8)
        let ascii = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F } ? bytes : nil
        let now = Date()
        // Only the best few are kept while scanning, in order, and only those
        // become suggestions. Making one for every match in a big history,
        // only to sort them all and keep five, was work thrown away each key.
        var best: [(Suggestion, Double)] = []
        // Higher first, then the shorter key, then whichever came first: the
        // order a stable sort of every match would have left them in.
        func ahead(_ score: Double, _ key: String, of other: (Suggestion, Double)) -> Bool {
            score == other.1 ? key.count < other.0.key.count : score > other.1
        }
        func offer(_ key: String, _ score: Double, _ make: () -> Suggestion?) {
            if best.count == limit, let last = best.last, !ahead(score, key, of: last) { return }
            guard let made = make() else { return }
            best.insert((made, score), at: best.firstIndex { ahead(score, key, of: $0) } ?? best.endIndex)
            if best.count > limit { best.removeLast() }
        }

        for visit in visits.values {
            guard let text = pageText[visit.key],
                  let rank = rank(text.searchable, against: needle, ascii: ascii)
            else { continue }
            // The front door before the room inside it: a bare domain is
            // what a bare domain typed into a field means.
            let score = rank + 4 + frecency(visit, now: now) + (text.homepage ? 1.5 : 0)
            offer(text.address, score) {
                URL(string: visit.url).map { Suggestion(key: text.address, title: visit.title, url: $0, kind: .visited) }
            }
        }

        // Only where memory has nothing to offer. A list of famous websites is
        // a poor substitute for knowing where someone actually goes.
        for known in History.known where !visitedHosts.contains(known.0) {
            guard let rank = rank(known.0, against: needle, ascii: ascii) else { continue }
            offer(known.0, rank) {
                URL(string: "https://" + known.0).map { Suggestion(key: known.0, title: known.1, url: $0, kind: .known) }
            }
        }

        return best.map(\.0)
    }

    /// How often each site has been visited, for site search to weigh one
    /// against another (SiteSearch.match): every page on its host and the
    /// host's subdomains, or under its path for one like google.com/maps —
    /// so a site counts at least as often as any part of it.
    func hosts(endingIn suffix: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for visit in visits.values {
            guard let host = pageText[visit.key]?.host, host.hasSuffix(suffix) else { continue }
            counts[host, default: 0] = min(History.mostVisits, counts[host, default: 0] + visit.count)
        }
        return counts
    }

    func namesSite(_ word: String) -> Bool {
        if word.contains(".") { return true }
        return visitedHosts.contains { $0.split(separator: ".").dropLast().contains { $0 == word } }
    }

    func visits(to sites: [String]) -> [String: Int] {
        let wanted = sites.map { site -> (site: String, host: String, path: String) in
            let bare = site.lowercased().hasPrefix("www.") ? String(site.lowercased().dropFirst(4)) : site.lowercased()
            let host = bare.split(separator: "/", maxSplits: 1).first.map(String.init) ?? bare
            return (site, host, String(bare.dropFirst(host.count)))
        }
        var counts: [String: Int] = [:]
        for visit in visits.values {
            guard let text = pageText[visit.key] else { continue }
            for one in wanted where text.host == one.host || text.host.hasSuffix("." + one.host) {
                if !one.path.isEmpty {
                    guard text.searchable.hasPrefix(one.host + one.path) else { continue }
                    let rest = text.searchable.dropFirst(one.host.count + one.path.count)
                    guard rest.first.map({ "/?#".contains($0) }) ?? true else { continue }
                }
                counts[one.site, default: 0] = min(History.mostVisits, counts[one.site, default: 0] + visit.count)
            }
        }
        return counts
    }

    /// What the field should draw greyed out after the caret: the rest of the
    /// best match, or nothing if it doesn't carry on from what was typed.
    func completion(for typed: String, among options: [Suggestion]) -> String? {
        guard !typed.isEmpty else { return nil }
        // One letter finishes only the top row, and only when it is the
        // front door of a site you have been to: "x" becomes x.com, as in
        // Safari and Chrome (#696). A room inside a site, a name the app
        // merely knows, or a lower row waits for a second letter.
        let single = typed.count == 1
        if single, let first = options.first?.kind, first != .visited { return nil }
        for option in single ? Array(options.prefix(1)) : options {
            for (key, target) in History.endings(of: option) {
                guard key.count >= typed.count else { continue }
                if single, key.contains("/") || key.contains("?") || key.contains("#") { continue }
                let prefix = String(key.prefix(typed.count))
                guard prefix.caseInsensitiveCompare(typed) == .orderedSame else { continue }
                let rest = String(key.dropFirst(typed.count))
                guard let completed = Address.url(from: typed + rest),
                      History.identity(for: completed) == target
                else { continue }
                return rest.isEmpty ? nil : rest
            }
        }
        return nil
    }

    /// What a row can be finished as, and the page that has to come of it.
    /// Its address as shown; and for a www site, the name without the www,
    /// as the field always finished it: "app" still becomes apple.com, and
    /// the site sends you on to its www. Only the www is let go of: the
    /// scheme, the port and the path's case still have to come out the same.
    private static func endings(of option: Suggestion) -> [(String, String)] {
        var found = [(option.key, identity(for: option.url))]
        if option.key.lowercased().hasPrefix("www."),
           var parts = URLComponents(url: option.url, resolvingAgainstBaseURL: false),
           let host = parts.host, host.lowercased().hasPrefix("www.") {
            parts.host = String(host.dropFirst(4))
            if let bare = parts.url { found.append((String(option.key.dropFirst(4)), identity(for: bare))) }
        }
        return found
    }

    /// Where the match falls decides most of the ordering: the start of the
    /// host is what people mean, the middle of a path almost never is.
    private func rank(_ key: String, against needle: String, ascii: [UInt8]?) -> Double? {
        // Plain addresses can be read as bytes. Check the whole key: even a
        // mark attached to a slash can change where a Character ends. A nil
        // score asks the original matcher below; zero means no ASCII match.
        if let ascii,
           let score = key.utf8.withContiguousStorageIfAvailable({ bytes -> Double? in
               guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
               if bytes.starts(with: ascii) { return 6 }
               let hostEnd = bytes.firstIndex(where: { $0 == 0x2F || $0 == 0x3F || $0 == 0x23 }) ?? bytes.endIndex
               let host = bytes[..<hostEnd]
               if let dot = host.firstIndex(of: 0x2E), host[(dot + 1)...].starts(with: ascii) { return 3 }
               if ascii.count >= 2, ascii.count <= host.count {
                   for start in 0...(host.count - ascii.count) {
                       if host[start...].starts(with: ascii) { return 2 }
                   }
               }
               return 0
           }), let score {
            return score == 0 ? nil : score
        }
        if key.hasPrefix(needle) { return 6 }
        // Read in place: this runs for every place in the history on every
        // key, and splitting each key into new strings was most of its cost.
        let hostEnd = key.firstIndex(where: { "/?#".contains($0) }) ?? key.endIndex
        let host = key[..<hostEnd]
        // "google" finding mail.google.com without the subdomain.
        if let dot = host.firstIndex(of: "."), host[host.index(after: dot)...].hasPrefix(needle) { return 3 }
        // Only from two letters up. A single letter matching anywhere inside
        // a name turns "x" into example.com and netflix.com, which is not what
        // anybody meant by it.
        if needle.count >= 2, host.contains(needle) { return 2 }
        // Deliberately no match on the path. "blog" turning up six articles
        // from three sites is not an answer to anything.
        return nil
    }

    /// Often, and lately. A month-old visit counts for about a third of a
    /// fresh one, which is roughly how long a habit takes to stop being one.
    private func frecency(_ visit: Visit, now: Date) -> Double {
        History.score(visit, now: now)
    }

    nonisolated private static func score(_ visit: Visit, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(visit.last) / 86_400)
        return Double(visit.count) * exp(-days / 30)
    }

    private func strip(_ typed: String) -> String { History.stripped(typed) }

    // MARK: - the file

    @ObservationIgnored private let file: URL

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        guard let list = try? JSONDecoder().decode([Visit].self, from: data) else {
            Store.quarantine(file)
            return
        }
        // Keys written by an older Search can meet under the new rule:
        // they are merged, never trusted to be unique.
        var cleaned = false
        var loaded = Dictionary(list.map { saved in
            var visit = saved
            // A count from a file edited by hand is held to a sane range,
            // so adding to it can't overflow.
            visit.count = min(max(visit.count, 0), History.mostVisits)
            visit.spaces = visit.spaces?.mapValues { Visit.Seen(count: min(max($0.count, 0), History.mostVisits), last: $0.last) }
            if let url = URL(string: visit.url) {
                // An address kept with a name and password in it, by a Search
                // from before they were taken off, loses them here.
                if let clean = History.kept(url), clean.absoluteString != visit.url {
                    visit.url = clean.absoluteString
                    cleaned = true
                }
                visit.key = History.identity(for: url)
            }
            return (visit.key, visit)
        }, uniquingKeysWith: History.merged)
        History.rehomeCredits(&loaded)
        visits = loaded
        hasUnplaced = loaded.values.contains { $0.placed == nil }
        for visit in visits.values { remember(visit) }
        // And written without them now, not at the next visit (Security).
        if cleaned { save() }
        pages.keep(only: Set(visits.keys))
    }

    /// The same page twice: its visits added up, the latest date, and a
    /// title if either had one.
    private static func merged(_ a: Visit, _ b: Visit) -> Visit {
        var kept = a.last >= b.last ? a : b
        kept.count = min(History.mostVisits, a.count.addingReportingOverflow(b.count).overflow ? History.mostVisits : a.count + b.count)
        if kept.title.isEmpty { kept.title = a.last >= b.last ? b.title : a.title }
        kept.spaces = joined(a.spaces, b.spaces)
        kept.placed = a.placed == true && b.placed == true ? true : nil
        return kept
    }

    /// Before 1.0.4, every deep page also credited https:// and its host
    /// without www, whatever the scheme, port or www the page was on. Such a
    /// credit, with no title and nothing else on its own origin, moves to the
    /// front door its pages actually used: left where it was, it would be
    /// offered next to the one new visits credit, the same site twice.
    private static func rehomeCredits(_ visits: inout [String: Visit]) {
        // Visits per front door, by host without www, from the deeper pages.
        var doors: [String: [String: Int]] = [:]
        for visit in visits.values {
            guard let url = URL(string: visit.url), let host = url.host()?.lowercased(),
                  !(url.path().isEmpty || url.path() == "/"),
                  let home = homepage(of: url)
            else { continue }
            let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
            doors[bare, default: [:]][identity(for: home), default: 0] += visit.count
        }
        for (key, credit) in visits {
            guard credit.title.isEmpty,
                  let url = URL(string: credit.url),
                  url.scheme == "https", url.port == nil, url.query() == nil,
                  url.path().isEmpty || url.path() == "/",
                  let host = url.host()?.lowercased(), !host.hasPrefix("www."),
                  let used = doors[host], used[key] == nil,
                  let door = used.max(by: { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value })?.key,
                  let doorURL = URL(string: door)
            else { continue }
            visits[key] = nil
            let moved = Visit(url: doorURL.absoluteString, key: door, title: "", count: credit.count, last: credit.last,
                              spaces: credit.spaces, placed: credit.placed)
            visits[door] = visits[door].map { merged($0, moved) } ?? moved
        }
    }

    /// Coalesced: a busy minute of browsing writes the file once, not thirty
    /// times, and never on the main thread.
    private func save() {
        guard !saving else { return }
        saving = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            saving = false
            let now = Date()
            // A cap, so the file can't grow without end. What goes is what has
            // been visited least and longest ago.
            let snapshot = self.visits
            let file = self.file
            let pages = self.pages
            Disk.write(file) {
                let list = Array(snapshot.values.sorted { History.score($0, now: now) > History.score($1, now: now) }.prefix(History.mostKept))
                if snapshot.count > History.mostKept { pages.keep(only: Set(list.map(\.key))) }
                return try? JSONEncoder().encode(list)
            }
        }
    }

    /// Somewhere to start on the first day, before there is any history to go
    /// on. Ranked below anything actually visited, and dropped from the list
    /// the moment you have been there yourself.
    private static let known: [(String, String)] = [
        ("google.com", "Google"), ("mail.google.com", "Gmail"),
        ("drive.google.com", "Google Drive"), ("calendar.google.com", "Google Calendar"),
        ("maps.google.com", "Google Maps"), ("youtube.com", "YouTube"),
        ("github.com", "GitHub"), ("figma.com", "Figma"), ("vercel.com", "Vercel"),
        ("notion.so", "Notion"), ("linear.app", "Linear"), ("slack.com", "Slack"),
        ("discord.com", "Discord"), ("x.com", "X"), ("linkedin.com", "LinkedIn"),
        ("instagram.com", "Instagram"), ("reddit.com", "Reddit"),
        ("news.ycombinator.com", "Hacker News"), ("stackoverflow.com", "Stack Overflow"),
        ("claude.ai", "Claude"), ("chatgpt.com", "ChatGPT"),
        ("dribbble.com", "Dribbble"), ("behance.net", "Behance"),
        ("awwwards.com", "Awwwards"), ("mobbin.com", "Mobbin"),
        ("siteinspire.com", "SiteInspire"), ("are.na", "Are.na"),
        ("pinterest.com", "Pinterest"), ("framer.com", "Framer"),
        ("webflow.com", "Webflow"), ("developer.apple.com", "Apple Developer"),
        ("swift.org", "Swift"), ("npmjs.com", "npm"), ("supabase.com", "Supabase"),
        ("stripe.com", "Stripe"), ("shopify.com", "Shopify"),
        ("cloudflare.com", "Cloudflare"), ("netlify.com", "Netlify"),
        ("apple.com", "Apple"), ("spotify.com", "Spotify"), ("netflix.com", "Netflix"),
        ("wikipedia.org", "Wikipedia"), ("deepl.com", "DeepL"), ("loom.com", "Loom"),
        ("amazon.fr", "Amazon"), ("leboncoin.fr", "leboncoin"), ("lemonde.fr", "Le Monde"),
    ]
}
