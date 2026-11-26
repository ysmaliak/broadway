import CoreGraphics
import Foundation

enum BroadwayMap {
    static let canvas: CGFloat = 1024
    static let tilt: CGFloat = 29
    static let avenuePitch: CGFloat = 190
    static let streetPitch: CGFloat = 54
    static let graceChurch = (avenue: CGFloat(3.76), street: CGFloat(10))
    static let here = CGPoint(x: 570, y: 445)
    static let avenues = -6...14
    static let firstStreet = -30
    static let lastStreet = 50
    static let streetStep = 2
    static let gridWidth: CGFloat = 12
    static let lineWidth: CGFloat = 124
    static let plateCorner: CGFloat = 229
    static let reachOfCorner: CGFloat = 1.52866483

    static let inkTop: UInt32 = 0x24262D
    static let inkBottom: UInt32 = 0x111216
    static let inkGrid: UInt32 = 0xFFFFFF
    static let inkGridAlpha: CGFloat = 0.13
    static let inkLine: UInt32 = 0xFFFFFF

    static func spot(avenue: CGFloat, street: CGFloat) -> CGPoint {
        let west = (avenue - graceChurch.avenue) * avenuePitch
        let north = (street - graceChurch.street) * streetPitch
        let turn = tilt * .pi / 180
        return CGPoint(x: here.x - west * cos(turn) + north * sin(turn), y: here.y + west * sin(turn) + north * cos(turn))
    }

    static func route() -> CGPath {
        let bend = spot(avenue: graceChurch.avenue, street: graceChurch.street)
        let fourthStreet = spot(avenue: 3.84, street: 4)
        let madisonSquare = spot(avenue: 5, street: 24)
        func toward(_ point: CGPoint, _ reach: CGFloat) -> CGPoint {
            let length = hypot(point.x - bend.x, point.y - bend.y)
            return CGPoint(x: bend.x + (point.x - bend.x) / length * reach, y: bend.y + (point.y - bend.y) / length * reach)
        }
        let path = CGMutablePath()
        path.move(to: toward(fourthStreet, 900))
        path.addLine(to: toward(fourthStreet, 260))
        path.addQuadCurve(to: toward(madisonSquare, 260), control: bend)
        path.addLine(to: toward(madisonSquare, 1100))
        return path
    }

    static func grid() -> CGPath {
        let path = CGMutablePath()
        for avenue in avenues {
            path.move(to: spot(avenue: CGFloat(avenue), street: CGFloat(firstStreet)))
            path.addLine(to: spot(avenue: CGFloat(avenue), street: CGFloat(lastStreet)))
        }
        for street in stride(from: firstStreet, through: lastStreet, by: streetStep) {
            path.move(to: spot(avenue: CGFloat(avenues.lowerBound), street: CGFloat(street)))
            path.addLine(to: spot(avenue: CGFloat(avenues.upperBound), street: CGFloat(street)))
        }
        return path
    }

    static func slab(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, min(rect.width, rect.height) / 2 / reachOfCorner)
        let corners: [(CGPoint, CGVector, CGVector)] = [
            (CGPoint(x: rect.maxX, y: rect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: rect.maxX, y: rect.minY), CGVector(dx: 0, dy: 1), CGVector(dx: -1, dy: 0)),
            (CGPoint(x: rect.minX, y: rect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: rect.minX, y: rect.maxY), CGVector(dx: 0, dy: -1), CGVector(dx: 1, dy: 0)),
        ]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + reachOfCorner * r, y: rect.maxY))
        for (corner, along, next) in corners {
            func at(_ a: CGFloat, _ b: CGFloat) -> CGPoint {
                CGPoint(x: corner.x + (a * along.dx + b * next.dx) * r, y: corner.y + (a * along.dy + b * next.dy) * r)
            }
            path.addLine(to: at(reachOfCorner, 0))
            path.addCurve(to: at(0.66993427, 0.06549600), control1: at(1.08849323, 0), control2: at(0.86840689, 0))
            path.addLine(to: at(0.63149399, 0.07491100))
            path.addCurve(to: at(0.07491100, 0.63149399), control1: at(0.37282392, 0.16905899), control2: at(0.16905899, 0.37282392))
            path.addLine(to: at(0.06549600, 0.66993427))
            path.addCurve(to: at(0, reachOfCorner), control1: at(0, 0.86840689), control2: at(0, 1.08849323))
        }
        path.closeSubpath()
        return path
    }
}
