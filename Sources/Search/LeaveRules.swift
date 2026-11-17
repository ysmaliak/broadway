import Foundation

enum LeaveWhy: Equatable {
    case navigate
    case closeTab
    case closeWindow
    case quit
    case restart(pressed: Bool)
    case broadwayCloses
    case broadwaySleeps
    case movePicked
}

struct LeavePage: Equatable {
    var hasPage = true
    var agent = false
    var stuck = false
    var settled = false
}

enum LeaveAnswer: Equatable {
    case ask
    case leave
    case endThenLeave
}

enum LeaveStep: Equatable {
    case ask(Int)
    case keep
    case go
}

enum LeaveRules {
    static let patience: TimeInterval = 5
    static let stayHolds: TimeInterval = 5

    static func asks(_ why: LeaveWhy) -> Bool {
        switch why {
        case .navigate, .closeTab, .closeWindow, .quit, .restart(pressed: true): true
        case .restart(pressed: false), .broadwayCloses, .broadwaySleeps, .movePicked: false
        }
    }

    static func answer(_ why: LeaveWhy, page: LeavePage, testing: Bool, held: Bool) -> LeaveAnswer {
        guard page.hasPage else { return .leave }
        if page.stuck { return why == .navigate ? .leave : .endThenLeave }
        guard asks(why), !page.agent, !page.settled else { return .leave }
        guard !testing || held else { return .leave }
        return .ask
    }

    static func timedOut(since: Date, asked: Bool, at now: Date) -> Bool {
        !asked && now.timeIntervalSince(since) >= patience
    }

    static func swallows(stayedAt: Date?, at now: Date) -> Bool {
        guard let stayedAt else { return false }
        return now.timeIntervalSince(stayedAt) < stayHolds
    }
}

struct LeaveRun: Equatable {
    let count: Int
    private(set) var at = 0
    private(set) var done: LeaveStep?

    init(count: Int) {
        self.count = count
        if count == 0 { done = .go }
    }

    var first: LeaveStep { done ?? .ask(0) }

    mutating func answered(leave: Bool) -> LeaveStep {
        if let done { return done }
        guard leave else {
            done = .keep
            return .keep
        }
        at += 1
        guard at < count else {
            done = .go
            return .go
        }
        return .ask(at)
    }
}
