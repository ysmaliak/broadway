import Foundation

struct FloatSeekRange: Equatable {
    let start: Double
    let end: Double
}

struct FloatTimeline: Equatable {
    let ranges: [FloatSeekRange]
    let live: Bool

    init(ranges: [[Double]] = [], live: Bool = false) {
        self.ranges = ranges.compactMap {
            guard $0.count == 2, $0[0].isFinite, $0[1].isFinite, $0[0] >= 0, $0[1] > $0[0] else { return nil }
            return FloatSeekRange(start: $0[0], end: $0[1])
        }.sorted { $0.start < $1.start }
        self.live = live
    }

    var start: Double { ranges.first?.start ?? 0 }
    var end: Double { ranges.map(\.end).max() ?? 0 }
    var span: Double { end - start }
    var seekable: Bool { !ranges.isEmpty }

    func fraction(_ seconds: Double) -> Double {
        span > 0 ? FloatTime.clamp((seconds - start) / span) : 0
    }

    func target(_ fraction: Double) -> Double? {
        guard seekable else { return nil }
        return clamp(start + FloatTime.clamp(fraction) * span)
    }

    func clamp(_ seconds: Double) -> Double? {
        guard seconds.isFinite, seekable else { return nil }
        if ranges.contains(where: { seconds >= $0.start && seconds <= $0.end }) { return seconds }
        return ranges.flatMap { [$0.start, $0.end] }.min { abs($0 - seconds) < abs($1 - seconds) }
    }
}

struct FloatCaption: Equatable, Identifiable {
    let id: Int
    let name: String
    let selected: Bool
}

struct FloatChapter: Equatable, Identifiable {
    let start: Double
    let end: Double
    let name: String
    var id: Double { start }
}

struct FloatMediaState {
    var current: Double = 0
    var playing = false
    var rate: Double?
    var timeline = FloatTimeline()
    var captions: [FloatCaption] = []
    var chapters: [FloatChapter] = []
    var waiting = false

    init() {}

    init(_ value: [String: Any]) {
        current = (value["current"] as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 0
        playing = value["playing"] as? Bool ?? false
        rate = value["rate"] as? Double
        timeline = FloatTimeline(ranges: value["ranges"] as? [[Double]] ?? [], live: value["live"] as? Bool ?? false)
        waiting = (value["waiting"] as? Double ?? 0) >= 0.4
        captions = (value["captions"] as? [[String: Any]] ?? []).compactMap {
            guard let id = $0["id"] as? Int, let name = $0["name"] as? String else { return nil }
            return FloatCaption(id: id, name: name, selected: $0["selected"] as? Bool ?? false)
        }
        var seen = Set<Double>()
        chapters = (value["chapters"] as? [[String: Any]] ?? []).compactMap {
            guard let start = $0["start"] as? Double, let end = $0["end"] as? Double,
                  start.isFinite, end.isFinite, start >= 0, end > start,
                  let name = $0["name"] as? String, !name.isEmpty, seen.insert(start).inserted else { return nil }
            return FloatChapter(start: start, end: end, name: name)
        }.sorted { $0.start < $1.start }
    }
}
