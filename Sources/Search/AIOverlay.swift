import AppKit

struct AIStage {
    var line: PageAsk?
    var fieldSearchOnTop: String?
    var chat: Conversation?
    var chatShown = false
    var chatListing = false
    var chatDraft = ""
    var chatEditing: ChatMessage.ID?
    var chatFocus = 0
    var chatFocused = false
    var foldedTasks: Set<UUID> = []
    var commands: CommandList?
    var result: SelectionRun?
}

extension Browser {
    func aiTabChanged() {
        closeSelection()
        if let line = ai.line, line.tab != active?.id { closeLine() }
    }

    func aiEscape() -> Bool {
        guard ai.result != nil || ai.commands != nil else { return lineEscape() }
        if let result = ai.result, result.running { result.stop() } else { closeSelection() }
        return true
    }

    func aiKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if chatKey(event, flags, key) { return true }
        if drivingKey(event) || deskKey(event) { return true }
        if let result = ai.result, result.keys(event, flags, key, self) { return true }
        if let commands = ai.commands, commands.keys(event, flags, self) { return true }
        if lineKey(event, flags, key) { return true }
        return false
    }

    func aiState() -> [String: Any] {
        var out: [String: Any] = lineState()
        out["acting"] = active?.agentActing ?? ""
        out.merge(chatState()) { _, chat in chat }
        if let commands = ai.commands {
            out["commands"] = commands.rows.map(\.name)
            out["selection"] = commands.picked.text
            let panel = CommandListPanel(browser: self, list: commands)
            out["foot"] = panel.footLine
            out["details"] = panel.entries.map(\.detail)
        }
        if let result = ai.result {
            out["result"] = result.text
            out["resultRunning"] = result.running
            out["target"] = result.command.output.rawValue
            out["canReplace"] = result.picked.editable
            out["place"] = result.place
        }
        return out
    }
}
