import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LookPadTests {
    private static let size = CGSize(width: 300, height: ThemePad.height)
    private static let pointers = [CGPoint(x: 290, y: 84), CGPoint(x: 10, y: 84), CGPoint(x: 150, y: 5), CGPoint(x: 150, y: 160),
                                   CGPoint(x: 250, y: 30), CGPoint(x: 60, y: 140), CGPoint(x: 200, y: 110), CGPoint(x: 110, y: 60)]

    private var windows: [NSWindow] = []
    private var browsers: [Browser] = []

    init() {
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        for window in windows { window.contentView = nil; window.close() }
        for browser in browsers { browser.closeAll() }
        windows.removeAll()
        browsers.removeAll()
    }

    @Test(arguments: ["E5E5E5", "1C1C1C", "808080", "3139FB"])
    func aPickedColourSitsWhereItWasPicked(base: String) {
        let tone = ThemePad.tone(ThemePad.toneValue([base]))

        let landed = Self.pointers.map {
            ThemePad.place(ThemePad.colour(at: $0, in: Self.size, lightness: tone, wide: true).code, in: Self.size, wide: true)
        }

        for (pointer, place) in zip(Self.pointers, landed) {
            #expect(hypot(place.x - pointer.x, place.y - pointer.y) < 4, "picked at \(pointer), placed at \(place) on \(base)")
        }
    }

    @Test func draggingOnALightSpaceMovesTheHandleUnderThePointer() async throws {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.setSpaceLook(browser.space.id, to: SpaceLook(colours: ["E5E5E5"], intensity: SpaceLook.bold, transparency: 0.3, grain: 0.2, glass: false),
                             lasting: false)
        let editor = SpaceLookEditorView(browser: browser)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: SpaceLookEditorView.width, height: SpaceLookEditorView.open),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        window.orderFrontRegardless()
        windows.append(window)
        editor.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let pad = try #require(editor.kitSubviews(of: LookPadView.self).first)
        let tone = ThemePad.toneValue(browser.space.look?.picked ?? [])
        let path = [CGPoint(x: 150, y: 84), CGPoint(x: 220, y: 50), CGPoint(x: 270, y: 40)]

        for (index, point) in path.enumerated() {
            let type: NSEvent.EventType = index == 0 ? .leftMouseDown : .leftMouseDragged
            let event = try #require(NSEvent.mouseEvent(with: type, location: pad.convert(point, to: nil), modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                        context: nil, eventNumber: index, clickCount: 1, pressure: 1))
            window.sendEvent(event)
            try await Task.sleep(for: .milliseconds(40))
        }

        let handle = try #require(pad.layer?.sublayers?.first { $0 is LookKnob })
        let end = path[path.count - 1]
        #expect(hypot(handle.position.x - end.x, handle.position.y - end.y) < 4, "the handle is at \(handle.position), the pointer at \(end)")
        #expect(abs(ThemePad.toneValue(browser.space.look?.picked ?? []) - tone) < 0.01, "a drag on the pad keeps the tone")
    }

    @Test func draggingThePadInsideItsPopupMovesTheHandleAndKeepsThePopupOpen() async throws {
        let browser = Browser(record: WindowRecord())
        browsers.append(browser)
        browser.setSpaceLook(browser.space.id, to: SpaceLook(colours: ["E5E5E5"], intensity: SpaceLook.bold, transparency: 0.3, grain: 0.2, glass: false),
                             lasting: false)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 900), styleMask: .borderless, backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 10, y: 840, width: 200, height: 30))
        window.contentView?.addSubview(anchor)
        window.orderFrontRegardless()
        windows.append(window)
        let editor = SpaceLookEditorView(browser: browser)
        editor.refresh()
        let size = NSSize(width: SpaceLookEditorView.width, height: SpaceLookEditorView.open)
        let popup = try #require(KitPopup.show(editor, size: size, from: anchor.bounds, of: anchor, edge: .right, bleeds: true))
        let panel = try #require(popup.panel)
        try await Task.sleep(for: .milliseconds(500))
        editor.layoutSubtreeIfNeeded()
        let pad = try #require(editor.kitSubviews(of: LookPadView.self).first)
        let path = [CGPoint(x: 150, y: 84), CGPoint(x: 220, y: 50), CGPoint(x: 270, y: 40)]

        var eaten = false
        for (index, point) in path.enumerated() {
            let type: NSEvent.EventType = index == 0 ? .leftMouseDown : .leftMouseDragged
            let event = try #require(NSEvent.mouseEvent(with: type, location: pad.convert(point, to: nil), modifierFlags: [],
                                                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                                        context: nil, eventNumber: index, clickCount: 1, pressure: 1))
            if index == 0, KitPopup.heard(event) { eaten = true }
            panel.sendEvent(event)
            try await Task.sleep(for: .milliseconds(40))
        }

        let handle = try #require(pad.layer?.sublayers?.first { $0 is LookKnob })
        let end = path[path.count - 1]
        #expect(!eaten)
        #expect(KitPopup.current(in: window) === popup)
        #expect(hypot(handle.position.x - end.x, handle.position.y - end.y) < 4, "the handle is at \(handle.position), the pointer at \(end)")
        popup.close(animated: false)
    }
}
