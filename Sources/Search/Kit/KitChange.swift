import Foundation

enum KitChange {
    static private(set) var easing = false

    static func eased<Result>(_ change: () throws -> Result) rethrows -> Result {
        let was = easing
        easing = true
        defer { easing = was }
        return try change()
    }

    static func still<Result>(_ change: () throws -> Result) rethrows -> Result {
        let was = easing
        easing = false
        defer { easing = was }
        return try change()
    }
}
