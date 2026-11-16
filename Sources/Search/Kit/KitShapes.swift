import AppKit

extension KitPath {
    static func continuous(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let r = max(0, min(radius, min(rect.width, rect.height) / 2 / 1.52866483))
        guard r > 0 else {
            path.addRect(rect)
            return path
        }
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x + px, y: y + py) }
        path.move(to: p(1.52866483 * r, 0))
        path.addLine(to: p(w - 1.52866483 * r, 0))
        path.addCurve(to: p(w - 0.63149399 * r, 0.07491100 * r), control1: p(w - 1.08849296 * r, 0), control2: p(w - 0.86840694 * r, 0))
        path.addCurve(to: p(w - 0.07491100 * r, 0.63149399 * r), control1: p(w - 0.37282392 * r, 0.16906387 * r), control2: p(w - 0.16906387 * r, 0.37282392 * r))
        path.addCurve(to: p(w, 1.52866483 * r), control1: p(w, 0.86840694 * r), control2: p(w, 1.08849296 * r))
        path.addLine(to: p(w, h - 1.52866483 * r))
        path.addCurve(to: p(w - 0.07491100 * r, h - 0.63149399 * r), control1: p(w, h - 1.08849296 * r), control2: p(w, h - 0.86840694 * r))
        path.addCurve(to: p(w - 0.63149399 * r, h - 0.07491100 * r), control1: p(w - 0.16906387 * r, h - 0.37282392 * r), control2: p(w - 0.37282392 * r, h - 0.16906387 * r))
        path.addCurve(to: p(w - 1.52866483 * r, h), control1: p(w - 0.86840694 * r, h), control2: p(w - 1.08849296 * r, h))
        path.addLine(to: p(1.52866483 * r, h))
        path.addCurve(to: p(0.63149399 * r, h - 0.07491100 * r), control1: p(1.08849296 * r, h), control2: p(0.86840694 * r, h))
        path.addCurve(to: p(0.07491100 * r, h - 0.63149399 * r), control1: p(0.37282392 * r, h - 0.16906387 * r), control2: p(0.16906387 * r, h - 0.37282392 * r))
        path.addCurve(to: p(0, h - 1.52866483 * r), control1: p(0, h - 0.86840694 * r), control2: p(0, h - 1.08849296 * r))
        path.addLine(to: p(0, 1.52866483 * r))
        path.addCurve(to: p(0.07491100 * r, 0.63149399 * r), control1: p(0, 1.08849296 * r), control2: p(0, 0.86840694 * r))
        path.addCurve(to: p(0.63149399 * r, 0.07491100 * r), control1: p(0.16906387 * r, 0.37282392 * r), control2: p(0.37282392 * r, 0.16906387 * r))
        path.addCurve(to: p(1.52866483 * r, 0), control1: p(0.86840694 * r, 0), control2: p(1.08849296 * r, 0))
        path.closeSubpath()
        return path
    }
}

enum KitOklab {
    static func mix(_ a: NSColor, _ b: NSColor, by share: CGFloat) -> NSColor {
        let x = lab(a), y = lab(b)
        let t = Double(share)
        let l = x.l + (y.l - x.l) * t, m = x.a + (y.a - x.a) * t, s = x.b + (y.b - x.b) * t
        let alpha = x.alpha + (y.alpha - x.alpha) * t
        return color(l, m, s, alpha: alpha)
    }

    private static func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    private static func encoded(_ v: Double) -> Double { v <= 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055 }

    private static func lab(_ color: NSColor) -> (l: Double, a: Double, b: Double, alpha: Double) {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = linear(Double(c.redComponent)), g = linear(Double(c.greenComponent)), b = linear(Double(c.blueComponent))
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s, Double(c.alphaComponent))
    }

    private static func color(_ L: Double, _ A: Double, _ B: Double, alpha: Double) -> NSColor {
        let l = pow(L + 0.3963377774 * A + 0.2158037573 * B, 3)
        let m = pow(L - 0.1055613458 * A - 0.0638541728 * B, 3)
        let s = pow(L - 0.0894841775 * A - 1.2914855480 * B, 3)
        let r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
        let g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
        let b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
        func clamp(_ v: Double) -> CGFloat { CGFloat(max(0, min(1, encoded(v)))) }
        return NSColor(srgbRed: clamp(r), green: clamp(g), blue: clamp(b), alpha: CGFloat(alpha))
    }
}

extension KitPath {
    static func continuous(_ rect: CGRect, left: CGFloat, right: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let k: CGFloat = 1.52866483
        let most = min(rect.width, rect.height) / 2 / k
        let a = max(0, min(left, most)), b = max(0, min(right, most))
        guard a > 0 || b > 0 else {
            path.addRect(rect)
            return path
        }
        let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
        func p(_ px: CGFloat, _ py: CGFloat) -> CGPoint { CGPoint(x: x + px, y: y + py) }
        path.move(to: p(k * a, 0))
        path.addLine(to: p(w - k * b, 0))
        path.addCurve(to: p(w - 0.63149399 * b, 0.07491100 * b), control1: p(w - 1.08849296 * b, 0), control2: p(w - 0.86840694 * b, 0))
        path.addCurve(to: p(w - 0.07491100 * b, 0.63149399 * b), control1: p(w - 0.37282392 * b, 0.16906387 * b), control2: p(w - 0.16906387 * b, 0.37282392 * b))
        path.addCurve(to: p(w, k * b), control1: p(w, 0.86840694 * b), control2: p(w, 1.08849296 * b))
        path.addLine(to: p(w, h - k * b))
        path.addCurve(to: p(w - 0.07491100 * b, h - 0.63149399 * b), control1: p(w, h - 1.08849296 * b), control2: p(w, h - 0.86840694 * b))
        path.addCurve(to: p(w - 0.63149399 * b, h - 0.07491100 * b), control1: p(w - 0.16906387 * b, h - 0.37282392 * b), control2: p(w - 0.37282392 * b, h - 0.16906387 * b))
        path.addCurve(to: p(w - k * b, h), control1: p(w - 0.86840694 * b, h), control2: p(w - 1.08849296 * b, h))
        path.addLine(to: p(k * a, h))
        path.addCurve(to: p(0.63149399 * a, h - 0.07491100 * a), control1: p(1.08849296 * a, h), control2: p(0.86840694 * a, h))
        path.addCurve(to: p(0.07491100 * a, h - 0.63149399 * a), control1: p(0.37282392 * a, h - 0.16906387 * a), control2: p(0.16906387 * a, h - 0.37282392 * a))
        path.addCurve(to: p(0, h - k * a), control1: p(0, h - 0.86840694 * a), control2: p(0, h - 1.08849296 * a))
        path.addLine(to: p(0, k * a))
        path.addCurve(to: p(0.07491100 * a, 0.63149399 * a), control1: p(0, 1.08849296 * a), control2: p(0, 0.86840694 * a))
        path.addCurve(to: p(0.63149399 * a, 0.07491100 * a), control1: p(0.16906387 * a, 0.37282392 * a), control2: p(0.37282392 * a, 0.16906387 * a))
        path.addCurve(to: p(k * a, 0), control1: p(0.86840694 * a, 0), control2: p(1.08849296 * a, 0))
        path.closeSubpath()
        return path
    }
}

extension KitPath {
    static func fine(_ path: CGPath, parts: Int = 4) -> CGPath {
        let made = CGMutablePath()
        var at = CGPoint.zero
        path.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint:
                at = points[0]
                made.move(to: at)
            case .addLineToPoint:
                at = points[0]
                made.addLine(to: at)
            case .addQuadCurveToPoint:
                made.addQuadCurve(to: points[1], control: points[0])
                at = points[1]
            case .addCurveToPoint:
                var p0 = at, p1 = points[0], p2 = points[1]
                let p3 = points[2]
                func mid(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
                for left in stride(from: max(1, parts), to: 1, by: -1) {
                    let t = 1 / CGFloat(left)
                    let a = mid(p0, p1, t), b = mid(p1, p2, t), c = mid(p2, p3, t)
                    let d = mid(a, b, t), e = mid(b, c, t)
                    let f = mid(d, e, t)
                    made.addCurve(to: f, control1: a, control2: d)
                    p0 = f
                    p1 = e
                    p2 = c
                }
                made.addCurve(to: p3, control1: p1, control2: p2)
                at = p3
            case .closeSubpath:
                made.closeSubpath()
            @unknown default:
                break
            }
        }
        return made
    }
}
