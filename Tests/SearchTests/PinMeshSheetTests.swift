import AppKit
import Foundation
import Testing
@testable import Search

@Suite
@MainActor
struct PinMeshSheetTests {
    static let folder = ProcessInfo.processInfo.environment["PIN_MESH_SHEET"]

    struct Icon {
        let name: String
        let colours: [(CGFloat, CGFloat, CGFloat)]
        var glyph = false
    }

    static let icons: [Icon] = [
        Icon(name: "github", colours: [(0.05, 0.05, 0.06)], glyph: true),
        Icon(name: "linear", colours: [(0.37, 0.41, 0.82)]),
        Icon(name: "youtube", colours: [(1, 0, 0), (1, 1, 1)]),
        Icon(name: "figma", colours: [(0.95, 0.31, 0.12), (0.64, 0.35, 1), (0.04, 0.81, 0.51)]),
        Icon(name: "notion", colours: [(1, 1, 1), (0.05, 0.05, 0.05)]),
        Icon(name: "hn", colours: [(1, 0.4, 0)]),
        Icon(name: "teal", colours: [(0.08, 0.68, 0.7)]),
        Icon(name: "red", colours: [(0.9, 0.16, 0.14)]),
        Icon(name: "blue", colours: [(0.15, 0.42, 0.95)]),
        Icon(name: "green", colours: [(0.2, 0.75, 0.3)]),
        Icon(name: "purple", colours: [(0.55, 0.25, 0.9)]),
        Icon(name: "yellow", colours: [(0.98, 0.8, 0.1)]),
        Icon(name: "pink", colours: [(0.95, 0.3, 0.6)]),
        Icon(name: "navy", colours: [(0.1, 0.15, 0.35)]),
        Icon(name: "duo", colours: [(0.98, 0.55, 0.1), (0.1, 0.62, 0.72)]),
        Icon(name: "bluegold", colours: [(0.15, 0.35, 0.9), (0.98, 0.78, 0.1)]),
        Icon(name: "greenpink", colours: [(0.15, 0.7, 0.35), (0.92, 0.25, 0.55)]),
        Icon(name: "rgb", colours: [(0.9, 0.15, 0.15), (0.15, 0.75, 0.25), (0.15, 0.35, 0.95)]),
        Icon(name: "trio", colours: [(0.98, 0.5, 0.1), (0.6, 0.2, 0.85), (0.1, 0.75, 0.85)]),
        Icon(name: "grey", colours: [(0.52, 0.52, 0.52)]),
        Icon(name: "white", colours: [(1, 1, 1)]),
        Icon(name: "black", colours: [(0.06, 0.06, 0.07)]),
        Icon(name: "brown", colours: [(0.55, 0.35, 0.2)]),
        Icon(name: "cyan", colours: [(0.1, 0.8, 0.95)]),
    ]

    static func image(_ icon: Icon) -> NSImage {
        NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            NSGraphicsContext.saveGraphicsState()
            disc.addClip()
            for (index, colour) in icon.colours.enumerated() {
                let share = rect.width / CGFloat(icon.colours.count)
                NSColor(srgbRed: colour.0, green: colour.1, blue: colour.2, alpha: 1).setFill()
                NSRect(x: CGFloat(index) * share, y: 0, width: share, height: rect.height).fill()
            }
            if icon.colours.count == 1, !icon.glyph, icon.colours[0] != (1, 1, 1), icon.colours[0] != (0.06, 0.06, 0.07) {
                NSColor.white.setFill()
                NSRect(x: 13, y: 8, width: 6, height: 16).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
    }

    static func tile(_ icon: Icon, seed: String, dark: Bool, into context: CGContext, at origin: CGPoint) {
        let size = CGSize(width: 56, height: 40)
        let box = CGRect(origin: origin, size: size)
        let radius: CGFloat = 12
        let picture = image(icon)
        let tint = PinTint.derive(PinTint.pixels(of: picture)).seeded(seed)
        let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let mesh = PinLook.mesh(tint, dark: dark) { context.draw(mesh, in: box) }
        context.restoreGState()
        for (band, width, inset) in [(PinLook.Band.inner, PinLook.ring, PinLook.ring / 2), (.outer, PinLook.ring / 2, PinLook.ring / 4)] {
            let colours = PinFaceView.ringColours(tint, band, dark: dark)
            let ring = CGPath(roundedRect: box.insetBy(dx: inset, dy: inset), cornerWidth: radius - inset, cornerHeight: radius - inset, transform: nil)
            let gradient = CAGradientLayer()
            gradient.type = .conic
            gradient.frame = CGRect(origin: .zero, size: size)
            gradient.colors = colours
            gradient.locations = [0, 0.13, 0.36, 0.64, 0.87, 1]
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            let angle = 135 * CGFloat.pi / 180
            gradient.endPoint = CGPoint(x: 0.5 + cos(angle), y: 0.5 + sin(angle))
            context.saveGState()
            context.addPath(ring.copy(strokingWithWidth: width, lineCap: .butt, lineJoin: .miter, miterLimit: 4))
            context.clip()
            context.translateBy(x: box.minX, y: box.minY)
            gradient.render(in: context)
            context.restoreGState()
        }
        let side: CGFloat = 16
        var rect = CGRect(x: box.midX - side / 2, y: box.midY - side / 2, width: side, height: side)
        if tint.dress(dark: dark) == .ink {
            context.setFillColor(NSColor(white: dark ? 1 : 0, alpha: 1).cgColor)
            context.fillEllipse(in: rect)
        } else if let cg = picture.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            context.draw(cg, in: rect)
        }
    }

    @Test(.enabled(if: folder != nil))
    func drawTheSheet() throws {
        let folder = try #require(Self.folder)
        let label = ProcessInfo.processInfo.environment["PIN_MESH_LABEL"] ?? "now"
        let columns = 6
        let cell = CGSize(width: 68, height: 52)
        let seeds = ["https://a.example/", "https://b.example/"]
        for dark in [true, false] {
            let rows = (Self.icons.count * seeds.count + columns - 1) / columns
            let scale: CGFloat = 2
            let width = Int(CGFloat(columns) * cell.width * scale), height = Int(CGFloat(rows) * cell.height * scale)
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
            context.setFillColor(dark ? NSColor(srgbRed: 0.09, green: 0.09, blue: 0.09, alpha: 1).cgColor
                                      : NSColor(srgbRed: 0.95, green: 0.93, blue: 0.9, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(columns) * cell.width, height: CGFloat(rows) * cell.height))
            var index = 0
            for icon in Self.icons {
                for seed in seeds {
                    let column = index % columns, row = rows - 1 - index / columns
                    Self.tile(icon, seed: seed + icon.name, dark: dark, into: context,
                              at: CGPoint(x: CGFloat(column) * cell.width + 6, y: CGFloat(row) * cell.height + 6))
                    index += 1
                }
            }
            let made = try #require(context.makeImage())
            let rep = NSBitmapImageRep(cgImage: made)
            let data = try #require(rep.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("sheet-\(label)-\(dark ? "dark" : "light").png"))
        }
    }
}
