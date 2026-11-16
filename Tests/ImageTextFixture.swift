import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, lines) in [("text", ["Ticket screenshot", "Проверка русского текста", "Last line here"]), ("blank", [])] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 500,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: 1600, height: 500).fill()
    for (index, line) in lines.enumerated() {
        (line as NSString).draw(at: NSPoint(x: 70, y: 370 - index * 100),
                               withAttributes: [.font: NSFont.systemFont(ofSize: 54), .foregroundColor: NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
}
