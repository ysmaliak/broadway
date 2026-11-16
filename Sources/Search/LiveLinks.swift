import Foundation

enum LiveLinks {
    static let videoHosts: Set<String> = ["youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be"]
    static let videoPages: Set<String> = ["shorts", "live", "embed"]

    static func thing(_ url: URL, in kind: LiveSource.Kind) -> String? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let named = parts.host?.lowercased(), !named.isEmpty else { return nil }
        let bare = LinkRouter.withoutWWW(named)
        var host = kind == .subscriptions && videoHosts.contains(bare) ? "youtube.com" : bare
        if let port = parts.port { host += ":\(port)" }
        let path = parts.path.split(separator: "/").map(String.init)
        let shaped: String? = switch kind {
        case .pullRequests, .repository, .issues, .notifications: numbered(path)
        case .linear: issue(path)
        case .subscriptions: video(path, short: bare == "youtu.be", items: parts.queryItems ?? [])
        case .feed, .page: nil
        }
        return host + "\u{0}" + (shaped ?? exact(url))
    }

    static func same(_ url: URL, as key: String, in kind: LiveSource.Kind) -> Bool {
        guard let asked = thing(url, in: kind), let kept = URL(string: key).flatMap({ thing($0, in: kind) }) else { return false }
        return asked == kept
    }

    static func shows(_ page: URL?, _ asked: URL) -> Bool {
        guard let page, LinkRouter.key(of: page) == LinkRouter.key(of: asked) else { return false }
        return asked.fragment == nil || asked.fragment == page.fragment
    }

    private static func numbered(_ path: [String]) -> String? {
        guard path.count >= 4, path[2] == "pull" || path[2] == "issues", Int(path[3]) != nil else { return nil }
        return "\(path[0].lowercased())/\(path[1].lowercased())#\(path[3])"
    }

    private static func issue(_ path: [String]) -> String? {
        guard let at = path.firstIndex(of: "issue"), path.count > at + 1 else { return nil }
        return "issue:" + path[at + 1].uppercased()
    }

    private static func video(_ path: [String], short: Bool, items: [URLQueryItem]) -> String? {
        if short { return path.count == 1 ? "video:" + path[0] : nil }
        if path == ["watch"], let id = items.first(where: { $0.name == "v" })?.value, !id.isEmpty { return "video:" + id }
        if path.count == 2, videoPages.contains(path[0]) { return "video:" + path[1] }
        return nil
    }

    private static func exact(_ url: URL) -> String {
        guard let parts = URLComponents(url: CleanLink.clean(url), resolvingAgainstBaseURL: false) else { return url.absoluteString }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return path + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
    }
}
