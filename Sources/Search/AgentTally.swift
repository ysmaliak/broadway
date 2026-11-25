import BroadwayCLI
import Foundation

@MainActor
final class AgentTally {
    static let shared = AgentTally(file: Store.file(CallTally.name))
    static let other = CallTally.other

    let file: URL
    private(set) var tally: CallTally
    private(set) var closed = false

    init(file: URL) {
        self.file = file
        tally = CallTally.read(file)
    }

    func count(_ command: String, failed code: String?) {
        if closed { tally = CallTally.read(file) }
        tally.add(command == Self.other ? command : BrowserToolbox.command(command), failed: code)
        let data = tally.data
        Disk.write(file, now: closed) { data }
    }

    func count(_ command: String, reply: [String: Any]) {
        guard reply["ok"] as? Bool != true else { return count(command, failed: nil) }
        count(command, failed: (reply["error"] as? [String: Any])?["code"] as? String ?? "failed")
    }

    func count(_ command: String, outcome: ToolOutcome) {
        count(command, failed: outcome.failed ? outcome.code ?? ToolFailure.code(outcome.text ?? "") : nil)
    }

    func close() {
        guard !closed else { return }
        closed = true
        let data = tally.data
        Disk.write(file, now: true) { data }
    }

    func forget() {
        tally = CallTally()
        let data = tally.data
        Disk.write(file) { data }
    }

    static func command(_ words: [String], tools: [ToolSpec]) -> String {
        let names = Set(tools.flatMap { [$0.name, BrowserToolbox.command($0.name)] })
        let verbs = Set(PersonCommands.names)
        let first = words.first ?? ""
        if words.count > 1, verbs.contains("\(first) \(words[1])") { return "\(first) \(words[1])" }
        if names.contains(first) || verbs.contains(where: { $0.hasPrefix(first + " ") }) { return first }
        return other
    }
}
