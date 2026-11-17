import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(1))) struct BrandMarkTests {
    static let box = CGRect(x: 0, y: 0, width: 32, height: 32)

    static func root() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func number(_ value: CGFloat) -> String {
        var text = String(format: "%.2f", Double(value))
        while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func lean(_ from: CGPoint, _ to: CGPoint) -> CGFloat {
        atan2(to.x - from.x, to.y - from.y) * 180 / .pi
    }

    @Test func theMarkIsTheIconsBroadwayCutToThePlate() {
        let bend = BroadwayMap.spot(avenue: BroadwayMap.graceChurch.avenue, street: BroadwayMap.graceChurch.street)
        let fourthStreet = BroadwayMap.spot(avenue: 3.84, street: 4)
        let madisonSquare = BroadwayMap.spot(avenue: 5, street: 24)

        let p = BrandMark.points(in: Self.box)

        #expect(abs(Self.lean(p[0], p[1]) - Self.lean(fourthStreet, bend)) < 0.01)
        #expect(abs(Self.lean(p[3], p[4]) - Self.lean(bend, madisonSquare)) < 0.01)
        #expect(Self.lean(p[0], p[1]) > 30 && Self.lean(p[3], p[4]) > 10 && Self.lean(p[3], p[4]) < 13)
        #expect(abs((p[2].y - p[0].y) / (p[4].y - p[0].y) - bend.y / BroadwayMap.canvas) < 0.001)
        #expect(p[0].x < p[4].x && p[0].y < p[4].y)
        let chord = (p[4].x - p[0].x) * (p[2].y - p[0].y) - (p[4].y - p[0].y) * (p[2].x - p[0].x)
        #expect(chord < 0)
    }

    @Test func everyPointOfTheMarkLiesOnTheIconsLine() {
        let scale = Self.box.width * BrandMark.height / BroadwayMap.canvas
        let foot = Self.box.width * (BrandMark.margin + BrandMark.height * BrandMark.weight / 2)
        let line = BroadwayMap.route().copy(strokingWithWidth: 2, lineCap: .butt, lineJoin: .round, miterLimit: 1)
        var drawn: [CGPoint] = []

        BrandMark.path(in: Self.box).copy(dashingWithPhase: 0, lengths: [0.05, 0.05]).applyWithBlock { element in
            if element.pointee.type == .moveToPoint { drawn.append(element.pointee.points[0]) }
        }

        #expect(drawn.count > 250)
        for point in drawn {
            let icon = CGPoint(x: BrandMark.centre + (point.x - Self.box.midX) / scale, y: (point.y - foot) / scale)
            #expect(line.contains(icon), "\(point) is \(icon) on the icon")
        }
    }

    @Test func theRoundEndsSitInsideTheBoxWithTheSameMarginTopAndBottom() {
        let width = BrandMark.lineWidth(in: Self.box)

        let ink = BrandMark.path(in: Self.box).copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1).boundingBoxOfPath

        #expect(abs(width / (Self.box.height * BrandMark.height) - BrandMark.weight) < 0.0001)
        #expect(abs(ink.minY - Self.box.height * BrandMark.margin) < 0.01)
        #expect(abs(Self.box.maxY - ink.maxY - Self.box.height * BrandMark.margin) < 0.01)
        #expect(ink.minX > Self.box.minX && ink.maxX < Self.box.maxX)
    }

    @Test(.enabled(if: WebRepo.here)) func theSiteDrawsTheAppsMark() throws {
        let side = Self.box.width
        let p = BrandMark.points(in: Self.box).map { (x: Self.number($0.x), y: Self.number(side - $0.y)) }
        let d = "M\(p[0].x) \(p[0].y)L\(p[1].x) \(p[1].y)Q\(p[2].x) \(p[2].y) \(p[3].x) \(p[3].y)L\(p[4].x) \(p[4].y)"
        let svg = #"<svg class="mark" viewBox="0 0 32 32" aria-hidden="true"><path d="\#(d)"/></svg>"#
        let stroke = "stroke-width: \(Self.number(BrandMark.lineWidth(in: Self.box)));"
        let place = "top: calc(1.2em * \(Self.number(BrandMark.margin)) + \(Self.number(BrandMark.sink))em); width: 1.2em; height: 1.2em; margin-top: -0.4em;"
        let site = try #require(WebRepo.site)

        let pages = try ["index.html", "404.html", "privacy.html", "terms.html"].map { try String(contentsOf: site.appendingPathComponent($0), encoding: .utf8) }
        let share = try String(contentsOf: site.appendingPathComponent("tools/share.html"), encoding: .utf8)
        let styles = try ["styles.css", "404.css"].map { try String(contentsOf: site.appendingPathComponent($0), encoding: .utf8) }

        for page in pages {
            #expect(page.contains(svg))
        }
        #expect(share.contains(#"<svg viewBox="0 0 32 32" aria-hidden="true"><path d="\#(d)"/></svg>"#))
        for style in styles {
            #expect(style.contains(stroke))
            #expect(style.contains("stroke-linecap: round; stroke-linejoin: round;"))
            #expect(style.contains(place))
        }
    }
}
