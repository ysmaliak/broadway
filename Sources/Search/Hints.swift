import Foundation

enum HintID: String, CaseIterable, Codable {
    case close, reopen, split, clean, next

    var command: String? {
        switch self {
        case .close: return "file.closeTab"
        case .reopen: return "file.reopen"
        case .split: return nil
        case .clean: return "edit.copyCleanLink"
        case .next: return "edit.findNext"
        }
    }

    static func used(by command: String) -> HintID? {
        allCases.first { $0.command == command }
    }

    func line(key: KeyCombo?) -> String? {
        if self == .split { return "Drag a tab onto the page to see both side by side" }
        guard let key else { return nil }
        switch self {
        case .close: return "\(key.display) closes the tab in front"
        case .reopen: return "\(key.display) brings back the tab you just closed"
        case .clean: return "\(key.display) copies the link without its tracking"
        case .next: return "\(key.display) goes to the next match"
        case .split: return nil
        }
    }
}

struct HintRecord: Codable, Equatable {
    var shown: Set<HintID> = []
    var used: Set<HintID> = []
    var last: Date?
}

struct HintSwitch: Equatable {
    let from: UUID
    let to: UUID
    let at: Date
}

struct HintTrail: Equatable {
    var pointerCloses: [Date] = []
    var closedAt: Date?
    var switches: [HintSwitch] = []
    var findPresses = 0
    var lastShown: Date?
}

struct HintScene: Equatable {
    var inAddressField = false
    var inPageBox = false
    var fullScreen = false
    var privateWindow = false
    var agentTab = false
    var announcing = false

    var quiet: Bool { inAddressField || inPageBox || fullScreen || privateWindow || agentTab || announcing }
}

enum HintEvent: Equatable {
    case closedByPointer
    case closedTab
    case openedHistory
    case typedClosedAddress
    case switched(from: UUID, to: UUID, splitOn: Bool, eitherInSplit: Bool)
    case copiedTrackedAddress
    case findNextByPointer
    case searchChanged
}

enum Hints {
    static let closes = 3
    static let closesWithin: TimeInterval = 10 * 60
    static let reopenWithin: TimeInterval = 20
    static let switches = 6
    static let switchesWithin: TimeInterval = 2 * 60
    static let findPresses = 3
    static let afterStart: TimeInterval = 2 * 60
    static let windowGap: TimeInterval = 60 * 60
    static let stays: TimeInterval = 6

    static func note(_ event: HintEvent, trail: inout HintTrail, now: Date) -> HintID? {
        switch event {
        case .closedByPointer:
            trail.pointerCloses = trail.pointerCloses.filter { now.timeIntervalSince($0) < closesWithin } + [now]
            return trail.pointerCloses.count >= closes ? .close : nil
        case .closedTab:
            trail.closedAt = now
            return nil
        case .openedHistory, .typedClosedAddress:
            guard let closed = trail.closedAt, now.timeIntervalSince(closed) <= reopenWithin else { return nil }
            return .reopen
        case .switched(let from, let to, let splitOn, let eitherInSplit):
            trail.switches = trail.switches.filter { now.timeIntervalSince($0.at) < switchesWithin }
                + [HintSwitch(from: from, to: to, at: now)]
            guard splitOn, !eitherInSplit else { return nil }
            return backAndForth(trail.switches) >= switches ? .split : nil
        case .copiedTrackedAddress:
            return .clean
        case .findNextByPointer:
            trail.findPresses += 1
            return trail.findPresses >= findPresses ? .next : nil
        case .searchChanged:
            trail.findPresses = 0
            return nil
        }
    }

    static func backAndForth(_ switches: [HintSwitch]) -> Int {
        guard let last = switches.last, last.from != last.to else { return 0 }
        let pair: Set<UUID> = [last.from, last.to]
        var run = 1
        var after = last
        for step in switches.dropLast().reversed() {
            guard Set([step.from, step.to]) == pair, step.to == after.from else { break }
            run += 1
            after = step
        }
        return run
    }

    static func due(_ id: HintID, record: HintRecord, trail: HintTrail, scene: HintScene, now: Date, launched: Date,
                    calendar: Calendar, key: (String) -> KeyCombo?) -> String? {
        guard !record.shown.contains(id), !record.used.contains(id) else { return nil }
        guard now.timeIntervalSince(launched) >= afterStart else { return nil }
        if let last = record.last, calendar.isDate(last, inSameDayAs: now) { return nil }
        if let here = trail.lastShown, now.timeIntervalSince(here) < windowGap { return nil }
        guard !scene.quiet else { return nil }
        return id.line(key: id.command.flatMap(key))
    }

    static func shown(_ id: HintID, record: inout HintRecord, trail: inout HintTrail, now: Date) {
        record.shown.insert(id)
        record.last = now
        trail.lastShown = now
    }

    static func samePage(_ one: URL, _ other: URL) -> Bool {
        func parts(_ url: URL) -> [String] {
            var host = (url.host ?? "").lowercased()
            if host.hasPrefix("www.") { host.removeFirst(4) }
            var path = url.path
            while path.hasSuffix("/") { path.removeLast() }
            return [host, path, url.query ?? ""]
        }
        return !(one.host ?? "").isEmpty && parts(one) == parts(other)
    }

    static func used(_ command: String, record: inout HintRecord) {
        guard let id = HintID.used(by: command) else { return }
        record.used.insert(id)
    }
}
