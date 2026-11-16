import Foundation

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
}
