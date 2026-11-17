import AppKit

@MainActor
enum BenchSurfacePicture {
    static func save(_ window: NSWindow, to path: String, scale: CGFloat = 2) -> Bool {
        guard let stage = window.contentView else { return false }
        window.layoutIfNeeded()
        stage.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let size = stage.bounds.size
        guard size.width > 0, size.height > 0,
              let picture = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return false }
        picture.size = size
        stage.cacheDisplay(in: stage.bounds, to: picture)
        guard let data = picture.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}
