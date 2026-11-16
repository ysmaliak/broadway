import Foundation

enum PullList: String, Codable, CaseIterable, Identifiable {
    case reviewRequests, teamReviews, needsAction, waiting, ready, drafts, created, assigned, involved

    var id: String { rawValue }

    static let standard: [PullList] = [.reviewRequests, .created, .assigned]

    var title: String {
        switch self {
        case .reviewRequests: return "Review Requests"
        case .teamReviews: return "Team Reviews"
        case .needsAction: return "Needs Your Action"
        case .waiting: return "Waiting for Review"
        case .ready: return "Ready to Merge"
        case .drafts: return "Drafts"
        case .created: return "Created by You"
        case .assigned: return "Assigned to You"
        case .involved: return "Everything Involving You"
        }
    }

    var words: String {
        switch self {
        case .reviewRequests: return "review-requested:@me"
        case .teamReviews: return "team-review-requested:@me"
        case .needsAction: return "author:@me review:changes_requested"
        case .waiting: return "author:@me review:required draft:false"
        case .ready: return "author:@me review:approved draft:false"
        case .drafts: return "author:@me draft:true"
        case .created: return "author:@me"
        case .assigned: return "assignee:@me"
        case .involved: return "involves:@me"
        }
    }

    var query: String { "is:open is:pr archived:false \(words)" }

    var label: String? {
        switch self {
        case .reviewRequests: return "To review"
        case .teamReviews: return "Team review"
        case .needsAction: return "Changes"
        case .waiting: return "Waiting"
        case .ready: return "Ready"
        case .drafts: return "Draft"
        case .created, .involved: return nil
        case .assigned: return "Assigned"
        }
    }

    var asksForReview: Bool { self == .reviewRequests || self == .teamReviews }

    var page: URL {
        URL(string: "https://github.com/pulls?q=\(LiveSource.escaped(query).replacingOccurrences(of: "%20", with: "+"))")!
    }

    static func named(_ text: String) -> PullList? {
        let wanted = text.lowercased().filter { $0.isLetter }
        return allCases.first { list in
            list.rawValue.lowercased() == wanted || list.title.lowercased().filter(\.isLetter) == wanted
        }
    }

    static func ordered(_ lists: [PullList]) -> [PullList] {
        allCases.filter(lists.contains)
    }

    static func merged(_ answers: [(PullList, [LiveItem])], keepsState: Bool = false) -> [LiveItem] {
        var seen = Set<String>()
        var items: [LiveItem] = []
        for (list, found) in answers {
            for var item in found where seen.insert(item.key).inserted {
                if let label = list.label {
                    if !keepsState || PullState.rank(label) < PullState.rank(item.label) { item.label = label }
                }
                item.list = list
                items.append(item)
            }
        }
        return keepsState ? LiveStacks.arranged(items) : items
    }
}

enum PullState {
    static let merged = "Merged"
    static let closed = "Closed"
    static let conflict = "Conflict"
    static let changes = "Changes requested"
    static let draft = "Draft"
    static let approved = "Approved"

    static func rank(_ label: String?) -> Int {
        switch label {
        case merged: return 0
        case closed: return 1
        case conflict: return 2
        case changes: return 3
        case "To review", "Team review": return 4
        case draft: return 5
        case approved: return 6
        case nil: return 8
        default: return 7
        }
    }
}
