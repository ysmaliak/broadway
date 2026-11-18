import AppKit
import Combine
import Observation

enum LiveLoading {
    static let side = RingView.side

    static func waits(_ folder: LiveFolder, asked: Bool = false) -> Bool {
        !folder.paused && (folder.state == .waiting || (asked && folder.state != .signIn))
    }

    static func yields(_ folder: LiveFolder, asked: Bool = false, status: String?) -> Bool {
        !waits(folder, asked: asked) && status != nil
    }

    static func spoken(_ folder: LiveFolder) -> String { "Loading \(folder.name)" }
}

struct LiveLoadingPace: Equatable {
    static let wait: TimeInterval = 0.4
    static let stay: TimeInterval = RingView.turn

    var wait = LiveLoadingPace.wait
    var stay = LiveLoadingPace.stay
    private(set) var began: Date?
    private(set) var ended: Date?

    var busy: Bool { began != nil }

    private var appears: Date? { began?.addingTimeInterval(wait) }

    private var leaves: Date? {
        guard let appears, let ended, ended >= appears else { return nil }
        return max(ended, appears.addingTimeInterval(stay))
    }

    func shows(at now: Date) -> Bool {
        guard let appears, now >= appears else { return false }
        guard ended != nil else { return true }
        return leaves.map { now < $0 } ?? false
    }

    func turns(after now: Date) -> Date? {
        guard let appears else { return nil }
        if ended == nil { return now < appears ? appears : nil }
        return leaves.flatMap { now < $0 ? $0 : nil }
    }

    mutating func see(loading: Bool, at now: Date) {
        if loading {
            if began == nil || (ended != nil && !shows(at: now)) { began = now }
            ended = nil
        } else if began != nil {
            if ended == nil { ended = now }
            if !shows(at: now) { drop() }
        }
    }

    mutating func drop() {
        began = nil
        ended = nil
    }
}

@MainActor
@Observable
final class LiveLoadingClock {
    static let shared = LiveLoadingClock()

    private(set) var shown: Set<UUID> = []
    @ObservationIgnored var wait = LiveLoadingPace.wait { didSet { if wait != oldValue { restart() } } }
    @ObservationIgnored var stay = LiveLoadingPace.stay { didSet { if stay != oldValue { restart() } } }
    @ObservationIgnored private var paces: [UUID: LiveLoadingPace] = [:]
    @ObservationIgnored private var last: Set<UUID> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var watch: AnyCancellable?

    private init() {
        watch = kitTrack { [weak self] in self?.sync() }
    }

    private func restart() {
        paces = [:]
        sync()
    }

    func sync(at now: Date = Date()) {
        let live = LiveFolders.shared
        var showing: Set<UUID> = []
        var kept: [UUID: LiveLoadingPace] = [:]
        var next: Date?
        for folder in live.folders {
            let asked = live.requested.contains(folder.id)
            var pace = paces[folder.id] ?? LiveLoadingPace(wait: wait, stay: stay)
            if LiveLoading.yields(folder, asked: asked, status: LiveQuiet.status(folder)) { pace.drop() }
            pace.see(loading: LiveLoading.waits(folder, asked: asked), at: now)
            if pace.shows(at: now) { showing.insert(folder.id) }
            if let at = pace.turns(after: now) { next = min(next ?? at, at) }
            if pace.busy { kept[folder.id] = pace }
        }
        paces = kept
        if showing != last {
            last = showing
            shown = showing
        }
        timer?.invalidate()
        timer = nil
        guard let next else { return }
        let made = Timer(timeInterval: max(0, next.timeIntervalSince(now)), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }
}
