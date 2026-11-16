import AppKit

struct RowJoin: Equatable {
    var above = false
    var below = false

    static let none = RowJoin()
}

enum RowRun {
    static let apart = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    static func lit(picked: Set<UUID>, active: UUID?) -> Set<UUID> {
        guard !picked.isEmpty else { return [] }
        guard let active else { return picked }
        return picked.union([active])
    }

    static func join(_ id: UUID, in order: [UUID], lit: Set<UUID>) -> RowJoin {
        guard id != apart, lit.contains(id), let at = order.firstIndex(of: id) else { return .none }
        let above = at > 0 && order[at - 1] != apart && lit.contains(order[at - 1])
        let below = at + 1 < order.count && order[at + 1] != apart && lit.contains(order[at + 1])
        return RowJoin(above: above, below: below)
    }

    static func sink(pressed: Bool, gives: Bool, calm: Bool) -> CGFloat {
        pressed && gives && !calm ? Motion.give : 1
    }
}

@MainActor
enum SwitchFade {
    private static var switched: CFTimeInterval = 0

    static func switching() {
        switched = CACurrentMediaTime()
    }

    static func within(from: UUID?, to: [UUID], among tabs: [UUID]) -> Bool {
        guard CACurrentMediaTime() - switched < 0.25, let from, !to.contains(from) else { return false }
        return tabs.contains(from)
    }
}
