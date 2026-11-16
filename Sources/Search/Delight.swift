import AppKit
import Observation

@MainActor
@Observable
final class Delight {
    static let shared = Delight()

    enum Moment: String, CaseIterable {
        case firstPin = "delight.firstPin"
        case firstSpace = "delight.firstSpace"

        var line: String {
            switch self {
            case .firstPin: return "Your first pin. It stays put, in every window."
            case .firstSpace: return "A new space. Make it yours with a colour."
            }
        }
    }

    static let showKey = "delight.show"

    struct Burst: Equatable {
        let id = UUID()
        let window: ObjectIdentifier
    }

    private(set) var burst: Burst?
    @ObservationIgnored private(set) var celebrated: [Moment] = []

    nonisolated static func due(_ moment: Moment, testing: Bool, forced: Bool, done: Bool) -> Bool {
        if done { return false }
        return !testing || forced
    }

    func first(_ moment: Moment, in browser: Browser) {
        let settings = Store.settings
        let done = settings.bool(forKey: moment.rawValue)
        guard Self.due(moment, testing: Store.testing, forced: settings.bool(forKey: Self.showKey), done: done) else { return }
        settings.set(true, forKey: moment.rawValue)
        celebrated.append(moment)
        browser.announce(moment.line)
        burst(in: browser)
    }

    func burst(in browser: Browser) {
        guard !Motion.reduced else { return }
        let made = Burst(window: ObjectIdentifier(browser))
        burst = made
        DispatchQueue.main.asyncAfter(deadline: .now() + Confetti.lasts + 0.2) { [weak self] in
            if self?.burst == made { self?.burst = nil }
        }
    }

    static func markExisting(pins: Int, spaces: Int) {
        guard !Store.testing else { return }
        let keptPins = FileManager.default.fileExists(atPath: Store.file("pins.json").path)
        if pins > 0 || keptPins { Store.settings.set(true, forKey: Moment.firstPin.rawValue) }
        if spaces > 1 { Store.settings.set(true, forKey: Moment.firstSpace.rawValue) }
    }
}

final class DelightView: KitFlippedView {
    let browser: Browser
    var delight: Delight = .shared
    private var fired: UUID?

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }

    override func layout() {
        super.layout()
        guard let burst = delight.burst, burst.window == ObjectIdentifier(browser), burst.id != fired else { return }
        fired = burst.id
        guard let layer, bounds.width > 0, bounds.height > 0 else { return }
        Confetti.throwing(in: layer, size: bounds.size, seed: UInt64(Date().timeIntervalSince1970))
    }
}

enum Confetti {
    static let lasts: Double = 1.8
    static let count = 70

    struct Piece: Equatable {
        let x: Double
        let drift: Double
        let rise: Double
        let spin: Double
        let size: Double
        let colour: NSColor
        let round: Bool
    }

    static func pieces(seed: UInt64) -> [Piece] {
        var dots = SeededDots(seed: seed)
        return (0..<count).map { index in
            Piece(x: 0.3 + dots.next() * 0.4,
                  drift: (dots.next() - 0.5) * 0.9,
                  rise: 0.55 + dots.next() * 0.55,
                  spin: (dots.next() - 0.5) * 12,
                  size: 5 + dots.next() * 6,
                  colour: KitBrand.confetti[index % KitBrand.confetti.count],
                  round: dots.next() > 0.6)
        }
    }

    static func spot(_ piece: Piece, at t: Double, in size: CGSize) -> CGPoint {
        let up = piece.rise * size.height * 0.9
        let y = size.height * 0.95 - up * t * 2.2 + 0.5 * size.height * 1.35 * t * t
        let x = size.width * (piece.x + piece.drift * t * 0.45)
        return CGPoint(x: x, y: y)
    }

    @discardableResult
    static func throwing(in host: CALayer, size: CGSize, seed: UInt64) -> CALayer {
        let burst = CALayer()
        burst.frame = CGRect(origin: .zero, size: size)
        let steps = 36
        let times = (0...steps).map { Double($0) / Double(steps) }
        for piece in pieces(seed: seed) {
            let bit = CALayer()
            let height = piece.round ? piece.size : piece.size / 2
            bit.bounds = CGRect(x: 0, y: 0, width: piece.size, height: height)
            bit.anchorPoint = CGPoint(x: 0.5, y: piece.round ? 0.25 : 0.5)
            bit.backgroundColor = piece.colour.cgColor
            bit.cornerRadius = piece.round ? piece.size / 2 : 0
            bit.opacity = 0
            bit.position = spot(piece, at: 0, in: size)
            let path = CAKeyframeAnimation(keyPath: "position")
            path.values = times.map { NSValue(point: spot(piece, at: $0 * lasts, in: size)) }
            path.keyTimes = times.map { NSNumber(value: $0) }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = piece.spin * lasts
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, NSNumber(value: (lasts - 0.4) / lasts), 1]
            let group = CAAnimationGroup()
            for part in [path, turn, fade] as [CAAnimation] { part.duration = lasts }
            group.animations = [path, turn, fade]
            group.duration = lasts
            group.timingFunction = CAMediaTimingFunction(name: .linear)
            bit.add(group, forKey: "confetti")
            burst.addSublayer(bit)
        }
        host.addSublayer(burst)
        DispatchQueue.main.asyncAfter(deadline: .now() + lasts) { burst.removeFromSuperlayer() }
        return burst
    }
}
