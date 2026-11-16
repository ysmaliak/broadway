import Foundation

struct AgentHelper: Equatable {
    enum State: String { case running, done, failed, stopped }

    let id: UUID
    var state = State.running
    var answer = ""

    var report: [String: Any] {
        ["id": id.uuidString, "state": state.rawValue, "answer": answer]
    }
}

struct HelperRefused: Error, Equatable {
    let said: String
}

extension AgentTasks {
    static let helperLimit = 8

    func root(_ id: UUID) -> UUID {
        helpers.first { $0.value.contains { $0.id == id } }?.key ?? id
    }

    func startHelper(_ prompt: String, parent: UUID) -> Result<UUID, HelperRefused> {
        guard root(parent) == parent else { return .failure(HelperRefused(said: "A helper can't start helpers")) }
        guard let owner = running[parent] else { return .failure(HelperRefused(said: "That task isn't running")) }
        let asked = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else { return .failure(HelperRefused(said: "A helper needs something to do")) }
        let live = helpers[parent, default: []].filter { $0.state == .running }.count
        guard live < Self.helperLimit else {
            return .failure(HelperRefused(said: "Eight helpers are already running. Wait for one to finish."))
        }
        var id: UUID?
        let conversation = start(prompt: asked, choice: owner.chat.model, prefs: owner.prefs,
                                 command: helperCommand ?? AgentCommand.path, parent: parent) { [weak self] event in
            guard let id else { return }
            self?.helperHappened(event, helper: id, parent: parent)
        }
        guard let conversation else { return .failure(HelperRefused(said: "Broadway can't start a helper here")) }
        id = conversation.chat.id
        var helper = AgentHelper(id: conversation.chat.id)
        if running[helper.id] == nil {
            helper.state = .failed
            helper.answer = conversation.lastAnswer?.failed ?? ""
        }
        helpers[parent, default: []].append(helper)
        return .success(helper.id)
    }

    private func helperHappened(_ event: Conversation.Happening, helper: UUID, parent: UUID) {
        guard let index = helpers[parent]?.firstIndex(where: { $0.id == helper }) else { return }
        switch event {
        case .done(let text):
            helpers[parent]?[index].state = .done
            helpers[parent]?[index].answer = text
        case .failed(let said):
            helpers[parent]?[index].state = .failed
            helpers[parent]?[index].answer = said
        case .stopped:
            helpers[parent]?[index].state = .stopped
        default:
            break
        }
    }

    func stopHelpers(of parent: UUID) {
        for helper in helpers[parent, default: []] where helper.state == .running { running[helper.id]?.stop() }
        if running[parent] == nil, !helpers[parent, default: []].contains(where: { running[$0.id] != nil }) {
            helpers[parent] = nil
        }
    }

    func waitForHelpers(of parent: UUID, ids: [UUID]?, seconds: Double) async -> [AgentHelper] {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(seconds)
        func wanted() -> [AgentHelper] {
            helpers[parent, default: []].filter { ids?.contains($0.id) ?? true }
        }
        while wanted().contains(where: { $0.state == .running }), clock.now < end, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return wanted()
    }
}
