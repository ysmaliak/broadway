import Foundation
import Observation

extension AgentCommand {
    static let refreshWords = ["setup", "claude", "codex", "--refresh"]
    static let setupWords = ["setup", "claude", "codex"]
    static let setupAndLinkWords = ["setup", "command", "claude", "codex"]
    static let setUpKey = "agents.setUp"

    static var refreshesSkills: Bool { Store.world == nil && !Store.testing }

    static var setsUpAgents: Bool {
        opensSetup(world: Store.world, testing: Store.testing, unitTests: Store.unitTests, environment: ProcessInfo.processInfo.environment)
    }

    static func opensSetup(world: String?, testing: Bool, unitTests: Bool, environment: [String: String]) -> Bool {
        if world == nil, !testing { return true }
        guard world != nil, !unitTests else { return false }
        return !(environment["BROADWAY_HOME"] ?? "").isEmpty
    }

    static func setupWords(somethingAtLink: Bool) -> [String] {
        somethingAtLink ? setupWords : setupAndLinkWords
    }

    static func home(_ environment: [String: String]) -> String {
        environment["BROADWAY_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }

    static func link(home: String) -> String { home + "/.local/bin/broadway" }

    static var somethingAtLink: Bool {
        (try? FileManager.default.attributesOfItem(atPath: link(home: home(ProcessInfo.processInfo.environment)))) != nil
    }

    enum SetupMoment: Equatable {
        case launch
        case turned(wasOn: Bool)
    }

    static func setsUp(_ moment: SetupMoment, isOn: Bool, marked: Bool, open: Bool) -> Bool {
        guard open, isOn else { return false }
        switch moment {
        case .launch: return !marked
        case .turned(let wasOn): return !wasOn
        }
    }
}

@MainActor
@Observable
final class AgentSetup {
    static let shared = AgentSetup()

    private(set) var runs = 0
    @ObservationIgnored var runner: @Sendable ([String]) async -> Bool = { await AgentCommand.helper($0) != nil }
    @ObservationIgnored var available: () -> Bool = { AgentCommand.path != nil }
    @ObservationIgnored var open: () -> Bool = { AgentCommand.setsUpAgents }
    @ObservationIgnored var refreshes: () -> Bool = { AgentCommand.refreshesSkills }
    @ObservationIgnored var linkTaken: () -> Bool = { AgentCommand.somethingAtLink }
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private var last: Task<Void, Never>?

    init(store: UserDefaults = Store.settings) {
        self.store = store
    }

    var marked: Bool { store.bool(forKey: AgentCommand.setUpKey) }

    func turned(wasOn: Bool, isOn: Bool) {
        guard AgentCommand.setsUp(.turned(wasOn: wasOn), isOn: isOn, marked: marked, open: open()) else { return }
        setUp()
    }

    func launched(agentsOn: Bool) {
        if AgentCommand.setsUp(.launch, isOn: agentsOn, marked: marked, open: open()) { setUp() }
        if refreshes() { queue({ AgentCommand.refreshWords }, counts: false) }
    }

    func settled() async {
        await last?.value
    }

    private func setUp() {
        guard available() else { return }
        store.set(true, forKey: AgentCommand.setUpKey)
        let linkTaken = linkTaken
        queue({ AgentCommand.setupWords(somethingAtLink: linkTaken()) }, counts: true)
    }

    private func queue(_ words: @escaping () -> [String], counts: Bool) {
        let before = last
        let runner = runner
        last = Task(priority: .utility) { [weak self] in
            await before?.value
            _ = await runner(words())
            if counts { self?.runs += 1 }
        }
    }
}
