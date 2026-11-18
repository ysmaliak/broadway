import Foundation

@MainActor
enum IntegrationNow {
    nonisolated static let key = "integrations.now"
    static let most = 2

    static var on: Bool { Store.settings.object(forKey: key) as? Bool ?? true }

    static func rows(from folders: [LiveFolder], on given: Bool? = nil, at now: Date = Date(), memory given2: NowMemory? = nil) -> [NowRow] {
        guard given ?? on else { return [] }
        let memory = given2 ?? .shared
        var rows: [NowRow] = []
        var later: [NowRow] = []
        var seen = Set<String>()
        for folder in folders where !folder.paused && folder.state == .fine {
            let lists = folder.source.pullLists
            let review = folder.source.asksForReview
            guard review || folder.source.assignsToYou else { continue }
            for item in folder.items where item.opened == nil && !memory.hides("integration:\(item.key)", at: now) && seen.insert(item.key).inserted {
                let asks = lists == nil ? review : item.list?.asksForReview == true
                guard asks || folder.source.assignsToYou && item.arrived != nil else { continue }
                let said = asks ? "Review requested" : "Assigned to you"
                let detail = [said, item.author].compactMap { $0 }.joined(separator: " · ")
                let key = item.key
                let row = NowRow(id: "integration:\(key)", title: item.title, detail: detail,
                                 symbol: asks ? "arrow.triangle.pull" : "checklist", url: URL(string: key)) { browser in
                    browser.openLiveItem(key)
                }
                if asks { rows.append(row) } else { later.append(row) }
            }
        }
        return Array((rows + later).prefix(most))
    }
}

enum IssueRefs {
    struct Ref: Equatable {
        let url: URL
        let said: String
    }

    static let notRepositories: Set<String> = [
        "settings", "notifications", "pulls", "issues", "orgs", "organizations", "marketplace", "explore", "topics",
        "search", "login", "logout", "sponsors", "features", "new", "users", "apps", "codespaces", "dashboard",
        "trending", "collections", "events", "about", "pricing", "enterprise", "team", "customer-stories", "readme",
    ]

    private static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    static func repository(of page: URL?) -> String? {
        guard let page, let host = page.host()?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let path = page.path().split(separator: "/").map(String.init)
        guard path.count >= 2, !notRepositories.contains(path[0].lowercased()) else { return nil }
        return "\(path[0])/\(path[1])"
    }

    static func match(_ typed: String, page: URL? = nil) -> Ref? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 150, !text.contains(" ") else { return nil }
        if let parts = groups(#"^([A-Za-z0-9][A-Za-z0-9-]{0,38})/([A-Za-z0-9._-]{1,100})#([0-9]{1,7})$"#, in: text), parts.count == 3,
           let url = URL(string: "https://github.com/\(parts[0])/\(parts[1])/issues/\(parts[2])") {
            return Ref(url: url, said: "\(parts[0])/\(parts[1])#\(parts[2])")
        }
        if let parts = groups(#"^#([0-9]{1,7})$"#, in: text), let number = parts.first, let repository = repository(of: page),
           let url = URL(string: "https://github.com/\(repository)/issues/\(number)") {
            return Ref(url: url, said: "\(repository)#\(number)")
        }
        return nil
    }
}

extension Browser {
    func issueRef(for typed: String) -> IssueRefs.Ref? {
        IssueRefs.match(typed, page: active?.address)
    }

    func openLiveItem(_ key: String) {
        if let tab = tabs.first(where: { $0.liveKey.map { LiveIdentity.same($0, key) } == true }) {
            select(tab)
            return
        }
        guard let url = URL(string: key) else { return }
        open(url, foreground: true, from: active)
    }
}
