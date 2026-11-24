import Foundation
import Observation
import AppKit
import Combine
import WebKit

enum LiveRange: String, Codable, CaseIterable, Identifiable {
    case today, week, month, open

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Active Today"
        case .week: return "This Week"
        case .month: return "This Month"
        case .open: return "All Open"
        }
    }

    var days: Int? {
        switch self {
        case .today: return 1
        case .week: return 7
        case .month: return 30
        case .open: return nil
        }
    }
}

struct LiveSource: Codable, Equatable {
    enum Kind: String, Codable {
        case feed, pullRequests, repository, issues, subscriptions, page, notifications, linear
    }

    var kind: Kind
    var address: String
    var range: LiveRange? = nil
    var lists: [PullList]? = nil
    var statuses: [String]? = nil
    var hidesDraftReviews: Bool? = nil

    var linearStatuses: [LinearStatus]? {
        guard kind == .linear, LinearAPI.List(address: address)?.choosesStatus == true else { return nil }
        let chosen = (statuses ?? []).compactMap(LinearStatus.init(rawValue:))
        return chosen.isEmpty ? LinearStatus.standard : LinearStatus.ordered(chosen)
    }

    var leftOut: [LinearStatus] {
        guard let shown = linearStatuses else { return [] }
        return LinearStatus.allCases.filter { !shown.contains($0) }
    }

    func leavesOut(_ item: LiveItem) -> Bool {
        guard let status = item.status.flatMap(LinearStatus.init(rawValue:)) else { return false }
        return leftOut.contains(status)
    }

    var pullLists: [PullList]? {
        guard kind == .pullRequests else { return nil }
        if let lists { return PullList.ordered(lists) }
        return address == LiveSource.pullRequests.address ? PullList.standard : nil
    }

    static let pullRequestsName = "PRs"
    static let oldPullRequestsNames: Set<String> = ["GitHub Pull Requests", "Pull Requests"]
    static let pullRequests = LiveSource(kind: .pullRequests, address: "https://github.com/pulls?q=is%3Aopen+is%3Apr+involves%3A%40me+archived%3Afalse")
    static let issues = LiveSource(kind: .issues, address: "https://github.com/issues?q=is%3Aopen+is%3Aissue+involves%3A%40me+archived%3Afalse")
    static let subscriptions = LiveSource(kind: .subscriptions, address: "https://www.youtube.com/feed/subscriptions")
    static let reviewRequests = LiveSource(kind: .pullRequests, address: "https://github.com/pulls?q=is%3Aopen+is%3Apr+review-requested%3A%40me+archived%3Afalse")
    static let myPullRequests = LiveSource(kind: .pullRequests, address: "https://github.com/pulls?q=is%3Aopen+is%3Apr+author%3A%40me+archived%3Afalse")
    static let assignedIssues = LiveSource(kind: .issues, address: "https://github.com/issues?q=is%3Aopen+is%3Aissue+assignee%3A%40me+archived%3Afalse")
    static let gitHubNotifications = LiveSource(kind: .notifications, address: "https://github.com/notifications")

    static func linear(_ list: LinearAPI.List, workspace: String? = nil) -> LiveSource {
        LiveSource(kind: .linear, address: LinearAPI.address(for: list, workspace: workspace))
    }

    var asksForReview: Bool {
        if let lists = pullLists { return lists.contains(where: \.asksForReview) }
        return service == .gitHub && GitHubAPI.search(for: URL(string: address))?.contains("review-requested:@me") == true
    }

    var leavesOutDraftReviews: Bool { hidesDraftReviews == true && asksForReview }

    func page(_ list: PullList) -> URL { list.page(hidingDrafts: leavesOutDraftReviews) }

    func shownWithoutDraftReviews(_ item: LiveItem) -> LiveItem? {
        guard leavesOutDraftReviews, item.label != PullState.merged, item.label != PullState.closed,
              item.draft == true || item.label == PullState.draft else { return item }
        guard pullLists != nil else { return nil }
        guard let on = item.on else { return item.list?.asksForReview == true ? nil : item }
        let rest = on.filter { !$0.asksForReview }
        guard let first = rest.first else { return nil }
        guard rest != on else { return item }
        var kept = item
        kept.on = rest
        if kept.list?.asksForReview != false { kept.list = first }
        if kept.label == PullList.reviewRequests.label || kept.label == PullList.teamReviews.label { kept.label = PullState.draft }
        return kept
    }

    private var withoutDrafts: URL? {
        guard var parts = URLComponents(string: address), let search = GitHubAPI.search(for: parts.url), !search.contains("draft:") else {
            return URL(string: address)
        }
        var pairs = (parts.percentEncodedQuery ?? "").split(separator: "&").map(String.init)
        guard let at = pairs.firstIndex(where: { $0.hasPrefix("q=") }) else { return URL(string: address) }
        pairs[at] += "+draft%3Afalse"
        parts.percentEncodedQuery = pairs.joined(separator: "&")
        return parts.url
    }

    var assignsToYou: Bool { kind == .linear && LinearAPI.List(address: address) == .assigned }

    var personal: Bool {
        if pullLists != nil || kind == .notifications || kind == .subscriptions || kind == .linear { return true }
        return address.contains("%40me") || address.contains("@me")
    }

    var hidesPrivate: Bool { service == .gitHub }

    var emptyWording: String {
        if !leftOut.isEmpty { return "No issues outside \(LinearStatus.words(leftOut))" }
        return nothingWording
    }

    var nothingWording: String {
        switch kind {
        case .pullRequests, .repository: return "No pull requests"
        case .issues, .linear: return "No issues"
        case .notifications: return "No notifications"
        case .subscriptions: return "No new videos"
        case .feed, .page: return LiveDrive.reads(self) ? "No recent files" : "Nothing new"
        }
    }

    var keepsFew: Bool { kind == .feed || kind == .subscriptions || kind == .page }
    var cap: Int { keepsFew ? 12 : 30 }

    var pattern: String? {
        switch kind {
        case .pullRequests, .repository: return #"^/[^/]+/[^/]+/pull/\d+/?$"#
        case .issues: return #"^/[^/]+/[^/]+/issues/\d+/?$"#
        case .notifications: return #"^/[^/]+/[^/]+/(pull|issues)/\d+/?$"#
        case .subscriptions: return #"^/watch$"#
        case .feed, .page, .linear: return nil
        }
    }

    func reading(at now: Date = Date(), zone: TimeZone = .current) -> URL? {
        if kind == .pullRequests, pullLists == nil, leavesOutDraftReviews { return withoutDrafts }
        guard kind == .repository, let days = range?.days, var parts = URLComponents(string: address) else {
            return URL(string: address)
        }
        parts.percentEncodedQuery = "q=is%3Apr+is%3Aopen+updated%3A%3E%3D\(LiveSource.escaped(LiveSource.since(days, now: now, zone: zone)))"
        return parts.url
    }

    static func since(_ days: Int, now: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(max(days, 1) - 1), to: today) ?? today
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = calendar
        format.timeZone = zone
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxxxx"
        return format.string(from: start)
    }

    enum Service { case gitHub, youTube, linear, drive, own }

    var host: String? { URL(string: address)?.host().map { Address.withoutWWW($0.lowercased()) } }

    var service: Service {
        switch host {
        case "github.com": return .gitHub
        case "youtube.com", "m.youtube.com": return .youTube
        case "linear.app": return .linear
        case "drive.google.com": return .drive
        default: return .own
        }
    }

    var siteName: String {
        switch service {
        case .gitHub: return "GitHub"
        case .youTube: return "YouTube"
        case .linear: return "Linear"
        case .drive: return "Google Drive"
        case .own: return host ?? "this site"
        }
    }

    func owns(_ url: URL) -> Bool {
        guard let mine = host, let landed = url.host().map({ Address.withoutWWW($0.lowercased()) }) else { return false }
        if service == .youTube { return landed == "youtube.com" || landed.hasSuffix(".youtube.com") }
        return landed == mine || landed.hasSuffix("." + mine)
    }

    func signsIn(at url: URL) -> Bool {
        guard owns(url), url.path() != reading()?.path() else { return false }
        return LiveSignOn.step(url)
    }

    func signInPage(at now: Date = Date()) -> URL? {
        guard let page = reading(at: now) else { return nil }
        switch service {
        case .gitHub:
            return URL(string: "https://github.com/login?return_to=\(Self.escaped(page.absoluteString))")
        case .youTube:
            var next = page.path().isEmpty ? "/" : page.path()
            if let query = page.query(percentEncoded: true) { next += "?" + query }
            let back = "https://www.youtube.com/signin?action_handle_signin=true&app=desktop&next=\(Self.escaped(next))"
            return URL(string: "https://accounts.google.com/ServiceLogin?service=youtube&uilel=3&passive=true&continue=\(Self.escaped(back))")
        case .linear, .drive, .own:
            return page
        }
    }

    private static let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func escaped(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: plain) ?? text
    }

    static func from(_ text: String) -> LiveSource? {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if let short = shorthand(typed.lowercased()) { return short }
        if !typed.contains("://"), typed.range(of: #"^[A-Za-z]+:(?![0-9])"#, options: .regularExpression) != nil { return nil }
        let pieces = typed.split(separator: "/")
        if pieces.count == 2, !typed.contains(":"), !typed.contains("."), !typed.contains(" ") {
            return LiveSource(kind: .repository, address: "https://github.com/\(typed)/pulls", range: .open)
        }
        let address = typed.contains("://") ? typed : "https://\(typed)"
        guard let url = URL(string: address), let host = url.host()?.lowercased() else {
            return address.hasPrefix("file:") ? LiveSource(kind: .feed, address: address) : nil
        }
        if host == "github.com" || host == "www.github.com" {
            let path = url.path().split(separator: "/").map(String.init)
            if path.first == "pulls" { return LiveSource(kind: .pullRequests, address: address) }
            if path.first == "notifications" { return .gitHubNotifications }
            if path.first == "issues" || path.count >= 3 && path[2] == "issues" { return LiveSource(kind: .issues, address: address) }
            if path.count >= 2 {
                return LiveSource(kind: .repository, address: "https://github.com/\(path[0])/\(path[1])/pulls", range: .open)
            }
        }
        if host.hasSuffix("youtube.com"), url.path().hasPrefix("/feed/subscriptions") { return .subscriptions }
        if host == "linear.app", LinearAPI.List(address: address) != nil { return LiveSource(kind: .linear, address: address) }
        return LiveSource(kind: .feed, address: address)
    }

    static func shorthand(_ typed: String) -> LiveSource? {
        switch typed {
        case "github:reviews", "gh:reviews": return .reviewRequests
        case "github:mine", "gh:mine", "github:pulls", "gh:pulls": return .myPullRequests
        case "github:issues", "gh:issues": return .assignedIssues
        case "github:notifications", "gh:notifications": return .gitHubNotifications
        case "linear:assigned", "linear:mine": return .linear(.assigned)
        case "linear:created": return .linear(.created)
        case "linear:inbox": return .linear(.inbox)
        case "linear:mentions": return .linear(.mentions)
        default:
            guard typed.hasPrefix("linear:cycle/") else { return nil }
            let team = typed.dropFirst("linear:cycle/".count)
            guard !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
            return .linear(.cycle(team.uppercased()))
        }
    }
}

enum LiveChecks: String, Codable {
    case passing, failing, pending
}

struct LiveStack: Codable, Equatable {
    var position: Int
    var count: Int

    var said: String { "\(position)/\(count)" }
    var spoken: String { "stack \(position) of \(count)" }
}

enum LiveStackRuns {
    static func tops(_ items: [LiveItem?]) -> [Int?] {
        func joined(_ a: LiveItem?, _ b: LiveItem?) -> Bool {
            guard let low = a?.stack, let high = b?.stack else { return false }
            return high.count == low.count && high.position == low.position - 1 && a?.branch?.repository == b?.branch?.repository
        }
        var out = [Int?](repeating: nil, count: items.count)
        var start = 0
        while start < items.count {
            var end = start
            while end + 1 < items.count, joined(items[end], items[end + 1]) { end += 1 }
            if end > start { for index in start...end { out[index] = start } }
            start = end + 1
        }
        return out
    }
}


struct LiveBranch: Codable, Equatable {
    var repository: String
    var base: String
    var head: String
    var stack: Int? = nil
    var position: Int? = nil
    var stackRead: Bool? = nil
}

enum LiveStacks {
    static func key(_ item: LiveItem) -> String? {
        guard let branch = item.branch, let stack = branch.stack, branch.position != nil else { return nil }
        return "\(branch.repository.lowercased())\u{0}\(stack)"
    }

    static func arranged(_ items: [LiveItem]) -> [LiveItem] {
        var stacks: [String: [Int]] = [:]
        for index in items.indices {
            guard let key = key(items[index]) else { continue }
            stacks[key, default: []].append(index)
        }
        for key in stacks.keys {
            stacks[key]?.sort { (items[$0].branch?.position ?? 0, $0) < (items[$1].branch?.position ?? 0, $1) }
        }
        var placed: Set<Int> = []
        var out: [LiveItem] = []
        for index in items.indices where !placed.contains(index) {
            guard let key = key(items[index]), let order = stacks[key], order.count > 1 else {
                placed.insert(index)
                var item = items[index]
                item.stack = nil
                out.append(item)
                continue
            }
            for (position, member) in order.enumerated().reversed() where placed.insert(member).inserted {
                var item = items[member]
                item.stack = LiveStack(position: position + 1, count: order.count)
                out.append(item)
            }
        }
        return out
    }
}

enum LiveStackWalk {
    static func below(_ identity: String, in items: [LiveItem]) -> [String] {
        guard let top = items.first(where: { LiveIdentity.of($0.key) == identity && $0.branch?.stack != nil && $0.branch?.position != nil })?.branch,
              let stack = top.stack, let position = top.position else { return [] }
        let repository = top.repository.lowercased()
        var found: [String: Int] = [:]
        for item in items {
            guard let branch = item.branch, branch.repository.lowercased() == repository, branch.stack == stack,
                  let at = branch.position, at < position else { continue }
            let lower = LiveIdentity.of(item.key)
            guard lower != identity, LiveIdentity.typed(lower) else { continue }
            if item.label == PullState.merged || item.label == PullState.closed {
                found[lower] = -1
            } else if found[lower] == nil {
                found[lower] = at
            }
        }
        return found.filter { $0.value > 0 }.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map(\.key)
    }
}

struct LiveItem: Codable, Equatable {
    var key: String
    var title: String
    var label: String? = nil
    var opened: Date? = nil
    var author: String? = nil
    var checks: LiveChecks? = nil
    var updated: Date? = nil
    var arrived: Date? = nil
    var list: PullList? = nil
    var activity: Date? = nil
    var noticed: Date? = nil
    var stack: LiveStack? = nil
    var branch: LiveBranch? = nil
    var draft: Bool? = nil
    var unanswered: Int? = nil
    var signsRead: Bool? = nil
    var pageRead: Date? = nil
    var status: String? = nil
    var on: [PullList]? = nil
    var back: Bool? = nil

    var fresh: Bool {
        guard let activity else { return false }
        return noticed.map { activity > $0 } ?? true
    }

    var who: String? {
        let parts = [author, stack?.said].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    var byline: String? {
        if let document = LiveDocuments.byline(self) { return document }
        let parts = [who, label].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    var spokenByline: String? {
        if let document = LiveDocuments.spoken(self) { return document }
        let parts = [author, stack?.spoken, label].compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

enum LiveIdentity {
    static let tracking: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid", "ref_src", "_hsenc", "_hsmi"]

    static func of(_ key: String) -> String {
        guard let url = URL(string: key), let host = url.host()?.lowercased() else { return key }
        let path = url.path().split(separator: "/").map(String.init)
        switch Address.withoutWWW(host) {
        case "github.com":
            if path.count >= 4, path[2] == "pull" || path[2] == "issues", Int(path[3]) != nil {
                return "github:\(path[0].lowercased())/\(path[1].lowercased())#\(path[3])"
            }
        case "linear.app":
            if let at = path.firstIndex(of: "issue"), path.count > at + 1 { return "linear:\(path[at + 1].uppercased())" }
        case "youtube.com", "m.youtube.com":
            if path == ["watch"], let video = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "v" })?.value, !video.isEmpty {
                return "youtube:\(video)"
            }
            if path.count == 2, path[0] == "shorts" || path[0] == "live" { return "youtube:\(path[1])" }
        case "youtu.be":
            if path.count == 1 { return "youtube:\(path[0])" }
        default:
            if let document = LiveDocuments.identity(url) { return document }
        }
        return plain(url) ?? key
    }

    static func typed(_ identity: String) -> Bool {
        identity.hasPrefix("github:") || identity.hasPrefix("linear:") || identity.hasPrefix("youtube:")
            || identity.hasPrefix("drive:") || identity.hasPrefix("notion:")
    }

    static func same(_ one: String, _ other: String) -> Bool { one == other || of(one) == of(other) }

    static func plain(_ url: URL) -> String? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = parts.host else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = Address.withoutWWW(host.lowercased())
        parts.fragment = nil
        if let items = parts.percentEncodedQueryItems {
            let kept = items.filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !tracking.contains(name)
            }
            parts.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        }
        if parts.percentEncodedPath.count > 1, parts.percentEncodedPath.hasSuffix("/") {
            parts.percentEncodedPath = String(parts.percentEncodedPath.dropLast())
        }
        return parts.string
    }
}

struct LiveDismissal: Equatable {
    var folder: UUID
    var item: LiveItem
    var at: Int
}

struct LiveClaim: Equatable {
    var token = UUID()
    var space: UUID
    var since: Date
    var rows: [LiveDismissal]
    var marked = false
    var confirmed = false
    var letGo = false
}

struct LiveSSO: Codable, Equatable {
    var org: String?
    var url: String
}

struct LiveFolder: Codable, Identifiable, Equatable {
    enum State: String, Codable {
        case waiting, fine, signIn, failed

        init(from decoder: Decoder) throws {
            self = State(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .waiting
        }
    }

    var id = UUID()
    var space: UUID
    var name: String
    var source: LiveSource
    var paused = false
    var state = State.waiting
    var items: [LiveItem] = []
    var hidden: [String] = []
    var hiddenMissing: [String: Date]? = nil
    var hiddenAt: [String: Date]? = nil
    var listsOn: [String: Date]? = nil
    var read: Date? = nil
    var noticing: Bool? = nil
    var sso: LiveSSO? = nil
    var order: [String]? = nil
    var notFeeds: Int? = nil
    var emptyFeeds: Int? = nil
    var good: Date? = nil
    var cause: String? = nil
    var limitedUntil: Date? = nil
    var limitWait: Double? = nil
    var more: String? = nil
    var noCycle: Bool? = nil

    var why: LiveCause? { state == .failed ? cause.flatMap(LiveCause.init(rawValue:)) : nil }

    var freshCount: Int { items.filter(\.fresh).count }

    func hides(_ key: String) -> Bool {
        let identity = LiveIdentity.of(key)
        return hidden.contains { LiveIdentity.of($0) == identity }
    }

    var hiddenInFeed: Int {
        Set(hidden.map(LiveIdentity.of)).filter { hiddenMissing?[$0] == nil }.count
    }

    enum Note: Equatable { case loading, signIn, sso(LiveSSO), failed, empty, paused }

    var note: Note? {
        if paused { return items.isEmpty ? .paused : nil }
        switch state {
        case .signIn: return sso.map(Note.sso) ?? .signIn
        case .failed: return .failed
        case .waiting: return items.isEmpty ? .loading : nil
        case .fine: return items.isEmpty ? .empty : nil
        }
    }

    var status: String? {
        if paused { return "Paused" }
        switch state {
        case .signIn: return sso == nil ? "Sign in" : "Single sign-on"
        case .failed:
            switch why {
            case .offline: return "Offline"
            case .limited: return "Limited"
            case .unread, .other, nil: return "Can't read"
            }
        case .waiting, .fine: return nil
        }
    }

    var emptyWording: String { noCycle == true ? "No active cycle" : source.emptyWording }

    var signInWords: String {
        guard let sso else { return "Sign in to \(source.siteName)" }
        return "Single sign-on for \(sso.org ?? source.siteName)"
    }

    var signInPage: URL? {
        if state == .signIn, let sso, let url = URL(string: sso.url) { return url }
        return source.signInPage()
    }
}

enum LiveSignOn {
    static let steps: Set<String> = ["login", "signin", "sign_in", "sign-in", "session", "sessions"]
    static let lasts: TimeInterval = 180
    static let retries = 2

    static func step(_ url: URL) -> Bool {
        let path = url.path().lowercased().split(separator: "/").map(String.init)
        guard let first = path.first else { return false }
        if steps.contains(first) { return true }
        if first == "users", path.count > 1, steps.contains(path[1]) { return true }
        return path.count > 2 && (first == "orgs" || first == "enterprises") && (path[2] == "sso" || path[2] == "saml")
    }
}

struct LiveArrival: Equatable {
    var from: URL?
    var type: WKNavigationType = .other
    var asked = false
    var redirected = false
    var opened = false

    static let signOnTab = LiveArrival(opened: true)

    func signsIn(to source: LiveSource) -> Bool {
        if opened { return true }
        guard let from, !asked, type != .backForward, type != .reload else { return false }
        let posted = type == .formSubmitted || type == .formResubmitted
        guard redirected || posted || type == .other else { return false }
        if source.owns(from) { return LiveSignOn.step(from) }
        return type != .linkActivated
    }
}

enum LiveSeen {
    static let hosts: Set<String> = ["github.com", "linear.app"]

    private static func parts(_ url: URL) -> (String, [String])? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased() else { return nil }
        return (Address.withoutWWW(host), url.path().split(separator: "/").map(String.init))
    }

    static func same(_ page: URL, as key: String) -> Bool {
        guard let key = URL(string: key), let (host, wanted) = parts(key), let (there, path) = parts(page), host == there,
              !wanted.isEmpty, path.count >= wanted.count || host == "linear.app" else { return false }
        if host == "linear.app", let issue = wanted.firstIndex(of: "issue"), wanted.indices.contains(issue + 1) {
            let head = Array(wanted.prefix(issue + 2)).map { $0.lowercased() }
            return path.count >= head.count && path.prefix(head.count).map { $0.lowercased() } == head
        }
        return path.prefix(wanted.count).map { $0.lowercased() } == wanted.map { $0.lowercased() }
    }
}

enum LiveMerge {
    static let gone: TimeInterval = 86_400

    static func merged(_ folder: LiveFolder, fetched: [LiveItem], now: Date = Date(), complete: Bool = true) -> LiveFolder {
        var next = folder
        var hidden: [String] = []
        for entry in folder.hidden.map(LiveIdentity.of) where !hidden.contains(entry) { hidden.append(entry) }
        let id = { (item: LiveItem) in LiveIdentity.of(item.key) }
        let opened = Dictionary(folder.items.compactMap { item in item.opened.map { (id(item), $0) } }, uniquingKeysWith: { a, _ in a })
        let arrived = Dictionary(folder.items.compactMap { item in item.arrived.map { (id(item), $0) } }, uniquingKeysWith: { a, _ in a })
        let known = Set(folder.items.map(id))
        let first = folder.items.isEmpty && folder.state != .fine
        let baseline = first || folder.noticing != true
        let noticed = Dictionary(folder.items.compactMap { item in item.noticed.map { (id(item), $0) } }, uniquingKeysWith: { a, _ in a })
        let unsigned = Set(folder.items.filter { $0.signsRead != true }.map(id))
        if folder.source.keepsFew {
            for (identity, date) in opened where now.timeIntervalSince(date) >= gone && !hidden.contains(identity) {
                hidden.append(identity)
            }
        }
        let signed = folder.source.kind == .pullRequests || folder.source.kind == .repository
        var removed = folder.hiddenAt ?? [:]
        if signed {
            for entry in hidden where removed[entry] == nil { removed[entry] = now }
            let returning = Set(fetched.compactMap { item -> String? in
                let identity = id(item)
                guard let activity = item.activity, let since = removed[identity], activity > since else { return nil }
                return identity
            })
            hidden.removeAll { returning.contains($0) }
        }
        let turnedOn = folder.listsOn ?? [:]
        let refused = Set(hidden)
        var seen = Set<String>()
        var items: [LiveItem] = []
        for var item in fetched where !refused.contains(id(item)) && !folder.source.leavesOut(item)
            && seen.insert(id(item)).inserted {
            let identity = id(item)
            item.opened = opened[identity]
            item.arrived = arrived[identity] ?? (first || known.contains(identity) ? nil : now)
            item.noticed = baseline ? item.activity : noticed[identity]
            if !baseline, item.noticed == nil, item.signsRead == true, unsigned.contains(identity),
               let activity = item.activity, let seen = opened[identity], seen >= activity {
                item.noticed = activity
            }
            if !baseline, item.noticed == nil, !known.contains(identity), let on = item.on, !on.isEmpty, let activity = item.activity {
                let since = on.compactMap { turnedOn[$0.rawValue] }
                if since.count == on.count, let first = since.min(), activity <= first { item.noticed = activity }
            }
            items.append(item)
        }
        if fetched.contains(where: { $0.stack != nil && refused.contains(LiveIdentity.of($0.key)) }) {
            items = LiveStacks.arranged(items)
        }
        var missing = folder.hiddenMissing ?? [:]
        if complete, !fetched.isEmpty {
            let present = Set(fetched.map { LiveIdentity.of($0.key) })
            for entry in hidden {
                if present.contains(entry) { missing[entry] = nil } else if missing[entry] == nil { missing[entry] = now }
            }
            hidden.removeAll { entry in missing[entry].map { now.timeIntervalSince($0) >= gone } ?? false }
        }
        hidden = Array(hidden.suffix(300))
        missing = missing.filter { hidden.contains($0.key) }
        removed = removed.filter { hidden.contains($0.key) }
        next.items = Array(items.prefix(folder.source.cap))
        next.hidden = hidden
        next.hiddenMissing = missing.isEmpty ? nil : missing
        if signed || folder.hiddenAt != nil { next.hiddenAt = removed.isEmpty ? nil : removed }
        next.state = .fine
        next.sso = nil
        next.read = now
        next.noticing = true
        return next
    }

    static func cuts(_ folder: LiveFolder, fetched: [LiveItem]) -> Bool {
        var seen = Set<String>()
        let shown = fetched.filter { item in
            let identity = LiveIdentity.of(item.key)
            return !folder.hides(item.key) && !folder.source.leavesOut(item) && seen.insert(identity).inserted
        }
        return shown.count > folder.source.cap
    }

    static func without(_ identity: String, in items: [LiveItem]) -> [LiveItem] {
        let stacked = items.contains { $0.stack != nil && LiveIdentity.of($0.key) == identity }
        let kept = items.filter { LiveIdentity.of($0.key) != identity }
        return stacked ? LiveStacks.arranged(kept) : kept
    }
}

@MainActor
@Observable
final class LiveFolders {
    static let shared = LiveFolders()
    @ObservationIgnored var every: @MainActor () -> TimeInterval = { Shared.prefs.liveEvery.interval }
    @ObservationIgnored private var paced: AnyCancellable?
    static let hold: TimeInterval = 1.6
    static let stagger: TimeInterval = 0.09
    static let settles: TimeInterval = 8

    private(set) var folders: [LiveFolder] = []
    private(set) var retired: Set<UUID> = []
    private(set) var reading: Set<UUID> = []
    private(set) var requested: Set<UUID> = []
    @ObservationIgnored var syncing = false
    @ObservationIgnored var signInGap: TimeInterval = 15
    @ObservationIgnored var mergedHold: TimeInterval = LiveFolders.hold
    static let pageHold: TimeInterval = 90
    @ObservationIgnored var saidHold: TimeInterval = LiveFolders.pageHold
    @ObservationIgnored var stackStagger: TimeInterval = LiveFolders.stagger
    @ObservationIgnored var settles: TimeInterval = LiveFolders.settles
    @ObservationIgnored private var turned: [String: (token: UUID, folders: Set<UUID>)] = [:]
    @ObservationIgnored private var claims: [String: LiveClaim] = [:]
    @ObservationIgnored private var trail: [String: [String]] = [:]
    @ObservationIgnored private var trailed: [String: CFTimeInterval] = [:]
    @ObservationIgnored private var departed: [UUID: Set<String>] = [:]
    @ObservationIgnored private var said: [String: (state: PullPageState, until: Date, folders: Set<UUID>)] = [:]
    @ObservationIgnored private var early: Set<UUID> = []
    @ObservationIgnored var reader: @MainActor (LiveFolder) async -> LiveReader.Answer = { await LiveReader.read($0) } {
        didSet { shared.forget() }
    }
    @ObservationIgnored private var again: Set<UUID> = []
    @ObservationIgnored private var held: [UUID: UUID] = [:]
    @ObservationIgnored private var began: [UUID: Date] = [:]
    @ObservationIgnored private var pauses: [UUID: Int] = [:]
    @ObservationIgnored private var reads: [UUID: Int] = [:]
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    @ObservationIgnored let shared = LiveShared()
    @ObservationIgnored private var signOns: [UUID: Date] = [:]
    @ObservationIgnored private var retries: [UUID: Int] = [:]
    @ObservationIgnored private var signOnTabs: [UUID: (folder: UUID, away: Bool)] = [:]
    @ObservationIgnored private var signedAt: [UUID: Date] = [:]
    @ObservationIgnored var signOnLasts: TimeInterval = LiveSignOn.lasts
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored var pointReader: @MainActor ([LiveTouch.Ask]) async -> [LiveItem] = { asks in
        Store.testing ? [] : await IntegrationReader.point(asks)
    }
    @ObservationIgnored var pageFetcher: @MainActor (LiveFolder) async -> LiveReader.PageFetch? = { await LiveReader.pageFetch($0) }
    @ObservationIgnored private var pageReading: Set<String> = []
    @ObservationIgnored var looking: @MainActor () -> Set<UUID>? = { LiveFolders.lookedAt() }
    @ObservationIgnored var idleness: @MainActor () -> TimeInterval = { LiveFolders.idleSeconds() }
    @ObservationIgnored var frontmost: @MainActor () -> Bool = { NSApp?.isActive ?? false }
    @ObservationIgnored private(set) var asleep: [String: Date] = [:]
    @ObservationIgnored private var actedReads: [UUID: Date] = [:]
    @ObservationIgnored private var locks: LiveLockWatch?
    private(set) var online = true
    private(set) var here: Date? = .distantPast
    @ObservationIgnored private var resigned: Date?
    @ObservationIgnored private var lastMoment: LiveMoment?
    @ObservationIgnored private var touched: [String: Date] = [:]
    @ObservationIgnored private var asked: [String: LiveTouch.Ask] = [:]
    @ObservationIgnored private var flushing: DispatchWorkItem?
    @ObservationIgnored private var pageAsks: [String: Date] = [:]
    @ObservationIgnored private var pageAsked: [String: Date] = [:]
    @ObservationIgnored private var pageReads: [UUID: Date] = [:]
    @ObservationIgnored private var pageSoon: [UUID: UUID] = [:]
    @ObservationIgnored private var watchers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private var path: UUID?
    @ObservationIgnored private(set) var foreign: [Data] = []
    @ObservationIgnored var foreignIDs: Set<UUID> = []
    @ObservationIgnored private var lastSaved: [LiveFolder]?
    var lost = false

    private static var file: URL { Store.file("live-folders.json") }

    private init() { load() }

    private func load() {
        guard !loaded else { return }
        loaded = true
        retired = Set((Store.settings.stringArray(forKey: LiveFolders.retiredKey) ?? []).compactMap(UUID.init(uuidString:)))
        guard let data = try? Data(contentsOf: LiveFolders.file) else {
            Store.settings.set(true, forKey: LiveFolders.againKey)
            return
        }
        guard let read = LiveFile.read(data, retiredKinds: LiveFolders.retiredKinds) else {
            Store.quarantine(LiveFolders.file)
            lost = true
            return
        }
        let saved = read.kept, gone = read.retired
        foreign = read.foreign
        foreignIDs = read.foreignIDs
        folders = LiveFolders.woken(saved)
        lastSaved = folders
        if !gone.isEmpty {
            retired.formUnion(gone)
            Store.settings.set(retired.map(\.uuidString).sorted(), forKey: LiveFolders.retiredKey)
            save()
        }
        if !Store.settings.bool(forKey: LiveFolders.namedKey) {
            Store.settings.set(true, forKey: LiveFolders.namedKey)
            let renamed = LiveFolders.renamed(saved)
            if renamed != saved {
                folders = renamed
                save()
            }
        }
        if !Store.settings.bool(forKey: LiveFolders.againKey) {
            Store.settings.set(true, forKey: LiveFolders.againKey)
            let moved = LiveFolders.reviewingAgain(folders)
            if moved != folders {
                folders = moved
                save()
            }
        }
    }

    static let namedKey = "live.prsNamed"
    static let againKey = "live.reviewAgain"
    static let retiredKey = "live.retired"
    static let retiredKinds: Set<String> = ["actions", "deployments", "mergeRequests"]

    static func sorted(_ data: Data) -> (kept: [LiveFolder], retired: [UUID])? {
        LiveFile.read(data, retiredKinds: retiredKinds).map { ($0.kept, $0.retired) }
    }


    static func woken(_ folders: [LiveFolder]) -> [LiveFolder] {
        folders.map { folder in
            var folder = folder
            if folder.good == nil, folder.state == .fine { folder.good = folder.read }
            if folder.state == .waiting { folder.read = nil }
            return folder
        }
    }

    static func reviewingAgain(_ folders: [LiveFolder], now: Date = Date()) -> [LiveFolder] {
        folders.map { folder in
            guard folder.source.kind == .pullRequests else { return folder }
            var folder = folder
            if let lists = folder.source.lists {
                guard Set(lists) == PullList.oldStandard else { return folder }
                folder.source.lists = PullList.ordered(lists + [.changed])
            } else if folder.source.address != LiveSource.pullRequests.address {
                return folder
            }
            var since = folder.listsOn ?? [:]
            since[PullList.changed.rawValue] = now
            folder.listsOn = since
            return folder
        }
    }

    static func renamed(_ folders: [LiveFolder]) -> [LiveFolder] {
        folders.map { folder in
            var folder = folder
            if folder.source.kind == .pullRequests, LiveSource.oldPullRequestsNames.contains(folder.name) {
                folder.name = LiveSource.pullRequestsName
            }
            return folder
        }
    }

    private func save() {
        guard folders != lastSaved else { return }
        lastSaved = folders
        let folders = folders, foreign = foreign
        Disk.write(LiveFolders.file) { LiveFile.written(folders, foreign: foreign) }
    }

    private func change(_ id: UUID, _ edit: (inout LiveFolder) -> Void) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        var folder = folders[index]
        edit(&folder)
        LiveOrder.keep(&folder)
        guard folder != folders[index] else { return }
        folders[index] = folder
        save()
    }

    func folder(_ id: UUID) -> LiveFolder? { folders.first { $0.id == id } }

    @discardableResult
    func add(name: String, source: LiveSource, space: UUID) -> LiveFolder {
        let made = LiveFolder(space: space, name: name, source: source)
        folders.append(made)
        save()
        if !Store.testing { update(made.id) }
        return made
    }

    func remove(_ id: UUID) {
        folders.removeAll { $0.id == id }
        departed[id] = nil
        held[id] = nil
        began[id] = nil
        signOns[id] = nil
        retries[id] = nil
        for (identity, turn) in turned where turn.folders.contains(id) {
            let left = turn.folders.subtracting([id])
            turned[identity] = left.isEmpty ? nil : (turn.token, left)
            if left.isEmpty { trail[identity] = nil }
        }
        for (identity, claim) in claims where claim.rows.contains(where: { $0.folder == id }) {
            let rows = claim.rows.filter { $0.folder != id }
            claims[identity] = rows.isEmpty ? nil : LiveClaim(token: claim.token, space: claim.space, since: claim.since, rows: rows,
                                                              marked: claim.marked, confirmed: claim.confirmed)
        }
        save()
    }

    func rename(_ id: UUID, to name: String) { change(id) { $0.name = name } }
    func pause(_ id: UUID, _ paused: Bool) {
        pauses[id, default: 0] += 1
        change(id) { $0.paused = paused }
    }

    func ticket(_ folder: LiveFolder) -> LiveReadTicket {
        LiveReadTicket(space: folder.space, source: folder.source, paused: pauses[folder.id] ?? 0, applied: reads[folder.id] ?? 0)
    }

    func settled(_ id: UUID) async {
        guard reading.contains(id) else { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    func readNow(_ id: UUID) async {
        if reading.contains(id) { return await settled(id) }
        guard let folder = begin(id) else { return }
        await read(folder)
    }

    private func finished(_ id: UUID) {
        reading.remove(id)
        requested.remove(id)
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }
    func move(_ id: UUID, to address: String) { change(id) { $0.source.address = address } }
    func setOrder(_ id: UUID, _ order: [String]?) { change(id) { $0.order = order } }

    func setLists(_ id: UUID, _ lists: [PullList], now: Date = Date()) {
        guard !lists.isEmpty else { return }
        change(id) { folder in
            let was = folder.source.pullLists ?? []
            folder.source.lists = PullList.ordered(lists)
            let on = folder.source.pullLists ?? []
            var since = (folder.listsOn ?? [:]).filter { key, _ in on.contains { $0.rawValue == key } }
            for list in on where !was.contains(list) && (folder.state == .fine || !folder.items.isEmpty) { since[list.rawValue] = now }
            folder.listsOn = since.isEmpty ? nil : since
        }
        update(id)
    }

    func setStatuses(_ id: UUID, _ statuses: [LinearStatus]) {
        guard !statuses.isEmpty, folder(id)?.source.linearStatuses != nil else { return }
        change(id) { folder in
            folder.source.statuses = LinearStatus.ordered(statuses).map(\.rawValue)
            folder.items = folder.items.filter { !folder.source.leavesOut($0) }
        }
        update(id)
    }

    func setHidesDraftReviews(_ id: UUID, _ hides: Bool) {
        guard let current = folder(id), current.source.asksForReview, current.source.leavesOutDraftReviews != hides else { return }
        change(id) { folder in
            folder.source.hidesDraftReviews = hides ? true : nil
            guard hides else { return }
            let kept = folder.items.compactMap { folder.source.shownWithoutDraftReviews($0) }
            folder.items = kept.contains(where: { $0.branch != nil }) ? LiveStacks.arranged(kept) : kept
        }
        update(id)
    }

    func setRange(_ id: UUID, _ range: LiveRange) {
        change(id) { $0.source.range = range }
        update(id)
    }

    @discardableResult
    func hide(_ key: String, in id: UUID, item: LiveItem? = nil) -> LiveDismissal? {
        guard let current = folder(id) else { return nil }
        let identity = LiveIdentity.of(key)
        let at = current.items.firstIndex { LiveIdentity.of($0.key) == identity }
        let made = LiveDismissal(folder: id, item: at.map { current.items[$0] } ?? item ?? LiveItem(key: key, title: key),
                                 at: at ?? current.items.count)
        change(id) { folder in
            folder.items = LiveMerge.without(identity, in: folder.items)
            if !folder.hides(key) { folder.hidden.append(identity) }
            folder.hiddenMissing?[identity] = nil
            if folder.source.kind == .pullRequests || folder.source.kind == .repository {
                var removed = folder.hiddenAt ?? [:]
                removed[identity] = Date()
                folder.hiddenAt = removed
            }
        }
        return made
    }

    func hide(_ key: String, space: UUID) {
        let identity = LiveIdentity.of(key)
        for folder in folders where folder.space == space && folder.items.contains(where: { LiveIdentity.of($0.key) == identity }) {
            hide(key, in: folder.id)
        }
    }

    @discardableResult
    func restore(_ dismissal: LiveDismissal) -> Bool {
        guard folder(dismissal.folder) != nil else { return false }
        let identity = LiveIdentity.of(dismissal.item.key)
        departed[dismissal.folder]?.remove(identity)
        change(dismissal.folder) { folder in
            folder.hidden.removeAll { LiveIdentity.of($0) == identity }
            folder.hiddenMissing?[identity] = nil
            if folder.hiddenMissing?.isEmpty == true { folder.hiddenMissing = nil }
            folder.hiddenAt?[identity] = nil
            if folder.hiddenAt?.isEmpty == true { folder.hiddenAt = nil }
            guard !folder.items.contains(where: { LiveIdentity.of($0.key) == identity }) else { return }
            var items = folder.items
            items.insert(dismissal.item, at: min(max(dismissal.at, 0), items.count))
            folder.items = items.contains(where: { $0.branch != nil }) ? LiveStacks.arranged(items) : items
        }
        return true
    }

    func showHidden(_ id: UUID) {
        departed[id] = nil
        change(id) { folder in
            folder.hidden = []
            folder.hiddenMissing = nil
            folder.hiddenAt = nil
        }
        update(id)
    }

    func opened(_ key: String, space: UUID? = nil, at date: Date = Date()) {
        let identity = LiveIdentity.of(key)
        for folder in folders where space == nil || folder.space == space {
            guard folder.items.contains(where: { LiveIdentity.of($0.key) == identity && ($0.opened == nil || $0.fresh) }) else { continue }
            change(folder.id) { folder in
                for index in folder.items.indices where LiveIdentity.of(folder.items[index].key) == identity {
                    if folder.items[index].opened == nil { folder.items[index].opened = date }
                    if let activity = folder.items[index].activity { folder.items[index].noticed = activity }
                }
            }
        }
    }

    func landed(_ url: URL, space: UUID, at date: Date = Date()) {
        guard let host = url.host()?.lowercased(), LiveSeen.hosts.contains(Address.withoutWWW(host)) else { return }
        var keys = Set<String>()
        for folder in folders where folder.space == space {
            for item in folder.items where (item.opened == nil || item.fresh) && LiveSeen.same(url, as: item.key) { keys.insert(item.key) }
        }
        for key in keys { opened(key, space: space, at: date) }
    }

    func apply(_ result: LiveReader.Answer, to id: UUID, now: Date = Date()) {
        reads[id, default: 0] += 1
        let before = folder(id)
        var begun: [(String, UUID)] = []
        let verdicts = judged(result, in: id)
        change(id) { folder in
            folder = LiveTrust.after(folder, result, now: now, online: online)
            guard let before else { return }
            folder.items = holding(folder.items, before: before.items, in: id)
            folder.items = keeping(folder.items, in: id, now: now)
            folder.items = withheld(folder.items, in: id, verdicts: verdicts)
            folder.items = fresher(folder.items, space: folder.space)
            let was = Dictionary(before.items.map { (LiveIdentity.of($0.key), $0.label) }, uniquingKeysWith: { a, _ in a })
            for item in folder.items where item.label == PullState.merged {
                let identity = LiveIdentity.of(item.key)
                guard let label = was[identity], label != PullState.merged else { continue }
                if let token = record(identity, in: [id]) { begun.append((identity, token)) }
            }
        }
        for (identity, token) in begun { hold(identity, token) }
        for (identity, verdict) in verdicts {
            switch verdict {
            case .merged: confirm(identity)
            case .gone: release(identity)
            case .still(let state, let fresh): refute(identity, state, fresh: [id: fresh])
            case .waiting: break
            }
        }
    }

    enum Verdict: Equatable {
        case merged, gone, waiting
        case still(PullPageState, LiveItem)
    }

    var claimed: Set<String> { Set(claims.filter { !$0.value.confirmed }.keys) }

    var rereads: Set<String> { claimed.union(pageAsks.keys) }

    func pageShown(_ url: URL, space: UUID, person: Bool = false, now: Date = Date()) {
        let identity = LiveIdentity.of(url.absoluteString)
        guard LiveIdentity.typed(identity) else { return }
        let near = folders.filter { folder in
            folder.space == space && !folder.paused && (folder.source.kind == .pullRequests || folder.source.kind == .repository)
        }
        let ids = near.filter { folder in folder.items.contains { LiveIdentity.of($0.key) == identity && LiveRefs.open($0) } }.map(\.id)
        if ids.isEmpty {
            guard person, PullPageRelay.pull(url), !LiveRefs.young(pageAsked[identity], at: now, within: LiveRefs.fresh),
                  !near.contains(where: { $0.items.contains { LiveIdentity.of($0.key) == identity } }) else { return }
            let own = near.filter { LiveFolders.listsOwn($0.source) }.map(\.id)
            guard !own.isEmpty else { return }
            pageAsked[identity] = now
            for id in own { readSoon(id, now: now) }
            return
        }
        guard !LiveRefs.young(pageAsked[identity], at: now, within: person ? LiveTouch.gap(.landed) : LiveRefs.fresh) else { return }
        pageAsked[identity] = now
        pageAsks[identity] = now
        for id in ids { readSoon(id, now: now) }
    }

    static func listsOwn(_ source: LiveSource) -> Bool {
        source.kind == .pullRequests && (source.pullLists ?? []).contains(where: \.own)
    }

    func keep(_ folder: LiveFolder) -> TimeInterval {
        max(LivePace.pace(folder, every: every()), LiveEvery.usual.interval) - LivePace.tick
    }

    private func fresher(_ items: [LiveItem], space: UUID) -> [LiveItem] {
        guard !LiveRefs.known.isEmpty else { return items }
        var restack = false
        let out = items.map { item -> LiveItem in
            guard LiveRefs.open(item), let known = LiveRefs.known[LiveRefs.slot(item.key, space: space)],
                  known.read > (item.pageRead ?? .distantPast), known.read != .distantPast else { return item }
            var next = item
            if let branch = known.branch { next.branch = branch }
            LiveRefs.signed(&next, known.signs)
            next.pageRead = known.read
            if next.branch?.stack != item.branch?.stack || next.branch?.position != item.branch?.position { restack = true }
            return next
        }
        return restack ? LiveStacks.arranged(out) : out
    }

    func readPages(_ asks: [LiveTouch.Ask], now: Date = Date()) async {
        for space in Set(asks.map(\.space)) {
            let wanted = Set(asks.filter { $0.space == space }.map { LiveIdentity.of($0.key) }).subtracting(pageReading)
            let near = folders.filter { $0.space == space && !$0.paused && LiveFolders.follows($0.source) }
            guard !wanted.isEmpty, let first = near.first(where: { folder in
                folder.items.contains { wanted.contains(LiveIdentity.of($0.key)) && LiveRefs.open($0) }
            }), let pages = await pageFetcher(first) else { continue }
            var rows: [LiveItem] = []
            var seen: Set<String> = []
            for folder in near {
                for item in folder.items where seen.insert(LiveIdentity.of(item.key)).inserted { rows.append(item) }
            }
            pageReading.formUnion(wanted)
            for identity in wanted where rows.contains(where: { LiveIdentity.of($0.key) == identity && LiveRefs.open($0) }) {
                pageAsks[identity] = max(pageAsks[identity] ?? .distantPast, now)
            }
            let read = await LiveRefs.filled(rows, previous: rows, space: space, host: pages.host, also: pages.also, at: now,
                                             again: wanted, only: true, fetch: pages.fetch)
            pageReading.subtract(wanted)
            pagesRead()
            let fresh = Dictionary(read.filter { $0.pageRead == now }.map { (LiveIdentity.of($0.key), $0) }, uniquingKeysWith: { first, _ in first })
            guard !fresh.isEmpty else { continue }
            for folder in folders where folder.space == space && LiveFolders.follows(folder.source) {
                change(folder.id) { folder in
                    var restack = false
                    let items = folder.items.map { row -> LiveItem in
                        let identity = LiveIdentity.of(row.key)
                        guard let new = fresh[identity] else { return row }
                        var next = row
                        if let branch = new.branch { next.branch = branch }
                        next.activity = new.activity
                        next.unanswered = new.unanswered
                        next.back = new.back
                        next.signsRead = new.signsRead
                        next.pageRead = new.pageRead
                        if wanted.contains(identity) { next.noticed = new.activity ?? row.noticed }
                        if next.branch?.stack != row.branch?.stack || next.branch?.position != row.branch?.position { restack = true }
                        return next
                    }
                    folder.items = restack ? LiveStacks.arranged(items) : items
                }
            }
            for (identity, item) in fresh where claims[identity] == nil && turned[identity] == nil {
                guard let known = LiveRefs.known[LiveRefs.slot(item.key, space: space)], let state = known.state,
                      state != .open || known.headed == true, let url = URL(string: item.key) else { continue }
                pageSays(state, at: url, space: space, now: now)
            }
        }
    }

    func pagesRead() {
        guard !pageAsks.isEmpty else { return }
        var read: [String: Date] = [:]
        for (slot, known) in LiveRefs.known {
            let identity = LiveRefs.identity(of: slot)
            guard pageAsks[identity] != nil else { continue }
            read[identity] = max(read[identity] ?? .distantPast, known.read)
        }
        pageAsks = pageAsks.filter { identity, asked in (read[identity] ?? .distantPast) < asked }
    }

    private func readSoon(_ id: UUID, now: Date) {
        let wait = pageReads[id].map { LiveTouch.reread - now.timeIntervalSince($0) } ?? 0
        guard wait > 0 else {
            pageReads[id] = now
            recheck(id, early: true)
            return
        }
        guard pageSoon[id] == nil else { return }
        let token = UUID()
        pageSoon[id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pageSoon[id] == token else { return }
                self.pageSoon[id] = nil
                self.pageReads[id] = Date()
                self.recheck(id, early: true)
            }
        }
    }

    func claimedRow(_ key: String) -> Bool { claims[LiveIdentity.of(key)] != nil }

    func leads(_ key: String) -> Bool { turning(key) && !claimedRow(key) }

    func followed(_ key: String) -> CFTimeInterval? { claims[LiveIdentity.of(key)] == nil ? nil : trailed[LiveIdentity.of(key)] }

    func explained(_ folder: LiveFolder) -> Set<String> {
        var out = Set(folder.hidden.map(LiveIdentity.of))
        out.formUnion(departed[folder.id] ?? [])
        out.formUnion(turned.keys)
        out.formUnion(claims.keys)
        for item in folder.items {
            let identity = LiveIdentity.of(item.key)
            if let state = LiveRefs.known[LiveRefs.slot(item.key, space: folder.space)]?.state, state == .merged || state == .closed {
                out.insert(identity)
            }
            if let word = said[identity], word.state == .merged || word.state == .closed { out.insert(identity) }
        }
        return out
    }

    private func judged(_ result: LiveReader.Answer, in id: UUID) -> [String: Verdict] {
        guard result.whole, let fetched = result.found else { return [:] }
        var out: [String: Verdict] = [:]
        for (identity, claim) in claims where !claim.confirmed && claim.rows.contains(where: { $0.folder == id }) {
            guard let item = fetched.first(where: { LiveIdentity.of($0.key) == identity }) else {
                out[identity] = .gone
                continue
            }
            if item.label == PullState.merged {
                out[identity] = .merged
            } else if let known = LiveRefs.known[LiveRefs.slot(item.key, space: claim.space)], known.read >= claim.since, let state = known.state,
                      state == .merged || known.read >= claim.since.addingTimeInterval(settles) {
                out[identity] = state == .merged ? .merged : .still(state, item)
            } else {
                out[identity] = .waiting
            }
        }
        return out
    }

    private func withheld(_ items: [LiveItem], in id: UUID, verdicts: [String: Verdict]) -> [LiveItem] {
        let away = Set(claims.filter { identity, claim in
            claim.marked && turned[identity] == nil && claim.rows.contains { $0.folder == id }
                && { if case .still = verdicts[identity] { return false } else { return true } }()
        }.keys)
        guard !away.isEmpty, items.contains(where: { away.contains(LiveIdentity.of($0.key)) }) else { return items }
        var out = items
        for identity in away { out = LiveMerge.without(identity, in: out) }
        return out
    }

    private func follow(_ identity: String, space: UUID, now: Date) {
        let near = folders.filter { $0.space == space && LiveFolders.follows($0.source) }
        let below = LiveStackWalk.below(identity, in: near.flatMap(\.items))
        var asked: Set<UUID> = []
        var step = 0
        var followers: [String] = []
        for lower in below where turned[lower] == nil {
            let rows = near.compactMap { folder -> LiveDismissal? in
                guard let at = folder.items.firstIndex(where: { LiveIdentity.of($0.key) == lower && $0.label != PullState.merged }) else { return nil }
                return LiveDismissal(folder: folder.id, item: folder.items[at], at: at)
            }
            guard !rows.isEmpty else { continue }
            let claim = LiveClaim(space: space, since: now, rows: rows)
            claims[lower] = claim
            trailed[lower] = CACurrentMediaTime()
            asked.formUnion(rows.map(\.folder))
            followers.append(lower)
            step += 1
            let wait = Motion.reduced ? 0 : stackStagger * Double(step)
            guard wait > 0 else {
                mark(lower, claim.token)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                MainActor.assumeIsolated { self?.mark(lower, claim.token) }
            }
        }
        if turned[identity] != nil, !followers.isEmpty { trail[identity, default: []].append(contentsOf: followers) }
        for id in asked { recheck(id, early: true) }
        guard !asked.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + settles + 1) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, followers.contains(where: { self.claims[$0].map { !$0.confirmed } ?? false }) else { return }
                for id in asked { self.recheck(id, early: true) }
            }
        }
    }

    private func release(_ identity: String) {
        guard var claim = claims[identity] else { return }
        guard claim.marked, turned[identity] == nil else {
            claim.letGo = true
            claims[identity] = claim
            return
        }
        claims[identity] = nil
    }

    private func mark(_ identity: String, _ token: UUID) {
        guard var claim = claims[identity], claim.token == token, !claim.marked else { return }
        let ids = Set(claim.rows.map(\.folder).filter { id in
            folder(id)?.items.contains { LiveIdentity.of($0.key) == identity && $0.label != PullState.merged } == true
        })
        guard !ids.isEmpty, turned[identity] == nil else {
            claims[identity] = nil
            return
        }
        claim.marked = true
        claims[identity] = claim
        turn(identity, in: ids, now: Date())
    }

    private func confirm(_ identity: String) {
        guard var claim = claims[identity] else { return }
        guard claim.marked, turned[identity] == nil else {
            claim.confirmed = true
            claims[identity] = claim
            return
        }
        claims[identity] = nil
        for row in claim.rows where folder(row.folder) != nil {
            change(row.folder) { folder in
                folder.items = LiveMerge.without(identity, in: folder.items)
                if !folder.hides(identity) { folder.hidden.append(identity) }
                if folder.hiddenAt != nil, folder.hiddenAt?[identity] == nil { folder.hiddenAt?[identity] = Date() }
            }
        }
    }

    private func refute(_ identity: String, _ state: PullPageState, fresh: [UUID: LiveItem] = [:]) {
        guard let claim = claims.removeValue(forKey: identity) else { return }
        turned[identity] = nil
        for row in claim.rows where folder(row.folder) != nil {
            departed[row.folder]?.remove(identity)
            change(row.folder) { folder in
                var back = LiveFolders.told(fresh[row.folder] ?? row.item, state)
                back.arrived = row.item.arrived
                back.opened = row.item.opened
                back.noticed = row.item.noticed
                var items = folder.items
                if let at = items.firstIndex(where: { LiveIdentity.of($0.key) == identity }) {
                    items[at] = back
                } else {
                    items.insert(back, at: min(max(row.at, 0), items.count))
                }
                folder.items = items.contains { $0.branch?.stack != nil } ? LiveStacks.arranged(items) : items
            }
        }
    }

    func turning(_ key: String) -> Bool { turned[LiveIdentity.of(key)] != nil }

    func departed(_ key: String, from id: UUID) -> Bool { departed[id]?.contains(LiveIdentity.of(key)) == true }

    func pageMerged(_ url: URL, space: UUID, now: Date = Date()) {
        let identity = LiveIdentity.of(url.absoluteString)
        guard LiveIdentity.typed(identity) else { return }
        if claims[identity] != nil { confirm(identity) }
        let ids = folders.filter { folder in
            folder.space == space && folder.items.contains { LiveIdentity.of($0.key) == identity && $0.label != PullState.merged }
        }.map(\.id)
        turn(identity, in: Set(ids), now: now)
        follow(identity, space: space, now: now)
    }

    func pageSays(_ state: PullPageState, at url: URL, space: UUID, now: Date = Date()) {
        guard state != .merged else { return pageMerged(url, space: space, now: now) }
        let identity = LiveIdentity.of(url.absoluteString)
        if claims[identity] != nil { refute(identity, state) }
        guard LiveIdentity.typed(identity), turned[identity] == nil else { return }
        said = said.filter { $0.value.until > now }
        let ids = folders.filter { folder in
            folder.space == space && LiveFolders.follows(folder.source)
                && folder.items.contains { LiveIdentity.of($0.key) == identity && $0.label != PullState.merged && LiveFolders.shows($0) != state }
        }.map(\.id)
        guard !ids.isEmpty else { return }
        for id in ids {
            change(id) { folder in
                folder.items = folder.items.map { LiveIdentity.of($0.key) == identity ? LiveFolders.told($0, state) : $0 }
            }
        }
        let kept = said[identity].flatMap { $0.state == state ? $0.folders : nil } ?? []
        said[identity] = (state, now.addingTimeInterval(saidHold), kept.union(ids))
        for id in ids { recheck(id, early: true) }
    }

    static func follows(_ source: LiveSource) -> Bool {
        source.kind == .pullRequests || source.kind == .repository
    }

    static func shows(_ item: LiveItem) -> PullPageState {
        if item.label == PullState.merged { return .merged }
        if item.label == PullState.closed { return .closed }
        if item.draft == true || item.label == PullState.draft { return .draft }
        return .open
    }

    static func told(_ item: LiveItem, _ state: PullPageState) -> LiveItem {
        var item = item
        switch state {
        case .merged:
            item.label = PullState.merged
            item.draft = nil
        case .closed:
            item.label = PullState.closed
            item.draft = nil
        case .open:
            item.draft = nil
            if [PullState.draft, PullState.closed, PullState.merged].contains(item.label) { item.label = nil }
        case .draft:
            item.draft = true
            if item.label == PullState.closed || PullState.rank(item.label) > PullState.rank(PullState.draft) { item.label = PullState.draft }
        }
        return item
    }

    private func keeping(_ items: [LiveItem], in id: UUID, now: Date) -> [LiveItem] {
        let words = said.filter { $0.value.folders.contains(id) && $0.value.until > now && turned[$0.key] == nil }
        guard !words.isEmpty else { return items }
        return items.map { item in
            guard let word = words[LiveIdentity.of(item.key)], item.label != PullState.merged,
                  LiveFolders.shows(item) != word.state else { return item }
            return LiveFolders.told(item, word.state)
        }
    }

    private func turn(_ identity: String, in ids: Set<UUID>, now: Date) {
        guard !ids.isEmpty else { return }
        let token = record(identity, in: ids)
        for id in ids {
            change(id) { folder in folder.items = LiveFolders.marked(folder.items, identity) }
        }
        if let token { hold(identity, token) }
    }

    private func record(_ identity: String, in ids: Set<UUID>) -> UUID? {
        if let turn = turned[identity] {
            turned[identity] = (turn.token, turn.folders.union(ids))
            return nil
        }
        let token = UUID()
        turned[identity] = (token, ids)
        return token
    }

    private func hold(_ identity: String, _ token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + mergedHold) { [weak self] in
            MainActor.assumeIsolated { self?.leave(identity, turn: token) }
        }
    }

    private func leave(_ identity: String, turn token: UUID) {
        guard turned[identity]?.token == token, let turn = turned.removeValue(forKey: identity) else { return }
        trailed[identity] = nil
        let pending = claims[identity].map { !$0.confirmed } ?? false
        if !pending || claims[identity]?.letGo == true { claims[identity] = nil }
        for id in turn.folders where folder(id) != nil {
            departed[id, default: []].insert(identity)
            if pending {
                change(id) { $0.items = LiveMerge.without(identity, in: $0.items) }
            } else {
                hide(identity, in: id)
            }
        }
        for lower in trail.removeValue(forKey: identity) ?? [] {
            if let follower = turned[lower]?.token { leave(lower, turn: follower) }
        }
    }

    private func holding(_ items: [LiveItem], before: [LiveItem], in id: UUID) -> [LiveItem] {
        let held = Set(turned.filter { $0.value.folders.contains(id) }.keys)
        guard !held.isEmpty else { return items }
        var out = items
        for (index, item) in before.enumerated() where held.contains(LiveIdentity.of(item.key)) {
            guard !out.contains(where: { LiveIdentity.of($0.key) == LiveIdentity.of(item.key) }) else { continue }
            out.insert(item, at: min(index, out.count))
        }
        for identity in held { out = LiveFolders.marked(out, identity) }
        return out
    }

    static func marked(_ items: [LiveItem], _ identity: String) -> [LiveItem] {
        items.map { item in
            guard LiveIdentity.of(item.key) == identity else { return item }
            var item = item
            item.label = PullState.merged
            item.draft = nil
            return item
        }
    }

    func forget(_ id: UUID) {
        change(id) { folder in
            folder.items = []
            folder.state = .waiting
            folder.sso = nil
            folder.read = nil
            folder.good = nil
            folder.cause = nil
            folder.limitedUntil = nil
            folder.limitWait = nil
            folder.notFeeds = nil
            folder.emptyFeeds = nil
        }
    }

    func benchHere(_ since: Date?) {
        guard Store.testing, here != since else { return }
        here = since
    }

    func benchAged(_ id: UUID, by seconds: TimeInterval) {
        guard Store.testing, let index = folders.firstIndex(where: { $0.id == id }), let good = folders[index].good else { return }
        folders[index].good = good.addingTimeInterval(-seconds)
    }

    func benchAsked(_ id: UUID, for seconds: TimeInterval) {
        guard Store.testing, folder(id) != nil else { return }
        requested.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { if self?.reading.contains(id) == false { self?.requested.remove(id) } }
        }
    }

    func update(_ id: UUID, asked: Bool = false) {
        let folder = begin(id)
        if asked, reading.contains(id) { requested.insert(id) }
        guard let folder else { return }
        Task { await read(folder) }
    }

    func updateAll() {
        round(folders.filter { !$0.paused }.map(\.id))
    }

    func round(_ ids: [UUID]) {
        for id in ids where !reading.contains(id) { update(id) }
    }

    func moment(at now: Date = Date()) -> LiveMoment {
        let active = frontmost()
        let idle = idleness()
        if active { resigned = nil } else if resigned == nil { resigned = now }
        asleep = asleep.filter { !LivePace.woke(since: $0.value, idle: idle, now: now) }
        return LiveMoment(active: active, away: LivePace.away(active: active, idle: idle, resigned: resigned, now: now),
                          asleep: !asleep.isEmpty, online: online, idle: idle)
    }

    @discardableResult
    func tick(at now: Date = Date()) -> [UUID] {
        let current = moment(at: now)
        if !LivePace.attended(current) {
            if here != nil { here = nil }
        } else if here == nil {
            here = now
        }
        let back = LivePace.returned(from: lastMoment, to: current)
        let looked = looking()
        if !back || looked?.isEmpty != true { lastMoment = current }
        let wanted = LivePace.wanted(folders, moment: current, looked: looked, returned: back, now: now, every: every())
            .filter { !signingOn($0, at: now) && held[$0] == nil }
        round(wanted)
        return wanted
    }

    static let awayFromApp = "app"

    func wentAway(_ reason: String, at now: Date = Date()) {
        if reason == LiveFolders.awayFromApp { resigned = resigned ?? now } else { asleep[reason] = now }
        lastMoment = moment(at: now)
    }

    func cameBack(from reason: String, at now: Date = Date()) {
        if reason == LiveFolders.awayFromApp { resigned = nil } else { asleep[reason] = nil }
        tick(at: now)
    }

    func network(_ up: Bool, at now: Date = Date()) {
        guard up != online else { return }
        online = up
        if up { tick(at: now) } else { lastMoment = moment(at: now) }
    }

    static func lookedAt() -> Set<UUID>? {
        let seen = Browsers.all.filter { !$0.isPopup && $0.windowSeen }
        return Set(seen.map(\.spaceID))
    }

    static func idleSeconds() -> TimeInterval {
        guard let any = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
    }

    func touch(_ url: URL, space: UUID, cause: LiveTouch.Cause, agent: Bool = false, now: Date = Date()) {
        let identity = LiveIdentity.of(url.absoluteString)
        guard LiveIdentity.typed(identity) else { return }
        let matches = folders.filter { $0.space == space && !$0.paused && LiveTouch.follows($0.source) }.compactMap { folder in
            folder.items.first { LiveIdentity.of($0.key) == identity }.map { (folder.id, $0.key) }
        }
        guard let key = matches.first?.1 else { return }
        if cause == .acted {
            guard idleness() < LiveTouch.handsOn else { return }
            for (id, _) in matches where LiveTouch.rereads(last: actedReads[id], now: now) {
                actedReads[id] = now
                recheck(id, early: true)
            }
        }
        guard !(agent && PullPageRelay.pull(url)), LiveTouch.wanted(cause, last: touched[identity], now: now) else { return }
        touched[identity] = now
        asked[identity] = LiveTouch.Ask(key: key, space: space)
        flushing?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.flush() }
            }
        }
        flushing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + LiveTouch.settle(cause), execute: work)
    }

    var asking: [LiveTouch.Ask] { Array(asked.values) }

    func resetPace() {
        flushing?.cancel()
        flushing = nil
        asked = [:]
        touched = [:]
        actedReads = [:]
        pageAsks = [:]
        pageAsked = [:]
        pageReads = [:]
        pageSoon = [:]
        pageReading = []
        asleep = [:]
        if here != .distantPast { here = .distantPast }
        online = true
        resigned = nil
        lastMoment = nil
    }

    func flush(at now: Date = Date()) async {
        flushing?.cancel()
        flushing = nil
        let asks = Array(asked.values)
        asked = [:]
        guard !asks.isEmpty else { return }
        let fresh = await pointReader(asks)
        refreshed(fresh, asks: asks, now: now)
        let pulls = asks.filter { URL(string: $0.key).map(PullPageRelay.pull) ?? false }
        if !pulls.isEmpty { await readPages(pulls, now: Date()) }
    }

    func refreshed(_ fresh: [LiveItem], asks: [LiveTouch.Ask], now: Date = Date()) {
        for item in fresh {
            let identity = LiveIdentity.of(item.key)
            guard let ask = asks.first(where: { LiveIdentity.of($0.key) == identity }) else { continue }
            if let url = URL(string: item.key), PullPageRelay.pull(url) {
                if claims[identity] != nil, LiveFolders.shows(item) != .merged { refute(identity, LiveFolders.shows(item)) }
                guard turned[identity] == nil else { continue }
                let state = LiveFolders.shows(item)
                if state == .merged {
                    pageMerged(url, space: ask.space, now: now)
                    continue
                }
                if said[identity].map({ $0.until <= now }) ?? true { pageSays(state, at: url, space: ask.space, now: now) }
            }
            let ids = folders.filter { folder in
                folder.space == ask.space && LiveTouch.follows(folder.source) && folder.items.contains { LiveIdentity.of($0.key) == identity }
            }.map(\.id)
            for id in ids {
                var moved = false
                var restack = false
                change(id) { folder in
                    var items = folder.items.map { row in
                        guard LiveIdentity.of(row.key) == identity else { return row }
                        let next = LiveTouch.patched(row, with: item, in: folder.source)
                        if next.label != row.label || next.draft != row.draft { moved = true }
                        if next.branch?.stack != row.branch?.stack || next.branch?.position != row.branch?.position { restack = true }
                        return next
                    }
                    items = keeping(items, in: id, now: now).filter { !folder.source.leavesOut($0) }
                    if restack { items = LiveStacks.arranged(items) }
                    folder.items = items
                }
                if moved { recheck(id, early: true) }
            }
        }
    }

    private func begin(_ id: UUID) -> LiveFolder? {
        guard !reading.contains(id), let folder = folder(id) else { return nil }
        reading.insert(id)
        began[id] = Date()
        return folder
    }

    private func read(_ folder: LiveFolder) async {
        let start = Date()
        began[folder.id] = start
        let asked = ticket(folder)
        let answer = await shared.answer(folder, reader: reader)
        guard let current = self.folder(folder.id) else {
            again.remove(folder.id)
            early.remove(folder.id)
            finished(folder.id)
            return
        }
        guard asked.holds(ticket(current), paused: current.paused) else {
            again.remove(folder.id)
            early.remove(folder.id)
            finished(folder.id)
            if !current.paused, current.source != folder.source || current.space != folder.space { update(folder.id) }
            return
        }
        let before = signedAt[folder.id].map { start < $0 } ?? false
        if !(before && again.contains(folder.id) && LiveFolders.asks(answer)) { apply(answer, to: folder.id) }
        if !before { signedAt[folder.id] = nil }
        finished(folder.id)
        let waiting = self.folder(folder.id)?.state == .signIn
        if !waiting {
            signOns[folder.id] = nil
            retries[folder.id] = nil
        }
        if again.remove(folder.id) != nil {
            recheck(folder.id, early: early.remove(folder.id) != nil)
        } else if waiting, let left = retries[folder.id] {
            retries[folder.id] = left > 1 ? left - 1 : nil
            recheck(folder.id)
        }
    }

    static func asks(_ answer: LiveReader.Answer) -> Bool {
        switch answer {
        case .signIn, .sso: return true
        case .items, .failed, .read, .missed: return false
        }
    }

    func signInMayBeOver(_ id: UUID, at now: Date = Date()) {
        guard let folder = folder(id), folder.state == .signIn, !folder.paused else { return }
        if signingOn(id, at: now) { retries[id] = LiveSignOn.retries }
        signedAt[id] = now
        change(id) { folder in
            folder.state = .waiting
            folder.sso = nil
        }
        held[id] = nil
        recheck(id, early: true)
    }

    func signOnTab(_ tab: UUID, for id: UUID, at page: URL) {
        guard let folder = folder(id) else { return }
        signOnTabs[tab] = (id, !folder.source.owns(page) || LiveSignOn.step(page))
    }

    func signOnTab(_ tab: UUID, at url: URL) {
        guard let (id, away) = signOnTabs[tab] else { return }
        guard let folder = folder(id), folder.state == .signIn else {
            signOnTabs[tab] = nil
            return
        }
        if !folder.source.owns(url) || folder.source.signsIn(at: url) || LiveSignOn.step(url) {
            signOnTabs[tab] = (id, true)
            return
        }
        guard away else { return }
        signOnTabs[tab] = nil
        signInMayBeOver(id)
    }

    func opened(_ tab: UUID) -> Bool { signOnTabs[tab] != nil }

    func signOnTabClosed(_ tab: UUID) {
        guard let (id, _) = signOnTabs.removeValue(forKey: tab) else { return }
        signInMayBeOver(id)
    }

    func signingOn(_ id: UUID, at now: Date = Date()) -> Bool {
        guard let since = signOns[id], folder(id)?.state == .signIn else { return false }
        return since > now || now.timeIntervalSince(since) < signOnLasts
    }

    func signOnBegan(_ id: UUID, at now: Date = Date()) {
        guard let folder = folder(id), folder.state == .signIn, !folder.paused else { return }
        signOns[id] = now
        retries[id] = nil
        held[id] = nil
        again.remove(id)
    }

    func signInPressed(_ id: UUID, at now: Date = Date()) {
        guard let folder = folder(id), let page = folder.signInPage else { return }
        if folder.source.signsIn(at: page) || !folder.source.owns(page) { signOnBegan(id, at: now) }
    }

    func cameBack(to url: URL? = nil, space: UUID? = nil, through arrival: LiveArrival? = nil, at now: Date = Date()) {
        for folder in folders where folder.state == .signIn && !folder.paused && (space == nil || url == nil || folder.space == space) {
            if let url {
                if folder.source.signsIn(at: url) {
                    signOnBegan(folder.id, at: now)
                    continue
                }
                guard folder.source.owns(url) else { continue }
                if arrival?.signsIn(to: folder.source) == true {
                    signInMayBeOver(folder.id, at: now)
                    continue
                }
            }
            if !signingOn(folder.id, at: now) { recheck(folder.id) }
        }
    }

    private func recheck(_ id: UUID, early soon: Bool = false) {
        guard let folder = folder(id), soon || folder.state == .signIn, !folder.paused, !LiveLimit.holds(folder, at: Date()) else { return }
        if reading.contains(id) {
            again.insert(id)
            if soon { early.insert(id) }
            return
        }
        let wait = (began[id] ?? folder.read).map { signInGap - Date().timeIntervalSince($0) } ?? 0
        guard wait > 0 else {
            update(id)
            return
        }
        guard held[id] == nil else { return }
        let token = UUID()
        held[id] = token
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.held[id] == token else { return }
                self.held[id] = nil
                self.recheck(id, early: soon)
            }
        }
    }

    var running: Bool { timer != nil }

    func run(_ on: Bool, testing: Bool = Store.testing) {
        guard !testing, on != running else { return }
        timer?.invalidate()
        timer = nil
        unwatch()
        paced = nil
        guard on else { return }
        watch()
        tick()
        paced = kitObserve(initial: false, distinct: true, { Shared.prefs.liveEvery }) { [weak self] _ in _ = self?.tick() }
        let made = Timer(timeInterval: LivePace.tick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.tick() }
        }
        made.tolerance = 15
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    private func watch() {
        let center = NotificationCenter.default
        let desk = NSWorkspace.shared.notificationCenter
        let away: [(NotificationCenter, Notification.Name, String)] = [
            (center, NSApplication.didResignActiveNotification, LiveFolders.awayFromApp),
            (desk, NSWorkspace.willSleepNotification, "sleep"),
            (desk, NSWorkspace.screensDidSleepNotification, "screen"),
            (desk, NSWorkspace.sessionDidResignActiveNotification, "session"),
        ]
        let back: [(NotificationCenter, Notification.Name, String)] = [
            (center, NSApplication.didBecomeActiveNotification, LiveFolders.awayFromApp),
            (desk, NSWorkspace.didWakeNotification, "sleep"),
            (desk, NSWorkspace.screensDidWakeNotification, "screen"),
            (desk, NSWorkspace.sessionDidBecomeActiveNotification, "session"),
        ]
        for (hub, name, reason) in away {
            watchers.append((hub, hub.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wentAway(reason) }
            }))
        }
        for (hub, name, reason) in back {
            watchers.append((hub, hub.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cameBack(from: reason) }
            }))
        }
        locks = LiveLockWatch { [weak self] locked in
            if locked { self?.wentAway("lock") } else { self?.cameBack(from: "lock") }
        }
        path = NetworkPath.shared.listen { [weak self] up, _ in self?.network(up) }
    }

    private func unwatch() {
        for (hub, token) in watchers { hub.removeObserver(token) }
        watchers = []
        locks?.stop()
        locks = nil
        NetworkPath.shared.stopListening(path)
        path = nil
    }
}

extension Browser {
    func watchLiveFolders() -> [AnyObject] {
        let live = LiveFolders.shared
        let prefs = prefs
        let folders = kitObserve(initial: false, { [weak live] in live?.folders }) { [weak self] _ in self?.syncLive() }
        let turned = kitObserve(initial: false, { [weak prefs] in prefs?.liveFolders ?? false }) { [weak self] on in
            live.run(on)
            self?.syncLive()
        }
        let moved = kitObserve(initial: false, { [weak self] in (self?.spaceID, prefs.usesTabGroups) }) { [weak self] _ in
            self?.syncLive()
            if prefs.liveFolders { live.tick() }
        }
        RunLoop.main.perform { [weak self, weak prefs] in
            MainActor.assumeIsolated {
                if let prefs { live.run(prefs.liveFolders) }
                self?.syncLive()
            }
        }
        let back = NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, prefs.liveFolders, !isPopup else { return }
                live.cameBack()
                live.tick()
                considerLiveOffer()
            }
        return [folders, turned, moved, back, watchLiveOffers()]
    }

    var windowSeen: Bool {
        if let sightForBench { return sightForBench }
        guard let window else { return false }
        return window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
    }

    func livePullState(_ tab: Tab, at url: URL, said state: PullPageState) {
        guard prefs.liveFolders, !tab.shy, !isPopup else { return }
        LiveFolders.shared.pageSays(state, at: url, space: spaceID)
    }

    func livePullShown(_ tab: Tab) {
        guard prefs.liveFolders, !tab.shy, !isPopup, let url = tab.address else { return }
        liveTouch(tab, at: url, .shown)
        livePullAsk(tab, at: url)
        guard let web = tab.built, PullPageRelay.pull(url) else { return }
        web.evaluateInSearch(PullPageRelay.again)
    }

    func livePullAsk(_ tab: Tab, at url: URL, person: Bool = false) {
        guard prefs.liveFolders, !tab.shy, !isPopup, !tab.agent, tab.id == activeID, PullPageRelay.pull(url) else { return }
        LiveFolders.shared.pageShown(url, space: spaceID, person: person)
    }

    func liveTouch(_ tab: Tab, at url: URL, _ cause: LiveTouch.Cause) {
        guard prefs.liveFolders, !tab.shy, !isPopup, tab.id == activeID, windowSeen, NSApp.isActive else { return }
        LiveFolders.shared.touch(url, space: spaceID, cause: cause, agent: tab.agent)
    }

    func liveTabLanded(_ tab: Tab, at url: URL) {
        guard prefs.liveFolders, !tab.shy, !isPopup else { return }
        liveTouch(tab, at: url, .landed)
        liveSeen(tab, at: url)
        livePullAsk(tab, at: url, person: true)
        guard !tab.bench else { return }
        let arrival = LiveFolders.shared.opened(tab.id) ? .signOnTab : tab.arrival
        LiveFolders.shared.signOnTab(tab.id, at: url)
        LiveFolders.shared.cameBack(to: url, space: spaceID, through: arrival)
    }

    func liveMoved(_ tab: Tab, at url: URL) {
        liveTouch(tab, at: url, .moved)
        guard prefs.liveFolders, !tab.shy, !isPopup else { return }
        LiveFolders.shared.signOnTab(tab.id, at: url)
        liveSeen(tab, at: url)
        livePullAsk(tab, at: url, person: true)
    }

    func liveSeen(_ tab: Tab, at url: URL) {
        guard tab.id == activeID, windowSeen, !tab.agent, !tab.agentSteeredLately else { return }
        LiveFolders.shared.landed(url, space: spaceID)
    }

    func retireLive(_ retired: Set<UUID>) -> Bool {
        let ids = Set(tabGroups.filter { $0.live && retired.contains($0.id) }.map(\.id))
        guard !ids.isEmpty else { return false }
        tabGroups = tabGroups.map { group in
            guard ids.contains(group.id) else { return group }
            var group = group
            group.live = false
            group.held = false
            return group
        }
        for tab in tabs where tab.groupID.map(ids.contains) == true {
            tab.liveKey = nil
            tab.liveItem = nil
        }
        return true
    }

    func syncLive() {
        guard !isPopup else { return }
        let live = LiveFolders.shared
        var changed = retireLive(live.retired)
        let asked = prefs.liveFolders && prefs.usesTabGroups ? live.folders.filter { $0.space == spaceID } : []
        let liveIDs = Set(tabGroups.filter(\.live).map(\.id))
        for tab in tabs where tab.liveKey != nil && !(tab.groupID.map(liveIDs.contains) ?? false) && liveIDs.count + asked.count > 0 {
            if let key = tab.liveKey { live.hide(key, space: spaceID) }
            tab.liveKey = nil
            tab.liveItem = nil
        }
        let wanted = prefs.liveFolders && prefs.usesTabGroups ? live.folders.filter { $0.space == spaceID } : []
        live.syncing = true
        defer { live.syncing = false }
        for group in tabGroups where group.live && !wanted.contains(where: { $0.id == group.id }) {
            if live.foreignIDs.contains(group.id) { continue }
            if let index = tabGroups.firstIndex(where: { $0.id == group.id }) { tabGroups[index].held = false }
            if live.lost, !live.folders.contains(where: { $0.id == group.id }), let index = tabGroups.firstIndex(where: { $0.id == group.id }) {
                tabGroups[index].live = false
                for tab in tabs where tab.groupID == group.id {
                    tab.liveKey = nil
                    tab.liveItem = nil
                    tab.leads = false
                    tab.arrives = false
                }
                changed = true
                continue
            }
            for tab in tabs where tab.groupID == group.id {
                switch liveFate(tab) {
                case .close: closeLiveTab(tab)
                case .keep, .ask: freeLiveTab(tab)
                }
            }
            tabGroups.removeAll { $0.id == group.id }
            changed = true
        }
        var row = tabs
        var made = Set<UUID>()
        for folder in wanted {
            if let index = tabGroups.firstIndex(where: { $0.id == folder.id }) {
                if tabGroups[index].name != folder.name {
                    tabGroups[index].name = folder.name
                    changed = true
                }
            } else {
                tabGroups.append(TabGroup(id: folder.id, name: folder.name, collapsed: true, held: true, live: true))
                changed = true
            }
            let keys = Set(folder.items.map { LiveIdentity.of($0.key) })
            for tab in row where tab.groupID == folder.id {
                guard let key = tab.liveKey, !keys.contains(LiveIdentity.of(key)) else { continue }
                switch liveFate(tab) {
                case .ask:
                    continue
                case .keep:
                    freeLiveTab(tab)
                    row.removeAll { $0.id == tab.id }
                    row.insert(tab, at: row.firstIndex { $0.pin == nil && $0.groupID == nil } ?? row.count)
                    changed = true
                case .close:
                    closeLiveTab(tab)
                    row.removeAll { $0.id == tab.id }
                    changed = true
                }
            }
            row = row.filter { tab in made.contains(tab.id) || tabs.contains { $0.id == tab.id } }
            for item in folder.items {
                let identity = LiveIdentity.of(item.key)
                if let tab = row.first(where: { $0.groupID == folder.id && $0.liveKey.map(LiveIdentity.of) == identity }) {
                    if tab.liveKey != item.key {
                        tab.liveKey = item.key
                        changed = true
                    }
                    if tab.liveItem != item {
                        if item.label == PullState.merged, tab.liveItem?.label != PullState.merged, live.turning(item.key),
                           !Motion.reduced, windowSeen {
                            tab.leads = live.leads(item.key)
                            tab.arrives = true
                        }
                        tab.liveItem = item
                    }
                    continue
                }
                guard let url = URL(string: item.key) else { continue }
                let tab = makeTab()
                prepare(tab)
                tab.restore(url: url, title: item.title)
                tab.groupID = folder.id
                tab.liveKey = item.key
                tab.liveItem = item
                row.append(tab)
                made.insert(tab.id)
                changed = true
            }
            let order = LiveOrder.shown(folder.items, by: folder.order).map { LiveIdentity.of($0.key) }
            let place = { (tab: Tab) in tab.liveKey.flatMap { order.firstIndex(of: LiveIdentity.of($0)) } ?? order.count }
            let inside = row.filter { $0.groupID == folder.id }.sorted { place($0) < place($1) }
            var next = inside.makeIterator()
            row = row.map { tab in tab.groupID == folder.id ? next.next() ?? tab : tab }
        }
        if changed || !row.elementsEqual(tabs, by: { $0.id == $1.id }) {
            replaceRow(row)
            writeSession()
        }
    }

    func letGoLive(_ tab: Tab, from old: UUID?) {
        guard let key = tab.liveKey, let old, tab.groupID != old, LiveFolders.shared.folder(old) != nil else { return }
        LiveFolders.shared.hide(key, in: old, item: tab.liveItem)
        tab.liveKey = nil
        tab.liveItem = nil
    }

    func followSite(_ tab: Tab) {
        guard prefs.liveFolders, let address = tab.address?.absoluteString,
              let source = LiveSource.from(address) else { return }
        let name = tab.address?.host().map(Address.withoutWWW) ?? tab.label
        LiveFolders.shared.add(name: name, source: source, space: spaceID)
        announce("Following \(name)")
    }

    func askForLiveFolder() {
        Ask.name("New Live Folder", detail: "A feed, a site, or a GitHub owner/repository. Read from this Mac.",
                 placeholder: "https://example.com/feed.xml", confirm: "Follow") { [weak self] text in
            guard let self else { return }
            guard let source = LiveSource.from(text) else {
                announce("That isn't an address")
                return
            }
            let name = URL(string: source.address)?.host().map(Address.withoutWWW) ?? text
            LiveFolders.shared.add(name: source.kind == .repository ? text : name, source: source, space: spaceID)
        }
    }

    func addLivePreset(_ name: String, _ source: LiveSource) {
        LiveFolders.shared.add(name: name, source: source, space: spaceID)
    }

    func liveSpace(_ asked: UUID?) -> UUID {
        SettingsSpaceChoice.resolve(picked: asked, current: spaceID, spaces: spaces.map(\.id), offered: showsSpaces)
    }

    @discardableResult
    func addLivePreset(_ name: String, _ source: LiveSource, space asked: UUID?, live: LiveFolders = .shared) -> LiveFolder {
        let space = liveSpace(asked)
        if !prefs.liveFolders { prefs.liveFolders = true }
        let made = live.add(name: name, source: source, space: space)
        announce(SettingsSpaceChoice.added(name, to: spaces.first { $0.id == space }, current: spaceID))
        return made
    }

    func signInToLive(_ id: UUID) {
        guard let page = LiveFolders.shared.folder(id)?.signInPage else { return }
        LiveFolders.shared.signInPressed(id)
        let tab = open(page, foreground: true)
        LiveFolders.shared.signOnTab(tab.id, for: id, at: page)
    }

    func openLiveSource(_ id: UUID) {
        guard let folder = LiveFolders.shared.folder(id), let url = folder.source.reading() else { return }
        if folder.space != spaceID, showsSpaces, spaces.contains(where: { $0.id == folder.space }) {
            if stacked { stackedJump(to: folder.space) } else { switchSpace(to: folder.space) }
        }
        open(url, foreground: true)
    }
}

@MainActor
enum LiveMenu {
    static func show(for browser: Browser) {
        menu(for: browser).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    static func menu(for browser: Browser) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(PlusMenu.item("Feed or Site…") { browser.askForLiveFolder() })
        menu.addItem(.separator())
        menu.addItem(PlusMenu.item("GitHub Pull Requests") { browser.addLivePreset(LiveSource.pullRequestsName, .pullRequests) })
        menu.addItem(PlusMenu.item("GitHub Issues") { browser.addLivePreset("Issues", .issues) })
        menu.addItem(PlusMenu.item("GitHub Notifications") { browser.addLivePreset("Notifications", .gitHubNotifications) })
        menu.addItem(.separator())
        menu.addItem(PlusMenu.item("Linear My Issues") { browser.addLivePreset("My Issues", .linear(.assigned)) })
        menu.addItem(PlusMenu.item("Linear Mentions") { browser.addLivePreset("Mentions", .linear(.mentions)) })
        menu.addItem(.separator())
        menu.addItem(PlusMenu.item("YouTube Subscriptions") { browser.addLivePreset("Subscriptions", .subscriptions) })
        return menu
    }
}
