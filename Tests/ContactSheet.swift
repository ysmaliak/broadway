import AppKit

@main struct Sheet {
    static func main() throws {
        var args = Array(CommandLine.arguments.dropFirst())
        let out = URL(fileURLWithPath: args.removeFirst())
        let columns = Int(args.removeFirst())!
        let cropWidth = CGFloat(Double(args.removeFirst())!)
        let cropHeight = CGFloat(Double(args.removeFirst())!)
        let scale: CGFloat = 0.5
        let cells: [(String, NSImage?)] = args.map { entry in
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], NSImage(contentsOfFile: parts[1]))
        }
        let cellWidth = cropWidth * scale
        let cellHeight = cropHeight * scale
        let label: CGFloat = 22
        let pad: CGFloat = 8
        let rows = (cells.count + columns - 1) / columns
        let size = NSSize(width: CGFloat(columns) * (cellWidth + pad) + pad,
                          height: CGFloat(rows) * (cellHeight + label + pad) + pad)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(white: 0.5, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        for (index, cell) in cells.enumerated() {
            let column = CGFloat(index % columns), row = CGFloat(index / columns)
            let x = pad + column * (cellWidth + pad)
            let top = size.height - pad - row * (cellHeight + label + pad)
            let frame = NSRect(x: x, y: top - cellHeight, width: cellWidth, height: cellHeight)
            if let image = cell.1, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let wide = min(CGFloat(cg.width), cropWidth)
                let high = min(CGFloat(cg.height), cropHeight)
                if let cut = cg.cropping(to: CGRect(x: 0, y: 0, width: wide, height: high)) {
                    NSGraphicsContext.current?.cgContext.draw(cut, in: NSRect(x: x, y: top - high * scale, width: wide * scale, height: high * scale))
                }
            }
            NSColor.black.withAlphaComponent(0.25).setStroke()
            NSBezierPath(rect: frame).stroke()
            let text = NSAttributedString(string: cell.0, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
            ])
            text.draw(at: NSPoint(x: x + 2, y: top - cellHeight - label + 5))
        }
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: out)
        print("sheet \(out.path) \(Int(size.width))x\(Int(size.height))")
    }
}
