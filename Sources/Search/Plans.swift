import Foundation
import Observation

enum AIRoute: String, CaseIterable, Identifiable {
    case commands, tasks, forms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commands: return "Commands"
        case .tasks: return "Tasks"
        case .forms: return "Form drafts"
        }
    }
}

@MainActor
@Observable
final class Plans {
    static let shared = Plans()

    init() {}

    private(set) var statuses: [Plan: PlanStatus] = [:]
    var limits: [Plan: PlanLimit] = [:]
    var ranOut: [Plan: Date] = [:]
    private(set) var looked = false
    private(set) var looking = false
    @ObservationIgnored private var stand: [Plan: Provider] = [:]
    private let claude = ClaudeProvider()
    private let codex = CodexProvider()
    private let mac = MacModelProvider()

    func provider(_ plan: Plan) -> Provider {
        if let stand = stand[plan] { return stand }
        switch plan {
        case .claude: return claude
        case .chatGPT: return codex
        case .thisMac: return mac
        }
    }

    func standIn(_ provider: Provider?, for plan: Plan) {
        guard CLIGuard.underTest else { return }
        stand[plan] = provider
        looked = false
    }

    func refresh() async {
        while looking { try? await Task.sleep(for: .milliseconds(10)) }
        looking = true
        defer { looking = false }
        for plan in Plan.allCases {
            statuses[plan] = await provider(plan).status()
        }
        looked = true
    }

    func models(_ plan: Plan) -> [PlanModel] { provider(plan).models() }

    nonisolated static func modelName(_ model: String, plan: Plan) -> String {
        MainActor.assumeIsolated {
            shared.models(plan).first { $0.id == model }?.name ?? model
        }
    }

    func connected(_ plan: Plan) -> Bool { statuses[plan]?.connected ?? false }

    func defaultPlan(_ prefs: Preferences) -> Plan? {
        Self.defaultPlan(chosen: prefs.aiPlan, looked: looked, connected: connected)
    }

    nonisolated static func defaultPlan(chosen: Plan?, looked: Bool, connected: (Plan) -> Bool) -> Plan? {
        if let chosen, Plan.cloud.contains(chosen), connected(chosen) || !looked { return chosen }
        return Plan.cloud.first(where: connected)
    }

    func choice(_ route: AIRoute, _ prefs: Preferences) -> ModelChoice? {
        if let kept = prefs.aiRoutes[route.rawValue], connected(kept.plan) || !looked { return kept }
        guard let plan = defaultPlan(prefs) else { return nil }
        return defaultChoice(plan)
    }

    func defaultChoice(_ plan: Plan) -> ModelChoice {
        let model = models(plan).first
        return ModelChoice(plan: plan, model: model?.id ?? "", effort: model?.defaultEffort)
    }

    func otherChoice(than choice: ModelChoice, _ prefs: Preferences) -> ModelChoice? {
        if connected(choice.plan.other) { return defaultChoice(choice.plan.other) }
        let others = models(choice.plan).filter { $0.id != choice.model }
        return others.first.map { ModelChoice(plan: choice.plan, model: $0.id, effort: $0.defaultEffort) }
    }

    var agents: [Plan] { Plan.allCases.filter(connected) }

    func agent(_ prefs: Preferences) -> Plan? {
        Self.agent(chosen: prefs.aiPlan, looked: looked, connected: connected)
    }

    nonisolated static func agent(chosen: Plan?, looked: Bool, connected: (Plan) -> Bool) -> Plan? {
        if let chosen, connected(chosen) || !looked { return chosen }
        if chosen == .thisMac { return nil }
        return Plan.cloud.first(where: connected) ?? (connected(.thisMac) ? .thisMac : nil)
    }

    nonisolated static let macOff = "This Mac can't answer now. Pick another agent in Settings › Agents."

    func commandChoice(_ command: TextCommand, blind: Bool, _ prefs: Preferences) -> ModelChoice? {
        let mac = ModelChoice(plan: .thisMac, model: "", effort: nil)
        let macCan = command.mine || TextCommand.onDevice.contains(command.id)
        if blind { return macCan && connected(.thisMac) ? mac : nil }
        if let model = command.model { return model }
        guard let plan = agent(prefs) else { return nil }
        if plan == .thisMac { return macCan ? mac : nil }
        return defaultChoice(plan)
    }

    func start(_ request: ProviderRequest, on choice: ModelChoice) -> ProviderSession {
        var request = request
        request.model = choice.model.isEmpty ? nil : choice.model
        request.effort = choice.effort
        return provider(choice.plan).start(request)
    }

    func trouble(_ prefs: Preferences) -> String? {
        guard looked else { return nil }
        guard defaultPlan(prefs) != nil else {
            let installed = Plan.cloud.filter { statuses[$0]?.installed == true }
            return installed.isEmpty ? "Install Claude Code or Codex first"
                : "Sign in to \(installed[0].tool) first. Run \(installed[0].signIn) in Terminal."
        }
        return nil
    }
}
