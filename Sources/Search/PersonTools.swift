import BroadwayCLI
import Foundation

@MainActor
enum PersonTools {
    @MainActor
    struct Tool {
        let noun: String
        let verb: String
        let name: String
        let kind: PersonClass
        let line: NounSchema.Line

        var properties: [String: [String: Any]] {
            var found: [String: [String: Any]] = [:]
            for argument in line.arguments {
                var schema: [String: Any]
                if argument.many {
                    schema = ["type": "array", "items": ["type": "string"]]
                } else {
                    schema = ["type": ["number", "integer", "boolean"].contains(argument.type) ? argument.type : "string"]
                }
                if !argument.choices.isEmpty { schema["enum"] = argument.choices }
                found[argument.name] = schema
            }
            if line.tabbed { found["tab"] = ["type": "string"] }
            return found
        }

        var required: [String] { line.arguments.filter(\.required).map(\.name) }

        var description: String {
            let summary = line.summary.hasSuffix(".") ? line.summary : line.summary + "."
            let about = line.about.isEmpty ? "" : " " + (line.about.hasSuffix(".") ? line.about : line.about + ".")
            return summary + about + PersonTools.gateNote(kind)
        }

        var listed: [String: Any] {
            var schema: [String: Any] = ["type": "object", "properties": properties]
            if !required.isEmpty { schema["required"] = required }
            var tool: [String: Any] = ["name": name, "description": description, "inputSchema": schema]
            let notes = PersonTools.annotations(self)
            if !notes.isEmpty { tool["annotations"] = notes }
            return tool
        }
    }

    static let nouns: [String] = ["spaces", "folders", "bookmarks", "live", "settings"]

    static let leftOut: [String: String] = [
        "space": "not asked for", "tabs": "not asked for", "groups": "not asked for", "split": "not asked for",
        "windows": "not asked for", "downloads": "not asked for", "files": "not asked for", "history": "not asked for",
        "tasks": "not asked for", "logins": "not asked for", "fill": "not asked for", "page": "not asked for",
        "site": "not asked for", "shortcuts": "not asked for", "extensions": "not asked for", "shields": "not asked for",
        "permissions": "not asked for", "skills": "not asked for", "replies": "not asked for", "now": "not asked for",
        "plans": "not asked for", "agents": "not asked for", "approvals": "not asked for", "helpers": "not asked for", "hooks": "not asked for",
        "complete": "Broadway's own completion of a shell's words, not a command an agent runs",
    ]

    static let gentle: Set<String> = [
        "spaces_new", "spaces_switch", "folders_new", "folders_fold", "folders_unfold",
        "bookmarks_add", "bookmarks_folder", "bookmarks_open", "live_add", "live_update", "settings_open",
    ]

    static let reachesSites: Set<String> = ["bookmarks_open", "live_add", "live_update", "live_resume"]

    static func name(_ noun: String, _ verb: String) -> String { "\(noun)_\(verb)" }

    static let tools: [Tool] = {
        let lines = NounSchema.lines
        return nouns.flatMap { noun in
            lines.filter { $0.noun == noun }.compactMap { line -> Tool? in
                guard let entry = PersonCommands.find(line.noun, line.verb) else { return nil }
                return Tool(noun: line.noun, verb: line.verb, name: name(line.noun, line.verb), kind: entry.kind, line: line)
            }
        }
    }()

    static func tool(_ name: String) -> Tool? { tools.first { $0.name == name } }

    static func annotations(_ tool: Tool) -> [String: Any] {
        var found: [String: Any] = ["title": tool.line.summary]
        if tool.kind == .look {
            found["readOnlyHint"] = true
        } else if gentle.contains(tool.name) {
            found["destructiveHint"] = false
        }
        if !reachesSites.contains(tool.name) { found["openWorldHint"] = false }
        return found
    }

    static func gateNote(_ kind: PersonClass) -> String {
        switch kind {
        case .look: " In Ask mode the person says yes once for the session."
        case .arrange: " In Ask mode the person says yes each time."
        case .erase: " The person says yes first, except in Bypass."
        case .person: " Only the person can say yes to this, every time."
        case .open, .tool: ""
        }
    }

    static func outcome(_ reply: [String: Any], tool: Tool) -> ToolOutcome {
        guard reply["ok"] as? Bool == true else {
            let error = reply["error"] as? [String: Any] ?? [:]
            return .failure(error["message"] as? String ?? "That didn't work", code: error["code"] as? String ?? "failed",
                            hint: error["hint"] as? String, retrySafe: error["retry_safe"] as? Bool,
                            data: reply["data"] as? [String: Any])
        }
        let data = reply["data"] as? [String: Any] ?? [:]
        let said = NounSchema.text(noun: tool.noun, verb: tool.verb, data: data)
        return ToolOutcome(text: ToolReply.notice + said, data: data, plain: ToolReply.notice + said)
    }

    static func call(_ tool: Tool, _ arguments: [String: Any], link: UUID?, browser: Browser, socket: AgentSocket) async -> ToolOutcome {
        let request: [String: Any] = ["noun": tool.noun, "verb": tool.verb, "arguments": arguments]
        let channel = PersonChannel { _ in }
        let reply = await withTaskCancellationHandler {
            await PersonCommands.perform(request, browser: browser, socket: socket, channel: channel) {
                link.flatMap { AgentLinks.shared.link($0) }
            }
        } onCancel: {
            Task { @MainActor in channel.leave() }
        }
        return outcome(reply, tool: tool)
    }
}
