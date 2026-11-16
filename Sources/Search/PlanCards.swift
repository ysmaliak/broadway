import Foundation

enum PlanCardKind: String, CaseIterable, Identifiable, Sendable {
    case claude, chatGPT, thisMac

    var id: String { rawValue }

    static let plans: [PlanCardKind] = [.claude, .chatGPT]
    static let helpers: [PlanCardKind] = [.thisMac]

    var plan: Plan? {
        switch self {
        case .claude: .claude
        case .chatGPT: .chatGPT
        case .thisMac: .thisMac
        }
    }

    var name: String {
        switch self {
        case .claude: "Claude"
        case .chatGPT: "ChatGPT"
        case .thisMac: "This Mac"
        }
    }

    var maker: String {
        switch self {
        case .claude: "Claude Code"
        case .chatGPT: "Codex"
        case .thisMac: "Apple Intelligence"
        }
    }

    var role: String {
        switch self {
        case .claude, .chatGPT: "Commands and tasks"
        case .thisMac: "Quick commands and group names, without leaving your Mac"
        }
    }
}

enum PlanCardState: Equatable, Sendable {
    case looking
    case missing
    case signedOut
    case ready(String?)

    var ready: Bool {
        if case .ready = self { return true }
        return false
    }
}

enum PlanCardFix: Equatable, Sendable {
    case install(String)
    case signIn(String)
    case appleIntelligence

    var title: String {
        switch self {
        case .install: "Copy Install Command"
        case .signIn: "Copy Sign-In Command"
        case .appleIntelligence: "Open System Settings"
        }
    }

    var command: String? {
        switch self {
        case .install(let command), .signIn(let command): command
        case .appleIntelligence: nil
        }
    }
}

struct PlanCard: Equatable, Identifiable, Sendable {
    let kind: PlanCardKind
    let state: PlanCardState
    let isDefault: Bool

    var id: String { kind.id }

    var canBeDefault: Bool {
        guard let plan = kind.plan, Plan.cloud.contains(plan) else { return false }
        return state.ready
    }

    var lit: Bool { state.ready || state == .looking }

    var fix: PlanCardFix? {
        switch (kind, state) {
        case (_, .looking), (_, .ready): nil
        case (.thisMac, _): .appleIntelligence
        case (_, .missing): kind.plan.map { .install($0.install) }
        case (_, .signedOut): kind.plan.map { .signIn($0.signIn) }
        }
    }

    var detail: String {
        switch state {
        case .looking:
            return "Looking…"
        case .missing:
            switch kind {
            case .thisMac: return "Apple Intelligence is off, so commands use your plan"
            default: return "\(kind.maker) isn't on this Mac"
            }
        case .signedOut:
            return "\(kind.maker) is here but not signed in"
        case .ready(let account):
            switch kind {
            case .thisMac: return "Apple Intelligence"
            default: return [PlanCard.account(account), kind.maker].compactMap { $0 }.joined(separator: " · ")
            }
        }
    }

    static func account(_ said: String?) -> String? {
        guard let said, !said.isEmpty else { return nil }
        if said.hasPrefix("not a plan") { return "Paid per use, not a plan" }
        return said
    }
}

enum PlanCards {
    static func state(_ status: PlanStatus?) -> PlanCardState {
        guard let status else { return .looking }
        guard status.installed else { return .missing }
        guard status.connected else { return .signedOut }
        return .ready(status.account)
    }

    static func cards(statuses: [Plan: PlanStatus], looked: Bool, chosen: Plan?) -> [PlanCard] {
        let connected = { (plan: Plan) in statuses[plan]?.connected ?? false }
        let chosenNow = Plans.defaultPlan(chosen: chosen, looked: looked, connected: connected)
        return PlanCardKind.allCases.map { kind in
            switch kind {
            case .thisMac:
                let status = statuses[.thisMac]
                let state: PlanCardState = status == nil ? .looking : status?.connected == true ? .ready(nil) : .missing
                return PlanCard(kind: kind, state: state, isDefault: false)
            case .claude, .chatGPT:
                let plan = kind.plan
                let state = state(plan.flatMap { statuses[$0] })
                return PlanCard(kind: kind, state: state, isDefault: plan != nil && plan == chosenNow && (state.ready || !looked))
            }
        }
    }

    static func choose(_ card: PlanCard) -> Plan? {
        card.canBeDefault ? card.kind.plan : nil
    }
}
