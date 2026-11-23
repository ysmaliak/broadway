import Foundation

enum MiniRole: String, Equatable {
    case none, float, mini
}

enum MiniPair: String, Equatable {
    case tracks, seconds, none
}

enum MiniSpoken: String, CaseIterable, Equatable {
    case seconds, tracks

    var title: String {
        switch self {
        case .seconds: return "Skip Back and Forward"
        case .tracks: return "Previous and Next"
        }
    }
}

struct MiniReport: Equatable {
    var picture = false
    var sound = false
    var undecided = false
    var unseen = false
    var reading: Reading?
    var refused: Double = 0
    var media: [Media] = []
    var reported: Reported?
    var session = Session()

    struct Reading: Equatable {
        var playing = false
        var time: Double = 0
        var duration: Double = 0
        var rate: Double = 1
        var live = false
        var minor = false
        var element = true
        var loop = false
        var source = ""
        var why = ""
    }

    struct Media: Equatable {
        var kind = "audio"
        var duration: Double = 0
        var time: Double = 0
        var paused = true
        var muted = false
        var loop = false
        var loose = false
        var chosen = false
        var picture = false

        var pictured: Bool { kind == "video" && picture && !muted && (chosen || !paused) }
        var heard: Bool { chosen && !muted && !(kind == "video" && picture) }
    }

    var video: Bool { unseen || media.contains(where: \.pictured) }
    var audio: Bool { !video && (sound || media.contains(where: \.heard)) }

    struct Reported: Equatable {
        var duration: Double = 0
        var time: Double = 0
        var rate: Double = 1
    }

    struct Session: Equatable {
        var title = ""
        var artist = ""
        var album = ""
        var art = ""
        var actions: Set<String> = []
        var state = ""

        var declared: Bool { !title.isEmpty || !actions.isEmpty }
    }

    static let most = 300

    static func parse(_ body: [String: Any]) -> MiniReport {
        func text(_ any: Any?) -> String { String((any as? String ?? "").prefix(most)) }
        func number(_ any: Any?) -> Double {
            let value = (any as? NSNumber)?.doubleValue ?? 0
            return value.isFinite ? value : 0
        }
        func rate(_ any: Any?) -> Double {
            let value = number(any)
            return value > 0 ? min(value, 16) : 1
        }
        func flag(_ any: Any?) -> Bool { any as? Bool ?? false }
        var made = MiniReport()
        made.picture = flag(body["picture"])
        made.sound = flag(body["sound"])
        made.undecided = flag(body["undecided"])
        made.unseen = flag(body["unseen"])
        if let found = body["reading"] as? [String: Any] {
            made.reading = Reading(playing: flag(found["playing"]), time: max(0, number(found["time"])),
                                   duration: max(0, number(found["duration"])), rate: rate(found["rate"]), live: flag(found["live"]),
                                   minor: flag(found["minor"]), element: flag(found["element"]), loop: flag(found["loop"]),
                                   source: text(found["source"]), why: text(found["why"]))
        }
        let refused = number(body["refused"])
        made.refused = refused > 0 ? min(refused, 16) : 0
        made.media = (body["media"] as? [[String: Any]] ?? []).prefix(8).map { found in
            Media(kind: text(found["kind"]) == "video" ? "video" : "audio", duration: number(found["duration"]), time: max(0, number(found["time"])),
                  paused: flag(found["paused"]), muted: flag(found["muted"]), loop: flag(found["loop"]), loose: flag(found["loose"]),
                  chosen: flag(found["chosen"]), picture: flag(found["picture"]))
        }
        if let found = body["reported"] as? [String: Any] {
            made.reported = Reported(duration: max(0, number(found["duration"])), time: max(0, number(found["time"])), rate: rate(found["rate"]))
        }
        if let session = body["session"] as? [String: Any] {
            made.session.title = text(session["title"])
            made.session.artist = text(session["artist"])
            made.session.album = text(session["album"])
            let art = session["art"] as? String ?? ""
            made.session.art = art.count <= 4096 ? art : ""
            made.session.actions = Set((session["actions"] as? [String] ?? []).prefix(16).filter(MiniAction.known.contains))
            made.session.state = text(session["state"])
        }
        return made
    }
}

enum MiniAction: String, CaseIterable {
    case play, pause, previous = "previoustrack", next = "nexttrack", back = "seekbackward", forward = "seekforward", seek = "seekto"

    static let known = Set(allCases.map(\.rawValue))
}

struct MiniFacts: Equatable {
    var noisy = false
    var waited = false
    var held = false
    var reports: [MiniReport] = []

    var earned: Bool {
        waited || reports.contains { report in
            report.session.declared || (report.reading?.duration ?? 0) >= MiniRule.soundLeast || report.reading?.live == true
        }
    }

    var picture: Bool { reports.contains(where: \.picture) }
    var sound: Bool { reports.contains(where: \.sound) }
    var undecided: Bool { reports.contains(where: \.undecided) }
    var video: Bool { reports.contains(where: \.video) && !reports.contains(where: \.audio) }
    var playing: Bool { noisy || reports.contains { $0.reading?.playing == true } }
}

enum MiniRule {
    static let spokenLength: Double = 20 * 60
    static let skips = [10, 15, 30]
    static let skipDefault = 15

    static let soundLeast: Double = 30
    static let lasting: TimeInterval = 3

    static func role(_ facts: MiniFacts, was: MiniRole) -> MiniRole {
        let role = sounding(facts, was: was)
        return role == .mini && facts.video ? .none : role
    }

    private static func sounding(_ facts: MiniFacts, was: MiniRole) -> MiniRole {
        if facts.picture { return .float }
        if facts.held { return .mini }
        if facts.sound { return facts.earned || was == .mini ? .mini : was }
        if facts.undecided { return was == .mini ? .mini : .none }
        if facts.noisy { return facts.waited || was == .mini ? .mini : was }
        return was == .mini && facts.reports.contains(where: { $0.reading != nil || $0.session.declared }) ? .mini : .none
    }

    static func seekable(actions: Set<String>, duration: Double, live: Bool) -> Bool {
        !live && (duration > 0 || actions.contains(MiniAction.seek.rawValue)
            || actions.contains(MiniAction.back.rawValue) || actions.contains(MiniAction.forward.rawValue))
    }

    static func long(actions: Set<String>, duration: Double, live: Bool) -> Bool {
        seekable(actions: actions, duration: duration, live: live) && duration >= spokenLength
    }

    static func speed(long: Bool, element: Bool, refused: Bool, on: Bool) -> Bool {
        on && long && element && !refused
    }

    static func pair(actions: Set<String>, duration: Double, live: Bool, spoken: MiniSpoken) -> MiniPair {
        let tracks = actions.contains(MiniAction.previous.rawValue) || actions.contains(MiniAction.next.rawValue)
        let seekable = seekable(actions: actions, duration: duration, live: live)
        if long(actions: actions, duration: duration, live: live) { return spoken == .tracks && tracks ? .tracks : .seconds }
        if tracks { return .tracks }
        if seekable { return .seconds }
        return .none
    }

    static func kept(_ entries: [(id: UUID, playing: Bool, started: Double)]) -> [UUID] {
        let latest = entries.filter(\.playing).map(\.started).max() ?? -.infinity
        return entries.filter { $0.playing || $0.started > latest }.map(\.id)
    }

    static func chosen(_ entries: [(id: UUID, playing: Bool, started: Double)]) -> UUID? {
        entries.max { $0.started < $1.started }?.id
    }

    static let marks: Set<Character> = ["▶", "►", "▷", "⏵", "⏸", "⏯", "❚", "‖", "♪", "♫", "🔊", "🔉", "🔈", "🎵", "🎶", "•", "·"]

    static func bare(_ title: String) -> String {
        var rest = Substring(title)
        while let first = rest.first, first.isWhitespace || first.unicodeScalars.first.map({ marks.contains(Character($0)) }) == true {
            rest = rest.dropFirst()
        }
        return rest.isEmpty ? title : String(rest)
    }

    static func symbol(back: Bool, seconds: Int) -> String {
        let step = skips.contains(seconds) ? seconds : skipDefault
        return back ? "gobackward.\(step)" : "goforward.\(step)"
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let whole = Int(seconds.rounded(.down))
        let hours = whole / 3600, minutes = whole / 60 % 60, rest = whole % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    static let speeds: [Double] = [0.8, 1, 1.2, 1.5, 1.8, 2, 2.5, 3]

    static func steps(around rate: Double) -> [Double] {
        let near = Tempo.rounded(Tempo.clamped(rate))
        return speeds.contains(where: { abs($0 - near) < 0.001 }) ? speeds : (speeds + [near]).sorted()
    }
}

struct MiniPosition: Equatable {
    var time: Double
    var duration: Double
    var rate: Double
    var playing: Bool
    var at: Date

    func elapsed(now: Date) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        let moved = playing ? max(0, now.timeIntervalSince(at)) * rate : 0
        return max(0, min(duration, time + moved))
    }

    func fraction(now: Date) -> Double {
        guard duration.isFinite, duration > 0 else { return 0 }
        return elapsed(now: now) / duration
    }

    func left(now: Date) -> Double {
        max(0, duration - elapsed(now: now))
    }
}

struct FloatMiss: Equatable {
    static let lasts: TimeInterval = 8

    let tab: UUID
    let quietly: Bool
    let at: Date
    var trying = false

    init(tab: UUID, quietly: Bool, since earlier: FloatMiss? = nil, now: Date = Date()) {
        self.tab = tab
        self.quietly = quietly
        at = earlier.map { $0.tab == tab && $0.fresh(now: now) ? $0.at : now } ?? now
    }

    func fresh(now: Date = Date()) -> Bool { now.timeIntervalSince(at) < Self.lasts }
}

struct MiniFrameSeen: Equatable {
    var key: String
    var main = false
    var reading: MiniReport.Reading?
    var declared = false
    var since: Double = 0
    var at: Double = 0
}

struct MiniHold: Equatable {
    static let longest: TimeInterval = 3
    static let near: Double = 2
    static let settle: TimeInterval = 1.2
    static let rateLongest: TimeInterval = 1.5

    var time: Double
    var at: Date
    var playing: Bool?

    init(time: Double, at: Date, playing: Bool? = nil) {
        self.time = time
        self.at = at
        self.playing = playing
    }

    func expected(rate: Double, playing: Bool, now: Date) -> Double {
        time + (playing ? max(0, now.timeIntervalSince(at)) * rate : 0)
    }

    func holds(against reading: MiniReport.Reading?, now: Date) -> Bool {
        let age = now.timeIntervalSince(at)
        guard age < Self.longest else { return false }
        guard let reading else { return true }
        if abs(reading.time - expected(rate: reading.rate, playing: reading.playing, now: now)) > Self.near { return true }
        return playing == true && !reading.playing && age < Self.settle
    }

    func sounding(now: Date) -> Bool {
        playing == true && now.timeIntervalSince(at) < Self.settle
    }

    func position(duration: Double, rate: Double) -> MiniPosition {
        MiniPosition(time: max(0, min(duration, time)), duration: duration, rate: rate, playing: false, at: at)
    }
}

extension MiniRule {
    static func lead(_ frames: [MiniFrameSeen], was: String?) -> String? {
        func first(_ list: [MiniFrameSeen], by order: (MiniFrameSeen) -> Double) -> String? {
            (list.first(where: \.main) ?? list.max { order($0) < order($1) })?.key
        }
        let usable = frames.filter { $0.reading != nil || $0.declared }
        guard !usable.isEmpty else { return nil }
        let reported = usable.filter { $0.reading?.source == "page" }
        if !reported.isEmpty {
            if let main = reported.first(where: \.main) { return main.key }
            if let was, reported.contains(where: { $0.key == was }) { return was }
            return first(reported, by: \.at)
        }
        let solid = usable.filter { $0.reading.map { !$0.minor } ?? false }
        if let was, let kept = solid.first(where: { $0.key == was }) {
            let newer = solid.filter { $0.key != was && $0.reading?.playing == true && $0.since > kept.since }
            return newer.max { $0.since < $1.since }?.key ?? was
        }
        let playing = solid.filter { $0.reading?.playing == true }
        if !playing.isEmpty { return first(playing, by: \.since) }
        if !solid.isEmpty { return first(solid, by: \.at) }
        let sounding = usable.filter { $0.reading?.playing == true }
        if !sounding.isEmpty { return first(sounding, by: \.since) }
        return first(usable, by: \.at)
    }

    static func rateShown(reading: Double, asked: (rate: Double, at: Date)?, refused: Bool, now: Date) -> Double {
        guard let asked, !refused, now.timeIntervalSince(asked.at) < MiniHold.rateLongest, abs(reading - asked.rate) > 0.001 else { return reading }
        return asked.rate
    }
}
