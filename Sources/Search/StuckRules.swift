import Foundation

struct StuckTimes: Equatable {
    var question: TimeInterval
    var agent: TimeInterval
    var quiet: TimeInterval

    static let standard = StuckTimes(question: 12, agent: 20, quiet: 30)
    static let askHolds: TimeInterval = 4
    static let endHolds: TimeInterval = 5
}

enum StuckAsk: Equatable {
    case reload(fromOrigin: Bool)
    case stop
    case back
    case forward
    case address(URL)
}

enum StuckReach: Equatable {
    case ask(StuckAsk)
    case sleep
    case close
}

enum StuckPlan: Equatable {
    case asIs
    case remember(StuckAsk)
    case endThen(StuckAsk)
    case endAndSleep
    case endAndClose
}

enum StuckWord: Equatable {
    case redo(StuckAsk)
    case askAt(Date)
    case endAgentAt(Date)
    case nothing
}

enum StuckDue: Equatable {
    case show
    case owe
    case nothing
}

struct StuckState: Equatable {
    var since: Date?
    var card = false
    var owed = false
    var due: Date?
    var quietUntil: Date?
    var asked: StuckAsk?
    var askedAt: Date?
    var agentDue: Date?
    var owesAgent = false
    var restarts = 0

    var stuck: Bool { since != nil }

    mutating func letGo() {
        since = nil
        card = false
        owed = false
        due = nil
        asked = nil
        askedAt = nil
        agentDue = nil
    }
}

enum StuckRules {
    static func plan(_ reach: StuckReach, stuck: Bool, remembers: Bool) -> StuckPlan {
        switch reach {
        case .ask(.stop) where stuck: .endAndSleep
        case .ask(let ask) where stuck: .endThen(ask)
        case .ask(let ask): remembers ? .remember(ask) : .asIs
        case .sleep: stuck ? .endAndSleep : .asIs
        case .close: stuck ? .endAndClose : .asIs
        }
    }

    static func redo(_ ask: StuckAsk) -> StuckPlan {
        ask == .stop ? .endAndSleep : .endThen(ask)
    }

    static func remember(_ ask: StuckAsk, in state: inout StuckState, at now: Date) {
        state.asked = ask
        state.askedAt = now
    }

    static func committed(_ state: inout StuckState) {
        state.asked = nil
        state.askedAt = nil
    }

    static func heard(_ state: inout StuckState, at now: Date, agent: Bool, times: StuckTimes) -> StuckWord {
        let first = state.since == nil
        if first { state.since = now }
        let asked = state.asked
        let askedAt = state.askedAt
        committed(&state)
        if !agent, let asked, let askedAt, now.timeIntervalSince(askedAt) <= StuckTimes.askHolds {
            return .redo(asked)
        }
        if agent {
            guard state.agentDue == nil, let since = state.since else { return .nothing }
            let due = since.addingTimeInterval(times.agent)
            state.agentDue = due
            return .endAgentAt(due)
        }
        guard !state.card, !state.owed, state.due == nil else { return .nothing }
        if let quiet = state.quietUntil, now < quiet { return .nothing }
        let due = now.addingTimeInterval(times.question)
        state.due = due
        return .askAt(due)
    }

    static func answered(_ state: inout StuckState) {
        state.since = nil
        state.card = false
        state.owed = false
        state.due = nil
        state.agentDue = nil
    }

    static func due(_ state: inout StuckState, at now: Date, onScreen: Bool, agent: Bool) -> StuckDue {
        guard state.stuck, !agent, let due = state.due, now >= due.addingTimeInterval(-0.05) else { return .nothing }
        state.due = nil
        if onScreen {
            state.card = true
            return .show
        }
        state.owed = true
        return .owe
    }

    static func cameForward(_ state: inout StuckState, agent: Bool) -> Bool {
        guard state.owed else { return false }
        state.owed = false
        guard state.stuck, !agent else { return false }
        state.card = true
        return true
    }

    static func wait(_ state: inout StuckState, at now: Date, times: StuckTimes) {
        state.card = false
        state.owed = false
        state.due = nil
        state.quietUntil = now.addingTimeInterval(times.quiet)
    }

    static func agentDue(_ state: StuckState, at now: Date, agent: Bool) -> Bool {
        guard agent, state.stuck, let due = state.agentDue else { return false }
        return now >= due.addingTimeInterval(-0.05)
    }

    static func restartedForAgent(_ state: inout StuckState) {
        state.owesAgent = true
        state.restarts += 1
    }

    static func takeAgentFailure(_ state: inout StuckState) -> Bool {
        guard state.owesAgent else { return false }
        state.owesAgent = false
        return true
    }
}
