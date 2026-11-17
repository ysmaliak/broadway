import AppKit
import Testing
@testable import Search

@Suite(.serialized)
@MainActor
struct DockBarTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let builtIcons = root.appendingPathComponent("build/Broadway.app/Contents/Resources/Icons", isDirectory: true)

    private struct Pixel {
        let red: Double, green: Double, blue: Double, alpha: Double
        var white: Bool { red > 0.97 && green > 0.97 && blue > 0.97 && alpha > 0.97 }
    }

    private func icons() throws -> [(AppIcon, NSImage)] {
        try AppIcon.allCases.map { icon in
            let file = Self.builtIcons.appendingPathComponent(icon.rawValue + ".png")
            if let image = NSImage(contentsOf: file) { return (icon, image) }
            return (icon, try stand(in: icon.brand))
        }
    }

    private func stand(in colour: NSColor) throws -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { rect in
            colour.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185).fill()
            return true
        }
    }

    private func pixels(_ image: NSImage) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 128, pixelsHigh: 128, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func at(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Pixel {
        let colour = rep.colorAt(x: x, y: 127 - y)?.usingColorSpace(.deviceRGB) ?? .clear
        return Pixel(red: colour.redComponent, green: colour.greenComponent, blue: colour.blueComponent, alpha: colour.alphaComponent)
    }

    private func fillEnd(_ rep: NSBitmapImageRep) -> Int? {
        (16..<112).last { at(rep, $0, 19).white }
    }

    @Test func theBarSitsWhereTheTokensSay() {
        #expect(DockBarLook.tile == 128)
        #expect(DockBarLook.width == 96)
        #expect(DockBarLook.height == 10)
        #expect(DockBarLook.lift == 14)
        #expect(DockBarLook.inset == 1.5)
        #expect(DockBarLook.track.alphaComponent == 0.45)
        #expect(DockBarLook.track.whiteComponent == 0)
        #expect(DockBarLook.fill == .white)
    }

    @Test func theFillReachesAsFarAsTheDownloadsAndTheIconStaysUnderIt() throws {
        let keep = ProcessInfo.processInfo.environment["BROADWAY_DOCK_PICTURES"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let keep { try FileManager.default.createDirectory(at: keep, withIntermediateDirectories: true) }
        for (icon, image) in try icons() {
            let plain = try pixels(image)
            for percent in [0, 50, 100] {
                let picture = DockBar.picture(icon: image, fraction: Double(percent) / 100)
                let drawn = try pixels(picture)
                if let keep, let png = drawn.representation(using: .png, properties: [:]) {
                    try png.write(to: keep.appendingPathComponent("\(icon.rawValue)-\(percent).png"))
                }

                let end = fillEnd(drawn)
                switch percent {
                case 0: #expect(end == nil, "\(icon) \(percent)")
                case 50: #expect(end.map { (61...64).contains($0) } == true, "\(icon) \(percent): \(String(describing: end))")
                default: #expect(end.map { (108...110).contains($0) } == true, "\(icon) \(percent): \(String(describing: end))")
                }
                #expect(!at(drawn, 64, 26).white || at(plain, 64, 26).white, "\(icon) \(percent): above the bar")
                #expect(!at(drawn, 64, 12).white || at(plain, 64, 12).white, "\(icon) \(percent): under the bar")

                for (x, y) in [(64, 64), (30, 100), (100, 40), (64, 26), (64, 12)] {
                    let before = at(plain, x, y), after = at(drawn, x, y)
                    #expect(abs(before.red - after.red) < 0.01 && abs(before.alpha - after.alpha) < 0.01, "\(icon) \(percent): \(x),\(y)")
                }
                if percent < 100 {
                    let under = at(plain, 100, 19), track = at(drawn, 100, 19)
                    #expect(abs(track.red - under.red * 0.55) < 0.03, "\(icon) \(percent): the icon shows through the track")
                    #expect(abs(track.green - under.green * 0.55) < 0.03, "\(icon) \(percent): the icon shows through the track")
                }
            }
        }
    }

    @Test func withNoIconTheBarIsStillDrawn() throws {
        let drawn = try pixels(DockBar.picture(icon: nil, fraction: 0.5))

        #expect(at(drawn, 30, 19).white)
        #expect(at(drawn, 64, 64).alpha == 0)
        #expect(abs(at(drawn, 100, 19).alpha - 0.45) < 0.02)
    }

    @Test func theBarFollowsTheDownloadsWithoutTouchingTheDockInATestRun() async throws {
        let bar = DockBar.shared
        #expect(!bar.drivesTile)

        bar.update([DockLoad(received: 30, expected: 100, underWay: true)])
        try await Task.sleep(for: .milliseconds(300))
        let during = bar.shown
        bar.update([])
        try await Task.sleep(for: .milliseconds(300))

        #expect(during == 30)
        #expect(bar.shown == nil)
        #expect(!bar.tileSet)
        #expect(NSApplication.shared.dockTile.contentView == nil)
    }
}
