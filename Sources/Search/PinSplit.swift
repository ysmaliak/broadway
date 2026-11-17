import Foundation

struct PinSplit: Codable, Equatable {
    var id: UUID
    var axis: TabSplit.Axis = .horizontal
    var size: Double = 0.5

    static func whole(_ defs: [PinDef]) -> [PinDef] {
        var out = defs
        var index = 0
        while index < out.count {
            guard let id = out[index].split?.id else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < out.count, out[end + 1].split?.id == id { end += 1 }
            let elsewhere = out.indices.contains { ($0 < index || $0 > end) && out[$0].split?.id == id }
            if end == index || elsewhere {
                for at in index...end { out[at].split = nil }
            }
            index = end + 1
        }
        return out
    }

    static func groups(_ defs: [PinDef]) -> [(split: PinSplit, ids: [UUID], sizes: [Double])] {
        var out: [(split: PinSplit, ids: [UUID], sizes: [Double])] = []
        for def in whole(defs) {
            guard let split = def.split else { continue }
            if let last = out.last, last.split.id == split.id {
                out[out.count - 1].ids.append(def.id)
                out[out.count - 1].sizes.append(split.size)
            } else {
                out.append((split, [def.id], [split.size]))
            }
        }
        return out
    }
}

extension PinSplit {
    private enum Keys: String, CodingKey { case id, axis, size }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(UUID.self, forKey: .id)
        axis = (try? c.decodeIfPresent(TabSplit.Axis.self, forKey: .axis)) ?? .horizontal
        let read = (try? c.decodeIfPresent(Double.self, forKey: .size)) ?? 0.5
        size = read.isFinite && read > 0 ? read : 0.5
    }
}

extension PinPlaces {
    static let pairMark: CGFloat = 14
    static let pairGap: CGFloat = 4

    static func pair(in box: CGRect, axis: TabSplit.Axis, lift: CGFloat) -> (first: CGRect, second: CGRect) {
        let side = pairMark
        let across = axis == .horizontal
        let span = side * 2 + pairGap
        let x = across ? (box.width - span) / 2 : (box.width - side) / 2
        let y = across ? (box.height - side) / 2 - lift : (box.height - span) / 2 - lift
        let first = CGRect(x: x, y: y, width: side, height: side)
        let second = across ? first.offsetBy(dx: side + pairGap, dy: 0) : first.offsetBy(dx: 0, dy: side + pairGap)
        return (first, second)
    }
}
