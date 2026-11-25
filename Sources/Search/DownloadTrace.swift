import BroadwayCLI
import Foundation
import WebKit

@MainActor
enum DownloadTrace {
    private(set) static var events: [[String: String]] = []
    static let disk: FailureLog? = Store.testing ? nil : FailureLog(folder: Store.folder)
    private static let queue = DispatchQueue(label: "broadway.failure-log", qos: .utility)

    static func note(_ kind: String, _ fields: [String: String] = [:], private secret: Bool) {
        write(kind, fields, private: secret, to: disk)
        guard Store.testing else { return }
        events.append(fields.merging(["kind": kind]) { _, new in new })
        if events.count > 400 { events.removeFirst(events.count - 400) }
    }

    static func error(_ kind: String, _ error: Error, _ fields: [String: String] = [:], private secret: Bool) {
        let ns = error as NSError
        note(kind, fields.merging(["domain": ns.domain, "code": String(ns.code), "error": ns.localizedDescription]) { _, new in new },
             private: secret)
    }

    static func write(_ kind: String, _ fields: [String: String], private secret: Bool, to log: FailureLog?, at date: Date = Date()) {
        guard !secret, let log, let line = FailureLog.entry(kind, fields, at: date) else { return }
        queue.async { log.append(line) }
    }

    static func forget(_ log: FailureLog? = DownloadTrace.disk) {
        AgentTally.shared.forget()
        guard let log else { return }
        queue.async { log.clear() }
    }

    static func settle() {
        queue.sync {}
    }

    static func clear() { events.removeAll() }
}

extension Browser {
    func tracesPrivately(_ webView: WKWebView?) -> Bool {
        if isPrivate { return true }
        guard let webView else { return false }
        return !webView.configuration.websiteDataStore.isPersistent || anyTab(for: webView)?.shy == true
    }

    func tracesPrivately(_ tab: Tab) -> Bool {
        if isPrivate || tab.shy { return true }
        return tab.built.map { tracesPrivately($0) } ?? false
    }

    func tracesPrivately(_ download: WKDownload) -> Bool {
        unlisted.contains(ObjectIdentifier(download)) || tracesPrivately(download.webView)
    }
}
