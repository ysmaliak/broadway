import AppKit

struct FootRow: Equatable {
    struct Mark: Equatable {
        var from: CGFloat
        var to: CGFloat
        var share: CGFloat
        var size: CGFloat
        var dot: CGFloat
        var alpha: CGFloat

        var middle: CGFloat { (from + to) / 2 }
        var small: Bool { share < FootRow.smallBelow }
    }

    static let cell: CGFloat = 30
    static let tight: CGFloat = 20
    static let smallBelow: CGFloat = 0.62
    static let none = FootRow(marks: [], pitch: cell, room: 0, scroll: 0, rest: 0, range: 0, before: 0, after: 0)

    let marks: [Mark]
    let pitch: CGFloat
    let room: CGFloat
    let scroll: CGFloat
    let rest: CGFloat
    let range: CGFloat
    let before: CGFloat
    let after: CGFloat

    var many: Bool { range > 0 }
    var pan: CGFloat { scroll - rest }
    var page: CGFloat { max(pitch, room - 2 * FootRow.reach(pitch: pitch, room: room) - pitch) }

    static func reach(pitch: CGFloat, room: CGFloat) -> CGFloat {
        min(1.5 * pitch, max(pitch, room * 0.2))
    }

    static func ramp(_ share: CGFloat) -> CGFloat {
        let x = min(1, max(0, share))
        return x * x * (3 - 2 * x)
    }

    static func focus(_ lights: [CGFloat]) -> CGFloat? {
        let weight = lights.reduce(0, +)
        guard weight > 0 else { return nil }
        return zip(lights.indices, lights).reduce(0) { $0 + CGFloat($1.0) * $1.1 } / weight
    }

    static func lay(count: Int, draft: CGFloat? = nil, room: CGFloat, focus: CGFloat, pan: CGFloat = 0) -> FootRow {
        let extra = draft.map { min(1, max(0, $0)) }
        let units = CGFloat(count) + (extra ?? 0)
        let total = count + (extra == nil ? 0 : 1)
        guard total > 0, room > 0 else { return .none }
        let pitch = units > 0 ? min(cell, max(tight, room / units)) : cell
        let length = units * pitch
        let range = max(0, length - room)
        let lead = max(0, (room - length) / 2)

        func edge(_ index: Int) -> CGFloat {
            CGFloat(min(index, count)) * pitch + (index > count ? (extra ?? 0) * pitch : 0)
        }
        func middle(_ index: Int) -> CGFloat {
            let at = min(max(0, index), total - 1)
            return (edge(at) + edge(at + 1)) / 2
        }
        let held = min(CGFloat(total - 1), max(0, focus))
        let low = Int(held.rounded(.down))
        let part = held - CGFloat(low)
        let centre = middle(low) + (middle(low + 1) - middle(low)) * part
        let rest = min(range, max(0, centre - room / 2))
        let scroll = min(range, max(0, rest + pan))

        let reach = FootRow.reach(pitch: pitch, room: room)
        let before = reach * ramp(scroll / pitch)
        let after = reach * ramp((range - scroll) / pitch)
        func lens(_ x: CGFloat) -> CGFloat {
            if x < before {
                return before > 0 ? before * exp((x - before) / before) : max(0, x)
            }
            if x > room - after {
                let back = room - x
                return room - (after > 0 ? after * exp((back - after) / after) : max(0, back))
            }
            return x
        }

        var marks: [Mark] = []
        marks.reserveCapacity(total)
        for index in 0..<total {
            let natural = edge(index + 1) - edge(index)
            let from = lens(lead + edge(index) - scroll)
            let to = lens(lead + edge(index + 1) - scroll)
            var share = natural > 0.0001 ? (to - from) / natural : 1
            if abs(share - 1) < 0.000001 { share = 1 }
            share = min(1, max(0, share))
            marks.append(Mark(from: from, to: to, share: share, size: pitch / cell * share,
                              dot: min(1, max(0, (0.8 - share) / 0.3)), alpha: min(1, max(0, (share - 0.12) / 0.2))))
        }
        return FootRow(marks: marks, pitch: pitch, room: room, scroll: scroll, rest: rest, range: range, before: before, after: after)
    }
}
