import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let out = URL(fileURLWithPath: arguments.first ?? ".")
let layoutFile = URL(fileURLWithPath: arguments.count > 1 ? arguments[1] : "Installer/layout.json")
let style = ProcessInfo.processInfo.environment["BROADWAY_DMG_STYLE"] ?? "ink"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let layout = try! JSONSerialization.jsonObject(with: Data(contentsOf: layoutFile)) as! [String: Any]
func number(_ key: String) -> CGFloat { CGFloat((layout[key] as! NSNumber).doubleValue) }
func point(_ key: String) -> CGPoint {
    let pair = layout[key] as! [NSNumber]
    return CGPoint(x: pair[0].doubleValue, y: pair[1].doubleValue)
}

let window = CGSize(width: number("width"), height: number("height"))
let bleed: CGFloat = 40
let size = CGSize(width: window.width + bleed, height: window.height + bleed)
let app = point("app")
let applications = point("applications")
let half = number("iconSize") / 2
let labelCentre = number("labelCentre")

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

enum Names {
    case plates
    case street
    case bare
}

struct Look {
    let top: UInt32
    let bottom: UInt32
    let grid: UInt32
    let gridAlpha: CGFloat
    let line: UInt32
    let words: UInt32
    let wordsAlpha: CGFloat
    let names: Names
}

let looks: [String: Look] = [
    "ink": Look(top: BroadwayMap.inkTop, bottom: BroadwayMap.inkBottom, grid: BroadwayMap.inkGrid, gridAlpha: BroadwayMap.inkGridAlpha,
                line: BroadwayMap.inkLine, words: 0xF3F4F6, wordsAlpha: 0.66, names: .plates),
    "street": Look(top: BroadwayMap.inkTop, bottom: BroadwayMap.inkBottom, grid: BroadwayMap.inkGrid, gridAlpha: BroadwayMap.inkGridAlpha,
                   line: BroadwayMap.inkLine, words: 0xF3F4F6, wordsAlpha: 0.66, names: .street),
    "day": Look(top: 0xFFFFFF, bottom: 0xE9E9EE, grid: 0x111216, gridAlpha: 0.11,
                line: 0x111216, words: 0x111216, wordsAlpha: 0.68, names: .bare),
]
let look = looks[style] ?? looks["ink"]!

func flipped(_ y: CGFloat) -> CGFloat { size.height - y }

func drawGround(_ context: CGContext) {
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                              colors: [colour(look.top), colour(look.bottom)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: bleed),
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawMap(_ context: CGContext) {
    let layer = CGLayer(context, size: size, auxiliaryInfo: nil)!
    let ink = layer.context!
    let turn = -BroadwayMap.tilt * .pi / 180
    let avenue: CGFloat = 118
    let street: CGFloat = 67
    let reach = hypot(size.width, size.height)
    ink.translateBy(x: app.x + 22, y: flipped(app.y) + 9)
    ink.rotate(by: turn)
    ink.setStrokeColor(colour(look.grid, look.gridAlpha))
    ink.setLineWidth(1.5)
    var x = -ceil(reach / avenue) * avenue
    while x <= reach {
        ink.move(to: CGPoint(x: x, y: -reach))
        ink.addLine(to: CGPoint(x: x, y: reach))
        x += avenue
    }
    var y = -ceil(reach / street) * street
    while y <= reach {
        ink.move(to: CGPoint(x: -reach, y: y))
        ink.addLine(to: CGPoint(x: reach, y: y))
        y += street
    }
    ink.strokePath()

    context.saveGState()
    let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(),
                          colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 1, alpha: 1), CGColor(gray: 0, alpha: 1)] as CFArray,
                          locations: [0, 0.52, 1])!
    let maskContext = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    maskContext.drawLinearGradient(fade, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: 0, y: bleed + 56),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.clip(to: CGRect(origin: .zero, size: size), mask: maskContext.makeImage()!)
    context.draw(layer, at: .zero)
    context.restoreGState()
}

func drawRoute(_ context: CGContext) {
    let y = flipped(app.y)
    let start = app.x + half + 30
    let end = applications.x - half - 30
    let head: CGFloat = 14
    context.setStrokeColor(colour(look.line))
    context.setLineWidth(7)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: start, y: y))
    context.addLine(to: CGPoint(x: end, y: y))
    context.move(to: CGPoint(x: end - head, y: y + head))
    context.addLine(to: CGPoint(x: end, y: y))
    context.addLine(to: CGPoint(x: end - head, y: y - head))
    context.strokePath()
}

func drawPlate(_ context: CGContext, under icon: CGPoint, width: CGFloat) {
    let rect = CGRect(x: icon.x - width / 2, y: flipped(icon.y + labelCentre) - 12, width: width, height: 24)
    let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: CGColor(gray: 0, alpha: 0.35))
    context.addPath(path)
    context.setFillColor(colour(0x858A94))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.setStrokeColor(CGColor(gray: 1, alpha: 0.18))
    context.setLineWidth(1)
    context.move(to: CGPoint(x: rect.minX, y: rect.maxY - 0.5))
    context.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 0.5))
    context.strokePath()
    context.restoreGState()
}

func drawNames(_ context: CGContext) {
    switch look.names {
    case .plates:
        drawPlate(context, under: app, width: 96)
        drawPlate(context, under: applications, width: 112)
    case .street:
        let y = flipped(app.y + labelCentre)
        context.setStrokeColor(colour(look.line))
        context.setLineWidth(30)
        context.setLineCap(.butt)
        context.move(to: CGPoint(x: -10, y: y))
        context.addLine(to: CGPoint(x: size.width + 10, y: y))
        context.strokePath()
    case .bare:
        break
    }
}

func drawWords() {
    let words = "Drag Broadway to Applications"
    let text = NSAttributedString(string: words, attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(cgColor: colour(look.words, look.wordsAlpha))!,
        .kern: 0.1,
    ])
    let box = text.size()
    text.draw(at: CGPoint(x: (window.width - box.width) / 2, y: flipped(window.height - 70) - box.height / 2))
}

func draw(_ context: CGContext) {
    drawGround(context)
    drawMap(context)
    drawRoute(context)
    drawNames(context)
    drawWords()
}

for (scale, name) in [(1, "background.png"), (2, "background@2x.png")] {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    draw(graphics.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
}
