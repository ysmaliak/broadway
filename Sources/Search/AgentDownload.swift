import AppKit
import UniformTypeIdentifiers
import WebKit

enum DownloadPlace {
    static let patience = 5.0

    private final class Busy: @unchecked Sendable {
        private let lock = NSLock()
        private var folders: Set<String> = []
        func take(_ folder: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return folders.insert(folder).inserted
        }
        func give(_ folder: String) {
            lock.lock()
            folders.remove(folder)
            lock.unlock()
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    private static let busy = Busy()

    static var held: URL { Store.file("Held Downloads") }

    static func stall(_ path: String) {
        guard Store.testing, let stall = ProcessInfo.processInfo.environment["SEARCH_FILE_STALL"],
              stall.split(separator: ":").contains(where: { path.hasPrefix(String($0)) }) else { return }
        Thread.sleep(forTimeInterval: 3600)
    }

    static func opens(_ folder: URL) -> Bool {
        stall(folder.path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let directory = opendir(folder.path) else { return false }
        _ = readdir(directory)
        closedir(directory)
        return access(folder.path, W_OK) == 0
    }

    static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    private static func race<T: Sendable>(seconds: Double, _ work: @escaping @Sendable () -> T?) async -> T? {
        await withCheckedContinuation { done in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let found = work()
                if once.take() { done.resume(returning: found) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.take() { done.resume(returning: nil) }
            }
        }
    }

    static func find(_ name: String, in folder: URL, numbered: Bool, seconds: Double) async -> (file: URL, held: Bool) {
        let key = folder.standardizedFileURL.path
        if busy.take(key) {
            let found: URL? = await race(seconds: seconds) {
                defer { busy.give(key) }
                guard opens(folder) else { return nil }
                return numbered ? free(name, in: folder) : folder.appendingPathComponent(name)
            }
            if let found { return (found, false) }
        }
        let room = held
        let spare: URL? = await race(seconds: seconds) {
            try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true)
            return free(name, in: room)
        }
        return (spare ?? room.appendingPathComponent(UUID().uuidString + "-" + name), true)
    }

    static func write(_ data: Data, to file: URL, seconds: Double) async -> Bool {
        await race(seconds: seconds) { () -> Bool? in
            stall(file.path)
            return (try? data.write(to: file)) != nil
        } ?? false
    }
}

@MainActor
enum AgentDownloadWatch {
    struct Record {
        var tab: UUID
        var started = Date()
        var file: URL?
        var source: URL?
        var type: String?
        var done = false
        var failed: String?

        var row: [String: Any] {
            let path = file?.path ?? ""
            let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            let kind = type.flatMap { $0.isEmpty ? nil : $0 } ?? file.flatMap { UTType(filenameExtension: $0.pathExtension)?.preferredMIMEType } ?? "application/octet-stream"
            return ["name": file?.lastPathComponent ?? "", "path": path, "bytes": bytes, "type": kind,
                    "site": source?.host() ?? "", "url": AgentSecrets.shown(source)]
        }
    }

    private struct Expectation {
        var person: Bool
        var name: String
        var until: Date
    }

    private static var records: [ObjectIdentifier: Record] = [:]
    private static var order: [ObjectIdentifier] = []
    private static var expected: [UUID: Expectation] = [:]

    static func folderName(_ name: String) -> String {
        let cleaned = name.map { "/:\\".contains($0) || $0.isNewline ? "-" : $0 }
        let trimmed = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: " .-"))
        return trimmed.isEmpty ? "Agent" : String(trimmed.prefix(60))
    }

    static func agentName(_ tab: Tab) -> String {
        tab.agentTask.flatMap { AgentLinks.shared.link(AgentTasks.shared.root($0))?.name } ?? "Agent"
    }

    static func expect(_ tab: Tab, person: Bool, seconds: Double) {
        expected[tab.id] = Expectation(person: person, name: agentName(tab), until: Date().addingTimeInterval(seconds + 30))
    }

    static func unexpect(_ tab: Tab) {
        expected[tab.id] = nil
    }

    static func folder(for download: WKDownload, in browser: Browser, type: String?) -> URL? {
        guard let web = download.webView,
              let tab = (browser.tabs + browser.parkedAgentTabs).first(where: { $0.built === web }) ?? browser.anyTab(for: web) else { return nil }
        let wish = expected[tab.id].flatMap { $0.until > Date() ? $0 : nil }
        guard tab.agent || wish != nil else { return nil }
        let id = ObjectIdentifier(download)
        if records[id] == nil {
            records[id] = Record(tab: tab.id, source: download.originalRequest?.url, type: type)
            order.append(id)
            if order.count > 200 { records[order.removeFirst()] = nil }
        }
        if wish?.person == true { return nil }
        return AgentDownloads.root.appendingPathComponent(folderName(wish?.name ?? agentName(tab)), isDirectory: true)
    }

    static func watches(_ download: WKDownload) -> Bool {
        records[ObjectIdentifier(download)] != nil
    }

    static func placed(_ download: WKDownload, at file: URL) {
        records[ObjectIdentifier(download)]?.file = file
    }

    static func finished(_ download: WKDownload, at file: URL?) {
        let id = ObjectIdentifier(download)
        guard records[id] != nil else { return }
        if let file { records[id]?.file = file }
        records[id]?.done = true
    }

    static func failed(_ download: WKDownload, _ why: String) {
        let id = ObjectIdentifier(download)
        guard records[id] != nil, records[id]?.done == false else { return }
        records[id]?.failed = why
    }

    static func downloading(_ tabs: Set<UUID>, since: Date) -> Bool {
        guard !tabs.isEmpty else { return false }
        return records.values.contains { tabs.contains($0.tab) && !$0.done && $0.failed == nil && $0.started >= since }
    }

        static func latest(_ tab: UUID, since: Date) -> Record? {
        order.reversed().compactMap { records[$0] }.first { $0.tab == tab && $0.started >= since }
    }
}

extension BrowserToolbox {
    func download(_ tab: Tab, _ arguments: [String: Any], task: UUID?, browser: Browser) async -> ToolOutcome {
        let ref = arguments["ref"] as? String ?? ""
        let address = arguments["url"] as? String ?? ""
        guard ref.isEmpty != address.isEmpty else { return .failure("download takes a ref or a url, one of them. Nothing was fetched.") }
        let seconds = min(max(arguments["seconds"] as? Double ?? 60, 1), 300)
        let person = arguments["downloads"] as? Bool == true
        let since = Date()
        AgentDownloadWatch.expect(tab, person: person, seconds: seconds)
        if !address.isEmpty {
            guard let url = Address.url(from: address), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                AgentDownloadWatch.unexpect(tab)
                return .failure("That isn't a web address")
            }
            if let refused = await gate(.tab, tab: tab, site: AgentSites.site(of: url), task: task) {
                AgentDownloadWatch.unexpect(tab)
                return refused
            }
            guard let web = tab.built else {
                AgentDownloadWatch.unexpect(tab)
                return .failure("That tab isn't showing a web page")
            }
            acting(tab, "Downloading")
            await mark(tab, task: task)
            web.startDownload(using: URLRequest(url: url)) { [weak browser, weak web] download in
                MainActor.assumeIsolated { browser?.keep(download, from: web) }
            }
        } else {
            let clicked = await click(tab, ref: ref, final: nil, task: task, browser: browser)
            if clicked.failed {
                AgentDownloadWatch.unexpect(tab)
                return clicked
            }
            let first = since.addingTimeInterval(8)
            while seconds > 8, AgentDownloadWatch.latest(tab.id, since: since) == nil, Date() < first {
                try? await Task.sleep(for: .milliseconds(150))
            }
            if seconds > 8, AgentDownloadWatch.latest(tab.id, since: since) == nil {
                AgentDownloadWatch.unexpect(tab)
                AgentWatchBox.current?.said = "Nothing started downloading within 8 s: the click did something else"
                return .json(["started": false, "website": true])
            }
        }
        return await awaitDownload(tab, since: since, seconds: seconds, clearing: true)
    }

    func awaitDownload(_ tab: Tab, since: Date, seconds: Double, clearing: Bool) async -> ToolOutcome {
        defer { if clearing { AgentDownloadWatch.unexpect(tab) } }
        let limit = Date().addingTimeInterval(seconds)
        repeat {
            if let record = AgentDownloadWatch.latest(tab.id, since: since) {
                if record.done {
                    let row = record.row
                    return ToolOutcome(text: "Saved \(row["name"] ?? "") at \(row["path"] ?? "")", data: row)
                }
                if let failed = record.failed { return .failure("The download didn't finish: \(failed)") }
            }
            try? await Task.sleep(for: .milliseconds(150))
        } while Date() < limit
        if AgentDownloadWatch.latest(tab.id, since: since) != nil {
            return .failure("Timed out waiting for the download to finish. It goes on: broadway downloads list shows it.")
        }
        return .failure("Timed out: no download started")
    }
}
