import AppKit

@MainActor
final class GlassKeyGallery {
    struct Key {
        let name: String
        let view: NSView
        let glass: () -> NSView?
        let point: () -> NSPoint
        var hover: KitHoverView?
    }

    static let cell = NSSize(width: 170, height: 110)
    static let columns = 5

    let window: NSWindow
    let root = KitFlippedView()
    let chrome = FloatChrome()
    private(set) var keys: [Key] = []
    private(set) var fired: [String: Int] = [:]
    private let ground = CAGradientLayer()

    init(dark: Bool, at origin: NSPoint = NSPoint(x: -20000, y: -20000)) {
        window = NSWindow(contentRect: NSRect(origin: origin, size: .zero), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        root.wantsLayer = true
        ground.colors = [NSColor.systemIndigo, NSColor.systemTeal, NSColor.systemOrange].map(\.cgColor)
        ground.startPoint = CGPoint(x: 0, y: 0)
        ground.endPoint = CGPoint(x: 1, y: 1)
        root.layer?.addSublayer(ground)
        window.contentView = root
        build()
        let rows = (keys.count + Self.columns - 1) / Self.columns
        let size = NSSize(width: Self.cell.width * CGFloat(Self.columns), height: Self.cell.height * CGFloat(rows))
        window.setContentSize(size)
        window.setFrameOrigin(origin)
        ground.frame = NSRect(origin: .zero, size: size)
        for (index, key) in keys.enumerated() {
            let column = CGFloat(index % Self.columns)
            let row = CGFloat(index / Self.columns)
            let cell = NSRect(x: column * Self.cell.width, y: row * Self.cell.height, width: Self.cell.width, height: Self.cell.height)
            var fit = key.view.frame.size
            if fit == .zero { fit = key.view.fittingSize }
            key.view.frame = root.kitSnap(NSRect(x: cell.midX - fit.width / 2, y: cell.midY - fit.height / 2, width: fit.width, height: fit.height))
            root.addSubview(key.view)
        }
        chrome.shown = true
        root.layoutSubtreeIfNeeded()
        window.benchShowBehind()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    private func fire(_ name: String) { fired[name, default: 0] += 1 }

    private func centre(_ view: NSView) -> () -> NSPoint {
        { [weak view] in
            guard let view else { return .zero }
            return view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        }
    }

    private func add(_ name: String, _ view: NSView, size: NSSize? = nil, glass: @escaping () -> NSView?, point: (() -> NSPoint)? = nil,
                     hover: KitHoverView? = nil) {
        if let size { view.frame.size = size }
        keys.append(Key(name: name, view: view, glass: glass, point: point ?? centre(view), hover: hover ?? view as? KitHoverView))
    }

    private func build() {
        let corner = FloatKeyView(symbol: "xmark", size: 12, weight: .bold, label: "Close", help: "Close") { [weak self] in self?.fire("float close") }
        add("float close", corner, size: NSSize(width: FloatLayout.circle, height: FloatLayout.circle), glass: { [weak corner] in corner?.glass })

        let transport = FloatTransportView(chrome: chrome, rewind: {}, toggle: { [weak self] in self?.fire("float play") }, forward: {})
        add("float play", transport, size: FloatLayout.transport, glass: { [weak transport] in transport?.toggle.glass },
            point: centre(transport.toggle), hover: transport.toggle)

        let speed = FloatKeyView(text: "1.5×", font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), label: "Playback Speed") { [weak self] in
            self?.fire("float speed")
        }
        add("float speed", speed, size: NSSize(width: 54, height: FloatLayout.circle), glass: { [weak speed] in speed?.glass })

        let live = FloatKeyView(text: "Go Live", font: .systemFont(ofSize: 10, weight: .semibold), label: "Go Live") { [weak self] in self?.fire("float go live") }
        add("float go live", live, size: NSSize(width: 54, height: FloatLayout.line), glass: { [weak live] in live?.glass })

        chrome.captions = [FloatCaption(id: 0, name: "English", selected: true), FloatCaption(id: 1, name: "Deutsch", selected: false)]
        let captions = FloatCaptionsView(chrome: chrome) { [weak self] _ in self?.fire("float subtitles") }
        add("float subtitles", captions, size: NSSize(width: 120, height: FloatCaptionsView.height),
            glass: { [weak captions] in captions?.subviews.first?.subviews.first { $0 is NSGlassEffectView } },
            point: { [weak captions] in
                guard let captions else { return .zero }
                let pill = captions.capsule
                return captions.convert(NSPoint(x: pill.minX + FloatCaptionsView.lead / 2, y: pill.midY), to: nil)
            }, hover: captions.kitSubviews(of: FloatKeyView.self).first)

        let call = KitButton(.plain(press: 1)) { [weak self] in self?.fire("call mic") }
        let callFace = KitGlassFace(KitSymbol("mic.fill", style: KitSymbol.Style(size: 13, weight: .medium)))
        callFace.effectIsInteractive = true
        callFace.tintColor = KitGlass.keyTint(.secondary, dark: true)
        call.content = callFace
        add("call mic", call, size: NSSize(width: 32, height: 32), glass: { [weak call] in call?.kitSubviews(of: NSGlassEffectView.self).first })

        let wait = UpdateWait()
        let update = UpdateCardView(wait: wait)
        update.onRestart = {}
        add("update card hide", update, size: NSSize(width: 160, height: 46), glass: { [weak update] in
            update?.kitSubviews(of: KitGlassFace.self).first
        }, point: { [weak update] in
            guard let update, let face = update.kitSubviews(of: KitGlassFace.self).first else { return .zero }
            return face.convert(NSPoint(x: face.bounds.midX, y: face.bounds.midY), to: nil)
        }, hover: update)

        let peek = PeekKnobsView(split: true, close: { [weak self] in self?.fire("peek close") }, open: {}, beside: {})
        add("peek close", peek, size: PeekKnobsView.size(split: true), glass: { [weak peek] in
            peek?.kitSubviews(of: KitGlassFace.self).first
        }, point: { [weak peek] in
            guard let face = peek?.kitSubviews(of: KitGlassFace.self).first else { return .zero }
            return face.convert(NSPoint(x: face.bounds.midX, y: face.bounds.midY), to: nil)
        }, hover: peek.kitSubviews(of: PeekKnob.self).first)

        let plain = KitGlassKey(title: "Not Now") { [weak self] in self?.fire("glass key") }
        add("glass key", plain, glass: { [weak plain] in plain?.kitSubviews(of: NSGlassEffectView.self).first })

        let primary = KitGlassKey(title: "Save", kind: .primary) { [weak self] in self?.fire("glass key primary") }
        add("glass key primary", primary, glass: { [weak primary] in primary?.kitSubviews(of: NSGlassEffectView.self).first })

        let destructive = KitButton(title: "Delete", font: .systemFont(ofSize: 12), look: .keycap(.destructive)) { [weak self] in
            self?.fire("keycap destructive")
        }
        destructive.padding = 9
        destructive.height = 22
        add("keycap destructive", destructive, glass: { [weak destructive] in destructive?.kitSubviews(of: NSGlassEffectView.self).first })

        let round = KitGlassKey(symbol: "chevron.down", circle: 22, symbolSize: 9, weight: .semibold, quiet: true, label: "Next Match") { [weak self] in
            self?.fire("glass key round")
        }
        add("glass key round", round, glass: { [weak round] in round?.kitSubviews(of: NSGlassEffectView.self).first })

        let page = PageKey("Allow", kind: .secondary)
        page.action = { [weak self] in self?.fire("passwords key") }
        add("passwords key", page, glass: { [weak page] in page?.kitSubviews(of: NSGlassEffectView.self).first })

        let join = MeetingJoinButton(symbol: "video.fill", drawn: false)
        join.action = { [weak self] in self?.fire("meeting join") }
        add("meeting join", join, size: NSSize(width: 84, height: 28), glass: { [weak join] in join?.kitSubviews(of: NSGlassEffectView.self).first })

        let choice = KitChoice("Size", options: [.init(title: "Small", symbol: "circle"), .init(title: "Large", symbol: "circle.fill")], picked: 0)
        choice.pick = { [weak self] _ in self?.fire("choice") }
        add("choice thumb", choice, glass: { [weak choice] in choice?.kitSubviews(of: KitGlass.self).last }, point: { [weak choice] in
            guard let choice else { return .zero }
            return choice.convert(NSPoint(x: choice.bounds.width * 0.25, y: choice.bounds.midY), to: nil)
        })

        let slider = LookClearSlider(frame: NSRect(x: 0, y: 0, width: 150, height: 30))
        slider.show(value: 0.4, glass: false, curve: .none)
        add("look glass bead", slider, size: NSSize(width: 150, height: 30), glass: { [weak slider] in
            slider?.kitSubviews(of: KitGlass.self).first
        }, point: { [weak slider] in
            guard let slider else { return .zero }
            return slider.convert(NSPoint(x: slider.bounds.width - 11, y: slider.bounds.midY), to: nil)
        })

        let off = KitGlassKey(title: "Off") { [weak self] in self?.fire("glass key off") }
        off.isEnabled = false
        add("glass key off", off, glass: { [weak off] in off?.kitSubviews(of: NSGlassEffectView.self).first })

        let system = NSButton(title: "System", target: nil, action: nil)
        system.bezelStyle = .glass
        add("system glass button", system, size: NSSize(width: 90, height: 28), glass: { [weak system] in system })
    }

    static func swelled(_ view: NSView?) -> Bool { abs(scale(view) - 1) > 0.004 }

    static func scale(_ view: NSView?) -> Double {
        var ground = view
        var climb = view?.superview
        while let next = climb {
            if next is NSGlassEffectContainerView { ground = next }
            climb = next.superview
        }
        guard let layer = ground?.layer else { return 1 }
        var found: CGFloat = 1
        func walk(_ layer: CALayer, _ alpha: Swift.Float) {
            guard layer.name != "contentHolderView" else { return }
            let shown = layer.presentation() ?? layer
            let seen = alpha * shown.opacity
            guard seen > 0.05, !shown.isHidden else { return }
            if abs(shown.transform.m11 - 1) > abs(found - 1) { found = shown.transform.m11 }
            layer.sublayers?.forEach { walk($0, seen) }
        }
        walk(layer, 1)
        return Double(found)
    }

    private func picture(_ view: NSView) -> Data? {
        guard let drawn = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: drawn)
        return drawn.tiffRepresentation
    }

    private var number = Int.random(in: 1...Int(Int32.max / 2))

    private func event(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent? {
        if type == .leftMouseDown { number += 1 }
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                                  pressure: type == .leftMouseUp ? 0 : 1)
    }

    func hit(_ key: Key) -> NSView? {
        let point = key.point()
        return root.hitTest(root.superview?.convert(point, from: nil) ?? point)
    }

    func press(_ key: Key, hold: Duration = .milliseconds(160), settle: Duration = .milliseconds(700)) async -> [String: Any] {
        let point = key.point()
        let glass = key.glass()
        let hit = hit(key)
        let inGlass = glass.map { glass in hit.map { $0 === glass || $0.isDescendant(of: glass) } ?? false } ?? false
        let before = fired[key.name, default: 0]
        let rest = Self.swelled(glass)
        var down = false
        var trace: [[Double]] = []
        let start = ContinuousClock.now
        func sample() {
            let elapsed = (ContinuousClock.now - start).components
            let ms = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
            trace.append([ms.rounded(), (Self.scale(glass) * 10000).rounded() / 10000])
        }
        if key.view is NSButton {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { down = Self.swelled(glass) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let up = event(.leftMouseUp, at: point) else { return }
                window.postEvent(up, atStart: false)
            }
            if let press = event(.leftMouseDown, at: point) { window.sendEvent(press) }
        } else {
            if let press = event(.leftMouseDown, at: point) { window.sendEvent(press) }
            let until = ContinuousClock.now + hold
            while ContinuousClock.now < until {
                try? await Task.sleep(for: .milliseconds(20))
                if Self.swelled(glass) { down = true }
                sample()
            }
            if let up = event(.leftMouseUp, at: point) { window.sendEvent(up) }
        }
        let settled = ContinuousClock.now + settle
        while ContinuousClock.now < settled {
            try? await Task.sleep(for: .milliseconds(20))
            sample()
        }
        var hoverDraws: Any = NSNull()
        if let hover = key.hover, hover.window != nil {
            let still = picture(hover)
            hover.benchPillHover(true)
            try? await Task.sleep(for: .milliseconds(300))
            let lit = picture(hover)
            hover.benchPillHover(false)
            try? await Task.sleep(for: .milliseconds(300))
            hoverDraws = still != nil && still != lit
        }
        return [
            "name": key.name,
            "hitInGlass": inGlass,
            "restSwelled": rest,
            "pressSwelled": down,
            "settled": !Self.swelled(glass),
            "fired": fired[key.name, default: 0] - before,
            "hoverDraws": hoverDraws,
            "trace": trace,
        ]
    }

    func measure() async -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for key in keys { rows.append(await press(key)) }
        return rows
    }
}

@MainActor
enum BenchGlassKeys {
    private static var gallery: GlassKeyGallery?

    static func run(_ request: [String: Any], answer: @escaping ([String: Any]) -> Void) {
        let action = request["action"] as? String ?? "measure"
        if action == "open" || gallery == nil {
            gallery?.close()
            let dark = (request["look"] as? String ?? "dark") == "dark"
            let below = request["below"] as? Bool ?? false
            let made = GlassKeyGallery(dark: dark, at: below ? NSPoint(x: 60, y: 60) : NSPoint(x: -20000, y: -20000))
            if below { made.window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1) }
            if request["behind"] as? Bool == true, let screen = NSScreen.main {
                made.window.setFrameOrigin(NSPoint(x: screen.frame.minX - made.window.frame.width + 1, y: screen.frame.minY))
                made.window.benchShowBehind()
            }
            gallery = made
        }
        guard let gallery else { return answer(["error": "no gallery"]) }
        func mark(_ transport: FloatTransportView?) -> [String: Any] {
            guard let key = transport?.toggle, let glyph = key.glyph else { return ["swaps": -1, "mark": ""] }
            let frame = glyph.frame
            return ["swaps": glyph.replaced, "mark": glyph.name.replacingOccurrences(of: ".fill", with: ""),
                    "morph": glyph.morphed, "nudge": [Double(key.nudge.dx), Double(key.nudge.dy)],
                    "frame": [frame.minX, frame.minY, frame.width, frame.height].map(Double.init),
                    "rests": key.nudge == .zero && frame == glyph.superview?.bounds, "reduced": Motion.reduced]
        }
        func frame(_ key: GlassKeyGallery.Key) -> [Double] {
            let rect = key.view.convert(key.view.bounds, to: nil)
            let height = gallery.window.frame.height
            return [rect.minX, height - rect.maxY, rect.width, rect.height].map(Double.init)
        }
        switch action {
        case "open":
            answer(["window": gallery.window.windowNumber, "scale": gallery.window.backingScaleFactor,
                    "size": [gallery.window.frame.width, gallery.window.frame.height],
                    "keys": gallery.keys.map { ["name": $0.name, "frame": frame($0)] as [String: Any] }])
        case "press":
            guard let key = gallery.keys.first(where: { $0.name == request["name"] as? String }) else { return answer(["error": "no such key"]) }
            let hold = request["hold"] as? Int ?? 160
            Task { @MainActor in answer(await gallery.press(key, hold: .milliseconds(hold), settle: .milliseconds(500))) }
        case "play":
            gallery.chrome.playing = request["playing"] as? Bool ?? !gallery.chrome.playing
            let transport = gallery.keys.first { $0.name == "float play" }?.view as? FloatTransportView
            transport?.needsLayout = true
            transport?.layoutSubtreeIfNeeded()
            var said = mark(transport)
            said["playing"] = gallery.chrome.playing
            answer(said)
        case "state":
            let transport = gallery.keys.first { $0.name == "float play" }?.view as? FloatTransportView
            transport?.needsLayout = true
            transport?.layoutSubtreeIfNeeded()
            answer(mark(transport))
        case "skip":
            gallery.chrome.rewinds += 1
            let transport = gallery.keys.first { $0.name == "float play" }?.view as? FloatTransportView
            transport?.needsLayout = true
            transport?.layoutSubtreeIfNeeded()
            answer(["rewinds": gallery.chrome.rewinds])
        case "close":
            gallery.close()
            self.gallery = nil
            answer(["closed": true])
        default:
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                answer(["keys": await gallery.measure()])
            }
        }
    }
}

@MainActor
enum BenchGlassFrames {
    static func record(_ view: NSView, seconds: Double, into folder: URL?, flip: () -> Void) async -> [String: Any] {
        guard let layer = view.layer else { return ["error": "no layer"] }
        var shots: [[UInt8]] = []
        var images: [CGImage] = []
        var times: [Double] = []
        var moving: [Int] = []
        let start = CACurrentMediaTime()
        let ground = view.superview ?? view
        func take() {
            let (pixels, image) = render(layer, at: view.frame.origin, flipped: ground.isFlipped, size: ground.bounds.size)
            shots.append(pixels)
            if let image { images.append(image) }
            times.append(CACurrentMediaTime() - start)
            moving.append(animations(layer))
        }
        take()
        flip()
        while CACurrentMediaTime() - start < seconds {
            try? await Task.sleep(for: .milliseconds(8))
            take()
        }
        guard let first = shots.first, let last = shots.last else { return ["error": "no frames"] }
        let ends = distance(first, last)
        let path = shots.map { [distance($0, first), distance($0, last)] }
        let between = path.filter { $0[0] > ends * 0.15 && $0[1] > ends * 0.15 }.count
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, image) in images.enumerated() {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(String(format: "%04d.png", index)))
            }
        }
        let wide = max(1, Int(ground.bounds.width * 2))
        return ["frames": shots.count, "ends": ends, "between": between, "times": times, "path": path, "sides": shots.map { side($0, wide: wide) },
                "mostAnimations": moving.max() ?? 0, "animatedFrames": moving.filter { $0 > 0 }.count]
    }

    static func side(_ pixels: [UInt8], wide: Int) -> Int {
        let high = pixels.count / 4 / max(1, wide)
        var left = wide, right = -1, top = high, bottom = -1
        for y in 0..<high {
            for x in 0..<wide {
                let at = (y * wide + x) * 4
                guard Int(pixels[at]) + Int(pixels[at + 1]) + Int(pixels[at + 2]) > 180 else { continue }
                left = min(left, x)
                right = max(right, x)
                top = min(top, y)
                bottom = max(bottom, y)
            }
        }
        return right < left ? 0 : max(right - left + 1, bottom - top + 1)
    }

    static func animations(_ layer: CALayer) -> Int {
        (layer.animationKeys()?.count ?? 0) + (layer.sublayers ?? []).reduce(0) { $0 + animations($1) }
    }

    static func render(_ layer: CALayer, at origin: CGPoint, flipped: Bool, size: CGSize) -> ([UInt8], CGImage?) {
        let scale: CGFloat = 2
        let width = max(1, Int(size.width * scale))
        let height = max(1, Int(size.height * scale))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        var image: CGImage?
        data.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.scaleBy(x: scale, y: scale)
            let shown = layer.presentation() ?? layer
            context.translateBy(x: origin.x, y: flipped ? size.height - origin.y - shown.bounds.height : origin.y)
            shown.render(in: context)
            image = context.makeImage()
        }
        return (data, image)
    }

    static func distance(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var sum = 0
        for index in a.indices { sum += abs(Int(a[index]) - Int(b[index])) }
        return Double(sum) / Double(a.count * 255)
    }
}
