import Foundation
import AppKit
import CryptoKit

struct LiveMoment: Equatable {
    var active: Bool
    var away: TimeInterval
    var asleep = false
    var online = true
}

enum LivePace {
    static let seen: TimeInterval = 5 * 60
    static let unseen: TimeInterval = 20 * 60
    static let idle: TimeInterval = 5 * 60
    static let gone: TimeInterval = 2 * 60 * 60
    static let catchUp: TimeInterval = 60
    static let tick: TimeInterval = 60

    static func engaged(_ moment: LiveMoment) -> Bool {
        moment.active && moment.away < idle && !moment.asleep && moment.online
    }

    static func interval(_ moment: LiveMoment, looked: Bool) -> TimeInterval? {
        guard !moment.asleep, moment.online else { return nil }
        if engaged(moment) { return looked ? seen : unseen }
        return moment.away < gone ? unseen : nil
    }

    static func due(_ read: Date?, now: Date, every: TimeInterval?) -> Bool {
        guard let every else { return false }
        guard let read else { return true }
        return read > now || now.timeIntervalSince(read) >= every
    }

    static func returned(from old: LiveMoment?, to new: LiveMoment) -> Bool {
        engaged(new) && !(old.map(engaged) ?? false)
    }

    static func woke(since: Date, idle: TimeInterval, now: Date) -> Bool {
        now.addingTimeInterval(-idle) > since.addingTimeInterval(2)
    }

    static func stale(_ read: Date?, now: Date) -> Bool {
        guard let read else { return true }
        return read > now || now.timeIntervalSince(read) >= catchUp
    }

    static func away(active: Bool, idle: TimeInterval, resigned: Date?, now: Date) -> TimeInterval {
        guard !active, let resigned else { return max(0, idle) }
        return max(idle, now.timeIntervalSince(resigned), 0)
    }

    static func wanted(_ folders: [LiveFolder], moment: LiveMoment, looked: Set<UUID>?, returned: Bool, now: Date) -> [UUID] {
        folders.filter { folder in
            guard !folder.paused, !LiveLimit.holds(folder, at: now) else { return false }
            if folder.source.heavy, let read = folder.read, read <= now, now.timeIntervalSince(read) < LiveDrive.every { return false }
            let seen = looked?.contains(folder.space) ?? true
            if LivePace.due(folder.read, now: now, every: interval(moment, looked: seen)) { return true }
            return returned && seen && (stale(folder.read, now: now) || folder.state == .failed)
        }.map(\.id)
    }
}

enum LiveTouch {
    enum Cause: Equatable { case landed, moved, shown, acted }

    struct Ask: Equatable {
        var key: String
        var space: UUID
    }

    static func gap(_ cause: Cause) -> TimeInterval {
        switch cause {
        case .shown: return 60
        case .acted: return 2
        case .landed, .moved: return 5
        }
    }

    static let handsOn: TimeInterval = 5
    static let reread: TimeInterval = 60

    static func rereads(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return last > now || now.timeIntervalSince(last) >= reread
    }

    static func settle(_ cause: Cause) -> TimeInterval {
        cause == .acted ? 1.5 : 0.8
    }

    static func wanted(_ cause: Cause, last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return last > now || now.timeIntervalSince(last) >= gap(cause)
    }

    static func follows(_ source: LiveSource) -> Bool {
        switch source.kind {
        case .pullRequests, .repository, .issues, .linear: return true
        default: return false
        }
    }

    static func keepsLabel(_ source: LiveSource) -> Bool {
        guard source.kind == .linear, let list = LinearAPI.List(address: source.address) else { return false }
        return list == .inbox || list == .mentions
    }

    static func patched(_ row: LiveItem, with fresh: LiveItem, in source: LiveSource) -> LiveItem {
        var item = row
        item.title = fresh.title
        item.updated = fresh.updated ?? row.updated
        item.activity = fresh.activity
        item.noticed = fresh.activity ?? row.noticed
        guard source.kind != .linear else {
            item.status = fresh.status ?? row.status
            if !keepsLabel(source) { item.label = fresh.label }
            return item
        }
        var label = fresh.label
        if let named = row.list?.label, PullState.rank(named) < PullState.rank(label) { label = named }
        item.label = label
        item.checks = fresh.checks
        item.draft = fresh.draft
        if let branch = fresh.branch { item.branch = branch }
        return item
    }
}

struct LiveConditional {
    struct Kept: Equatable {
        var tag: String?
        var modified: String?
        var data: Data
    }

    static let room = 64
    private(set) var kept: [String: Kept] = [:]
    private var order: [String] = []

    static func key(_ request: URLRequest) -> String? {
        guard (request.httpMethod ?? "GET").uppercased() == "GET", let url = request.url?.absoluteString else { return nil }
        let secret = request.value(forHTTPHeaderField: "Cookie") ?? ""
        let digest = SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
        return url + "\u{0}" + digest
    }

    func asking(_ request: URLRequest) -> URLRequest {
        guard let key = Self.key(request), let kept = kept[key] else { return request }
        var asked = request
        if let tag = kept.tag { asked.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        if let modified = kept.modified { asked.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        return asked
    }

    mutating func answered(_ request: URLRequest, data: Data, status: Int, tag: String?, modified: String?) -> (Data, Int) {
        guard let key = Self.key(request) else { return (data, status) }
        if status == 304, let kept = kept[key] { return (kept.data, 200) }
        guard (200..<300).contains(status), tag != nil || modified != nil else {
            if status != 304 { forget(key) }
            return (data, status)
        }
        kept[key] = Kept(tag: tag, modified: modified, data: data)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.room { kept[order.removeFirst()] = nil }
        return (data, status)
    }

    private mutating func forget(_ key: String) {
        kept[key] = nil
        order.removeAll { $0 == key }
    }

    @MainActor static var shared = LiveConditional()

    @MainActor
    static func send(_ request: URLRequest, delegate: URLSessionTaskDelegate) async -> (Data, Int)? {
        await exchange(request, delegate: delegate).map { ($0.0, $0.1) }
    }

    @MainActor
    static func exchange(_ request: URLRequest, delegate: URLSessionTaskDelegate) async -> (Data, Int, [String: String])? {
        let asked = shared.asking(request)
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: asked, delegate: delegate) else { return nil }
        let http = response as? HTTPURLResponse
        let headers = Dictionary((http?.allHeaderFields ?? [:]).compactMap { key, value in (key as? String).map { ($0, "\(value)") } },
                                 uniquingKeysWith: { a, _ in a })
        let (body, status) = shared.answered(request, data: data, status: http?.statusCode ?? 200,
                                             tag: http?.value(forHTTPHeaderField: "ETag"), modified: http?.value(forHTTPHeaderField: "Last-Modified"))
        return (body, status, headers)
    }
}

@MainActor
final class LiveLockWatch: NSObject {
    private let heard: @MainActor (Bool) -> Void

    init(_ heard: @escaping @MainActor (Bool) -> Void) {
        self.heard = heard
        super.init()
        let wide = DistributedNotificationCenter.default()
        wide.addObserver(self, selector: #selector(locked), name: Notification.Name("com.apple.screenIsLocked"), object: nil,
                         suspensionBehavior: .deliverImmediately)
        wide.addObserver(self, selector: #selector(unlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil,
                         suspensionBehavior: .deliverImmediately)
    }

    func stop() {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc private func locked() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.heard(true) } }
    }

    @objc private func unlocked() {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.heard(false) } }
    }
}
