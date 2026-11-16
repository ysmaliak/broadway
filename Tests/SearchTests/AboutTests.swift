import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct AboutTests {
    private static let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fonts")

    private func placed(_ view: NSView, dark: Bool) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: AboutView.size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(origin: .zero, size: AboutView.size)
        window.contentView = view
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func drawn(_ view: NSView) throws -> NSBitmapImageRep {
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private func colour(_ rep: NSBitmapImageRep, at point: CGPoint, in size: NSSize) throws -> NSColor {
        let x = Int(point.x / size.width * CGFloat(rep.pixelsWide))
        let y = Int(point.y / size.height * CGFloat(rep.pixelsHigh))
        return try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    private func near(_ a: NSColor, _ b: NSColor, within: CGFloat = 0.02) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) <= within && abs(a.greenComponent - b.greenComponent) <= within
            && abs(a.blueComponent - b.blueComponent) <= within
    }

    private func texts(in view: AboutView) -> [NSView] {
        view.subviews.filter { $0 is NSTextField || $0 is KitLabel || $0 is KitParagraph }
    }

    @Test func theWindowStaysANativeTitledWindowOfOneSize() throws {
        let window = AboutWindow.make()
        defer { window.close() }

        #expect(window.styleMask == [.titled, .closable, .fullSizeContentView])
        #expect(!window.styleMask.contains(.resizable))
        #expect(window.standardWindowButton(.closeButton) != nil)
        #expect(window.isMovableByWindowBackground)
        #expect(window.title == "About Broadway")
        #expect(window.contentView is AboutView)
        #expect(window.contentRect(forFrameRect: window.frame).size == AboutView.size)
    }

    @Test func theVersionIsShownAsSelectableMonospacedText() throws {
        let view = AboutView()
        let window = placed(view, dark: true)
        defer { window.close() }

        let version = try #require(view.kitSubviews(of: NSTextField.self).first { $0.stringValue == AboutWindow.version })
        #expect(version.isSelectable)
        #expect(version.font?.isFixedPitch == true)
        #expect(!version.isHidden && version.frame.width >= version.intrinsicContentSize.width && view.bounds.contains(version.frame))
    }

    @Test(arguments: [true, false])
    func theViewDrawsThePlateOfItsAppearance(dark: Bool) throws {
        let view = AboutView()
        let window = placed(view, dark: dark)
        defer { window.close() }

        let rep = try drawn(view)

        let foot = try (0..<200).map { try colour(rep, at: CGPoint(x: CGFloat($0), y: view.bounds.height - 3), in: view.bounds.size) }
        let plate = foot.sorted { $0.redComponent < $1.redComponent }[foot.count / 2]
        #expect(near(plate, AboutBrand.plate(dark: dark), within: 0.04))
        #expect(near(AboutBrand.plate(dark: dark), dark ? AboutBrand.hex(0x111216) : .white, within: 0.001))
        let onLine = try colour(rep, at: view.lineSample, in: view.bounds.size)
        #expect(near(onLine, AboutBrand.line(dark: dark), within: 0.06))
    }

    @Test(arguments: [true, false])
    func theWordsReadAgainstThePlateAndTheGrid(dark: Bool) {
        let plate = AboutBrand.plate(dark: dark)
        let gridded = SidebarStyleTests.over(AboutBrand.grid(dark: dark), plate)

        for ink in [AboutBrand.ink(dark: dark), AboutBrand.quiet(dark: dark)] {
            #expect(SidebarStyleTests.contrast(SidebarStyleTests.over(ink, plate), plate) >= 4.5)
            #expect(SidebarStyleTests.contrast(SidebarStyleTests.over(ink, gridded), gridded) >= 4.5)
        }
        #expect(SidebarStyleTests.contrast(AboutBrand.line(dark: dark), plate) >= 15)
    }

    @Test func noWordsSitOnTheLineInOverpassOrTheSystemFont() {
        let first = AboutView()
        AboutFonts.register(AboutFonts.files.map { Self.fonts.appendingPathComponent($0) })
        let overpass = AboutView()

        for view in [first, overpass] {
            let window = placed(view, dark: true)
            defer { window.close() }
            let stroke = view.route.copy(strokingWithWidth: AboutView.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
            let words = texts(in: view)

            #expect(words.count == 4)
            for word in words {
                #expect(view.bounds.contains(word.frame), "\(type(of: word)) \(word.frame)")
                #expect(!stroke.intersects(CGPath(rect: word.frame.insetBy(dx: -4, dy: -4), transform: nil)), "\(type(of: word)) \(word.frame)")
            }
        }
    }

    @Test func theNameStaysWholeInEitherFont() {
        let view = AboutView()
        let window = placed(view, dark: false)
        defer { window.close() }

        let name = view.kitSubviews(of: NSTextField.self).first { $0.stringValue == "Broadway" }

        #expect(name.map { $0.frame.width >= ceil($0.attributedStringValue.size().width) } == true)
    }

    @Test func theIconWavesWhenClickedFollowsAChangedIconAndStaysStillUnderReduceMotion() throws {
        Store.settings.set(true, forKey: "motion.testReduced")
        defer { Store.settings.removeObject(forKey: "motion.testReduced") }
        let view = AboutView()
        let window = placed(view, dark: true)
        defer { window.close() }
        let icon = try #require(view.kitSubviews(of: AboutIcon.self).first)
        let click = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))

        icon.mouseDown(with: click)

        let layer = try #require(icon.layer)
        #expect(layer.animationKeys()?.isEmpty ?? true)
        #expect(abs(atan2(layer.transform.m12, layer.transform.m11) + 6 * .pi / 180) < 0.001)
        icon.mouseDown(with: click)
        #expect(CATransform3DIsIdentity(layer.transform))
        icon.image = nil
        NotificationCenter.default.post(name: AppIconShown.changed, object: nil)
        #expect(icon.image === NSApp.applicationIconImage)
    }

    @Test func overpassRegistersFromItsFilesAndAMissingFileFallsBack() {
        let missing = URL(fileURLWithPath: "/nonexistent/overpass.woff2")

        #expect(!AboutFonts.register([missing]))
        #expect(!AboutFonts.register([]))
        let fallback = AboutFonts.face("NoSuchFace-Black", size: 20, or: .systemFont(ofSize: 20, weight: .black))
        #expect(fallback.fontName == NSFont.systemFont(ofSize: 20, weight: .black).fontName)
        #expect(AboutFonts.register(AboutFonts.files.map { Self.fonts.appendingPathComponent($0) }))
        #expect(AboutFonts.register(AboutFonts.files.map { Self.fonts.appendingPathComponent($0) }))
        #expect(AboutFonts.name(30).fontName == AboutFonts.black)
        #expect(AboutFonts.code(11).fontName == AboutFonts.mono)
        #expect(AboutFonts.text(14).fontName == AboutFonts.regular)
    }
}
