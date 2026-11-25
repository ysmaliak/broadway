import AppKit
import Foundation

@MainActor
final class PersonWatch {
    private static var live: [ObjectIdentifier: PersonWatch] = [:]
    private static let beat: Duration = .milliseconds(250)

    private let connection: LineConnection
    private weak var browser: Browser?
    private let box: BrowserToolbox
    private let only: Set<String>
    private var seen: [String: [String: [String: Any]]] = [:]
    private var running = true

    private init(connection: LineConnection, browser: Browser, box: BrowserToolbox, only: Set<String>) {
        self.connection = connection
        self.browser = browser
        self.box = box
        self.only = only
    }

    static func handle(_ request: [String: Any], browser: Browser, socket: AgentSocket, on connection: LineConnection) {
        let box = socket.box
        box.browser = browser
        guard box.open else {
            connection.send(ToolFailure.error("agents_off", "Agents are off in Broadway"))
            return connection.close()
        }
        if AgentPolicy.verdict(.tab, mode: browser.prefs.agentMode, rule: nil) == .ask {
            connection.send(ToolFailure.error("needs_task", "This needs the person's yes, and only a connected agent can ask for it. Nothing was done."))
            return connection.close()
        }
        let watch = PersonWatch(connection: connection, browser: browser, box: box, only: Set(request["only"] as? [String] ?? Self.kinds))
        let key = ObjectIdentifier(connection)
        live[key] = watch
        connection.onClose = { [previous = connection.onClose] in
            previous?()
            MainActor.assumeIsolated {
                live[key]?.running = false
                live[key] = nil
            }
        }
        connection.send(["ok": true, "data": ["watching": true]])
        Task { @MainActor in await watch.run() }
    }

    static let kinds = ["tabs", "spaces", "downloads", "approvals"]

    private func run() async {
        _ = look()
        while running {
            try? await Task.sleep(for: Self.beat)
            guard running else { return }
            guard box.open else {
                connection.send(ToolFailure.error("agents_off", "Agents are off in Broadway"))
                return connection.close()
            }
            for (name, fields) in look() { send(name, fields) }
        }
    }

    private func send(_ name: String, _ fields: [String: Any]) {
        var event = fields
        event["event"] = name
        event["at"] = PersonCommands.stamp(Date())
        connection.send(["ok": true, "data": AgentSecrets.scrub(event, sealed: AgentSeals.all)])
    }

    private func tabs() -> [String: [String: Any]] {
        guard let browser else { return [:] }
        var found: [String: [String: Any]] = [:]
        for row in PersonTabs.everyTab(PersonCall(noun: "", verb: "", arguments: [:], browser: browser, box: box)) {
            guard row.onScreen || row.tab.agent else { continue }
            found[PersonCommands.short(row.tab.id)] = Self.tabRow(row, box: box)
        }
        return found
    }

    static func tabRow(_ row: PersonTab, box: BrowserToolbox) -> [String: Any] {
        var fields = box.describe(row.tab, row.browser).filter { ["id", "title", "url", "front"].contains($0.key) }
        fields["space"] = PersonTabs.spaceName(row)
        return fields
    }

    private func spaces() -> [String: [String: Any]] {
        guard let browser else { return [:] }
        var found: [String: [String: Any]] = [:]
        for space in browser.spaces {
            found[space.id.uuidString] = ["id": PersonCommands.short(space.id), "name": space.name, "current": space.id == browser.spaceID]
        }
        return found
    }

    private func downloads() -> [String: [String: Any]] {
        guard let browser else { return [:] }
        var found: [String: [String: Any]] = [:]
        for entry in browser.fetches.entries {
            found[entry.id.uuidString] = ["id": PersonCommands.short(entry.id), "name": entry.name, "detail": "\(entry.state)"]
        }
        for keep in browser.loot.kept.prefix(20) {
            found[keep.path] = ["id": PersonStuff.stableID(keep.path), "name": keep.name, "detail": "done"]
        }
        return found
    }

    private func approvals() -> [String: [String: Any]] {
        var found: [String: [String: Any]] = [:]
        for question in AgentDesk.shared.pending {
            found[question.id.uuidString] = ["id": PersonCommands.short(question.id), "title": question.title, "detail": question.site ?? ""]
        }
        return found
    }

    private func look() -> [(String, [String: Any])] {
        var events: [(String, [String: Any])] = []
        let now: [(String, [String: [String: Any]])] = [
            ("tabs", only.contains("tabs") ? tabs() : [:]), ("spaces", only.contains("spaces") ? spaces() : [:]),
            ("downloads", only.contains("downloads") ? downloads() : [:]),
            ("approvals", only.contains("approvals") ? approvals() : [:]),
        ]
        let names = ["tabs": "tab", "spaces": "space", "downloads": "download", "approvals": "approval"]
        for (kind, rows) in now {
            let word = names[kind] ?? kind
            let before = seen[kind] ?? [:]
            for key in rows.keys.sorted() {
                guard let row = rows[key] else { continue }
                guard let old = before[key] else {
                    events.append(("\(word).added", row))
                    continue
                }
                if !NSDictionary(dictionary: old).isEqual(to: row) { events.append(("\(word).changed", row)) }
            }
            for key in before.keys.sorted() where rows[key] == nil {
                if let row = before[key] { events.append(("\(word).gone", row)) }
            }
            seen[kind] = rows
        }
        return events
    }
}
