import AppKit

struct AIStage {
    var foldedTasks: Set<UUID> = []
    var commands: CommandList?
    var result: SelectionRun?
}

extension Browser {
    func aiTabChanged() {
        closeSelection()
    }

    func aiEscape() -> Bool {
        guard ai.result != nil || ai.commands != nil else { return false }
        if let result = ai.result, result.running { result.stop() } else { closeSelection() }
        return true
    }

    func aiKey(_ event: NSEvent) -> Bool {
        if drivingKey(event) || deskKey(event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if let result = ai.result, result.keys(event, flags, key, self) { return true }
        if let commands = ai.commands, commands.keys(event, flags, self) { return true }
        return false
    }

    func aiState() -> [String: Any] {
        var out: [String: Any] = ["acting": active?.agentActing ?? ""]
        if let commands = ai.commands { out["commands"] = commands.rows.map(\.name); out["selection"] = commands.picked.text }
        if let result = ai.result {
            out["result"] = result.text
            out["resultRunning"] = result.running
            out["target"] = result.command.output.rawValue
            out["canReplace"] = result.picked.editable
        }
        return out
    }
}
