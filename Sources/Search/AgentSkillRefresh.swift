import Foundation

extension AgentCommand {
    static let refreshWords = ["setup", "claude", "codex", "--refresh"]

    static var refreshesSkills: Bool { Store.world == nil && !Store.testing }

    static func refreshSkills() {
        guard refreshesSkills else { return }
        Task.detached(priority: .utility) { _ = await helper(refreshWords) }
    }
}
