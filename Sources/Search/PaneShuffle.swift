import CoreGraphics
import Foundation

struct PaneShuffle: Equatable {
    static let lift: CGFloat = 1
    static let hysteresis: CGFloat = 12

    let carried: Tab.ID
    let order: [Tab.ID]
    let frames: [Tab.ID: CGRect]
    let gap: CGFloat
    private(set) var travel: CGFloat = 0
    private(set) var landing: Int
    private(set) var settled = false

    init?(carried: Tab.ID, order: [Tab.ID], frames: [Tab.ID: CGRect], gap: CGFloat) {
        guard order.count > 1, Set(order).count == order.count, let start = order.firstIndex(of: carried),
              order.allSatisfy({ frames[$0] != nil }) else { return nil }
        self.carried = carried
        self.order = order
        self.frames = frames
        self.gap = gap
        landing = start
    }

    var start: Int { order.firstIndex(of: carried) ?? 0 }

    var moved: Bool { landing != start }

    var result: [Tab.ID] { arranged(landing) }

    var targets: [Tab.ID: CGRect] { places(result) }

    private var leading: CGFloat { order.compactMap { frames[$0]?.minX }.min() ?? 0 }

    private var trailing: CGFloat { order.compactMap { frames[$0]?.maxX }.max() ?? 0 }

    private func arranged(_ place: Int) -> [Tab.ID] {
        var out = order
        out.remove(at: start)
        out.insert(carried, at: min(max(0, place), out.count))
        return out
    }

    func places(_ arrangement: [Tab.ID]) -> [Tab.ID: CGRect] {
        var x = leading
        var out: [Tab.ID: CGRect] = [:]
        for id in arrangement {
            guard let frame = frames[id] else { continue }
            out[id] = CGRect(x: x, y: frame.minY, width: frame.width, height: frame.height)
            x += frame.width + gap
        }
        return out
    }

    func shift(of id: Tab.ID) -> CGFloat {
        guard let frame = frames[id] else { return 0 }
        if id == carried, !settled { return travel }
        return (targets[id]?.minX ?? frame.minX) - frame.minX
    }

    mutating func move(by dx: CGFloat) {
        guard !settled, let frame = frames[carried] else { return }
        travel = min(max(dx, leading - frame.minX), trailing - frame.maxX)
        let centre = frame.midX + travel
        func distance(_ place: Int) -> CGFloat {
            abs((places(arranged(place))[carried]?.midX ?? centre) - centre)
        }
        let best = order.indices.min { distance($0) < distance($1) } ?? landing
        if best != landing, distance(best) + Self.hysteresis < distance(landing) { landing = best }
    }

    mutating func drop() {
        settled = true
    }

    mutating func cancel() {
        landing = start
        settled = true
    }
}
