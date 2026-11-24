import Foundation

enum PullList: String, Codable, CaseIterable, Identifiable {
    case reviewRequests, teamReviews, changed, needsAction, waiting, ready, drafts, created, assigned, involved

    var id: String { rawValue }

    static let standard: [PullList] = [.reviewRequests, .changed, .created, .assigned]
    static let oldStandard: Set<PullList> = [.reviewRequests, .created, .assigned]

    var title: String {
        switch self {
        case .reviewRequests: return "Review Requests"
        case .teamReviews: return "Team Reviews"
        case .changed: return "Changed Since Your Review"
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
        case .changed: return "reviewed-by:@me -author:@me"
        case .needsAction: return "author:@me review:changes_requested"
        case .waiting: return "author:@me review:required draft:false"
        case .ready: return "author:@me review:approved draft:false"
        case .drafts: return "author:@me draft:true"
        case .created: return "author:@me"
        case .assigned: return "assignee:@me"
        case .involved: return "involves:@me"
        }
    }

    func words(hidingDrafts: Bool) -> String {
        hidingDrafts && asksForReview ? words + " draft:false" : words
    }

    func query(hidingDrafts: Bool) -> String { "is:open is:pr archived:false \(words(hidingDrafts: hidingDrafts))" }

    var label: String? {
        switch self {
        case .reviewRequests: return "To review"
        case .teamReviews: return "Team review"
        case .changed: return "Review again"
        case .needsAction: return "Changes"
        case .waiting: return "Waiting"
        case .ready: return "Ready"
        case .drafts: return "Draft"
        case .created, .involved: return nil
        case .assigned: return "Assigned"
        }
    }

    var asksForReview: Bool { self == .reviewRequests || self == .teamReviews }

    var detail: String {
        switch self {
        case .reviewRequests: return "Pull requests that ask for your review"
        case .teamReviews: return "Pull requests that ask a team of yours for a review"
        case .changed: return "Pull requests you reviewed, once the author pushes, replies or resolves your comment"
        case .needsAction: return "Yours, with changes requested"
        case .waiting: return "Yours, waiting for a review"
        case .ready: return "Yours, approved"
        case .drafts: return "Your drafts"
        case .created: return "Every open pull request of yours"
        case .assigned: return "Open pull requests assigned to you"
        case .involved: return "Every open pull request you wrote, reviewed or were mentioned in"
        }
    }

    var own: Bool { words.split(separator: " ").contains { $0 == "author:@me" || $0 == "involves:@me" } }

    func page(hidingDrafts: Bool) -> URL {
        URL(string: "https://github.com/pulls?q=\(LiveSource.escaped(query(hidingDrafts: hidingDrafts)).replacingOccurrences(of: "%20", with: "+"))")!
    }

    static func named(_ text: String) -> PullList? {
        let wanted = text.lowercased().filter { $0.isLetter }
        return allCases.first { list in
            list.rawValue.lowercased() == wanted || list.title.lowercased().filter(\.isLetter) == wanted
                || list.label?.lowercased().filter(\.isLetter) == wanted
        }
    }

    static func reading(_ lists: [PullList]) -> [PullList] {
        ordered(lists).filter { $0 != .changed } + (lists.contains(.changed) ? [.changed] : [])
    }

    static func judged(_ found: [(PullList, [LiveItem])], cap: Int, judge: (([LiveItem], [LiveItem]) async -> [LiveItem])?) async -> [(PullList, [LiveItem])] {
        guard let at = found.firstIndex(where: { $0.0 == .changed }) else { return found }
        let others = found.filter { $0.0 != .changed }
        let elsewhere = Set(others.flatMap { $0.1.map { LiveIdentity.of($0.key) } })
        let asked = Array(found[at].1.filter { !elsewhere.contains(LiveIdentity.of($0.key)) }.prefix(cap))
        let read = await judge?(merged(shared(others, cap: cap).answers, keepsState: true), asked) ?? asked
        let by = Dictionary(read.map { (LiveIdentity.of($0.key), $0) }, uniquingKeysWith: { first, _ in first })
        return found.map { list, rows in
            (list, rows.compactMap { row in
                let identity = LiveIdentity.of(row.key)
                guard list != .changed || by[identity]?.back == true else { return nil }
                return by[identity].map { paged(row, from: $0) } ?? row
            })
        }
    }

    static func paged(_ row: LiveItem, from read: LiveItem) -> LiveItem {
        var next = row
        next.branch = read.branch ?? row.branch
        next.activity = read.activity
        next.unanswered = read.unanswered
        next.signsRead = read.signsRead
        next.pageRead = read.pageRead
        next.back = read.back
        return next
    }

    static func shared(_ answers: [(PullList, [LiveItem])], cap: Int) -> (answers: [(PullList, [LiveItem])], cut: [PullList]) {
        var chosen = Set<String>()
        var all = Set<String>()
        for (_, found) in answers { for item in found { all.insert(LiveIdentity.of(item.key)) } }
        guard all.count > cap else { return (answers, []) }
        var round = 0
        let longest = answers.map(\.1.count).max() ?? 0
        while chosen.count < cap, round < longest {
            for (_, found) in answers where round < found.count && chosen.count < cap {
                chosen.insert(LiveIdentity.of(found[round].key))
            }
            round += 1
        }
        var cut: [PullList] = []
        let kept = answers.map { list, found in
            let left = found.filter { chosen.contains(LiveIdentity.of($0.key)) }
            if left.count < found.count { cut.append(list) }
            return (list, left)
        }
        return (kept, cut)
    }

    static func ordered(_ lists: [PullList]) -> [PullList] {
        allCases.filter(lists.contains)
    }

    static func merged(_ answers: [(PullList, [LiveItem])], keepsState: Bool = false) -> [LiveItem] {
        var seen: [String: Int] = [:]
        var items: [LiveItem] = []
        for (list, found) in answers {
            for var item in found {
                if let at = seen[LiveIdentity.of(item.key)] {
                    if items[at].on?.contains(list) == false { items[at].on?.append(list) }
                    continue
                }
                if let label = list.label {
                    if !keepsState || PullState.rank(label) < PullState.rank(item.label) { item.label = label }
                }
                item.list = list
                item.on = [list]
                seen[LiveIdentity.of(item.key)] = items.count
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
        case "To review", "Team review", "Review again": return 4
        case draft: return 5
        case approved: return 6
        case nil: return 8
        default: return 7
        }
    }
}
