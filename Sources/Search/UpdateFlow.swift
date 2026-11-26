import AppKit
import Observation
import Sparkle

struct UpdateFound: Equatable {
    let version: String
    let build: String
}

enum UpdatePhase: String {
    case idle, available, checking, downloading, installing, failed

    var busy: Bool { self == .checking || self == .downloading || self == .installing }
}

enum UpdateStage {
    case notDownloaded, downloaded, installing
}

enum UpdateChoice {
    case install, dismiss, cancel
}

enum UpdateTell: Equatable {
    case upToDate(String)
    case available(UpdateFound)
    case checkFailed(String)
}

@MainActor
protocol UpdateEngine: AnyObject {
    var busy: Bool { get }
    var running: String { get }
    var version: String { get }
    func begin()
    func read(_ done: @escaping (UpdateFound?, String?) -> Void)
}

@MainActor
@Observable
final class UpdateFlow {
    private(set) var phase: UpdatePhase = .idle
    private(set) var found: UpdateFound?
    private(set) var staged: UpdateFound?
    private(set) var hidden: UpdateFound?
    private(set) var progress: Double?
    private(set) var trouble: String?
    private(set) var pressed = false
    private(set) var quiet = false
    private(set) var arrivals = 0
    private(set) var told: [UpdateTell] = []
    @ObservationIgnored private(set) var trail: [String] = []

    @ObservationIgnored weak var engine: UpdateEngine?
    @ObservationIgnored var installsQuietly: () -> Bool = { false }
    @ObservationIgnored var cardSeen: () -> Bool = { true }
    @ObservationIgnored private var retryQuit: (() -> Void)?
    @ObservationIgnored private var quitTurn = 0
    static var quitWait: TimeInterval = 10
    @ObservationIgnored var tell: (UpdateTell) -> Void = { _ in }

    private enum Intent {
        case none, check, install
    }

    @ObservationIgnored private var intent: Intent = .none
    @ObservationIgnored private var afterCycle: (() -> Void)?
    @ObservationIgnored private var dropped: UpdateFound?
    @ObservationIgnored private var drops = 0
    @ObservationIgnored private var item: UpdateFound?
    @ObservationIgnored private var expected: UInt64 = 0
    @ObservationIgnored private var received: UInt64 = 0
    @ObservationIgnored private var extracting = false
    @ObservationIgnored private var reading = false
    @ObservationIgnored private var newest: UpdateFound??
    @ObservationIgnored private var heldReady: ((UpdateChoice) -> Void)?

    static let dropTries = 6

    nonisolated static func newer(_ build: String, than other: String) -> Bool {
        SUStandardVersionComparator.default.compareVersion(build, toVersion: other) == .orderedDescending
    }

    var shown: UpdatePhase {
        if pressed || phase == .failed { return phase }
        guard let found, !isHidden(found) else { return .idle }
        return .available
    }

    var card: Bool { shown != .idle }

    var offered: Bool { found != nil || phase == .failed }

    var canCheck: Bool { !phase.busy }

    var canInstall: Bool { offered && !(pressed && phase.busy) }

    private func isHidden(_ update: UpdateFound) -> Bool {
        guard let hidden else { return false }
        return !Self.newer(update.build, than: hidden.build)
    }

    private func note(_ update: UpdateFound) {
        if let found, !Self.newer(update.build, than: found.build) { return }
        found = update
        if card, !pressed { arrivals += 1 }
    }

    func hide() {
        hidden = found
        if phase == .failed {
            phase = .idle
            pressed = false
            trouble = nil
        }
    }

    func press() {
        mark("press")
        guard !(pressed && phase.busy) else { return }
        hidden = nil
        if let retry = retryQuit {
            pressed = true
            installing(retry: retry)
            retry()
            return
        }
        pressed = true
        trouble = nil
        progress = nil
        if quiet {
            phase = extracting ? .installing : .downloading
            progress = extracting ? 1 : fraction
            readNewest()
            return
        }
        phase = .checking
        guard let staged else { return start(.install) }
        guard let engine else { return start(.install) }
        reading = true
        engine.read { [weak self] newest, _ in
            guard let self else { return }
            reading = false
            if let newest, Self.newer(newest.build, than: staged.build), Self.newer(newest.build, than: engine.running) {
                note(newest)
                dropped = staged
                drops = 0
                self.staged = nil
            }
            start(.install)
        }
    }

    func checkNow() {
        mark("checkNow")
        guard canCheck else { return }
        hidden = nil
        trouble = nil
        phase = .checking
        guard staged != nil || quiet, let engine else { return start(.check) }
        engine.read { [weak self] newest, failure in
            guard let self else { return }
            if phase == .checking, !pressed { phase = .idle }
            if let failure { return say(.checkFailed(failure)) }
            if let newest, Self.newer(newest.build, than: engine.running) { note(newest) }
            guard let shown = found else { return say(.upToDate(engine.version)) }
            if !cardSeen() { say(.available(shown)) }
        }
    }

    private func say(_ what: UpdateTell) {
        told.append(what)
        mark("say \(what)")
        DispatchQueue.main.async { [weak self] in self?.tell(what) }
    }

    private func mark(_ event: String) {
        trail.append(event)
        if trail.count > 60 { trail.removeFirst(trail.count - 60) }
    }

    private func start(_ wanted: Intent) {
        mark("start \(wanted) busy \(engine?.busy == true)")
        intent = wanted
        guard let engine else {
            if wanted == .install {
                pressed = true
                fail(UpdateWords.none)
            } else {
                phase = .idle
            }
            return
        }
        guard !engine.busy else {
            afterCycle = { [weak self] in self?.start(wanted) }
            retry(wanted)
            return
        }
        afterCycle = nil
        waits = 0
        engine.begin()
    }

    @ObservationIgnored private var waits = 0

    static let waitLimit = 60

    private func retry(_ wanted: Intent) {
        guard waits < Self.waitLimit else { return }
        waits += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, afterCycle != nil, intent == wanted, engine?.busy == false else {
                if let self, afterCycle != nil, intent == wanted { retry(wanted) }
                return
            }
            mark("retry \(wanted)")
            start(wanted)
        }
    }

    private func readNewest() {
        guard let engine, !reading else { return }
        reading = true
        newest = nil
        engine.read { [weak self] update, _ in
            guard let self else { return }
            reading = false
            newest = .some(update)
            if let held = heldReady {
                heldReady = nil
                ready(held)
            }
        }
    }

    private var fraction: Double? {
        guard expected > 0 else { return nil }
        return min(1, Double(received) / Double(expected))
    }

    private func fail(_ reason: String) {
        trouble = reason
        phase = .failed
        quiet = false
        intent = .none
        afterCycle = nil
    }

    func checkStarted() {
        mark("checkStarted")
        if intent != .none, phase == .idle { phase = .checking }
    }

    func found(_ update: UpdateFound, stage: UpdateStage, informational: Bool, reply: @escaping (UpdateChoice) -> Void) {
        mark("found \(update.build) \(stage) pressed \(pressed) intent \(intent) dropped \(dropped?.build ?? "")")
        guard !informational else { return reply(.dismiss) }
        if let dropped, dropped.build == update.build, stage == .installing {
            drops += 1
            reply(.cancel)
            let again = intent
            afterCycle = { [weak self] in
                guard let self else { return }
                let wait = drops > 1 ? 1.0 : 0
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    guard let self else { return }
                    if drops >= Self.dropTries { self.dropped = nil }
                    start(again == .none ? .install : again)
                }
            }
            return
        }
        dropped = nil
        let checking = intent == .check
        if stage == .installing { staged = update }
        note(update)
        item = update
        if pressed || intent == .install {
            intent = .none
            afterCycle = nil
            pressed = true
            phase = stage == .notDownloaded ? .downloading : .installing
            progress = stage == .notDownloaded ? nil : 1
            expected = 0
            received = 0
            extracting = stage != .notDownloaded
            reply(.install)
            return
        }
        intent = .none
        if checking {
            phase = .idle
            if !cardSeen() { say(.available(found ?? update)) }
        }
        if stage == .installing { return reply(.dismiss) }
        if installsQuietly() {
            quiet = true
            expected = 0
            received = 0
            extracting = stage == .downloaded
            return reply(.install)
        }
        reply(.dismiss)
    }

    func downloadStarted() {
        mark("downloadStarted")
        expected = 0
        received = 0
        extracting = false
        if pressed { progress = nil }
    }

    func expect(_ length: UInt64) {
        expected = length
        received = 0
        if pressed { progress = fraction }
    }

    func receive(_ length: UInt64) {
        received += length
        if pressed { progress = fraction }
    }

    func extractStarted() {
        mark("extractStarted")
        extracting = true
        if pressed {
            phase = .installing
            progress = 1
        }
    }

    func ready(_ reply: @escaping (UpdateChoice) -> Void) {
        mark("ready pressed \(pressed) reading \(reading)")
        let update = item ?? found
        quiet = false
        extracting = false
        guard pressed else {
            staged = update
            return reply(.dismiss)
        }
        if reading {
            heldReady = reply
            return
        }
        if let read = newest, let update, let later = read, Self.newer(later.build, than: update.build) {
            newest = nil
            note(later)
            staged = nil
            phase = .checking
            progress = nil
            afterCycle = { [weak self] in self?.start(.install) }
            return reply(.cancel)
        }
        newest = nil
        staged = update
        phase = .installing
        progress = 1
        reply(.install)
    }

    func installing(retry: (() -> Void)? = nil) {
        mark("installing")
        guard pressed else { return }
        phase = .installing
        progress = 1
        retryQuit = retry
        guard retry != nil else { return }
        let turn = quitTurn &+ 1
        quitTurn = turn
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quitWait) { [weak self] in
            guard let self, quitTurn == turn, phase == .installing, retryQuit != nil else { return }
            mark("quit held")
            pressed = false
            phase = .idle
            progress = nil
        }
    }

    func notFound() {
        mark("notFound intent \(intent)")
        let wanted = intent
        intent = .none
        dropped = nil
        trouble = nil
        if pressed || wanted == .install {
            pressed = false
            phase = .idle
            progress = nil
            found = nil
            staged = nil
            return
        }
        found = nil
        guard wanted == .check else { return }
        phase = .idle
        say(.upToDate(engine?.version ?? ""))
    }

    func failed(_ reason: String) {
        mark("failed \(reason)")
        let wanted = intent
        dropped = nil
        if pressed || wanted == .install {
            pressed = true
            return fail(reason)
        }
        trouble = reason
        intent = .none
        quiet = false
        extracting = false
        guard wanted == .check else { return }
        phase = .idle
        say(.checkFailed(reason))
    }

    func cycleEnded() {
        mark("cycleEnded queued \(afterCycle != nil)")
        quiet = false
        if let next = afterCycle {
            afterCycle = nil
            DispatchQueue.main.async { next() }
            return
        }
        if intent == .check {
            intent = .none
            if phase == .checking { phase = .idle }
        }
        guard pressed, phase == .checking || phase == .downloading, heldReady == nil, !reading else { return }
        pressed = false
        phase = .idle
        progress = nil
    }

    func pretend(_ phase: UpdatePhase, found: UpdateFound?, staged: Bool = false, progress: Double? = nil, trouble: String? = nil) {
        let wasCard = card
        let before = self.found
        self.phase = phase == .available ? .idle : phase
        pressed = phase.busy || phase == .failed
        self.found = found
        self.staged = staged ? found : nil
        self.progress = progress
        self.trouble = trouble
        quiet = false
        intent = .none
        afterCycle = nil
        if found == nil { hidden = nil }
        if card, !wasCard || found != before { arrivals += 1 }
    }

    func reset() {
        phase = .idle
        found = nil
        staged = nil
        hidden = nil
        progress = nil
        trouble = nil
        pressed = false
        quiet = false
        intent = .none
        afterCycle = nil
        dropped = nil
        item = nil
        heldReady = nil
        reading = false
        newest = nil
        told = []
        retryQuit = nil
    }
}
