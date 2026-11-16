import Foundation

@MainActor
enum PlansBench {
    static let usage = "plans fake [claude=ready|out|missing] [chatGPT=…] [thisMac=ready|missing] [default=claude|chatGPT] | pick KIND | real | state"

    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "plans only works on a --test run"]); return }
        let args = request["args"] as? [String] ?? []
        let plans = Plans.shared
        switch args.first {
        case "fake":
            var said: [String: String] = [:]
            for word in args.dropFirst() {
                let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { answer(["error": usage]); return }
                said[parts[0]] = parts[1]
            }
            for plan in Plan.allCases {
                guard let state = said[plan.rawValue] else { continue }
                let fake = FakeProvider(plan: plan)
                fake.fakeStatus = status(state, plan: plan)
                fake.fakeModels = models(plan)
                plans.standIn(fake, for: plan)
            }
            if let chosen = said["default"].flatMap(Plan.init(rawValue:)) { browser.prefs.aiPlan = chosen }
            Task {
                await plans.refresh()
                answer(state(browser))
            }
            return
        case "pick":
            guard args.count == 2, let kind = PlanCardKind(rawValue: args[1]),
                  let card = cards(browser).first(where: { $0.kind == kind }) else { answer(["error": usage]); return }
            if let plan = PlanCards.choose(card) { browser.prefs.aiPlan = plan }
        case "real":
            for plan in Plan.allCases { plans.standIn(nil, for: plan) }
            Task {
                await plans.refresh()
                answer(state(browser))
            }
            return
        case "state", nil:
            break
        default:
            answer(["error": usage])
            return
        }
        answer(state(browser))
    }

    private static func cards(_ browser: Browser) -> [PlanCard] {
        PlanCards.cards(statuses: Plans.shared.statuses, looked: Plans.shared.looked, chosen: browser.prefs.aiPlan)
    }

    private static func state(_ browser: Browser) -> [String: Any] {
        ["ai": browser.prefs.ai, "chosen": browser.prefs.aiPlan?.rawValue ?? "",
         "cards": cards(browser).map { ["kind": $0.kind.rawValue, "detail": $0.detail, "default": $0.isDefault,
                                        "choosable": $0.canBeDefault, "fix": $0.fix?.title ?? ""] }]
    }

    private static func status(_ word: String, plan: Plan) -> PlanStatus {
        switch word {
        case "ready": PlanStatus(path: "/fake/\(plan.executable)", connected: true,
                                 account: plan == .claude ? "Max plan" : plan == .chatGPT ? "ChatGPT plan" : nil)
        case "out": PlanStatus(path: "/fake/\(plan.executable)")
        default: PlanStatus()
        }
    }

    private static func models(_ plan: Plan) -> [PlanModel] {
        switch plan {
        case .claude: return ClaudeProvider().models()
        case .chatGPT:
            let efforts: [Effort] = [.low, .medium, .high, .xhigh]
            return [PlanModel(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", efforts: efforts, defaultEffort: .low,
                              note: "Latest workhorse model for coding and everyday work"),
                    PlanModel(id: "gpt-6-astra", name: "GPT-6-Astra", efforts: efforts, defaultEffort: .medium,
                              note: "Frontier intelligence for the most demanding work"),
                    PlanModel(id: "gpt-6-luna", name: "GPT-6-Luna", efforts: efforts, defaultEffort: .medium,
                              note: "Fast and affordable model for easier tasks")]
        case .thisMac: return [PlanModel(id: "", name: "This Mac")]
        }
    }
}
