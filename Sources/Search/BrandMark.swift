import CoreGraphics

enum BrandMark {
    static let weight: CGFloat = 0.2
    static let margin: CGFloat = 0.03
    static let sink: CGFloat = 0.05

    static var height: CGFloat { (1 - 2 * margin) / (1 + weight) }

    static let route: [CGPoint] = {
        var points: [CGPoint] = []
        BroadwayMap.route().applyWithBlock { element in
            let at = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint, .addLineToPoint: points.append(at[0])
            case .addQuadCurveToPoint: points += [at[0], at[1]]
            default: break
            }
        }
        func cut(_ a: CGPoint, _ b: CGPoint, at y: CGFloat) -> CGPoint {
            CGPoint(x: a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y), y: y)
        }
        return [cut(points[0], points[1], at: 0), points[1], points[2], points[3], cut(points[3], points[4], at: BroadwayMap.canvas)]
    }()

    static let centre: CGFloat = {
        let p = route
        var samples = [p[0]]
        for step in 0...32 {
            let t = CGFloat(step) / 32
            let u = 1 - t
            samples.append(CGPoint(x: u * u * p[1].x + 2 * u * t * p[2].x + t * t * p[3].x,
                                   y: u * u * p[1].y + 2 * u * t * p[2].y + t * t * p[3].y))
        }
        samples.append(p[4])
        var length: CGFloat = 0
        var moment: CGFloat = 0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let piece = hypot(b.x - a.x, b.y - a.y)
            length += piece
            moment += piece * (a.x + b.x) / 2
        }
        return moment / length
    }()

    static func points(in box: CGRect) -> [CGPoint] {
        let side = min(box.width, box.height)
        let scale = side * height / BroadwayMap.canvas
        let origin = CGPoint(x: box.midX - side / 2, y: box.midY - side / 2)
        let foot = side * (margin + height * weight / 2)
        return route.map { CGPoint(x: box.midX + ($0.x - centre) * scale, y: origin.y + foot + $0.y * scale) }
    }

    static func lineWidth(in box: CGRect) -> CGFloat {
        min(box.width, box.height) * height * weight
    }

    static func path(in box: CGRect) -> CGPath {
        let p = points(in: box)
        let path = CGMutablePath()
        path.move(to: p[0])
        path.addLine(to: p[1])
        path.addQuadCurve(to: p[3], control: p[2])
        path.addLine(to: p[4])
        return path
    }
}
