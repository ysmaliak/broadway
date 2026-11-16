import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon.iconset")
let dev = ProcessInfo.processInfo.environment["SEARCH_DEV"] == "1"
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

struct Colourway {
    let top: UInt32
    let bottom: UInt32
    let darkTop: UInt32
    let darkBottom: UInt32
    let grid: UInt32
    let gridAlpha: CGFloat
    let line: UInt32
    let dark: Bool
}

let colourways: [String: Colourway] = [
    "night": Colourway(top: 0x24262D, bottom: 0x111216, darkTop: 0x1D1F25, darkBottom: 0x0B0C0F,
                          grid: 0xFFFFFF, gridAlpha: 0.13, line: 0xFFC72C, dark: true),
    "day": Colourway(top: 0xFFFFFF, bottom: 0xE9E9EE, darkTop: 0xFFFFFF, darkBottom: 0xE9E9EE,
                     grid: 0x111216, gridAlpha: 0.11, line: 0x111216, dark: false),
    "ink": Colourway(top: BroadwayMap.inkTop, bottom: BroadwayMap.inkBottom, darkTop: 0x1D1F25, darkBottom: 0x0B0C0F,
                     grid: BroadwayMap.inkGrid, gridAlpha: BroadwayMap.inkGridAlpha, line: BroadwayMap.inkLine, dark: true),
    "volt": Colourway(top: 0x524BFF, bottom: 0x2A22E6, darkTop: 0x433CF0, darkBottom: 0x1F18C4,
                      grid: 0xFFFFFF, gridAlpha: 0.17, line: 0xFFFFFF, dark: true),
    "citrus": Colourway(top: 0xFFE45C, bottom: 0xF7C21A, darkTop: 0xFFE45C, darkBottom: 0xF7C21A,
                        grid: 0x111216, gridAlpha: 0.13, line: 0x111216, dark: false),
]

let wayName = ProcessInfo.processInfo.environment["SEARCH_ICON"] ?? "ink"
let way = colourways[wayName] ?? colourways["ink"]!
let plateTop: UInt32 = dev ? 0x3B3B41 : way.top
let plateBottom: UInt32 = dev ? 0x1B1B1F : way.bottom
let darkTop: UInt32 = way.darkTop
let darkBottom: UInt32 = way.darkBottom
let darkPlate = dev || way.dark
let plateCorner: CGFloat = BroadwayMap.plateCorner

let inset = CGAffineTransform(translationX: 100, y: 100).scaledBy(x: 824.0 / 1024, y: 824.0 / 1024)

func canvas(_ pixels: Int, _ paint: (CGContext) -> Void) -> CGImage {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    paint(context)
    return context.makeImage()!
}


func slab(_ rect: CGRect, radius: CGFloat) -> CGPath { BroadwayMap.slab(rect, radius: radius) }


func shadeInside(_ context: CGContext, path: CGPath, rect: CGRect, offset: CGSize, blur: CGFloat, color: CGColor) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    let ring = CGMutablePath()
    ring.addRect(rect.insetBy(dx: -rect.width, dy: -rect.height))
    ring.addPath(path)
    context.setShadow(offset: offset, blur: blur, color: color)
    context.addPath(ring)
    context.setFillColor(colour(0x000000))
    context.fillPath(using: .evenOdd)
    context.restoreGState()
}



func paintMap(_ context: CGContext, pixels: Int) {
    let small = pixels <= 32
    let middling = pixels == 64
    let line: CGFloat = small ? 128 : middling ? 116 : BroadwayMap.lineWidth
    context.saveGState()
    context.setLineCap(.round)
    if !small {
        context.setStrokeColor(colour(way.grid, way.gridAlpha * (middling ? 1.3 : 1)))
        context.setLineWidth(middling ? 16 : BroadwayMap.gridWidth)
        context.addPath(BroadwayMap.grid())
        context.strokePath()
    }
    context.addPath(BroadwayMap.route())
    context.setStrokeColor(colour(way.line))
    context.setLineWidth(line)
    context.strokePath()
    context.restoreGState()
}

func flat(_ pixels: Int) -> CGImage {
    let unit = CGFloat(pixels) / 1024 * inset.a
    return canvas(pixels) { context in
        context.saveGState()
        context.concatenate(inset)
        let whole = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        let plate = slab(whole, radius: plateCorner)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -14 * unit), blur: 30 * unit, color: colour(0x000000, 0.28))
        context.addPath(plate)
        context.setFillColor(colour(plateBottom))
        context.fillPath()
        context.restoreGState()
        context.saveGState()
        context.addPath(plate)
        context.clip()
        let wash = CGGradient(colorsSpace: space, colors: [colour(plateTop), colour(plateBottom)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(wash, start: CGPoint(x: 512, y: 1024), end: CGPoint(x: 512, y: 0), options: [])
        context.restoreGState()
        context.saveGState()
        context.addPath(plate)
        context.clip()
        paintMap(context, pixels: pixels)
        context.restoreGState()
        shadeInside(context, path: plate, rect: whole, offset: CGSize(width: 0, height: 6 * unit), blur: 10 * unit, color: colour(0x000000, darkPlate ? 0.4 : 0.08))
        shadeInside(context, path: plate, rect: whole, offset: CGSize(width: 0, height: -5 * unit), blur: 6 * unit, color: colour(0xFFFFFF, darkPlate ? 0.2 : 0.7))
        context.addPath(plate)
        context.setStrokeColor(colour(0x000000, darkPlate ? 0.3 : 0.1))
        context.setLineWidth(pixels > 64 ? 2 : 1024 / CGFloat(pixels) / inset.a * 0.5)
        context.strokePath()
        context.restoreGState()
    }
}

func write(_ image: CGImage, to url: URL) {
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: url)
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        write(flat(pixels), to: out.appendingPathComponent(name))
    }
}
print("drew: \(out.path)")

if CommandLine.arguments.count > 2 {
    let doc = URL(fileURLWithPath: CommandLine.arguments[2])
    let assets = doc.appendingPathComponent("Assets")
    try? FileManager.default.removeItem(at: doc)
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let layer = "map"
    write(canvas(1024) { paintMap($0, pixels: 1024) }, to: assets.appendingPathComponent("map.png"))

    func hex(_ value: UInt32) -> String {
        String(format: "srgb:%.5f,%.5f,%.5f,1.00000", Double(value >> 16 & 255) / 255, Double(value >> 8 & 255) / 255, Double(value & 255) / 255)
    }
    func wash(_ top: UInt32, _ bottom: UInt32) -> String {
        #"{ "linear-gradient" : [ "\#(hex(top))", "\#(hex(bottom))" ], "orientation" : { "start" : { "x" : 0.5, "y" : 0 }, "stop" : { "x" : 0.5, "y" : 1 } } }"#
    }
    let json = """
    {
      "fill-specializations" : [
        { "value" : \(wash(plateTop, plateBottom)) },
        { "appearance" : "dark", "value" : \(wash(darkTop, darkBottom)) }
      ],
      "groups" : [
        {
          "name" : "\(layer)",
          "layers" : [
            { "name" : "\(layer)", "image-name" : "\(layer).png", "glass" : false }
          ],
          "shadow" : { "kind" : "none", "opacity" : 0.5 },
          "specular" : false,
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : [ "macOS" ] }
    }
    """
    try json.write(to: doc.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
    print("wrote: \(doc.path)")
}
