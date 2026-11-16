import AppKit

extension KitPath {
    static func continuous(_ rect: CGRect, topLeft: CGFloat, topRight: CGFloat, bottomLeft: CGFloat, bottomRight: CGFloat) -> CGPath {
        let limit = min(rect.width, rect.height) / 2 / 1.52866483
        func clamp(_ r: CGFloat) -> CGFloat { max(0, min(r, limit)) }
        let tl = clamp(topLeft), tr = clamp(topRight), bl = clamp(bottomLeft), br = clamp(bottomRight)
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x + px, y: y + py) }
        let path = CGMutablePath()
        path.move(to: p(1.52866483 * tl, 0))
        path.addLine(to: p(w - 1.52866483 * tr, 0))
        if tr > 0 {
            let r = tr
            path.addCurve(to: p(w - 0.63149399 * r, 0.07491100 * r), control1: p(w - 1.08849296 * r, 0), control2: p(w - 0.86840694 * r, 0))
            path.addCurve(to: p(w - 0.07491100 * r, 0.63149399 * r), control1: p(w - 0.37282392 * r, 0.16906387 * r), control2: p(w - 0.16906387 * r, 0.37282392 * r))
            path.addCurve(to: p(w, 1.52866483 * r), control1: p(w, 0.86840694 * r), control2: p(w, 1.08849296 * r))
        }
        path.addLine(to: p(w, h - 1.52866483 * br))
        if br > 0 {
            let r = br
            path.addCurve(to: p(w - 0.07491100 * r, h - 0.63149399 * r), control1: p(w, h - 1.08849296 * r), control2: p(w, h - 0.86840694 * r))
            path.addCurve(to: p(w - 0.63149399 * r, h - 0.07491100 * r), control1: p(w - 0.16906387 * r, h - 0.37282392 * r), control2: p(w - 0.37282392 * r, h - 0.16906387 * r))
            path.addCurve(to: p(w - 1.52866483 * r, h), control1: p(w - 0.86840694 * r, h), control2: p(w - 1.08849296 * r, h))
        }
        path.addLine(to: p(1.52866483 * bl, h))
        if bl > 0 {
            let r = bl
            path.addCurve(to: p(0.63149399 * r, h - 0.07491100 * r), control1: p(1.08849296 * r, h), control2: p(0.86840694 * r, h))
            path.addCurve(to: p(0.07491100 * r, h - 0.63149399 * r), control1: p(0.37282392 * r, h - 0.16906387 * r), control2: p(0.16906387 * r, h - 0.37282392 * r))
            path.addCurve(to: p(0, h - 1.52866483 * r), control1: p(0, h - 0.86840694 * r), control2: p(0, h - 1.08849296 * r))
        }
        path.addLine(to: p(0, 1.52866483 * tl))
        if tl > 0 {
            let r = tl
            path.addCurve(to: p(0.07491100 * r, 0.63149399 * r), control1: p(0, 1.08849296 * r), control2: p(0, 0.86840694 * r))
            path.addCurve(to: p(0.63149399 * r, 0.07491100 * r), control1: p(0.16906387 * r, 0.37282392 * r), control2: p(0.37282392 * r, 0.16906387 * r))
            path.addCurve(to: p(1.52866483 * r, 0), control1: p(0.86840694 * r, 0), control2: p(1.08849296 * r, 0))
        }
        path.closeSubpath()
        return path
    }
}
