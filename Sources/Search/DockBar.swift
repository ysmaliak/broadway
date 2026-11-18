import AppKit

@MainActor
final class DockBar {
    static let shared = DockBar()

    var drivesTile = !Store.testing {
        didSet { if drivesTile != oldValue { paint() } }
    }
    private(set) var percent: Int?
    private var pace = DockPace()
    private var later: DispatchWorkItem?
    private var view: DockBarView?
    private var iconWatch: NSObjectProtocol?

    var shown: Int? { pace.shown }
    var tileSet: Bool { view != nil && NSApplication.shared.dockTile.contentView === view }

    init() {
        iconWatch = NotificationCenter.default.addObserver(forName: AppIconShown.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.view?.needsDisplay = true; self?.paint() }
        }
    }

    func update(_ loads: [DockLoad]) {
        percent = DockProgress.percent(loads)
        step()
    }

    private func step() {
        switch pace.see(percent, at: Date()) {
        case .draw:
            later?.cancel()
            later = nil
            paint()
        case .later(let when):
            guard later == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                later = nil
                step()
            }
            later = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, when.timeIntervalSinceNow), execute: work)
        case .nothing:
            break
        }
    }

    private func paint() {
        guard drivesTile, let shown = pace.shown else {
            if let view {
                let tile = NSApplication.shared.dockTile
                if tile.contentView === view {
                    tile.contentView = nil
                    tile.display()
                }
            }
            view = nil
            return
        }
        let tile = NSApplication.shared.dockTile
        let bar = view ?? DockBarView(frame: NSRect(origin: .zero, size: tile.size))
        bar.fraction = Double(shown) / 100
        if tile.contentView !== bar { tile.contentView = bar }
        view = bar
        tile.display()
    }

    static var icon: NSImage? {
        AppIconShown.picture(AppIconShown.current ?? AppIconShown.baked) ?? NSApplication.shared.applicationIconImage
    }

    static func picture(icon: NSImage?, fraction: Double, side: CGFloat = DockBarLook.tile) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            icon?.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            let scale = side / DockBarLook.tile
            let width = DockBarLook.width * scale, height = DockBarLook.height * scale
            let track = NSRect(x: (side - width) / 2, y: DockBarLook.lift * scale, width: width, height: height)
            DockBarLook.track.setFill()
            NSBezierPath(roundedRect: track, xRadius: height / 2, yRadius: height / 2).fill()
            let inner = track.insetBy(dx: DockBarLook.inset * scale, dy: DockBarLook.inset * scale)
            let filled = NSRect(x: inner.minX, y: inner.minY, width: inner.width * min(1, max(0, fraction)), height: inner.height)
            guard filled.width > 0 else { return true }
            let round = min(filled.width, filled.height) / 2
            DockBarLook.fill.setFill()
            NSBezierPath(roundedRect: filled, xRadius: round, yRadius: round).fill()
            return true
        }
    }
}

final class DockBarView: NSView {
    var fraction: Double = 0 { didSet { if fraction != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        MainActor.assumeIsolated {
            DockBar.picture(icon: DockBar.icon, fraction: fraction, side: bounds.width)
                .draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
        }
    }
}
