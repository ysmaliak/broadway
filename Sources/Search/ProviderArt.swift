import AppKit
import CoreImage

final class ProviderMarkView: NSView {
    var kind: PlanCardKind { didSet { if kind != oldValue { needsDisplay = true } } }
    var size: CGFloat { didSet { if size != oldValue { invalidateIntrinsicContentSize(); needsLayout = true; needsDisplay = true } } }
    var lit: Bool { didSet { if lit != oldValue { needsDisplay = true } } }

    private let art = CALayer()

    init(kind: PlanCardKind, size: CGFloat = 36, lit: Bool = true) {
        self.kind = kind
        self.size = size
        self.lit = lit
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(art)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        let pad = ProviderMarkView.pad(size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        art.frame = NSRect(x: (bounds.width - size) / 2 - pad, y: (bounds.height - size) / 2 - pad, width: size + pad * 2, height: size + pad * 2)
        art.contentsScale = scale
        art.contents = ProviderMarkView.image(kind, size: size, lit: lit, dark: kitDark, scale: scale)
        CATransaction.commit()
    }

    static func pad(_ size: CGFloat) -> CGFloat { ceil(size * 0.15) + 2 }

    struct Paint {
        let top: NSColor
        let bottom: NSColor
        var ink: NSColor = .white
    }

    static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static func tint(_ kind: PlanCardKind) -> NSColor {
        switch kind {
        case .claude: rgb(0xD97757)
        case .chatGPT: rgb(0x10A37F)
        case .thisMac: rgb(0xB36BF2)
        }
    }

    static func paint(_ kind: PlanCardKind, dark: Bool) -> Paint {
        switch kind {
        case .claude: Paint(top: rgb(0xEC9474), bottom: rgb(0xC9603D), ink: rgb(0xFFF6EE))
        case .chatGPT: Paint(top: rgb(0x34C9A0), bottom: rgb(0x0A8A69))
        case .thisMac: dark ? Paint(top: rgb(0x3A3B41), bottom: rgb(0x1B1C20)) : Paint(top: rgb(0xFFFFFF), bottom: rgb(0xE6E8EC))
        }
    }

    private struct Key: Hashable {
        let kind: PlanCardKind
        let size: CGFloat
        let lit: Bool
        let dark: Bool
        let scale: CGFloat
    }

    @MainActor private static var made: [Key: CGImage] = [:]

    static func image(_ kind: PlanCardKind, size: CGFloat, lit: Bool, dark: Bool, scale: CGFloat) -> CGImage? {
        let key = Key(kind: kind, size: size, lit: lit, dark: dark, scale: scale)
        if let known = made[key] { return known }
        let image = draw(kind, size: size, lit: lit, dark: dark, scale: scale)
        if made.count > 64 { made.removeAll() }
        made[key] = image
        return image
    }

    static let claudeLetter = monogram("C")

    static let chatGPTLetter = monogram("G")

    static func monogram(_ letter: String) -> CGPath {
        let base = NSFont.systemFont(ofSize: 24, weight: .bold)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 24) } ?? base
        var characters = Array(letter.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count), let glyph = glyphs.first,
              let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { return CGMutablePath() }
        var flip = CGAffineTransform(scaleX: 1, y: -1)
        return outline.copy(using: &flip) ?? outline
    }

    private static func draw(_ kind: PlanCardKind, size: CGFloat, lit: Bool, dark: Bool, scale: CGFloat) -> CGImage? {
        let pad = Self.pad(size)
        let side = Int(((size + pad * 2) * scale).rounded())
        guard side > 0, let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.translateBy(x: 0, y: CGFloat(side))
        c.scaleBy(x: scale, y: -scale)
        c.translateBy(x: pad, y: pad)
        let paint = Self.paint(kind, dark: dark)
        let tile = CGRect(x: 0, y: 0, width: size, height: size)
        let shape = KitPath.continuous(tile, radius: size * 0.25)
        let alpha: CGFloat = lit ? 1 : (dark ? 0.55 : 0.6)

        c.saveGState()
        c.setAlpha(alpha)
        c.setShadow(offset: CGSize(width: 0, height: -size * 0.03 * scale), blur: size * 0.045 * 2 * scale,
                    color: NSColor(white: 0, alpha: dark ? 0.42 : 0.2).cgColor)
        c.addPath(shape)
        c.setFillColor(paint.bottom.cgColor)
        c.fillPath()
        c.restoreGState()

        c.saveGState()
        c.setAlpha(alpha)
        c.addPath(shape)
        c.clip()
        linear(c, [paint.top, paint.bottom], from: 0, to: size)
        c.restoreGState()

        if kind == .thisMac {
            intelligence(c, size: size, dark: dark, scale: scale, alpha: alpha)
        } else {
            c.saveGState()
            c.setAlpha(alpha)
            c.clip(to: tile)
            c.scaleBy(x: size / 20, y: size / 20)
            glyph(kind, paint: paint, in: c, scale: scale * size / 20)
            c.restoreGState()
        }

        let line = max(0.5, size / 40)
        let edge = KitPath.continuous(tile.insetBy(dx: line / 2, dy: line / 2), radius: size * 0.25 - line / 2)
        c.saveGState()
        c.setAlpha(alpha)
        c.addPath(edge)
        c.setLineWidth(line)
        c.replacePathWithStrokedPath()
        c.clip()
        linear(c, dark ? [NSColor(white: 1, alpha: 0.34), NSColor(white: 1, alpha: 0.12)]
                       : [NSColor(white: 0, alpha: 0.10), NSColor(white: 0, alpha: 0.20)], from: 0, to: size)
        c.restoreGState()

        guard let drawn = c.makeImage() else { return nil }
        guard !lit else { return drawn }
        return faded(drawn, saturation: 0.2)
    }

    private static func linear(_ c: CGContext, _ colors: [NSColor], from top: CGFloat, to bottom: CGFloat, x: CGFloat = 10) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let gradient = CGGradient(colorsSpace: space, colors: colors.map { $0.usingColorSpace(.sRGB)?.cgColor ?? $0.cgColor } as CFArray,
                                        locations: nil) else { return }
        c.drawLinearGradient(gradient, start: CGPoint(x: x, y: top), end: CGPoint(x: x, y: bottom),
                             options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private static func ink(_ paint: Paint) -> [NSColor] {
        [paint.ink, KitOklab.mix(paint.ink, paint.bottom, by: 0.16)]
    }

    private static func raised(_ c: CGContext, _ paint: Paint, scale: CGFloat, _ body: () -> Void) {
        c.saveGState()
        let shade = KitOklab.mix(paint.bottom, .black, by: 0.45).withAlphaComponent(0.55)
        c.setShadow(offset: CGSize(width: 0, height: -0.35 * scale), blur: 0.45 * 2 * scale, color: shade.cgColor)
        c.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        c.endTransparencyLayer()
        c.restoreGState()
    }

    private static func glyph(_ kind: PlanCardKind, paint: Paint, in c: CGContext, scale: CGFloat) {
        switch kind {
        case .claude:
            raised(c, paint, scale: scale) {
                c.saveGState()
                c.addPath(fit(claudeLetter, side: 11.6))
                c.clip()
                linear(c, ink(paint), from: 4.2, to: 15.8)
                c.restoreGState()
            }
        case .chatGPT:
            raised(c, paint, scale: scale) {
                c.saveGState()
                c.addPath(fit(chatGPTLetter, side: 11.6))
                c.clip()
                linear(c, ink(paint), from: 4.2, to: 15.8)
                c.restoreGState()
            }
        case .thisMac:
            break
        }
    }

    private static func fit(_ path: CGPath, side: CGFloat, center: CGPoint = CGPoint(x: 10, y: 10)) -> CGPath {
        let bounds = path.boundingBoxOfPath
        let scale = side / max(bounds.width, bounds.height)
        var transform = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: scale, y: scale)
            .translatedBy(x: -bounds.midX, y: -bounds.midY)
        return path.copy(using: &transform) ?? path
    }

    private static func intelligence(_ c: CGContext, size: CGFloat, dark: Bool, scale: CGFloat, alpha: CGFloat) {
        let colors = [0xFF9A3C, 0xFF5F8F, 0xC36BFF, 0x5C8DFF, 0x3FD3FF, 0xFFC94A, 0xFF9A3C].map { rgb(UInt32($0)) }
        let config = NSImage.SymbolConfiguration(pointSize: size * 0.6, weight: .medium)
        guard let symbol = NSImage(systemSymbolName: "apple.intelligence", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let glyphSize = symbol.size
        let rect = CGRect(x: ((size - glyphSize.width) / 2 * scale).rounded() / scale, y: ((size - glyphSize.height) / 2 * scale).rounded() / scale,
                          width: glyphSize.width, height: glyphSize.height)
        guard let painted = conic(symbol, colors: colors, size: glyphSize, scale: scale) else { return }
        let blurred = blur(painted, radius: size * 0.07 * scale)
        c.saveGState()
        c.setAlpha((dark ? 0.85 : 0.6) * alpha)
        if let blurred {
            let grow = CGFloat(blurred.width - painted.width) / scale / 2
            draw(c, blurred, in: rect.insetBy(dx: -grow, dy: -grow))
        }
        c.restoreGState()
        c.saveGState()
        c.setAlpha(alpha)
        c.setShadow(offset: CGSize(width: 0, height: -size * 0.015 * scale), blur: size * 0.012 * 2 * scale,
                    color: NSColor(white: 0, alpha: dark ? 0.35 : 0.12).cgColor)
        draw(c, painted, in: rect)
        c.restoreGState()
    }

    private static func draw(_ c: CGContext, _ image: CGImage, in rect: CGRect) {
        c.saveGState()
        c.translateBy(x: rect.minX, y: rect.maxY)
        c.scaleBy(x: 1, y: -1)
        c.draw(image, in: CGRect(origin: .zero, size: rect.size))
        c.restoreGState()
    }

    private static func conic(_ symbol: NSImage, colors: [NSColor], size: NSSize, scale: CGFloat) -> CGImage? {
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let mask = symbol.cgImage(forProposedRect: nil, context: nil, hints: [.ctm: NSAffineTransform(transform: AffineTransform(scale: scale))])
        else { return nil }
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        guard let ring = conicImage(colors: colors, width: width, height: height) else { return nil }
        c.draw(mask, in: full)
        c.setBlendMode(.sourceIn)
        c.draw(ring, in: full)
        return c.makeImage()
    }

    private static func conicImage(colors: [NSColor], width: Int, height: Int) -> CGImage? {
        let parts = colors.map { color -> (CGFloat, CGFloat, CGFloat) in
            let c = color.usingColorSpace(.sRGB) ?? color
            return (c.redComponent, c.greenComponent, c.blueComponent)
        }
        guard parts.count > 1, let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = c.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        let cx = CGFloat(width) / 2, cy = CGFloat(height) / 2
        for row in 0..<height {
            for column in 0..<width {
                let dx = CGFloat(column) + 0.5 - cx, dy = CGFloat(row) + 0.5 - cy
                var turn = atan2(dy, dx) / (2 * .pi)
                if turn < 0 { turn += 1 }
                let place = turn * CGFloat(parts.count - 1)
                let index = min(parts.count - 2, Int(place))
                let t = place - CGFloat(index)
                let a = parts[index], b = parts[index + 1]
                let offset = (row * width + column) * 4
                pixels[offset] = UInt8(max(0, min(255, (a.0 + (b.0 - a.0) * t) * 255)))
                pixels[offset + 1] = UInt8(max(0, min(255, (a.1 + (b.1 - a.1) * t) * 255)))
                pixels[offset + 2] = UInt8(max(0, min(255, (a.2 + (b.2 - a.2) * t) * 255)))
                pixels[offset + 3] = 255
            }
        }
        return c.makeImage()
    }

    private static func blur(_ image: CGImage, radius: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input.clampedToExtent(), kCIInputRadiusKey: radius]),
              let output = filter.outputImage else { return nil }
        let grow = ceil(radius * 3)
        let extent = input.extent.insetBy(dx: -grow, dy: -grow)
        let unclamped = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: input, kCIInputRadiusKey: radius])?.outputImage ?? output
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]).createCGImage(unclamped.cropped(to: extent), from: extent)
    }

    private static func faded(_ image: CGImage, saturation: CGFloat) -> CGImage? {
        let width = image.width, height = image.height
        guard let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = c.data else { return nil }
        c.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
        for index in stride(from: 0, to: width * height * 4, by: 4) {
            let r = CGFloat(pixels[index]), g = CGFloat(pixels[index + 1]), b = CGFloat(pixels[index + 2])
            let grey = 0.2126 * r + 0.7152 * g + 0.0722 * b
            func channel(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (grey + (v - grey) * saturation).rounded()))) }
            pixels[index] = channel(r)
            pixels[index + 1] = channel(g)
            pixels[index + 2] = channel(b)
        }
        return c.makeImage()
    }
}

enum SVGPath {
    static func read(_ text: String) -> CGPath {
        let path = CGMutablePath()
        var scanner = Scanner(Array(text.utf8))
        var command: UInt8 = 0
        var current = CGPoint.zero
        var start = CGPoint.zero
        var control: CGPoint?
        var quadratic: CGPoint?
        while true {
            scanner.skipSeparators()
            guard let next = scanner.peek() else { break }
            if Scanner.isCommand(next) {
                command = next
                scanner.index += 1
            } else if command == 0 {
                break
            }
            let relative = command >= 97
            let base = relative ? current : .zero
            func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: base.x + x, y: base.y + y) }
            var curve: CGPoint?
            var quad: CGPoint?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                start = current
                path.move(to: current)
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                current = point(x, y)
                path.addLine(to: current)
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x2 = scanner.number(),
                      let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let second = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: point(x1, y1), control2: second)
                curve = second
            case UInt8(ascii: "s"):
                guard let x2 = scanner.number(), let y2 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let first = control.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                let second = point(x2, y2)
                current = point(x, y)
                path.addCurve(to: current, control1: first, control2: second)
                curve = second
            case UInt8(ascii: "q"):
                guard let x1 = scanner.number(), let y1 = scanner.number(), let x = scanner.number(), let y = scanner.number() else { return path }
                let pivot = point(x1, y1)
                current = point(x, y)
                path.addQuadCurve(to: current, control: pivot)
                quad = pivot
            case UInt8(ascii: "t"):
                guard let x = scanner.number(), let y = scanner.number() else { return path }
                let pivot = quadratic.map { CGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y) } ?? current
                current = point(x, y)
                path.addQuadCurve(to: current, control: pivot)
                quad = pivot
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let turn = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(),
                      let x = scanner.number(), let y = scanner.number() else { return path }
                let end = point(x, y)
                arc(path, from: current, to: end, rx: rx, ry: ry, degrees: turn, large: large, sweep: sweep)
                current = end
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                command = 0
            default:
                return path
            }
            control = curve
            quadratic = quad
        }
        return path
    }

    static func arc(_ path: CGMutablePath, from a: CGPoint, to b: CGPoint, rx: Double, ry: Double, degrees: Double, large: Bool, sweep: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, a != b else {
            path.addLine(to: b)
            return
        }
        let phi = degrees * .pi / 180
        let cosine = cos(phi), sine = sin(phi)
        let dx = (a.x - b.x) / 2, dy = (a.y - b.y) / 2
        let x1 = cosine * dx + sine * dy
        let y1 = -sine * dx + cosine * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 {
            rx *= lambda.squareRoot()
            ry *= lambda.squareRoot()
        }
        let top = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let bottom = rx * rx * y1 * y1 + ry * ry * x1 * x1
        let coefficient = (large != sweep ? 1.0 : -1.0) * max(0, top / bottom).squareRoot()
        let cx1 = coefficient * rx * y1 / ry
        let cy1 = -coefficient * ry * x1 / rx
        let cx = cosine * cx1 - sine * cy1 + (a.x + b.x) / 2
        let cy = sine * cx1 + cosine * cy1 + (a.y + b.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let start = angle(1, 0, (x1 - cx1) / rx, (y1 - cy1) / ry)
        var delta = angle((x1 - cx1) / rx, (y1 - cy1) / ry, (-x1 - cx1) / rx, (-y1 - cy1) / ry)
        if !sweep, delta > 0 { delta -= 2 * .pi }
        if sweep, delta < 0 { delta += 2 * .pi }
        func place(_ ux: Double, _ uy: Double) -> CGPoint {
            CGPoint(x: cx + rx * cosine * ux - ry * sine * uy, y: cy + rx * sine * ux + ry * cosine * uy)
        }
        let pieces = max(1, Int((abs(delta) / (.pi / 2)).rounded(.up)))
        let step = delta / Double(pieces)
        let k = 4.0 / 3.0 * tan(step / 4)
        var theta = start
        for index in 0..<pieces {
            let next = theta + step
            let first = place(cos(theta) - k * sin(theta), sin(theta) + k * cos(theta))
            let second = place(cos(next) + k * sin(next), sin(next) - k * cos(next))
            path.addCurve(to: index == pieces - 1 ? b : place(cos(next), sin(next)), control1: first, control2: second)
            theta = next
        }
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        static func isCommand(_ byte: UInt8) -> Bool {
            "MmLlHhVvCcSsQqTtAaZz".utf8.contains(byte)
        }

        func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipSeparators() {
            while let byte = peek(), byte == 32 || byte == 44 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
        }

        mutating func flag() -> Bool? {
            skipSeparators()
            guard let byte = peek(), byte == 48 || byte == 49 else { return nil }
            index += 1
            return byte == 49
        }

        mutating func number() -> Double? {
            skipSeparators()
            let begin = index
            if let sign = peek(), sign == 43 || sign == 45 { index += 1 }
            var dot = false, digits = false
            while let byte = peek() {
                if byte >= 48 && byte <= 57 {
                    digits = true
                } else if byte == 46, !dot {
                    dot = true
                } else {
                    break
                }
                index += 1
            }
            if digits, let byte = peek(), byte == 101 || byte == 69 {
                index += 1
                if let sign = peek(), sign == 43 || sign == 45 { index += 1 }
                while let byte = peek(), byte >= 48 && byte <= 57 { index += 1 }
            }
            guard digits else {
                index = begin
                return nil
            }
            return Double(String(decoding: bytes[begin..<index], as: UTF8.self))
        }
    }
}
