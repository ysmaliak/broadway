import Foundation

struct DockLoad: Equatable {
    var received: Int64
    var expected: Int64
    var underWay: Bool
}

enum DockProgress {
    static func fraction(_ loads: [DockLoad]) -> Double? {
        let sized = loads.filter { $0.underWay && $0.expected > 0 }
        guard !sized.isEmpty else { return nil }
        let expected = sized.reduce(Int64(0)) { $0 + $1.expected }
        let received = sized.reduce(Int64(0)) { $0 + min(max(0, $1.received), $1.expected) }
        return min(1, max(0, Double(received) / Double(expected)))
    }

    static func percent(_ loads: [DockLoad]) -> Int? {
        fraction(loads).map { Int(($0 * 100).rounded(.down)) }
    }
}

struct DockPace {
    static let gap: TimeInterval = 0.25

    enum Step: Equatable {
        case draw(Int?)
        case later(Date)
        case nothing
    }

    private(set) var shown: Int?
    private(set) var drawnAt: Date?

    mutating func see(_ percent: Int?, at now: Date) -> Step {
        guard percent != shown else { return .nothing }
        if let drawnAt, now.timeIntervalSince(drawnAt) < Self.gap {
            return .later(drawnAt.addingTimeInterval(Self.gap))
        }
        shown = percent
        drawnAt = now
        return .draw(percent)
    }
}
