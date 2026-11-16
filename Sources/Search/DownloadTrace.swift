import Foundation

@MainActor
enum DownloadTrace {
    private(set) static var events: [[String: String]] = []

    static func note(_ kind: String, _ fields: [String: String] = [:]) {
        guard Store.testing else { return }
        events.append(fields.merging(["kind": kind]) { _, new in new })
        if events.count > 400 { events.removeFirst(events.count - 400) }
    }

    static func error(_ kind: String, _ error: Error, _ fields: [String: String] = [:]) {
        let ns = error as NSError
        note(kind, fields.merging(["domain": ns.domain, "code": String(ns.code), "error": ns.localizedDescription]) { _, new in new })
    }

    static func clear() { events.removeAll() }
}
