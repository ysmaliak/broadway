import AppKit

enum PinMorph {
    static func tile(fromPin: Bool, crossing: Bool) -> Bool { fromPin != crossing }

    static let slow: Double = Store.testing ? Double(ProcessInfo.processInfo.environment["SEARCH_PIN_SLOW"] ?? "") ?? 1 : 1
}

enum PinShape {
    static func mix(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    static func mix(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: mix(a.minX, b.minX, t), y: mix(a.minY, b.minY, t),
               width: mix(a.width, b.width, t), height: mix(a.height, b.height, t))
    }

    static func centred(_ size: CGSize, on point: CGPoint) -> CGRect {
        CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height)
    }

    static func row(hand: CGPoint, fromPin: Bool, source: CGRect?, grab: CGSize, rows: CGRect, height: CGFloat) -> CGRect {
        if !fromPin, let source { return CGRect(x: source.minX, y: hand.y - grab.height, width: source.width, height: height) }
        let width = rows.width > 0 ? rows.width : source?.width ?? 200
        let x = rows.width > 0 ? rows.minX : hand.x - width / 2
        let y = fromPin ? hand.y - height / 2 : hand.y - grab.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func tile(hand: CGPoint, fromPin: Bool, source: CGRect?, size: CGSize) -> CGRect {
        if fromPin, let source { return source }
        return centred(size, on: hand)
    }

    static func frame(row: CGRect, tile: CGRect, form: CGFloat, aim: CGRect?, landed: CGFloat) -> CGRect {
        let carried = mix(row, tile, form)
        guard let aim else { return carried }
        return mix(carried, aim, landed)
    }
}

@MainActor
final class PinDragProbe {
    static let shared = PinDragProbe()
    var drive: ((Tab.ID, CGPoint?, Bool) -> Bool)?
    var page: CGRect = .zero
    var log: [String] = []
}

@MainActor
enum PinFlightTrace {
    static var on = false
    static var started: CFTimeInterval = 0
    static var log: [[String: Double]] = []
    static var events: [String] = []

    static func event(_ text: @autoclosure () -> String) {
        guard on else { return }
        events.append(String(format: "%.0f ", (CACurrentMediaTime() - started) * 1000) + text())
    }

    static func note(_ frame: CGRect, form: CGFloat, landed: CGFloat, aimed: Bool) -> Int {
        guard on else { return 0 }
        log.append(["t": (CACurrentMediaTime() - started) * 1000, "x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height,
                    "form": form, "landed": landed, "aimed": aimed ? 1 : 0])
        return 0
    }
}
