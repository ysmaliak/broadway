import AppKit
import QuartzCore

final class RowMarkView: NSView {
    var icon: NSImage? { didSet { if icon !== oldValue { changed() } } }
    var letter = "" { didSet { if letter != oldValue { changed() } } }
    var size: CGFloat = 16 { didSet { if size != oldValue { changed() } } }
    var dim = false { didSet { if dim != oldValue { changed() } } }
    var letterSize: CGFloat? { didSet { if letterSize != oldValue { changed() } } }
    var letterTone: KitTone = .muted { didSet { if letterTone != oldValue { changed() } } }
    var tiled = true { didSet { if tiled != oldValue { changed() } } }
    var glyph = false { didSet { if glyph != oldValue { changed() } } }
    var draft = false { didSet { if draft != oldValue { changed() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { changed() } } }

    private let tile = CALayer()
    private let plate = CALayer()
    private let rim = CALayer()
    private let picture = CALayer()
    private let monogram = CATextLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        for part in [tile, plate, rim, picture, monogram] {
            part.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "opacity": NSNull(),
                            "backgroundColor": NSNull(), "foregroundColor": NSNull(), "string": NSNull(), "filters": NSNull()]
            layer?.addSublayer(part)
        }
        tile.cornerCurve = .continuous
        plate.cornerCurve = .continuous
        picture.cornerCurve = .continuous
        picture.masksToBounds = true
        monogram.alignmentMode = .center
        monogram.isWrapped = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: size, height: size) }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    private func changed() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
        needsLayout = true
    }

    private(set) var dress = PinTint.Dress.plain

    override func layout() {
        super.layout()
        needsDisplay = true
    }

    override func updateLayer() {
        let dark = kitDark
        let scale = window?.backingScaleFactor ?? 2
        let box = CGRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        layer?.opacity = Swift.Float((dim ? 0.45 : 1) * (draft ? 0.5 : 1))
        let shown = icon != nil
        tile.frame = box
        tile.cornerRadius = size * PinTint.cornerRatio
        tile.backgroundColor = tiled && !shown ? KitTone.ink.opacity(0.06).resolved(ink, dark: dark).cgColor : nil
        monogram.isHidden = shown
        if !shown {
            let font = NSFont.systemFont(ofSize: letterSize ?? size * 0.56, weight: .medium)
            let height = ceil(font.ascender - font.descender)
            monogram.font = font
            monogram.fontSize = font.pointSize
            monogram.contentsScale = scale
            monogram.string = letter
            monogram.foregroundColor = letterTone.resolved(ink, dark: dark).cgColor
            monogram.frame = CGRect(x: box.minX - 4, y: box.midY - height / 2, width: box.width + 8, height: height)
        }
        picture.isHidden = !shown
        guard let icon else {
            plate.isHidden = true
            rim.isHidden = true
            dress = .plain
            return
        }
        let symbol = icon.isTemplate
        dress = symbol ? .plain : glyph ? .ink : PinTint.of(icon).dress(dark: dark)
        let drawn = symbol || dress == .ink
        if symbol {
            let inset = MarkView.edges(box.insetBy(dx: size * 0.06, dy: size * 0.06), scale: scale)
            let natural = icon.size
            let fit = min(inset.width / max(natural.width, 0.01), inset.height / max(natural.height, 0.01))
            let fitted = CGSize(width: natural.width * fit, height: natural.height * fit)
            picture.frame = MarkView.edges(CGRect(x: inset.midX - fitted.width / 2, y: inset.midY - fitted.height / 2,
                                                  width: fitted.width, height: fitted.height), scale: scale)
        } else if dress == .chip {
            picture.frame = MarkView.edges(box.insetBy(dx: size * PinTint.chipInset, dy: size * PinTint.chipInset), scale: scale)
        } else {
            picture.frame = box
        }
        picture.cornerRadius = drawn || dress == .chip ? 0 : size * PinTint.cornerRatio
        picture.contentsScale = scale
        picture.contentsGravity = symbol ? .resize : .resizeAspectFill
        picture.minificationFilter = .trilinear
        if drawn {
            let tint = dress == .ink ? (dark ? NSColor.white : KitTone.ink.resolved(ink, dark: dark)) : KitTone.ink.opacity(0.75).resolved(ink, dark: dark)
            picture.contents = RowMarkView.tinted(icon, tint, pixels: CGSize(width: picture.frame.width * scale, height: picture.frame.height * scale))
        } else {
            let made = RowMarkView.prepared(icon, scale: scale)
            if (picture.contents as AnyObject?) !== made { picture.contents = made }
        }
        plate.isHidden = dress != .chip
        if dress == .chip {
            plate.frame = box
            plate.cornerRadius = size * PinTint.cornerRatio
            plate.backgroundColor = PinTint.of(icon).chip(dark: dark)?.cgColor
        }
        rim.isHidden = dress != .edge
        if dress == .edge {
            let reach = 1 / scale
            rim.frame = box.insetBy(dx: -reach, dy: -reach)
            rim.contentsScale = scale
            rim.contents = RowMarkView.outlined(icon, PinTint.edge(dark: dark), side: size, scale: scale)
        }
        if draft {
            picture.filters = [CIFilter(name: "CIColorControls", parameters: ["inputSaturation": 0]) as Any].compactMap { $0 }
        } else {
            picture.filters = nil
        }
    }


    static func outlined(_ image: NSImage, _ color: NSColor, side: CGFloat, scale: CGFloat) -> CGImage? {
        let inner = max(1, Int((side * scale).rounded()))
        let width = inner + 2
        let key = "edge-\(color.description)-\(inner)"
        let kept = made(for: image)
        if let known = kept.images[key] { return known }
        guard let shape = tinted(image, .white, pixels: CGSize(width: inner, height: inner)),
              let context = CGContext(data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let solid = color.usingColorSpace(.sRGB) ?? color
        let whole = CGRect(x: 0, y: 0, width: width, height: width)
        let radius = CGFloat(inner) * PinTint.cornerRatio
        context.setAlpha(solid.alphaComponent)
        context.beginTransparencyLayer(in: whole, auxiliaryInfo: nil)
        for (dx, dy) in [(-1.0, 0.0), (1, 0), (0, -1), (0, 1), (-0.7, -0.7), (0.7, -0.7), (-0.7, 0.7), (0.7, 0.7)] {
            let spot = CGRect(x: 1 + dx, y: 1 + dy, width: CGFloat(inner), height: CGFloat(inner))
            context.saveGState()
            context.addPath(CGPath(roundedRect: spot, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            context.draw(shape, in: spot)
            context.restoreGState()
        }
        context.setBlendMode(.sourceAtop)
        context.setFillColor(solid.withAlphaComponent(1).cgColor)
        context.fill(whole)
        context.endTransparencyLayer()
        let made = context.makeImage()
        kept.images[key] = made
        return made
    }

    private static let drawings = NSMapTable<NSImage, Drawn>.weakToStrongObjects()
    private static let preparations = NSMapTable<NSImage, Prepared>.weakToStrongObjects()

    private final class Prepared {
        var images: [CGFloat: CGImage] = [:]
    }

    private final class Drawn {
        var images: [String: CGImage] = [:]
    }

    private static func made(for image: NSImage) -> Drawn {
        if let known = drawings.object(forKey: image) { return known }
        let fresh = Drawn()
        drawings.setObject(fresh, forKey: image)
        return fresh
    }

    static func prepared(_ image: NSImage, scale: CGFloat) -> CGImage? {
        let known = preparations.object(forKey: image) ?? Prepared()
        if let made = known.images[scale] { return made }
        var rect = CGRect(origin: .zero, size: image.size)
        let transform = NSAffineTransform(transform: AffineTransform(scale: scale))
        guard let made = image.cgImage(forProposedRect: &rect, context: nil, hints: [.ctm: transform]) else { return nil }
        known.images[scale] = made
        preparations.setObject(known, forKey: image)
        return made
    }

    static func tinted(_ image: NSImage, _ color: NSColor, pixels: CGSize) -> CGImage? {
        let width = max(1, Int(pixels.width.rounded()))
        let height = max(1, Int(pixels.height.rounded()))
        let key = "\(color.description)-\(width)x\(height)"
        let kept = made(for: image)
        if let known = kept.images[key] { return known }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        let ns = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        context.interpolationQuality = .high
        let solid = color.usingColorSpace(.sRGB) ?? color
        context.setAlpha(solid.alphaComponent)
        context.beginTransparencyLayer(in: rect, auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        context.setBlendMode(.sourceAtop)
        context.setFillColor(solid.withAlphaComponent(1).cgColor)
        context.fill(rect)
        context.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
        let made = context.makeImage()
        if kept.images.count > 32 { kept.images.removeAll() }
        kept.images[key] = made
        return made
    }
}


final class KitMark: NSView {
    var icon: NSImage? { didSet { if icon !== oldValue { needsLayout = true; needsDisplay = true } } }
    var letter: String { didSet { if letter != oldValue { label.text = letter } } }
    var side: CGFloat { didSet { if side != oldValue { restyle() } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { label.ink = ink; needsDisplay = true } } }

    private let label = KitLabel()
    private let tile = KitBox(fill: KitColor.ink.withAlphaComponent(0.06))
    private let plate = KitBox(fill: nil)
    private let picture = NSImageView()

    init(icon: NSImage?, letter: String, side: CGFloat = 16) {
        self.icon = icon
        self.letter = letter
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        label.text = letter
        label.color = KitColor.muted
        label.alignment = .center
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.cornerCurve = .continuous
        for view in [tile, label, plate, picture] { addSubview(view) }
        restyle()
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    private var template: Bool { icon?.isTemplate == true }

    private func restyle() {
        label.font = .systemFont(ofSize: side * 0.56, weight: .medium)
        tile.corners = .radius(side * 0.22)
        plate.corners = .radius(side * 0.32)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let box = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        tile.frame = box
        label.frame = box
        let shown = icon != nil
        tile.isHidden = shown
        label.isHidden = shown
        picture.isHidden = !shown
        picture.image = icon
        let inset = template ? side * 0.06 : 0
        picture.frame = box.insetBy(dx: inset, dy: inset)
        picture.layer?.cornerRadius = template ? 0 : side * 0.22
        picture.layer?.masksToBounds = !template
        picture.contentTintColor = template ? ink.color(KitColor.ink, .ink, opacity: 0.75, dark: kitDark) : nil
        plate.frame = box.insetBy(dx: -side * 0.14, dy: -side * 0.14)
        plate.fill = plateColour
        plate.isHidden = plate.fill == nil
    }

    private var plateColour: NSColor? {
        guard let icon, !template else { return nil }
        return PinTint.of(icon).backing(dark: kitDark)
    }
}
