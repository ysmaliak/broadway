import AppKit
import Observation
import Combine

@Observable
final class SpaceDraftName {
    var text = ""
}

enum SpaceTitleSize {
    static let height: CGFloat = 30
    static let lift: CGFloat = 7
    static let below: CGFloat = 6
    static let room: CGFloat = height - lift + below

    static func around(_ at: Int, seen: Int, next: Int?, count: Int) -> [Int] {
        var shown: [Int] = []
        for index in [at - 1, at + 1, seen - 1, seen, seen + 1] where index != at && index >= 0 && index < count && !shown.contains(index) {
            shown.append(index)
        }
        if let next, next != at, !shown.contains(next) { shown.append(next) }
        return shown
    }
}
