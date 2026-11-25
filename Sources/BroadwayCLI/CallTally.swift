import Foundation

public struct CallTally: Equatable {
    public static let name = "agent-calls.json"
    public static let commandLimit = 160
    public static let codeLimit = 24
    public static let other = "other"

    public struct Row: Equatable {
        public var calls = 0
        public var codes: [String: Int] = [:]

        public var failed: Int { codes.values.reduce(0, +) }
    }

    public var since: Date?
    public var rows: [String: Row] = [:]

    public init() {}

    public static func command(_ raw: String) -> String {
        let fits = (1...40).contains(raw.count) && raw.first?.isLetter == true
            && raw.allSatisfy { ("a"..."z").contains($0) || $0 == "_" || $0 == " " || $0 == "-" }
        return fits ? raw : other
    }

    public static func code(_ raw: String) -> String {
        let fits = (2...32).contains(raw.count) && raw.allSatisfy { ("a"..."z").contains($0) || $0 == "_" }
        return fits ? raw : other
    }

    public mutating func add(_ command: String, failed: String?, at date: Date = Date()) {
        var name = Self.command(command)
        if rows[name] == nil, rows.count >= Self.commandLimit { name = Self.other }
        var row = rows[name] ?? Row()
        row.calls += 1
        if let failed {
            var code = Self.code(failed)
            if row.codes[code] == nil, row.codes.count >= Self.codeLimit { code = Self.other }
            row.codes[code, default: 0] += 1
        }
        rows[name] = row
        if since == nil { since = date }
    }

    public var sorted: [(command: String, row: Row)] {
        rows.map { ($0.key, $0.value) }.sorted {
            ($0.row.failed, $0.row.calls, $1.command) > ($1.row.failed, $1.row.calls, $0.command)
        }
    }

    public var object: [String: Any] {
        var found: [String: Any] = ["commands": sorted.map { entry -> [String: Any] in
            ["command": entry.command, "calls": entry.row.calls, "failed": entry.row.failed, "codes": entry.row.codes]
        }]
        if let since { found["since"] = since.formatted(.iso8601) }
        return found
    }

    public var data: Data {
        var stored: [String: Any] = ["commands": rows.mapValues { ["calls": $0.calls, "codes": $0.codes] as [String: Any] }]
        if let since { stored["since"] = since.formatted(.iso8601) }
        return (try? JSONSerialization.data(withJSONObject: stored, options: [.sortedKeys])) ?? Data()
    }

    public init(data: Data) {
        guard let stored = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        since = (stored["since"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        for (command, value) in stored["commands"] as? [String: Any] ?? [:] {
            guard let value = value as? [String: Any], let calls = value["calls"] as? Int, calls >= 0 else { continue }
            var row = Row(calls: calls)
            for (code, count) in value["codes"] as? [String: Any] ?? [:] {
                guard let count = count as? Int, count > 0, row.codes.count < Self.codeLimit else { continue }
                row.codes[Self.code(code), default: 0] += count
            }
            let name = Self.command(command)
            guard rows[name] == nil, rows.count < Self.commandLimit + 1 else { continue }
            rows[name] = row
        }
    }

    public static func read(_ file: URL) -> CallTally {
        guard let data = try? Data(contentsOf: file) else { return CallTally() }
        return CallTally(data: data)
    }

    public static func file(socket: String) -> URL {
        URL(fileURLWithPath: socket).deletingLastPathComponent().appendingPathComponent(name)
    }

    public func lines() -> [String] {
        guard !rows.isEmpty else { return ["No agent calls are counted yet"] }
        let wide = max(7, (rows.keys.map(\.count).max() ?? 0) + 2)
        var found: [String] = []
        if let since { found.append("Counted since \(since.formatted(date: .abbreviated, time: .shortened))") }
        found.append(Self.pad("command", wide) + Self.right("calls", 7) + Self.right("failed", 8) + "  codes")
        for entry in sorted {
            let codes = entry.row.codes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "\($0.key) \($0.value)" }
            found.append(Self.pad(entry.command, wide) + Self.right(String(entry.row.calls), 7) + Self.right(String(entry.row.failed), 8)
                         + (codes.isEmpty ? "" : "  " + codes.joined(separator: ", ")))
        }
        return found
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text + String(repeating: " ", count: max(1, width - text.count))
    }

    private static func right(_ text: String, _ width: Int) -> String {
        String(repeating: " ", count: max(1, width - text.count)) + text
    }
}
