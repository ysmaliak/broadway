import CryptoKit
import Observation
import Foundation
import WebKit

@MainActor
@Observable
final class ShieldLists {
    static let shared = ShieldLists()

    struct Saved: Codable, Equatable {
        struct Fetched: Codable, Equatable {
            var etag: String?
            var modified: String?
        }

        var fetched: [String: Fetched] = [:]
        var checked: Date?
        var identifiers: [String] = []
        var rules = 0
        var skipped = 0
        var version = 0
    }

    nonisolated static let every: TimeInterval = 7 * 24 * 60 * 60
    static let prefix = "broadway-shield-list-"
    private static let attempts = 64

    private(set) var saved = Saved()
    private(set) var busy = false
    private(set) var trouble: String?

    @ObservationIgnored var sources = FilterLists.sources
    @ObservationIgnored private var started = false
    @ObservationIgnored private var clock: Timer?
    private let session = URLSession(configuration: .ephemeral)

    private static var folder: URL {
        let folder = Store.file("Shield/lists")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static var stateFile: URL { folder.appendingPathComponent("state.json") }
    private static func textFile(_ id: String) -> URL { folder.appendingPathComponent(id + ".txt") }

    nonisolated static func due(checked: Date?, now: Date = Date()) -> Bool {
        guard let checked else { return true }
        return now.timeIntervalSince(checked) >= every
    }

    nonisolated static func usable(_ data: Data) -> Bool {
        guard data.count > 16, data.count < 40_000_000, let text = String(data: data.prefix(4096), encoding: .utf8) else { return false }
        let start = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16).lowercased()
        return !start.hasPrefix("<") && !start.hasPrefix("{")
    }

    func start() {
        guard !started else { return }
        started = true
        if let data = try? Data(contentsOf: Self.stateFile), let read = try? JSONDecoder().decode(Saved.self, from: data) {
            saved = read
        }
        Task {
            await restore()
            guard !Store.testing else { return }
            try? await Task.sleep(for: .seconds(20))
            await refresh(force: false)
            clock = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    Task { await self.refresh(force: false) }
                }
            }
        }
    }

    private func restore() async {
        guard let store = Shield.store else { return }
        var found: [WKContentRuleList] = []
        if saved.version == FilterLists.version {
            for identifier in saved.identifiers {
                let list: WKContentRuleList? = await withCheckedContinuation { done in
                    store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in
                        nonisolated(unsafe) let list = list
                        done.resume(returning: list)
                    }
                }
                if let list { found.append(list) }
            }
        }
        if !saved.identifiers.isEmpty, found.count == saved.identifiers.count {
            Shield.shared.use(found)
        } else if !inputs().isEmpty {
            _ = await rebuild()
        }
    }

    private func inputs() -> [FilterLists.Input] {
        sources.compactMap { source in
            (try? String(contentsOf: Self.textFile(source.id), encoding: .utf8)).map { FilterLists.Input(text: $0, strict: source.strict) }
        }
    }

    func refresh(force: Bool) async {
        let wanted = Shield.shared.enabled && (Store.settings.object(forKey: "shield.lists") as? Bool ?? true)
        guard !busy, force || (wanted && Self.due(checked: saved.checked)) else { return }
        busy = true
        defer { busy = false }
        var changed = false
        var failed: [String] = []
        for source in sources {
            do {
                if try await fetch(source) { changed = true }
            } catch {
                failed.append(source.name)
            }
        }
        if failed.count < sources.count { saved.checked = Date() }
        if changed || Shield.shared.downloaded.isEmpty { _ = await rebuild() }
        trouble = failed.isEmpty ? nil : "Couldn't fetch \(failed.joined(separator: ", "))"
        write()
    }

    private func fetch(_ source: FilterLists.Source) async throws -> Bool {
        guard let url = URL(string: source.address) else { throw URLError(.badURL) }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        let known = saved.fetched[source.id]
        let cached = FileManager.default.fileExists(atPath: Self.textFile(source.id).path)
        if cached, let etag = known?.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if cached, let modified = known?.modified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 304 { return false }
            guard http.statusCode == 200 else { throw URLError(.badServerResponse) }
        }
        guard Self.usable(data) else { throw URLError(.cannotParseResponse) }
        try data.write(to: Self.textFile(source.id), options: .atomic)
        let http = response as? HTTPURLResponse
        saved.fetched[source.id] = .init(etag: http?.value(forHTTPHeaderField: "ETag"),
                                         modified: http?.value(forHTTPHeaderField: "Last-Modified"))
        return true
    }

    @discardableResult
    func rebuild() async -> Bool {
        let inputs = inputs()
        guard !inputs.isEmpty, let store = Shield.store else { return false }
        let made = await Task.detached(priority: .utility) { () -> (parts: [FilterLists.Part], rules: Int, skipped: Int, stamp: String) in
            let converted = FilterLists.convert(inputs)
            var hash = SHA256()
            hash.update(data: Data("\(FilterLists.version)".utf8))
            for input in inputs { hash.update(data: Data(input.text.utf8)) }
            let stamp = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
            return (FilterLists.parts(converted), converted.ruleCount, converted.skipped, stamp)
        }.value

        var lists: [WKContentRuleList] = []
        var budget = Self.attempts
        for (index, part) in made.parts.enumerated() {
            lists += await build(part, named: "\(Self.prefix)\(made.stamp)-\(index)", store: store, budget: &budget)
        }
        guard !lists.isEmpty || made.parts.isEmpty else {
            trouble = "Couldn't compile the new filter lists"
            return false
        }
        Shield.shared.use(lists)
        saved.identifiers = lists.compactMap(\.identifier)
        saved.rules = made.rules
        saved.skipped = made.skipped
        saved.version = FilterLists.version
        write()
        sweep(store)
        return true
    }

    private func build(_ part: FilterLists.Part, named name: String, store: WKContentRuleListStore, budget: inout Int) async -> [WKContentRuleList] {
        guard budget > 0 else { return [] }
        budget -= 1
        if let list = await compile(part.rules, named: name, store: store) { return [list] }
        guard part.head.count > 1 else { return [] }
        let middle = part.head.count / 2
        let left = FilterLists.Part(head: Array(part.head[..<middle]), tail: part.tail)
        let right = FilterLists.Part(head: Array(part.head[middle...]), tail: part.tail)
        let first = await build(left, named: name + "a", store: store, budget: &budget)
        return first + (await build(right, named: name + "b", store: store, budget: &budget))
    }

    private func compile(_ rules: [FilterRule], named name: String, store: WKContentRuleListStore) async -> WKContentRuleList? {
        let json = await Task.detached(priority: .utility) { FilterLists.encoded(rules) }.value
        guard let json else { return nil }
        return await withCheckedContinuation { done in
            store.compileContentRuleList(forIdentifier: name, encodedContentRuleList: json) { list, _ in
                nonisolated(unsafe) let list = list
                done.resume(returning: list)
            }
        }
    }

    private func sweep(_ store: WKContentRuleListStore) {
        let keep = Set(saved.identifiers)
        store.getAvailableContentRuleListIdentifiers { identifiers in
            for identifier in identifiers ?? [] where identifier.hasPrefix(ShieldLists.prefix) && !keep.contains(identifier) {
                store.removeContentRuleList(forIdentifier: identifier) { _ in }
            }
        }
    }

    private func write() {
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.stateFile, options: .atomic) }
    }
}
