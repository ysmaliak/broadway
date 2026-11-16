import AppKit
import Observation
import WebKit

// "● Loom is recording your screen — Stop": a small pill of Search's own,
// floating at the foot of the screen for as long as an extension records
// anything — the screen, a window, the camera or the microphone — beside
// macOS's own sharing item and dots, and with its own Stop. It never takes
// the keys or the focus from what you are doing. What is recording is
// ExtensionCapture's to say (see ExtensionCapture.swift); this only shows it.
//
// An offscreen document that records (Tella, Vidyard…) has nowhere WebKit
// counts as seen, and WebKit won't start a capture from a page nobody sees.
// While it records, its page is lent to the pill — a 2×2 point view behind
// the pill's content — and given back after: the thing that lets it record
// is the thing that says it is recording.

/// One line of the pill: who is recording, and what.
struct RecordingLine: Identifiable, Equatable {
    let id: String
    /// The extension's name.
    let name: String
    /// "is recording your screen", "is using your camera and microphone"…
    let what: String
}

@MainActor
@Observable
final class RecordingIndicator {
    static let shared = RecordingIndicator()

    /// What the pill says, one line per extension recording.
    private(set) var lines: [RecordingLine] = []
    /// What Stop does, for a line's extension.
    @ObservationIgnored var onStop: ((String) -> Void)?

    @ObservationIgnored private var panel: PillPanel?
    /// Offscreen pages lent to the pill while they record, with where each
    /// came from, to be given back.
    @ObservationIgnored private var hosted: [(web: WKWebView, home: NSView?)] = []

    /// The lines as they are now, and the pages capturing: shown when
    /// there are any, or a page is lent to the pill; gone when there are
    /// none. A tab whose page is among them wears a mark in the row.
    func update(_ lines: [RecordingLine], pages: [WKWebView] = []) {
        if self.lines != lines { self.lines = lines }
        let capturing = Set(pages.map(ObjectIdentifier.init))
        for browser in Browsers.all {
            for tab in browser.tabs {
                let now = tab.built.map { capturing.contains(ObjectIdentifier($0)) } ?? false
                if tab.recording != now { tab.recording = now }
            }
        }
        settle()
    }

    /// A line's Stop.
    func stop(_ id: String) { onStop?(id) }

    // MARK: - lending an offscreen page (phase 2)

    /// An offscreen document's page, lent to the pill so that WebKit counts
    /// it as seen while it records. Asked again for the same page, nothing
    /// more happens.
    func host(_ web: WKWebView) {
        guard !hosted.contains(where: { $0.web === web }) else { return }
        hosted.append((web, web.superview))
        let panel = ownPanel()
        web.removeFromSuperview()
        panel.lend(web)
        settle()
    }

    /// Given back to where it was, or to nowhere if it had no home.
    func release(_ web: WKWebView) {
        guard let index = hosted.firstIndex(where: { $0.web === web }) else { return }
        let home = hosted.remove(at: index).home
        web.removeFromSuperview()
        if let home { home.addSubview(web) }
        settle()
    }

    /// Whether a page is lent to the pill now, for the bench.
    func hosts(_ web: WKWebView) -> Bool { hosted.contains { $0.web === web } }

    // MARK: - on screen

    /// Up while anything records or a page is lent to it; down otherwise.
    /// A test run keeps it off every screen, whatever it would show: its
    /// model is what is tested there (see Bench, recording).
    private func settle() {
        hosted.removeAll { $0.web.superview == nil && $0.web.window == nil && !isLent($0.web) }
        let wanted = !lines.isEmpty || !hosted.isEmpty
        guard wanted else {
            panel?.orderOut(nil)
            return
        }
        let panel = ownPanel()
        panel.fit()
        guard !Store.testing else { return }
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func isLent(_ web: WKWebView) -> Bool { panel?.holds(web) == true }

    private func ownPanel() -> PillPanel {
        if let panel { return panel }
        let made = PillPanel(indicator: self)
        panel = made
        return made
    }

    static func surface(_ lines: [RecordingLine]) -> NSView {
        let indicator = RecordingIndicator()
        indicator.lines = lines
        return RecordingPillView(indicator: indicator)
    }

    /// The pill as it is drawn, as a picture, for the bench: the view alone,
    /// laid out off every screen.
    func picture(dark: Bool) -> NSBitmapImageRep? {
        let view = RecordingPillView(indicator: self)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = view.intrinsicContentSize
        view.frame = NSRect(origin: .zero, size: NSSize(width: max(size.width, 10), height: max(size.height, 10)))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard let layer = view.layer else { return nil }
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * scale), pixelsHigh: Int(view.bounds.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        rep.size = view.bounds.size
        context.translateBy(x: 0, y: view.bounds.height * scale)
        context.scaleBy(x: scale, y: -scale)
        layer.render(in: context)
        return rep
    }
}

/// The panel: borderless, never key or main, over every space and full
/// screen app, at the foot of the screen Search is on.
private final class PillPanel: NSPanel {
    private let content: RecordingPillView
    /// Where lent pages go: behind the pill's own content, 2×2 points.
    private let lending = NSView(frame: NSRect(x: 2, y: 2, width: 2, height: 2))

    init(indicator: RecordingIndicator) {
        content = RecordingPillView(indicator: indicator)
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 40),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        let root = NSView(frame: .zero)
        root.addSubview(lending)
        root.addSubview(content)
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func lend(_ web: WKWebView) {
        web.frame = lending.bounds
        lending.addSubview(web)
    }

    func holds(_ web: WKWebView) -> Bool { web.superview === lending }

    /// Its size for what it says, at the foot of the screen, centred.
    func fit() {
        let size = content.intrinsicContentSize
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: area.midX - size.width / 2, y: area.minY + 24, width: size.width, height: size.height)
        content.frame = NSRect(origin: .zero, size: size)
        if isVisible { setFrame(NSRect(origin: self.frame.origin, size: size), display: true) } else { setFrame(frame, display: false) }
    }
}

final class RecordingPillView: KitBox {
    private let indicator: RecordingIndicator
    private var shown: [RecordingLine] = []
    private var rows: [Row] = []

    private static let font = NSFont.systemFont(ofSize: 13)
    private static let bold = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private static let inset = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 7)

    private final class Row {
        let dot = KitBox(fill: .systemRed, corners: .capsule)
        let words = KitLabel()
        let stop: KitPushButton

        init(_ line: RecordingLine, indicator: RecordingIndicator) {
            stop = KitPushButton("Stop", prominent: true, size: .small) { [weak indicator] in indicator?.stop(line.id) }
            stop.setAccessibilityLabel("Stop \(line.name)")
            words.runs = [KitLabel.Run(text: line.name, font: RecordingPillView.bold),
                          KitLabel.Run(text: " \(line.what)", font: RecordingPillView.font)]
        }

        var views: [NSView] { [dot, words, stop] }
        var height: CGFloat { max(7, words.intrinsicContentSize.height, stop.intrinsicContentSize.height) }
        var width: CGFloat { 7 + 8 + words.intrinsicContentSize.width + 8 + 12 + 8 + stop.intrinsicContentSize.width }
    }

    init(indicator: RecordingIndicator) {
        self.indicator = indicator
        super.init(frame: .zero)
        fill = Palette.NS.ground
        stroke = Palette.NS.hairline
        corners = .radius(18)
        passesClicks = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Recording")
        sync(indicator.lines)
    }

    override var intrinsicContentSize: NSSize {
        sync(indicator.lines)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + CGFloat(max(0, rows.count - 1)) * 4
        return NSSize(width: Self.inset.left + width + Self.inset.right, height: Self.inset.top + height + Self.inset.bottom)
    }

    override func layout() {
        sync(indicator.lines)
        super.layout()
        let width = rows.map(\.width).max() ?? 0
        var y = Self.inset.top
        for row in rows {
            let height = row.height
            let words = row.words.intrinsicContentSize
            let stop = row.stop.intrinsicContentSize
            var x = Self.inset.left
            row.dot.frame = kitSnap(NSRect(x: x, y: y + (height - 7) / 2, width: 7, height: 7))
            x += 7 + 8
            row.words.frame = kitSnap(NSRect(x: x, y: y + (height - words.height) / 2, width: words.width, height: words.height))
            row.stop.frame = kitSnap(NSRect(x: Self.inset.left + width - stop.width, y: y + (height - stop.height) / 2,
                                            width: stop.width, height: stop.height))
            y += height + 4
        }
    }

    private func sync(_ lines: [RecordingLine]) {
        guard lines != shown else { return }
        shown = lines
        for row in rows { row.views.forEach { $0.removeFromSuperview() } }
        rows = lines.map { Row($0, indicator: indicator) }
        for row in rows { row.views.forEach(addSubview) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }
}
