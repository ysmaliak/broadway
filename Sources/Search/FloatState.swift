import Foundation

struct FloatReveal: Equatable {
    static let linger: TimeInterval = 0.7
    static let idle: TimeInterval = 2.6

    private(set) var shown = false
    private(set) var inside = false
    private(set) var overControl = false
    private(set) var holding = false
    private var lastMove: TimeInterval = 0
    private var leftAt: TimeInterval?

    mutating func enter(at now: TimeInterval) {
        inside = true
        leftAt = nil
        lastMove = now
        shown = true
    }

    mutating func move(at now: TimeInterval, overControl: Bool = false) {
        guard inside else { return enter(at: now) }
        self.overControl = overControl
        lastMove = now
        shown = true
    }

    mutating func exit(at now: TimeInterval) {
        inside = false
        overControl = false
        leftAt = now
    }

    mutating func hold(at now: TimeInterval) {
        holding = true
        shown = true
        lastMove = now
    }

    mutating func release(at now: TimeInterval) {
        holding = false
        lastMove = now
        if !inside { leftAt = now }
    }

    mutating func signal(at now: TimeInterval, for seconds: TimeInterval) {
        shown = true
        lastMove = now
        if !inside { leftAt = now + max(0, seconds - Self.linger) }
    }

    mutating func hide() {
        shown = false
        leftAt = nil
    }

    var deadline: TimeInterval? {
        guard shown, !holding else { return nil }
        if let leftAt, !inside { return leftAt + Self.linger }
        if inside, !overControl { return lastMove + Self.idle }
        return nil
    }

    mutating func tick(at now: TimeInterval) {
        guard let deadline, now >= deadline - 0.001 else { return }
        shown = false
        leftAt = nil
    }
}

struct FloatPlay: Equatable {
    static let trust: TimeInterval = 0.8

    private(set) var playing = true
    private var pressedAt: TimeInterval?

    mutating func press(at now: TimeInterval) {
        playing.toggle()
        pressedAt = now
    }

    mutating func answered(_ playing: Bool) {
        self.playing = playing
    }

    mutating func polled(_ playing: Bool, at now: TimeInterval) {
        if let pressedAt, now - pressedAt < Self.trust { return }
        pressedAt = nil
        self.playing = playing
    }
}

struct FloatTime: Equatable {
    private(set) var through: Double = 0
    private(set) var duration: Double = 0
    private(set) var scrubbing: Double?
    private var seekedAt: TimeInterval?
    static let trust: TimeInterval = 0.8

    var seekable: Bool { duration.isFinite && duration > 0 }

    var shown: Double { scrubbing ?? through }

    mutating func polled(through: Double, duration: Double, at now: TimeInterval) {
        self.duration = duration.isFinite ? max(0, duration) : 0
        guard scrubbing == nil else { return }
        if let seekedAt, now - seekedAt < Self.trust { return }
        seekedAt = nil
        self.through = Self.clamp(through)
    }

    mutating func scrub(to fraction: Double) {
        scrubbing = Self.clamp(fraction)
    }

    mutating func letGo(at now: TimeInterval) {
        guard let scrubbing else { return }
        through = scrubbing
        self.scrubbing = nil
        seekedAt = now
    }

    mutating func skipped(by seconds: Double, at now: TimeInterval) {
        guard seekable else { return }
        through = Self.clamp(through + seconds / duration)
        seekedAt = now
    }

    static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    static func label(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3600, minutes = whole / 60 % 60, rest = whole % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
