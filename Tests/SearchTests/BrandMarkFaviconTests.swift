import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Search

@Suite(.timeLimit(.minutes(1)), .enabled(if: WebRepo.here)) struct BrandMarkFaviconTests {
    static let tileScale: CGFloat = 0.72
    static let tileWeight: CGFloat = 8
    static let pages = ["index.html", "404.html", "privacy.html", "terms.html"]
    static let links = """
    <link rel="icon" href="/assets/brand/line-ink-64.png" type="image/png" sizes="64x64" media="(prefers-color-scheme: light)">
    <link rel="icon" href="/assets/brand/line-white-64.png" type="image/png" sizes="64x64" media="(prefers-color-scheme: dark)">
    <link rel="icon" href="/assets/brand/line-tile.svg" type="image/svg+xml" media="not all">
    """

    static func site() -> URL {
        WebRepo.site ?? URL(fileURLWithPath: "/")
    }

    static func number(_ value: CGFloat) -> String {
        var text = String(format: "%.2f", Double(value))
        while text.contains("."), text.hasSuffix("0") || text.hasSuffix(".") { text.removeLast() }
        return text
    }

    struct Pixels {
        var width: Int
        var height: Int
        var bytes: [UInt8]

        func at(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
            let i = (y * width + x) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3])
        }
    }

    static func pixels(_ data: Data) throws -> Pixels {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(width: image.width, height: image.height, bytes: bytes)
    }

    static func mask(_ side: Int, scale: CGFloat, weight: CGFloat) throws -> Pixels {
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        let context = try #require(CGContext(data: &bytes, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let middle = CGFloat(side) / 2
        context.translateBy(x: middle, y: middle)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -middle, y: -middle)
        context.addPath(BrandMark.path(in: box))
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(weight)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        return Pixels(width: side, height: side, bytes: bytes)
    }

    static func misses(_ image: Pixels, _ mask: Pixels, _ inked: ((r: UInt8, g: UInt8, b: UInt8, a: UInt8)) -> Bool) -> Int {
        var count = 0
        for y in 0..<image.height {
            for x in 0..<image.width where inked(image.at(x, y)) != (mask.at(x, y).a > 127) { count += 1 }
        }
        return count
    }

    @Test func theTileSVGIsTheMarkSmallerAndHeavierOnTheIconsInk() throws {
        let side: CGFloat = 32
        let p = BrandMark.points(in: CGRect(x: 0, y: 0, width: side, height: side)).map { (x: Self.number($0.x), y: Self.number(side - $0.y)) }
        let d = "M\(p[0].x) \(p[0].y)L\(p[1].x) \(p[1].y)Q\(p[2].x) \(p[2].y) \(p[3].x) \(p[3].y)L\(p[4].x) \(p[4].y)"
        let corner = Self.number(side * BroadwayMap.plateCorner / BroadwayMap.canvas)
        let top = String(format: "#%06x", BroadwayMap.inkTop)
        let bottom = String(format: "#%06x", BroadwayMap.inkBottom)
        let scale = Self.number(Self.tileScale)
        let weight = Self.number(Self.tileWeight)
        let expected = ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="\##(top)"/><stop offset="1" stop-color="\##(bottom)"/></linearGradient></defs><rect width="32" height="32" rx="\##(corner)" fill="url(#g)"/><path d="\##(d)" transform="translate(16 16) scale(\##(scale)) translate(-16 -16)" fill="none" stroke="#ffffff" stroke-width="\##(weight)" stroke-linecap="round" stroke-linejoin="round"/></svg>"## + "\n"

        let svg = try String(contentsOf: Self.site().appendingPathComponent("assets/brand/line-tile.svg"), encoding: .utf8)

        #expect(svg == expected)
        #expect(!svg.contains("<style"))
        #expect(Self.tileWeight * Self.tileScale > BrandMark.lineWidth(in: CGRect(x: 0, y: 0, width: side, height: side)))
    }

    @Test func theLinePNGsDrawTheMarkAtItsOwnWeight() throws {
        let side: CGFloat = 64
        let mask = try Self.mask(Int(side), scale: 1, weight: BrandMark.lineWidth(in: CGRect(x: 0, y: 0, width: side, height: side)))
        let on = BrandMark.points(in: CGRect(x: 0, y: 0, width: side, height: side))[1]
        for (name, grey) in [("line-ink-64.png", UInt8(0x11)), ("line-white-64.png", UInt8(0xFF))] {
            let image = try Self.pixels(Data(contentsOf: Self.site().appendingPathComponent("assets/brand/\(name)")))

            #expect(image.width == 64 && image.height == 64, "\(name)")
            let missed = Self.misses(image, mask) { $0.a > 127 }
            #expect(missed <= 4, "\(name) \(missed)")
            #expect(image.at(0, 0).a == 0 && image.at(63, 0).a == 0, "\(name)")
            let middle = image.at(Int(on.x), Int(side - on.y))
            #expect(middle.a == 255 && middle.r == grey, "\(name) \(middle)")
        }
    }

    @Test func everyPageLinksTheLinePerLookAndTheTileOnlyForEnginesThatIgnoreMedia() throws {
        for page in Self.pages {
            let html = try String(contentsOf: Self.site().appendingPathComponent(page), encoding: .utf8)
            let icons = html.components(separatedBy: "<link ").dropFirst().filter { $0.hasPrefix(#"rel="icon""#) }

            #expect(html.contains(Self.links), "\(page)")
            #expect(icons.count == 3, "\(page)")
            #expect(!html.contains("favicon.png"), "\(page)")
            for link in icons where link.contains(".svg") || link.contains("svg+xml") {
                #expect(link.contains(#"media="not all""#), "\(page) \(link)")
            }
            for link in html.components(separatedBy: "<link ").dropFirst() where link.hasPrefix(#"rel="icon""#) || link.hasPrefix(#"rel="apple-touch-icon""#) {
                #expect(link.contains(#"href="/"#), "\(page) \(link)")
            }
        }
        for gone in ["favicon.png", "line.svg", "line-tile-64.png"] {
            #expect(!FileManager.default.fileExists(atPath: Self.site().appendingPathComponent("assets/brand/\(gone)").path), "\(gone)")
        }
    }

    @Test func theRootIconIsTheTileAtThreeSizes() throws {
        let data = try Data(contentsOf: Self.site().appendingPathComponent("favicon.ico"))
        let bytes = [UInt8](data)
        func short(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        func long(_ at: Int) -> Int { short(at) | short(at + 2) << 16 }

        #expect(short(0) == 0 && short(2) == 1 && short(4) == 3)
        for (index, side) in [16, 32, 48].enumerated() {
            let entry = 6 + 16 * index
            #expect(Int(bytes[entry]) == side && Int(bytes[entry + 1]) == side)
            let png = data.subdata(in: long(entry + 12)..<(long(entry + 12) + long(entry + 8)))
            let image = try Self.pixels(png)
            #expect(image.width == side && image.height == side)
            #expect(image.at(0, 0).a == 0 && image.at(side / 2, 1).a == 255)
            if side == 48 {
                let mask = try Self.mask(side, scale: Self.tileScale, weight: Self.tileWeight * CGFloat(side) / 32)
                let missed = Self.misses(image, mask) { $0.a == 255 && $0.r > 128 }
                #expect(missed <= 8, "\(missed)")
            }
        }
    }
}
