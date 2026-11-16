import AppKit
import Testing
@testable import Search

@Suite
@MainActor
struct KitMeshTests {
    private func pixels(_ image: NSImage, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes
    }

    @Test(arguments: [false, true])
    func theKitMeshWearsEachCornersColour(dark: Bool) {
        let tints = [PinTint(hue: 0.6, saturation: 0.8, mark: .asIs),
                     PinTint(hue: 0.05, saturation: 0.7, mark: .asIs, others: [PinTint.Hue(hue: 0.3, saturation: 0.6)]),
                     PinTint.neutral]
        for tint in tints {
            let draw = PinMesh.draw(tint.seeded("https://example.com"), dark: dark)
            let colours = draw.tones.map(\.colour)
            let w = PinMesh.width, h = PinMesh.height
            let kit = KitMesh.image(width: w, height: h, points: draw.points, colours: colours, size: PinMesh.size, scale: 2)
            let bytes = pixels(kit, width: 128, height: 96)

            for (corner, x, y) in [(0, 0, 0), (w - 1, 127, 0), (w * (h - 1), 0, 95), (w * h - 1, 127, 95)] {
                let want = colours[corner].usingColorSpace(.sRGB)!
                let at = (y * 128 + x) * 4
                let alpha = Double(want.alphaComponent)
                let got = (0..<4).map { Double(bytes[at + $0]) }
                let expected = [want.redComponent, want.greenComponent, want.blueComponent].map { Double($0) * alpha * 255 } + [alpha * 255]
                let worst = zip(got, expected).map { abs($0 - $1) }.max() ?? 0
                #expect(worst < 16, "corner \(corner) dark=\(dark): \(got) vs \(expected)")
            }
        }
    }
}
