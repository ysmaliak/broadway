import AppKit

struct GiveBack: Equatable {
    var from: CGFloat = 0
    var to: CGFloat = 0
    var on = false
    var base: CGFloat = 0
    var rest: CGFloat = 0
    var slack: CGFloat = 0
    var run = 0

    var target: CGFloat { GiveBack.target(offset: base, maximum: rest) }

    static func target(offset: CGFloat, maximum: CGFloat) -> CGFloat {
        min(offset, max(0, maximum))
    }

    static func slack(offset: CGFloat, maximum: CGFloat) -> CGFloat {
        max(0, offset - maximum)
    }

    static func at(_ phase: CGFloat, run: Int, from: CGFloat, to: CGFloat) -> CGFloat {
        let done = min(1, max(0, phase - CGFloat(run - 1)))
        return from + (to - from) * done
    }
}
