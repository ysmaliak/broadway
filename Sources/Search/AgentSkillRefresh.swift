import BroadwayCLI
import Foundation
import Observation

extension AgentCommand {
    static let agentNames = ["claude", "codex", "cursor", "opencode", "gemini"]
    static let earlierNames = ["claude", "codex"]
    static let refreshWords = ["setup"] + agentNames + ["--refresh"]
    static let setupWords = ["setup"] + agentNames
    static let setupAndLinkWords = ["setup", "command"] + agentNames
    static let setUpKey = "agents.setUp"
    static let setUpForKey = "agents.setUpFor"

    static var refreshesSkills: Bool { Store.world == nil && !Store.testing }

    static var setsUpAgents: Bool {
        opensSetup(world: Store.world, testing: Store.testing, unitTests: Store.unitTests, environment: ProcessInfo.processInfo.environment)
    }

    static func opensSetup(world: String?, testing: Bool, unitTests: Bool, environment: [String: String]) -> Bool {
        if world == nil, !testing { return true }
        guard world != nil, !unitTests else { return false }
        return !(environment["BROADWAY_HOME"] ?? "").isEmpty
    }

    static func setupWords(somethingAtLink: Bool, staying: Bool) -> [String] {
        somethingAtLink || !staying ? setupWords : setupAndLinkWords
    }

    static var staying: Bool { UpdatePlace.found(Bundle.main.bundleURL) == nil }

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

    static func newlyCovered(isOn: Bool, marked: Bool, open: Bool, kept: [String]?, here: (String) -> Bool) -> [String] {
        guard open, isOn, marked else { return [] }
        let covered = kept ?? earlierNames
        return agentNames.filter { !covered.contains($0) && here($0) }
    }

    static func agentHere(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: Setup.Paths(home: home(ProcessInfo.processInfo.environment)).folder(name))
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
    @ObservationIgnored var staying: () -> Bool = { AgentCommand.staying }
    @ObservationIgnored var here: (String) -> Bool = { AgentCommand.agentHere($0) }
    @ObservationIgnored private let store: UserDefaults
    @ObservationIgnored private var last: Task<Void, Never>?

    init(store: UserDefaults = Store.settings) {
        self.store = store
    }

    var marked: Bool { store.bool(forKey: AgentCommand.setUpKey) }
    var covered: [String]? { store.stringArray(forKey: AgentCommand.setUpForKey) }

    func turned(wasOn: Bool, isOn: Bool) {
        guard AgentCommand.setsUp(.turned(wasOn: wasOn), isOn: isOn, marked: marked, open: open()) else { return }
        setUp()
    }

    func launched(agentsOn: Bool) {
        if AgentCommand.setsUp(.launch, isOn: agentsOn, marked: marked, open: open()) {
            setUp()
        } else {
            let newer = AgentCommand.newlyCovered(isOn: agentsOn, marked: marked, open: open(), kept: covered, here: here)
            if !newer.isEmpty { bring(newer) }
        }
        if refreshes() { queue({ AgentCommand.refreshWords }, counts: false) }
    }

    func settled() async {
        await last?.value
    }

    private func setUp() {
        guard available() else { return }
        store.set(true, forKey: AgentCommand.setUpKey)
        store.set(AgentCommand.agentNames.filter(here), forKey: AgentCommand.setUpForKey)
        let linkTaken = linkTaken
        let staying = staying
        queue({ AgentCommand.setupWords(somethingAtLink: linkTaken(), staying: staying()) }, counts: true)
    }

    private func bring(_ names: [String]) {
        guard available() else { return }
        let kept = covered ?? AgentCommand.earlierNames
        store.set(AgentCommand.agentNames.filter { kept.contains($0) || names.contains($0) }, forKey: AgentCommand.setUpForKey)
        queue({ ["setup"] + names }, counts: true)
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
