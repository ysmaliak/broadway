import Foundation
import QuartzCore

enum AddressMove: Equatable {
    case still
    case fade
    case roll(down: Bool)
    case slide(back: Bool)

    enum Cause: Equatable {
        case tab(from: Int?, to: Int?)
        case navigation(back: Bool)
        case space
        case style
    }

    static func between(_ old: String?, _ new: String?, cause: Cause, reduced: Bool, light: Bool) -> AddressMove {
        guard old != new else { return .still }
        let move: AddressMove
        switch cause {
        case .space, .style: return .still
        case let .tab(from, to):
            guard let from, let to else { move = .roll(down: true); break }
            move = .roll(down: to >= from)
        case let .navigation(back):
            move = .slide(back: back)
        }
        if reduced { return .still }
        if light { return .fade }
        return move
    }

    struct Mark: Equatable {
        let tab: UUID?
        let space: UUID
        let text: String?
        var full = false
    }

    static func cause(from old: Mark, to new: Mark, step: TabStep?, back: Bool) -> Cause {
        if old.space != new.space { return .space }
        if old.full != new.full { return .style }
        if old.tab != new.tab {
            guard let step, step.to == new.tab else { return .tab(from: nil, to: nil) }
            return .tab(from: step.fromPlace, to: step.toPlace)
        }
        return .navigation(back: back)
    }

    struct TabStep: Equatable {
        let to: UUID?
        let fromPlace: Int?
        let toPlace: Int?
    }

    var curve: KitCurve {
        switch self {
        case .still: .none
        case .fade: .easeOut(0.16)
        case .roll, .slide: Motion.kitRoll
        }
    }

    static func tick(_ old: String, _ new: String, same: Bool, shown: Bool, reduced: Bool, light: Bool) -> AddressMove {
        guard old != new, same, shown, !old.isEmpty else { return .still }
        if reduced { return .still }
        if light { return .fade }
        return .roll(down: !Ticks.shrinks(old, new))
    }

    @MainActor
    @discardableResult
    static func glide(_ layer: CALayer, shift: CGSize, leaving: Bool, curve: KitCurve) -> CFTimeInterval {
        let duration: CFTimeInterval = if case .easeOut(let seconds) = curve { seconds } else { 0.34 }
        let base = layer.position
        let away = CGPoint(x: base.x + shift.width, y: base.y + shift.height)
        if shift != .zero, let move = curve.animation("position", from: NSValue(point: leaving ? base : away), to: NSValue(point: leaving ? away : base)) {
            move.fillMode = .both
            move.isRemovedOnCompletion = !leaving
            layer.add(move, forKey: "glide.position")
        }
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = leaving ? [1, 0, 0] : [0, 0, 1, 1]
        fade.keyTimes = leaving ? [0, 0.45, 1] : [0, 0.2, 0.75, 1]
        fade.duration = duration
        fade.fillMode = .both
        fade.isRemovedOnCompletion = !leaving
        layer.add(fade, forKey: "glide.opacity")
        return duration
    }

    enum Ticks {
        struct Part: Equatable {
            let old: Range<Int>
            let new: Range<Int>
            let moves: Bool
        }

        static func shrinks(_ old: String, _ new: String) -> Bool {
            guard let was = numbers(old), let now = numbers(new), was.shape == now.shape else { return false }
            return now.values.lexicographicallyPrecedes(was.values)
        }

        static func numbers(_ text: String) -> (shape: String, values: [Int])? {
            var shape = ""
            var values: [Int] = []
            var digits = ""
            for character in text + " " {
                if character.isASCII, character.isNumber {
                    digits.append(character)
                    continue
                }
                if !digits.isEmpty {
                    values.append(Int(digits) ?? .max)
                    shape.append("#")
                    digits = ""
                }
                shape.append(character)
            }
            return values.isEmpty ? nil : (shape, values)
        }

        static func parts(_ old: String, _ new: String) -> [Part] {
            let was = Array(old), now = Array(new)
            var lead = 0
            while lead < was.count, lead < now.count, was[lead] == now[lead] { lead += 1 }
            var tail = 0
            while tail < was.count - lead, tail < now.count - lead, was[was.count - 1 - tail] == now[now.count - 1 - tail] { tail += 1 }
            var parts: [Part] = []
            if lead > 0 { parts.append(Part(old: 0..<lead, new: 0..<lead, moves: false)) }
            let wasEnd = was.count - tail, nowEnd = now.count - tail
            if wasEnd - lead == nowEnd - lead {
                var at = lead
                while at < wasEnd {
                    let differs = was[at] != now[at]
                    var end = at
                    while end < wasEnd, (was[end] != now[end]) == differs { end += 1 }
                    parts.append(Part(old: at..<end, new: at..<end, moves: differs))
                    at = end
                }
            } else {
                parts.append(Part(old: lead..<wasEnd, new: lead..<nowEnd, moves: true))
            }
            if tail > 0 { parts.append(Part(old: wasEnd..<was.count, new: nowEnd..<now.count, moves: false)) }
            return parts
        }
    }
}
