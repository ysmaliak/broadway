import Foundation

@MainActor
enum AgentLinkLine {
    static let open: Character = "\u{27EA}"
    static let close: Character = "\u{27EB}"

    static func shown(_ href: String, page: URL?) -> String? {
        guard let url = URL(string: href) else { return nil }
        if let site = AgentSites.site(of: url), site == AgentSites.site(of: page) { return url.path.isEmpty ? "/" : url.path }
        return AgentChange.short(AgentSecrets.shown(url))
    }

    static func fixed(_ line: String, page: URL?) -> String {
        guard line.last == close, let start = line.lastIndex(of: open) else { return line }
        let href = String(line[line.index(after: start)..<line.index(before: line.endIndex)])
        return String(line[..<start]) + (shown(href, page: page) ?? "")
    }

    static func fixed(_ item: [String: Any], page: URL?) -> [String: Any] {
        guard let href = item["href"] as? String else { return item }
        var item = item
        item.removeValue(forKey: "href")
        if let url = URL(string: href), AgentSites.site(of: url) != AgentSites.site(of: page) { item["url"] = AgentSecrets.shown(url) }
        return item
    }
}
