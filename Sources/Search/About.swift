import AppKit
import CoreText

@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info["CFBundleVersion"] as? String
        return build.map { $0 == short || $0.isEmpty ? "Version \(short)" : "Version \(short) (\($0))" } ?? "Version \(short)"
    }

    @discardableResult
    static func show(behind: Bool = false) -> NSWindow {
        let shown = window ?? make()
        window = shown
        if behind {
            shown.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            shown.orderFrontRegardless()
        } else {
            shown.center()
            shown.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        return shown
    }

    static func make() -> NSWindow {
        let made = NSWindow(contentRect: NSRect(origin: .zero, size: AboutView.size),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        made.titlebarAppearsTransparent = true
        made.titleVisibility = .hidden
        made.title = "About Broadway"
        made.isMovableByWindowBackground = true
        made.isReleasedWhenClosed = false
        made.backgroundColor = AboutBrand.dynamic(AboutBrand.plate)
        made.contentView = AboutView()
        made.setContentSize(AboutView.size)
        return made
    }

    static func picture(_ window: NSWindow, scale: CGFloat = 2) -> NSBitmapImageRep? {
        guard let frame = window.contentView?.superview else { return nil }
        window.layoutIfNeeded()
        frame.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let size = frame.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        frame.cacheDisplay(in: frame.bounds, to: rep)
        return rep
    }
}

enum AboutBrand {
    static func plate(dark: Bool) -> NSColor { dark ? hex(BroadwayMap.inkBottom) : hex(0xFFFFFF) }
    static func ink(dark: Bool) -> NSColor { dark ? hex(0xF3F4F6) : hex(BroadwayMap.inkBottom) }
    static func quiet(dark: Bool) -> NSColor { mix(ink(dark: dark), dark ? 0.66 : 0.68, over: plate(dark: dark)) }
    static func grid(dark: Bool) -> NSColor { dark ? hex(BroadwayMap.inkGrid, BroadwayMap.inkGridAlpha) : hex(BroadwayMap.inkBottom, 0.11) }
    static func line(dark: Bool) -> NSColor { dark ? hex(BroadwayMap.inkLine) : hex(BroadwayMap.inkBottom) }
    static func shade(dark: Bool) -> NSColor { dark ? hex(0x000000, 0.5) : hex(BroadwayMap.inkBottom, 0.22) }

    static func dynamic(_ pick: @escaping (Bool) -> NSColor) -> NSColor {
        NSColor(name: nil) { pick($0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) }
    }

    static func mix(_ top: NSColor, _ share: CGFloat, over under: NSColor) -> NSColor {
        let a = top.usingColorSpace(.sRGB) ?? top, b = under.usingColorSpace(.sRGB) ?? under
        func blend(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x * share + y * (1 - share) }
        return NSColor(srgbRed: blend(a.redComponent, b.redComponent), green: blend(a.greenComponent, b.greenComponent),
                       blue: blend(a.blueComponent, b.blueComponent), alpha: 1)
    }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }
}

enum AboutFonts {
    static let black = "OverpassRoman-Black"
    static let regular = "Overpass-Regular"
    static let mono = "OverpassMono-Regular"
    static let files = ["overpass.woff2", "overpass-mono.woff2"]

    static let loaded: Bool = register(files.compactMap { Bundle.main.resourceURL?.appendingPathComponent("Fonts/\($0)") })

    @discardableResult
    static func register(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        var all = true
        for url in urls {
            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) { continue }
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
            if code != CTFontManagerError.alreadyRegistered.rawValue { all = false }
        }
        return all
    }

    static func face(_ name: String, size: CGFloat, or fallback: @autoclosure () -> NSFont) -> NSFont {
        _ = loaded
        return NSFont(name: name, size: size) ?? fallback()
    }

    static func name(_ size: CGFloat) -> NSFont { face(black, size: size, or: .systemFont(ofSize: size, weight: .black)) }
    static func text(_ size: CGFloat) -> NSFont { face(regular, size: size, or: .systemFont(ofSize: size)) }
    static func code(_ size: CGFloat) -> NSFont { face(mono, size: size, or: .monospacedSystemFont(ofSize: size, weight: .regular)) }
}

final class AboutView: KitFlippedView {
    static let size = NSSize(width: 340, height: 420)
    static let margin: CGFloat = 28
    static let iconSide: CGFloat = 92
    static let nameSize: CGFloat = 44
    static let lineWidth: CGFloat = 10
    static let lineFoot = CGPoint(x: 224, y: 470)
    static let lineScale: CGFloat = 0.5
    static let tilt: CGFloat = 29
    static let avenue: CGFloat = 72
    static let street: CGFloat = 41
    static let gridFades: ClosedRange<CGFloat> = 200...470

    private let icon = AboutIcon()
    private let name = NSTextField(labelWithString: "Broadway")
    private let version = NSTextField(labelWithString: AboutWindow.version)
    private let line = KitLabel("A quiet browser for wandering the web", font: AboutFonts.text(14), color: AboutBrand.dynamic(AboutBrand.quiet))
    private let credit = KitParagraph("Open source under the MIT License,\na fork of Search by Office Commun",
                                      font: AboutFonts.text(11), color: AboutBrand.dynamic(AboutBrand.quiet), alignment: .left,
                                      maxWidth: 226)

    override init(frame: NSRect) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        let word = NSMutableAttributedString(string: "Broadway", attributes: [
            .font: AboutFonts.name(Self.nameSize), .foregroundColor: AboutBrand.dynamic(AboutBrand.ink),
        ])
        word.addAttribute(.kern, value: -Self.nameSize * 0.04, range: NSRange(location: 0, length: word.length - 1))
        name.attributedStringValue = word
        name.lineBreakMode = .byClipping
        version.font = AboutFonts.code(11)
        version.textColor = AboutBrand.dynamic(AboutBrand.quiet)
        version.isSelectable = true
        line.alignment = .left
        for view in [icon, name, version, line, credit] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }
    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        icon.shade(dark: kitDark)
        needsDisplay = true
    }

    var route: CGPath {
        let canvas = BroadwayMap.canvas
        let points = BrandMark.route.map { CGPoint(x: $0.x, y: canvas - $0.y) }
        let move = CGAffineTransform(translationX: -points[0].x, y: -points[0].y)
            .concatenating(CGAffineTransform(scaleX: Self.lineScale, y: Self.lineScale))
            .concatenating(CGAffineTransform(translationX: Self.lineFoot.x, y: Self.lineFoot.y))
        let p = points.map { $0.applying(move) }
        let path = CGMutablePath()
        path.move(to: p[0])
        path.addLine(to: p[1])
        path.addQuadCurve(to: p[3], control: p[2])
        path.addLine(to: p[4])
        return path
    }

    var lineSample: CGPoint {
        let canvas = BroadwayMap.canvas
        let points = BrandMark.route.map { CGPoint(x: $0.x, y: canvas - $0.y) }
        let foot = points[0], knee = points[1]
        let open = bounds.insetBy(dx: 12, dy: 12)
        for step in 0...40 {
            let t = CGFloat(step) / 40
            let point = CGPoint(x: Self.lineFoot.x + (knee.x - foot.x) * Self.lineScale * t,
                                y: Self.lineFoot.y + (knee.y - foot.y) * Self.lineScale * t)
            if open.contains(point) { return point }
        }
        return .zero
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let dark = kitDark
        let plate = AboutBrand.plate(dark: dark)
        cg.setFillColor(plate.cgColor)
        cg.fill(bounds)
        cg.saveGState()
        cg.translateBy(x: 40, y: 30)
        cg.rotate(by: Self.tilt * .pi / 180)
        let reach = hypot(bounds.width, bounds.height) * 1.5
        let grid = CGMutablePath()
        var x = -(reach / Self.avenue).rounded(.up) * Self.avenue
        while x <= reach {
            grid.move(to: CGPoint(x: x, y: -reach))
            grid.addLine(to: CGPoint(x: x, y: reach))
            x += Self.avenue
        }
        var y = -(reach / Self.street).rounded(.up) * Self.street
        while y <= reach {
            grid.move(to: CGPoint(x: -reach, y: y))
            grid.addLine(to: CGPoint(x: reach, y: y))
            y += Self.street
        }
        cg.addPath(grid)
        cg.setStrokeColor(AboutBrand.grid(dark: dark).cgColor)
        cg.setLineWidth(1)
        cg.strokePath()
        cg.restoreGState()
        let from = Self.gridFades.lowerBound, to = Self.gridFades.upperBound
        let clear = plate.withAlphaComponent(0).cgColor
        if let fade = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [clear, plate.cgColor] as CFArray, locations: [0, 1]) {
            cg.saveGState()
            cg.clip(to: CGRect(x: 0, y: from, width: bounds.width, height: bounds.height - from))
            cg.drawLinearGradient(fade, start: CGPoint(x: 0, y: from), end: CGPoint(x: 0, y: to), options: [.drawsAfterEndLocation])
            cg.restoreGState()
        }
        cg.addPath(route)
        cg.setStrokeColor(AboutBrand.line(dark: dark).cgColor)
        cg.setLineWidth(Self.lineWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
    }

    override func layout() {
        super.layout()
        icon.shade(dark: kitDark)
        func place(_ view: NSView, _ size: NSSize, at top: CGFloat) {
            view.frame = kitSnap(NSRect(x: Self.margin, y: top, width: size.width, height: size.height))
        }
        let side = Self.iconSide
        icon.frame = kitSnap(NSRect(x: Self.margin - side * 0.098, y: 64, width: side, height: side))
        let measured = name.attributedStringValue.size()
        let nameSize = NSSize(width: ceil(measured.width) + 8, height: ceil(measured.height) + 2)
        let codeSize = version.intrinsicContentSize
        let top: CGFloat = 186
        place(version, codeSize, at: top)
        place(name, nameSize, at: top + codeSize.height + 2)
        place(line, line.intrinsicContentSize, at: top + codeSize.height + nameSize.height + 8)
        let creditSize = NSSize(width: credit.naturalWidth, height: credit.height(for: credit.naturalWidth))
        place(credit, creditSize, at: bounds.height - 24 - creditSize.height)
    }
}

final class AboutIcon: NSImageView {
    private var waved = false

    init() {
        super.init(frame: .zero)
        image = NSApp.applicationIconImage
        NotificationCenter.default.addObserver(self, selector: #selector(iconChanged), name: AppIconShown.changed, object: nil)
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityElement(false)
        shade(dark: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func shade(dark: Bool) {
        WelcomeShadow.apply(self, colour: AboutBrand.shade(dark: dark).withAlphaComponent(1),
                            opacity: AboutBrand.shade(dark: dark).alphaComponent, radius: 14, y: 10)
    }

    @objc private func iconChanged() {
        image = NSApp.applicationIconImage
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        waved.toggle()
        let angle: CGFloat = waved ? -6 * .pi / 180 : 0
        let mid = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        let turn = CATransform3DConcat(CATransform3DConcat(CATransform3DMakeTranslation(-bounds.midX, -bounds.midY, 0),
                                                           CATransform3DMakeRotation(angle, 0, 0, 1)), mid)
        layer?.kitAnimate("transform", to: NSValue(caTransform3D: turn),
                          curve: Motion.reduced ? .none : .spring(KitSpring(response: 0.35, damping: 0.35)))
    }
}

@MainActor
enum AboutSurface {
    static func make(_ request: [String: Any]) -> NSView {
        let view = AboutView()
        view.kitSize(width: AboutView.size.width, height: AboutView.size.height)
        return view
    }
}
