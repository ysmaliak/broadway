import Foundation

enum LinearAPI {
    enum List: Equatable {
        case assigned, created, inbox, mentions
        case cycle(String)

        init?(address: String) {
            guard let url = URL(string: address), let host = url.host()?.lowercased(),
                  host == "linear.app" || host.hasSuffix(".linear.app") else { return nil }
            let path = url.path().split(separator: "/").map { String($0).lowercased() }
            if let mine = path.firstIndex(of: "my-issues") {
                self = path.indices.contains(mine + 1) && path[mine + 1] == "created" ? .created : .assigned
            } else if path.contains("inbox") {
                self = path.last == "mentions" ? .mentions : .inbox
            } else if let team = path.firstIndex(of: "team"), path.indices.contains(team + 1) {
                self = .cycle(url.path().split(separator: "/").map(String.init)[team + 1].uppercased())
            } else {
                return nil
            }
        }

        var path: String {
            switch self {
            case .assigned: return "my-issues/assigned"
            case .created: return "my-issues/created"
            case .inbox: return "inbox"
            case .mentions: return "inbox/mentions"
            case .cycle(let team): return "team/\(team)/cycle/current"
            }
        }

        var title: String {
            switch self {
            case .assigned: return "My Issues"
            case .created: return "Created by Me"
            case .inbox: return "Inbox"
            case .mentions: return "Mentions"
            case .cycle(let team): return "\(team) Cycle"
            }
        }
    }

    static func address(for list: List, workspace: String?) -> String {
        let root = workspace.map { "https://linear.app/\($0)" } ?? "https://linear.app"
        return "\(root)/\(list.path)"
    }

    static func workspace(in address: String) -> String? {
        guard let url = URL(string: address), let host = url.host()?.lowercased(), host == "linear.app" || host.hasSuffix(".linear.app"),
              let first = url.path().split(separator: "/").first.map({ String($0).lowercased() }),
              !["my-issues", "inbox", "team"].contains(first) else { return nil }
        return first
    }

    struct SessionUser: Equatable {
        let id: String
        let organization: String
        let workspace: String
    }

    static let usersBody = GraphQL.body("query { availableUsers { users { id organization { id urlKey } } } }")

    static func users(from data: Data) -> [SessionUser]? {
        guard let answer = GraphQL.data(data), let available = answer["availableUsers"] as? [String: Any],
              let users = available["users"] as? [[String: Any]] else { return nil }
        return users.compactMap { user in
            guard let id = user["id"] as? String, let organization = user["organization"] as? [String: Any],
                  let org = organization["id"] as? String, !id.isEmpty, !org.isEmpty else { return nil }
            return SessionUser(id: id, organization: org, workspace: (organization["urlKey"] as? String ?? "").lowercased())
        }
    }

    static func pick(_ users: [SessionUser], workspace: String?) -> SessionUser? {
        guard let wanted = workspace?.lowercased(), let match = users.first(where: { $0.workspace == wanted }) else { return users.first }
        return match
    }

    private static let issue = """
    fragment Row on Issue {
      identifier title url updatedAt state { name type position }
      comments(first: 3, orderBy: createdAt) { nodes { createdAt user { id } } }
      history(first: 3, orderBy: createdAt) { nodes { createdAt actor { id } } }
    }
    """

    private static let open = #"filter: { state: { type: { nin: ["completed", "canceled"] } } }"#

    static func body(for list: List) -> Data {
        switch list {
        case .assigned:
            return GraphQL.body("query { viewer { id assignedIssues(first: 30, orderBy: updatedAt, \(open)) { nodes { ...Row } } } }\n\(issue)")
        case .created:
            return GraphQL.body("query { viewer { id createdIssues(first: 30, orderBy: updatedAt, \(open)) { nodes { ...Row } } } }\n\(issue)")
        case .inbox, .mentions:
            return GraphQL.body("""
            query { viewer { id } notifications(first: 50) { nodes { id type createdAt readAt archivedAt ... on IssueNotification { issue { ...Row } } } } }
            \(issue)
            """)
        case .cycle(let team):
            return GraphQL.body("""
            query($key: String!) { viewer { id } teams(first: 1, filter: { key: { eq: $key } }) { nodes { activeCycle { issues(first: 50, orderBy: updatedAt) { nodes { ...Row } } } } } }
            \(issue)
            """, variables: ["key": team])
        }
    }

    static func identifier(of key: String) -> String? {
        let identity = LiveIdentity.of(key)
        guard identity.hasPrefix("linear:") else { return nil }
        let id = String(identity.dropFirst("linear:".count))
        return id.isEmpty ? nil : id
    }

    static func pointBody(_ keys: [String]) -> Data {
        var names: [String] = []
        var asks: [String] = []
        var variables: [String: Any] = [:]
        for (index, key) in keys.enumerated() {
            guard let id = identifier(of: key) else { continue }
            names.append("$i\(index): String!")
            asks.append("i\(index): issue(id: $i\(index)) { ...Row }")
            variables["i\(index)"] = id
        }
        let head = names.isEmpty ? "" : "(\(names.joined(separator: ", ")))"
        return GraphQL.body("query\(head) { viewer { id }\n\(asks.joined(separator: "\n"))\n}\n\(issue)", variables: variables)
    }

    static func pointItems(from data: Data, keys: [String]) -> [LiveItem]? {
        guard let answer = GraphQL.data(data) else { return nil }
        let me = (answer["viewer"] as? [String: Any])?["id"] as? String
        return keys.indices.compactMap { index in
            (answer["i\(index)"] as? [String: Any]).flatMap { row($0, viewer: me) }
        }
    }

    static func refused(_ data: Data) -> Bool {
        GraphQL.errors(data).contains { error in
            let said = error.lowercased()
            return said.contains("authentication") || said.contains("unauthenticated")
        }
    }

    static func notice(_ type: String) -> String {
        let said = type.lowercased()
        if said.contains("unassigned") { return "Unassigned" }
        if said.contains("assigned") { return "Assigned" }
        if said.contains("mention") { return "Mention" }
        if said.contains("reaction") { return "Reaction" }
        if said.contains("comment") || said.contains("reply") { return "Comment" }
        if said.contains("status") { return "Status" }
        if said.contains("due") { return "Due" }
        if said.contains("subscribed") { return "Subscribed" }
        return "Update"
    }

    static func activity(_ issue: [String: Any], viewer me: String?) -> Date? {
        let comments = (nodes(issue["comments"]) ?? []).map { ($0["createdAt"], ($0["user"] as? [String: Any])?["id"]) }
        let history = (nodes(issue["history"]) ?? []).map { ($0["createdAt"], ($0["actor"] as? [String: Any])?["id"]) }
        let events: [(Date, String)] = (comments + history).compactMap { when, who in
            guard let when = (when as? String).flatMap(GitHubAPI.date), let who = who as? String else { return nil }
            return (when, who)
        }
        guard let newest = events.max(by: { $0.0 < $1.0 }), newest.1 != me else { return nil }
        return newest.0
    }

    private static func row(_ issue: [String: Any], label: String? = nil, viewer: String?, notice: Date? = nil) -> LiveItem? {
        guard let url = issue["url"] as? String, let title = issue["title"] as? String else { return nil }
        let state = (issue["state"] as? [String: Any])?["name"] as? String
        return LiveItem(key: url, title: title, label: label ?? state, author: issue["identifier"] as? String,
                        updated: (issue["updatedAt"] as? String).flatMap(GitHubAPI.date),
                        activity: notice ?? activity(issue, viewer: viewer))
    }

    static let statusOrder = ["triage", "started", "unstarted", "backlog", "completed", "canceled"]

    private static func byStatus(_ issues: [[String: Any]]) -> [[String: Any]] {
        func place(_ issue: [String: Any]) -> (Int, Double, String) {
            let state = issue["state"] as? [String: Any]
            let rank = (state?["type"] as? String).flatMap { statusOrder.firstIndex(of: $0.lowercased()) } ?? statusOrder.count
            return (rank, -((state?["position"] as? NSNumber)?.doubleValue ?? 0), state?["name"] as? String ?? "")
        }
        return issues.enumerated().sorted { one, other in
            let a = place(one.element), b = place(other.element)
            return a != b ? a < b : one.offset < other.offset
        }.map(\.element)
    }

    private static func nodes(_ value: Any?) -> [[String: Any]]? {
        (value as? [String: Any])?["nodes"] as? [[String: Any]]
    }

    static func items(from data: Data, list: List) -> [LiveItem]? {
        guard let answer = GraphQL.data(data) else { return nil }
        let me = (answer["viewer"] as? [String: Any])?["id"] as? String
        switch list {
        case .assigned, .created:
            let field = list == .assigned ? "assignedIssues" : "createdIssues"
            guard let issues = nodes((answer["viewer"] as? [String: Any])?[field]) else { return nil }
            return byStatus(issues).compactMap { row($0, viewer: me) }
        case .inbox, .mentions:
            guard let notices = nodes(answer["notifications"]) else { return nil }
            var seen = Set<String>()
            return notices.compactMap { notice in
                guard notice["readAt"] is NSNull || notice["readAt"] == nil,
                      notice["archivedAt"] is NSNull || notice["archivedAt"] == nil,
                      let issue = notice["issue"] as? [String: Any],
                      let made = row(issue, label: (notice["type"] as? String).map(Self.notice), viewer: me,
                                     notice: (notice["createdAt"] as? String).flatMap(GitHubAPI.date)),
                      list == .inbox || made.label == "Mention",
                      seen.insert(made.key).inserted else { return nil }
                return made
            }
        case .cycle:
            guard let teams = nodes(answer["teams"]) else { return nil }
            guard let cycle = teams.first?["activeCycle"] as? [String: Any] else { return [] }
            return byStatus(nodes(cycle["issues"]) ?? []).compactMap { row($0, viewer: me) }
        }
    }
}
