import CoreGraphics

enum SideAir: Equatable {
    case row
    case folder
    case divider

    var margin: CGFloat {
        switch self {
        case .row: Metrics.sideGap
        case .folder: Metrics.folderAir
        case .divider: Metrics.sideDividerGap
        }
    }

    static func between(_ above: SideAir?, _ below: SideAir) -> CGFloat {
        guard let above else { return 0 }
        if above == .folder, below == .folder { return Metrics.sideGap }
        return max(above.margin, below.margin)
    }

    static func span(_ blocks: [(air: SideAir, height: CGFloat)]) -> CGFloat {
        var flow = SideFlow()
        return blocks.reduce(0) { $0 + flow.take($1.air) + $1.height }
    }
}

struct SideFlow {
    private(set) var last: SideAir?
    private var room: CGFloat = 0

    func lead(_ next: SideAir) -> CGFloat {
        guard let last else { return 0 }
        let gap = SideAir.between(last, next)
        return last == .divider ? max(gap, room) : gap
    }

    mutating func take(_ next: SideAir) -> CGFloat {
        let gap = lead(next)
        last = next
        room = gap
        return gap
    }
}
