import AppKit
import Combine
import Observation

@MainActor
enum LiveQuiet {
    static let least: TimeInterval = 20 * 60
    static let slack: TimeInterval = 5 * 60
    static let settle: TimeInterval = 60
    static let words = "Out of date"
    static let symbol = "exclamationmark.triangle"

    static func long(_ folder: LiveFolder, every: TimeInterval) -> TimeInterval {
        max(2 * LivePace.pace(folder, every: every) + slack, least)
    }

    static func stuck(_ folder: LiveFolder, online: Bool) -> Bool {
        !folder.paused && folder.state != .signIn && (folder.state == .failed || !online)
    }

    static func grace(_ folder: LiveFolder, every: TimeInterval, online: Bool = true) -> TimeInterval {
        online ? LivePace.pace(folder, every: every) + settle : settle
    }

    static func stale(_ folder: LiveFolder, at now: Date, every: TimeInterval, online: Bool = true, since: Date = .distantPast) -> Bool {
        guard stuck(folder, online: online) else { return false }
        guard let good = folder.good else { return folder.state == .failed }
        return now.timeIntervalSince(good) >= long(folder, every: every)
            && now.timeIntervalSince(since) >= grace(folder, every: every, online: online)
    }

    static func turns(_ folder: LiveFolder, after now: Date, every: TimeInterval, online: Bool = true, since: Date = .distantPast) -> Date? {
        guard stuck(folder, online: online), let good = folder.good else { return nil }
        let at = max(good.addingTimeInterval(long(folder, every: every)), since.addingTimeInterval(grace(folder, every: every, online: online)))
        return at > now ? at : nil
    }

    static func note(_ folder: LiveFolder, stale: Bool) -> LiveFolder.Note? {
        if folder.paused || folder.state == .signIn { return folder.note }
        if stale { return folder.items.isEmpty ? .failed : nil }
        switch folder.state {
        case .waiting, .signIn: return nil
        case .fine, .failed: return folder.items.isEmpty ? .empty : nil
        }
    }

    static func status(_ folder: LiveFolder, stale: Bool) -> String? {
        if folder.paused || folder.state == .signIn { return folder.status }
        return stale ? words : nil
    }

    static func updated(_ folder: LiveFolder, now: Date) -> String {
        guard let good = folder.good else { return "Not updated yet" }
        return "Updated \(LiveFolderRows.ago(good, now: now))"
    }

    static func cause(_ folder: LiveFolder, now: Date, online: Bool = true) -> String? {
        guard stuck(folder, online: online) else { return nil }
        let site = folder.source.siteName
        if !online || folder.why == .offline { return "You're offline" }
        if folder.why == .limited, LiveLimit.holds(folder, at: now) {
            return "Limited by \(site), trying again \(LiveWords.soon(folder.limitedUntil, now: now))"
        }
        return "Couldn't read \(site)"
    }

    static func detail(_ folder: LiveFolder, reading: Bool, now: Date, online: Bool = true) -> [String] {
        if reading { return ["Updating…"] }
        return [updated(folder, now: now)] + (cause(folder, now: now, online: online).map { [$0] } ?? [])
    }

    static func help(_ folder: LiveFolder, now: Date, online: Bool = true) -> String {
        let lines = detail(folder, reading: false, now: now, online: online)
        return lines.count == 1 ? lines[0] : lines.joined(separator: ". ") + "."
    }

    static func stale(_ id: UUID) -> Bool { LiveQuietClock.shared.stale.contains(id) }

    static func note(_ folder: LiveFolder) -> LiveFolder.Note? { note(folder, stale: stale(folder.id)) }

    static func status(_ folder: LiveFolder) -> String? { status(folder, stale: stale(folder.id)) }
}

@MainActor
@Observable
final class LiveQuietClock {
    static let shared = LiveQuietClock()

    private(set) var stale: Set<UUID> = []
    @ObservationIgnored private(set) var since: [UUID: Date] = [:]
    @ObservationIgnored private var back: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watch: AnyCancellable?

    private init() {
        watch = kitTrack { [weak self] in self?.sync() }
    }

    func sync(at now: Date = Date()) {
        let live = LiveFolders.shared
        let every = live.every()
        let online = live.online
        var found: Set<UUID> = []
        var held: [UUID: Date] = [:]
        var next: Date?
        let here = live.here
        for folder in live.folders where LiveQuiet.stuck(folder, online: online) {
            let began = since[folder.id] ?? now.addingTimeInterval(-(back[folder.id] ?? 0))
            held[folder.id] = began
            if stale.contains(folder.id) {
                if LiveQuiet.stale(folder, at: now, every: every, online: online) { found.insert(folder.id) }
                continue
            }
            guard let counted = here.map({ max(began, $0) }) else { continue }
            if LiveQuiet.stale(folder, at: now, every: every, online: online, since: counted) { found.insert(folder.id) }
            if let at = LiveQuiet.turns(folder, after: now, every: every, online: online, since: counted) { next = min(next ?? at, at) }
        }
        since = held
        if found != stale { stale = found }
        timer?.invalidate()
        timer = nil
        guard let next else { return }
        let made = Timer(timeInterval: max(0.05, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    func benchStuck(_ id: UUID, for seconds: TimeInterval) {
        guard Store.testing else { return }
        back[id] = seconds
        since[id] = nil
        sync()
    }
}
