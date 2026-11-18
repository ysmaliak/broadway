import Foundation

public final class FailureLog: @unchecked Sendable {
    public static let name = "failures.log"
    public static let limit = 500
    public static let shown = 100
    public static let trimmed = 400

    public static let kinds: Set<String> = [
        "action-download", "window", "response-attachment", "response-show", "response-download", "became", "blocked",
        "page-failed", "asked-destination", "refused-page", "refused-file", "placed", "finished", "failed", "site-file-asked",
    ]

    public static let verdicts: Set<String> = [
        "tab-under-held", "tab-under", "tab-under-file", "tab-under-page", "undone-file", "undone-page",
        "unseen", "inert", "astray", "wary", "unseen-fetched", "inert-fetched", "astray-fetched", "wary-fetched", "tab-under-fetched",
        "spent", "no-click", "peek", "routed", "opened",
    ]

    public static let domains: Set<String> = [
        "NSURLErrorDomain", "WebKitErrorDomain", "WKErrorDomain", "NSPOSIXErrorDomain", "NSCocoaErrorDomain",
        "NSOSStatusErrorDomain", "kCFErrorDomainCFNetwork",
    ]

    public static let flags: Set<String> = ["clicked", "view", "main", "held", "listed"]

    public let file: URL
    private var count: Int?

    public init(file: URL) {
        self.file = file
    }

    public convenience init(folder: URL) {
        self.init(file: folder.appendingPathComponent(Self.name))
    }

    public static func entry(_ kind: String, _ fields: [String: String], at date: Date) -> String? {
        var row: [String: Any] = ["kind": kinds.contains(kind) ? kind : "other", "time": date.formatted(.iso8601)]
        if let verdict = fields["verdict"], verdicts.contains(verdict) { row["verdict"] = verdict }
        if let domain = fields["domain"] { row["domain"] = domains.contains(domain) ? domain : "other" }
        if let code = fields["code"].flatMap({ Int($0) }) { row["code"] = code }
        for flag in flags {
            switch fields[flag] {
            case "true": row[flag] = true
            case "false": row[flag] = false
            default: break
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func lines() -> [String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    public func last(_ count: Int) -> [String] {
        Array(lines().suffix(max(0, count)))
    }

    public func append(_ line: String) {
        var held = count ?? lines().count
        if held >= Self.limit {
            let kept = lines().suffix(Self.trimmed - 1)
            try? Data((kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).utf8).write(to: file, options: .atomic)
            held = kept.count
        }
        let data = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: file.path) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        count = held + 1
    }

    public func clear() {
        count = 0
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        try? Data().write(to: file, options: .atomic)
    }
}
