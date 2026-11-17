import AppKit

@MainActor
enum BenchSurfaces {
    static let verbs: Set<String> = ["surface"]
    static let names = ["recording-pill", "shortcut-numbers", "trouble", "files-page", "integration-preview", "integration-hover", "developer", "nice-to-meet-you"]
        + ["space-ground", "stacked-headers", "new-space-card", "space-look-editor", "space-look-chooser"]
        + ["settings-switches", "settings-controls", "settings-drill", "settings-danger", "settings-header"]
        + ["newtab", "onboarding", "about"]
        + ["marks", "provider-marks", "hover-tab-card", "account-list", "device-bar", "hover-folder-list", "tab-offers"]
        + ["find-bar", "find-bar-empty", "find-bar-narrow", "find-count", "form-fill-card", "form-fill-done", "form-fill-offer", "form-drafts-working", "form-drafts-card", "form-drafts-warned"]
        + ["meeting-alert", "meeting-alert-two", "meeting-alert-faces", "meeting-alert-long", "pin-meeting-badges", "history-panel", "downloads-panel", "hidden-panel"]
        + BookmarksSurface.names + SettingsPieceSurfaces.names + BenchFloating.names + BenchPages.names + SiteSurfaces.names
        + BenchFieldFixtures.names + SideSurfaces.names
    private static var windows: [NSWindow] = []

    static func run(_ verb: String, _ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "surface only works on a --test run"]); return }
        switch request["action"] as? String ?? "show" {
        case "close":
            for window in windows { window.orderOut(nil) }
            windows.removeAll()
            answer(["closed": true])
        case "list":
            answer(["surfaces": names])
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
        case "provider-marks":
            return PieceSurfaces.providerMarks()
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
        case "nice-to-meet-you":
            return GetToKnowSurface.sheet(request)
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
        case "form-drafts-working": return FormDrafts.surface("working")
        case "form-drafts-card": return FormDrafts.surface("card")
        case "form-drafts-warned": return FormDrafts.surface("warned")
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
        let stage = KitBox(fill: ground(request["ground"] as? String))
        window.contentView = stage
        stage.addSubview(view)
        view.layoutSubtreeIfNeeded()
        let fitted = view.fittingSize
        let size = NSSize(width: ceil(max(fitted.width, 1)), height: ceil(max(fitted.height, 1)))
        view.frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrame(NSRect(x: area.minX + 40 + CGFloat(windows.count) * 24, y: area.maxY - 200 - size.height,
                               width: size.width + pad * 2, height: size.height + pad * 2), display: true)
        window.orderFrontRegardless()
        windows.append(window)
        var said: [String: Any] = ["number": window.windowNumber, "size": [size.width, size.height], "dark": dark]
        if request["controls"] as? Bool == true { said["controls"] = controls(in: view) }
        return said
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
                if let hit = control(of: view.hitTest(NSPoint(x: x, y: y)), under: view) {
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

    static func providerMarks() -> NSView {
        let stage = KitFlippedView()
        let sizes: [(CGFloat, Bool)] = [(40, true), (32, false), (20, true)]
        let column: CGFloat = 40
        let tall = sizes.map(\.0).reduce(0, +) + 10 * CGFloat(sizes.count - 1)
        for (index, kind) in PlanCardKind.allCases.enumerated() {
            var y: CGFloat = 8
            let x = 8 + CGFloat(index) * (column + 12)
            for (size, lit) in sizes {
                let mark = ProviderMarkView(kind: kind, size: size, lit: lit)
                mark.frame = NSRect(x: x + (column - size) / 2, y: y, width: size, height: size)
                stage.addSubview(mark)
                y += size + 10
            }
        }
        let count = CGFloat(PlanCardKind.allCases.count)
        stage.frame = NSRect(x: 0, y: 0, width: 16 + count * column + (count - 1) * 12, height: 16 + tall)
        return sized(stage, width: stage.frame.width, height: stage.frame.height)
    }
}
