import AppKit

@MainActor
enum BenchSurfaces {
    static let verbs: Set<String> = ["surface"]
    static let names = ["recording-pill", "shortcut-numbers", "trouble", "files-page", "integration-preview", "integration-hover", "developer", "nice-to-meet-you"]
        + ["space-ground", "stacked-headers", "new-space-card", "space-look-editor", "space-look-chooser"]
        + ["settings-switches", "settings-controls", "settings-drill", "settings-danger", "settings-header"]
        + ["newtab", "onboarding", "about"]
        + ["marks", "hover-tab-card", "account-list", "device-bar", "hover-folder-list", "tab-offers"]
        + ["find-bar", "find-bar-empty", "find-bar-narrow", "find-count", "form-fill-card", "form-fill-done", "form-fill-offer"]
        + ["meeting-alert", "meeting-alert-two", "meeting-alert-faces", "meeting-alert-long", "pin-meeting-badges", "history-panel", "downloads-panel", "hidden-panel"]
        + BookmarksSurface.names + SettingsPieceSurfaces.names + BenchFloating.names + BenchPages.names + SiteSurfaces.names
        + BenchFieldFixtures.names + SideSurfaces.names + BenchGlassFamily.names + BenchLinkChooser.names
    private static var windows: [NSWindow] = []
    private static var inked: String?

    static func run(_ verb: String, _ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "surface only works on a --test run"]); return }
        switch request["action"] as? String ?? "show" {
        case "close":
            for window in windows { window.orderOut(nil) }
            windows.removeAll()
            answer(["closed": true])
        case "draw":
            guard let stage = windows.last?.contentView, let path = request["path"] as? String else {
                answer(["error": "no surface to draw"])
                return
            }
            answer(draw(stage, to: path))
        case "list":
            answer(["surfaces": names])
        case "blank":
            guard let stage = windows.last?.contentView else { answer(["error": "no surface is up to blank"]); return }
            (inked.map { BenchInk.named($0, in: stage) } ?? [stage]).forEach(BenchInk.blank)
            answer(["blank": true])
        default:
            guard let name = request["name"] as? String, let view = make(name, request) else {
                answer(["error": "no surface named \(request["name"] as? String ?? "")", "surfaces": names])
                return
            }
            let said = show(view, request)
            guard let path = request["path"] as? String, let window = windows.last else { answer(said); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                var said = said
                if BenchSurfacePicture.save(window, to: path) {
                    said["saved"] = path
                    said["path"] = path
                }
                answer(said)
            }
        }
    }

    private static var browser: Browser? { Browsers.front ?? Browsers.primary }

    private static func make(_ name: String, _ request: [String: Any]) -> NSView? {
        switch name {
        case "recording-pill":
            let rows = request["lines"] as? [[String]] ?? [["loom", "Loom", "is recording your screen"]]
            return RecordingIndicator.surface(rows.compactMap { $0.count == 3 ? RecordingLine(id: $0[0], name: $0[1], what: $0[2]) : nil })
        case "shortcut-numbers":
            return PieceSurfaces.shortcutNumbers(lift: request["lift"] as? Double ?? 0)
        case "marks":
            return PieceSurfaces.marks(lift: request["lift"] as? Double ?? 0)
        case "hover-tab-card":
            return HoverCards.surface(plain: request["plain"] as? Bool ?? false)
        case "account-list":
            return AccountCardView.surface(kind: request["kind"] as? String ?? "logins")
        case "device-bar":
            return DeviceBarView.surface()
        case "hover-folder-list":
            return HoverCards.folderSurface(plain: request["plain"] as? Bool ?? false)
        case "tab-offers":
            return TabOffersListView.surface(picked: request["picked"] as? Int)
        case let site where SiteSurfaces.names.contains(site):
            return SiteSurfaces.make(site, request)
        case "trouble":
            return TroubleSurface.make(request)
        case "integration-preview":
            return IntegrationPreviewSurface.make(request)
        case "integration-hover":
            return IntegrationPreviewSurface.hover(request)
        case "developer":
            return DeveloperSurface.make(request)
        case _ where SettingsPieceSurfaces.names.contains(name):
            return SettingsPieceSurfaces.make(name, request)
        case "files-page":
            return FilesSurface.make(request)
        case _ where BookmarksSurface.names.contains(name):
            return BookmarksSurface.make(name, request)
        case "settings-switches", "settings-controls", "settings-drill", "settings-danger", "settings-header":
            return SettingsBenchFaces.make(name)
        case "space-ground":
            return PieceSurfaces.spaceGround(request["style"] as? String)
        case "stacked-headers":
            guard let browser = Browsers.all.first else { return nil }
            return PieceSurfaces.stackedHeaders(browser, style: request["style"] as? String)
        case "new-space-card":
            guard let browser = Browsers.all.first else { return nil }
            return PieceSurfaces.newSpaceCard(browser)
        case "space-look-chooser":
            return PieceSurfaces.spaceLookChooser(request["pick"] as? String)
        case "space-look-editor":
            guard let browser = Browsers.all.first else { return nil }
            return PieceSurfaces.spaceLookEditor(browser, style: request["style"] as? String)
        case "find-bar": return FindBarView.surface(needle: "orchid", narrow: false)
        case "find-bar-empty": return FindBarView.surface(needle: "", narrow: false)
        case "find-bar-narrow": return FindBarView.surface(needle: "orchid", narrow: true)
        case "find-count": return FindCountView.surface()
        case "form-fill-card": return FormFill.surface("card")
        case "form-fill-done": return FormFill.surface("done")
        case "form-fill-offer": return FormFill.surface("offer")
        case "meeting-alert": return MeetingAlerts.surface("one")
        case "meeting-alert-two": return MeetingAlerts.surface("two")
        case "meeting-alert-faces": return MeetingAlerts.surface("faces")
        case "meeting-alert-long": return MeetingAlerts.surface("long")
        case "pin-meeting-badges": return PinMeetingSurface.make()
        case "history-panel": return RecallSurface.history()
        case "downloads-panel": return RecallSurface.downloads()
        case "hidden-panel":
            guard let browser else { return nil }
            let panel = HiddenPanelView(browser: browser)
            panel.frame = NSRect(origin: .zero, size: panel.intrinsicContentSize)
            return panel
        case "newtab":
            return NewTabSurface.make(request)
        case "onboarding":
            return OnboardingSurface.make(request)
        case "about":
            return AboutSurface.make(request)
        case _ where SideSurfaces.names.contains(name):
            return SideSurfaces.make(name, request)
        case _ where BenchPages.names.contains(name):
            return BenchPages.make(name, request)
        case _ where BenchFieldFixtures.names.contains(name):
            return BenchFieldFixtures.surface(name, request, browser: browser)
        case _ where BenchGlassFamily.names.contains(name):
            return BenchGlassFamily.make(name, request, browser: browser)
        case _ where BenchLinkChooser.names.contains(name):
            return BenchLinkChooser.make(request)
        default:
            return BenchFloating.make(name, request)
        }
    }

    private static func show(_ view: NSView, _ request: [String: Any]) -> [String: Any] {
        let dark = request["look"] as? String == "dark"
        let pad = CGFloat(request["pad"] as? Double ?? 16)
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let stage: NSView = request["ground"] as? String == "picture" ? BenchPictureGround() : KitBox(fill: ground(request["ground"] as? String))
        window.contentView = stage
        stage.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let fitted = view.fittingSize
        let size = NSSize(width: ceil(max(fitted.width, 1)), height: ceil(max(fitted.height, 1)))
        view.frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrame(NSRect(x: area.minX + 40 + CGFloat(windows.count) * 24, y: area.maxY - 200 - size.height,
                               width: size.width + pad * 2, height: size.height + pad * 2), display: true)
        window.benchShowBehind()
        windows.append(window)
        var said: [String: Any] = ["number": window.windowNumber, "size": [size.width, size.height], "dark": dark]
        said["key"] = window.isKeyWindow
        said["active"] = NSApp.isActive
        said["level"] = window.level.rawValue
        if request["controls"] as? Bool == true { said["controls"] = controls(in: view) }
        inked = request["under"] as? String
        if request["inks"] as? Bool == true {
            said["inks"] = (inked.map { BenchInk.named($0, in: view) } ?? [view]).flatMap(BenchInk.said)
            said["others"] = Array(Set(BenchInk.others(in: view))).sorted()
        }
        if request["moving"] as? Bool == true { said["moving"] = moving(in: stage) }
        return said
    }

    private static func moving(in view: NSView) -> [[String: Any]] {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        var found: [[String: Any]] = []
        func walk(_ layer: CALayer, _ owner: String) {
            let owner = (layer.delegate as? NSView).map { String(describing: type(of: $0)) } ?? owner
            for key in layer.animationKeys() ?? [] {
                guard let animation = layer.animation(forKey: key), !Motion.staysUnderReduce(animation) else { continue }
                found.append(["view": owner, "key": key, "seconds": animation.duration,
                              "path": (animation as? CAPropertyAnimation)?.keyPath ?? String(describing: type(of: animation))])
            }
            layer.sublayers?.forEach { walk($0, owner) }
        }
        if let layer = view.layer { walk(layer, String(describing: type(of: view))) }
        return found
    }

    private static func draw(_ stage: NSView, to path: String) -> [String: Any] {
        stage.layoutSubtreeIfNeeded()
        stage.displayIfNeeded()
        CATransaction.flush()
        let scale: CGFloat = 2
        let size = stage.bounds.size
        guard size.width >= 1, size.height >= 1,
              let whole = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                           bytesPerRow: 0, bitsPerPixel: 0), let context = NSGraphicsContext(bitmapImageRep: whole) else {
            return ["error": "the surface gave no picture"]
        }
        let pen = context.cgContext
        pen.scaleBy(x: scale, y: scale)
        let ground = ((stage as? KitBox)?.fill ?? .white).kitResolved(dark: stage.kitDark).usingColorSpace(.deviceRGB) ?? .white
        pen.setFillColor(red: ground.redComponent, green: ground.greenComponent, blue: ground.blueComponent, alpha: 1)
        pen.fill(CGRect(origin: .zero, size: size))
        paint(stage, into: pen, size: size)
        guard let png = whole.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil else {
            return ["error": "could not write the picture"]
        }
        return ["drawn": path, "width": whole.pixelsWide, "height": whole.pixelsHigh]
    }

    static func paint(_ stage: NSView, into pen: CGContext, size: CGSize) {
        func glassy(_ view: NSView) -> Bool { view is NSGlassEffectView || view.subviews.contains(where: glassy) }
        func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
            let r = max(0, min(radius, min(rect.width, rect.height) / 2))
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
        func paint(_ view: NSView, _ alpha: CGFloat) {
            guard !view.isHidden, view.alphaValue > 0.01, view.bounds.width > 0, view.bounds.height > 0 else { return }
            let rect = stage.isFlipped
                ? { () -> CGRect in let r = view.convert(view.bounds, to: stage); return CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }()
                : view.convert(view.bounds, to: stage)
            let alpha = alpha * view.alphaValue
            if let glass = view as? NSGlassEffectView {
                pen.saveGState()
                pen.setAlpha(alpha)
                pen.setStrokeColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.6)
                pen.setLineWidth(0.5)
                pen.addPath(rounded(rect.insetBy(dx: 0.25, dy: 0.25), glass.cornerRadius))
                pen.strokePath()
                pen.restoreGState()
                if let content = glass.contentView { paint(content, alpha) }
                return
            }
            guard let layer = view.layer else { return view.subviews.forEach { paint($0, alpha) } }
            pen.saveGState()
            pen.setAlpha(alpha)
            if glassy(view) {
                if let fill = layer.backgroundColor, fill.alpha > 0 {
                    pen.setFillColor(fill)
                    pen.addPath(rounded(rect, layer.cornerRadius))
                    pen.fillPath()
                }
                pen.restoreGState()
                view.subviews.forEach { paint($0, alpha) }
                return
            }
            pen.clip(to: rect.insetBy(dx: -24, dy: -24))
            pen.translateBy(x: rect.minX, y: rect.minY)
            if view.isFlipped {
                pen.translateBy(x: 0, y: rect.height)
                pen.scaleBy(x: 1, y: -1)
            }
            layer.render(in: pen)
            pen.restoreGState()
        }
        stage.subviews.forEach { paint($0, 1) }
    }

    private static func landed(_ point: NSPoint, in view: NSView) -> NSView? {
        let hit = view.hitTest(point)
        if let found = control(of: hit, under: view) { return found }
        guard let table = hit as? NSTableView, table.action != nil, let above = view.superview else { return nil }
        let row = table.row(at: table.convert(point, from: above))
        guard row >= 0, table.numberOfColumns > 0, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) else { return nil }
        return control(of: cell, under: view)
    }

    private static func control(of view: NSView?, under top: NSView) -> NSView? {
        var at = view
        while let here = at, here !== top.superview {
            if here is KitButton || here is NSButton || here is NSSlider || here is NSSegmentedControl { return here }
            if let field = here as? NSTextField, field.isEditable { return here }
            if here.isAccessibilityElement(), here.accessibilityRole() == .button || here.accessibilityRole() == .slider { return here }
            at = here.superview
        }
        return nil
    }

    private static func controls(in view: NSView) -> [[String: Any]] {
        view.layoutSubtreeIfNeeded()
        var found: [NSView] = []
        var reach: [ObjectIdentifier: NSRect] = [:]
        func walk(_ here: NSView) {
            if here.isHidden { return }
            if control(of: here, under: here) === here { found.append(here); return }
            here.subviews.forEach(walk)
        }
        walk(view)
        let frame = view.frame
        var y = frame.minY + 0.5
        while y < frame.maxY {
            var x = frame.minX + 0.5
            while x < frame.maxX {
                if let hit = landed(NSPoint(x: x, y: y), in: view) {
                    let dot = NSRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)
                    reach[ObjectIdentifier(hit)] = reach[ObjectIdentifier(hit)].map { $0.union(dot) } ?? dot
                }
                x += 1
            }
            y += 1
        }
        return found.map { made in
            let box = made.convert(made.bounds, to: view)
            let hit = reach[ObjectIdentifier(made)] ?? .zero
            let title = (made as? NSButton)?.title ?? made.kitSubviews(of: KitLabel.self).map(\.text).joined(separator: " ")
            return ["kind": String(describing: type(of: made)), "size": [box.width, box.height], "hit": [hit.width, hit.height],
                    "label": made.accessibilityLabel() ?? "", "title": title, "help": made.toolTip ?? "",
                    "enabled": (made as? NSControl)?.isEnabled ?? (made as? KitButton)?.isEnabled ?? true]
        }
    }

    private static func ground(_ name: String?) -> NSColor {
        switch name {
        case nil, "ground": return Palette.NS.ground
        case "frame": return Palette.NS.frame
        case let hex?:
            let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
            return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                           blue: CGFloat(value & 0xFF) / 255, alpha: 1)
        }
    }
}

@MainActor
enum BenchArt {
    static let colour: NSImage = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor(srgbRed: 0.18, green: 0.42, blue: 0.95, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 9, dy: 9)).fill()
        NSColor(srgbRed: 0.98, green: 0.62, blue: 0.1, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 20, y: 20, width: 9, height: 9)).fill()
        return true
    }

    static let darkGlyph: NSImage = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
        NSColor.black.setFill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 4, y: 4))
        path.line(to: NSPoint(x: 16, y: 28))
        path.line(to: NSPoint(x: 28, y: 4))
        path.line(to: NSPoint(x: 22, y: 4))
        path.line(to: NSPoint(x: 16, y: 16))
        path.line(to: NSPoint(x: 10, y: 4))
        path.close()
        path.fill()
        return true
    }

    static let template: NSImage = {
        let image = KitGlyph.image("star.fill", .init(size: 24, weight: .regular))?.copy() as? NSImage ?? NSImage()
        image.isTemplate = true
        return image
    }()

    static func tab(_ name: String, address: String, icon: NSImage? = colour) -> Tab {
        let tab = Tab(bench: true)
        if let url = URL(string: address) { tab.hold(url) }
        tab.name = name
        tab.icon = icon
        return tab
    }
}

final class BenchPadded: NSView {
    let inner: NSView
    let pad: CGFloat

    init(_ inner: NSView, pad: CGFloat) {
        self.inner = inner
        self.pad = pad
        super.init(frame: NSRect(x: 0, y: 0, width: inner.frame.width + pad * 2, height: inner.frame.height + pad * 2))
        addSubview(inner)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var innerSize: NSSize {
        let fitted = inner.frame.size == .zero ? inner.fittingSize : inner.frame.size
        return NSSize(width: ceil(fitted.width), height: ceil(fitted.height))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: innerSize.width + pad * 2, height: innerSize.height + pad * 2)
    }

    override func layout() {
        super.layout()
        inner.frame = NSRect(origin: NSPoint(x: pad, y: pad), size: innerSize)
    }
}


@MainActor
enum PieceSurfaces {
    static func shortcutNumbers(lift: Double) -> NSView {
        let side = ShortcutNumberView.side
        let stage = KitFlippedView()
        for number in 1...9 {
            let view = ShortcutNumberView(number: number)
            view.ink = KitInk(lift: lift)
            view.frame = NSRect(x: 6 + CGFloat(number - 1) * (side + 6), y: 6, width: side, height: side)
            stage.addSubview(view)
        }
        stage.frame = NSRect(x: 0, y: 0, width: 12 + 9 * side + 8 * 6, height: 12 + side)
        return sized(stage, width: stage.frame.width, height: stage.frame.height)
    }
}
