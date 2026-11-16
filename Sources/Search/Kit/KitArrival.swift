import AppKit
import QuartzCore

struct KitArrival: Equatable {
    var anchor: CGPoint
    var scale: CGFloat
    var travel: CGSize = .zero
    var leaveScale: CGFloat? = nil
    var leaveTravel: CGSize? = nil

    static let topLeading = CGPoint(x: 0, y: 0)
    static let top = CGPoint(x: 0.5, y: 0)
    static let topTrailing = CGPoint(x: 1, y: 0)
    static let center = CGPoint(x: 0.5, y: 0.5)
    static let bottom = CGPoint(x: 0.5, y: 1)

    static func unfold(from anchor: CGPoint) -> KitArrival {
        KitArrival(anchor: anchor, scale: 0.86, leaveScale: 0.92)
    }

    static func rise(by distance: CGFloat, from anchor: CGPoint = bottom) -> KitArrival {
        KitArrival(anchor: anchor, scale: 0.9, travel: CGSize(width: 0, height: distance), leaveScale: 0.94,
                   leaveTravel: CGSize(width: 0, height: distance * 0.6))
    }

    static let sheet = KitArrival(anchor: center, scale: 0.94, leaveScale: 0.97)

    func transform(in bounds: CGRect, shown: Bool, up: Bool) -> CATransform3D {
        guard !shown else { return CATransform3DIdentity }
        let scale = leaveScale ?? self.scale
        let travel = leaveTravel ?? self.travel
        let x = bounds.width * anchor.x
        let y = bounds.height * (up ? 1 - anchor.y : anchor.y)
        var made = CATransform3DMakeTranslation(x + travel.width, y + (up ? -travel.height : travel.height), 0)
        made = CATransform3DScale(made, scale, scale, 1)
        return CATransform3DTranslate(made, -x, -y, 0)
    }

    static func moveCurve(_ shown: Bool) -> KitCurve {
        Motion.calm ? .none : .spring(shown ? KitSpring(response: 0.3, damping: 0.84) : KitSpring(response: 0.17, damping: 1))
    }

    static func fadeCurve(_ shown: Bool) -> KitCurve {
        Motion.calm ? .easeOut(0.14) : .easeOut(shown ? 0.18 : 0.1)
    }
}

extension NSView {
    func kitArrive(_ shown: Bool, _ arrival: KitArrival, animated: Bool = true) {
        wantsLayer = true
        guard let layer else { return }
        let up = !(superview?.isFlipped ?? false)
        let goal = Motion.calm ? CATransform3DIdentity : arrival.transform(in: bounds, shown: shown, up: up)
        layer.kitAnimate("transform", to: NSValue(caTransform3D: goal), curve: animated ? KitArrival.moveCurve(shown) : .none, key: "arrive")
        layer.kitAnimate("opacity", to: shown ? 1 : 0, curve: animated ? KitArrival.fadeCurve(shown) : .none, key: "arrive.fade")
    }
}
