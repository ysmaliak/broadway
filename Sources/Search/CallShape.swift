import AppKit
import WebKit

enum CallShape {
    static let narrowest: CGFloat = 3.0 / 4.0
    static let widest: CGFloat = 4
    static let patience = 2
    static let edge: CGFloat = 6
    static let widthKey = "call.width"
    static let shrunk: CGFloat = 0.5
    static let viewport = NSSize(width: 1280, height: 800)

    static var sides: CGFloat { CallFloat.stage.left + CallFloat.stage.right }
    static var ends: CGFloat { CallFloat.stage.top + CallFloat.stage.bottom }
    static var smallest: CGFloat { CallFloat.size.width }
    static var rest: CGFloat { (CallFloat.size.width - sides) / (CallFloat.size.height - ends) }

    static func shape(_ picture: CGFloat?) -> CGFloat {
        guard let picture, picture.isFinite, picture > 0 else { return rest }
        return min(max(picture, narrowest), widest)
    }

    static func height(width: CGFloat, shape: CGFloat) -> CGFloat {
        ((width - sides) / shape + ends).rounded()
    }

    static func width(height: CGFloat, shape: CGFloat) -> CGFloat {
        ((height - ends) * shape + sides).rounded()
    }

    static func largest(screen: NSRect?) -> CGFloat {
        max(smallest, screen.map { ($0.width / 2).rounded(.down) } ?? smallest * 2)
    }

    static func width(_ wanted: CGFloat, screen: NSRect?) -> CGFloat {
        min(max(wanted.rounded(), smallest), largest(screen: screen))
    }

    static func size(width wanted: CGFloat, picture: CGFloat?, screen: NSRect?, room: NSRect? = nil) -> NSSize {
        let wide = width(wanted, screen: screen)
        let tall = height(width: wide, shape: shape(picture))
        return NSSize(width: wide, height: room.map { min(tall, max(CallFloat.size.height, $0.height)) } ?? tall)
    }

    static func dragged(from was: NSSize, to asked: NSSize, picture: CGFloat?, screen: NSRect?, room: NSRect? = nil) -> NSSize {
        let byWidth = abs(asked.width - was.width) >= 0.5
        let wanted = byWidth ? asked.width : width(height: asked.height, shape: shape(picture))
        return size(width: wanted, picture: picture, screen: screen, room: room)
    }

    static func frame(_ was: NSRect, size: NSSize, in room: NSRect?) -> NSRect {
        guard let room else { return NSRect(origin: was.origin, size: size) }
        let right = was.midX >= room.midX
        let up = was.midY >= room.midY
        let made = NSRect(x: right ? was.maxX - size.width : was.minX, y: up ? was.maxY - size.height : was.minY, width: size.width,
                          height: size.height)
        return held(made, in: room.union(was))
    }

    static func held(_ frame: NSRect, in room: NSRect) -> NSRect {
        var made = frame
        made.origin.x = max(room.minX, min(made.minX, room.maxX - made.width))
        made.origin.y = max(room.minY, min(made.minY, room.maxY - made.height))
        return made
    }

    static func zoom(width: CGFloat) -> CGFloat {
        min(1, max(shrunk, shrunk * (width / smallest).squareRoot()))
    }

    static func zoom(tiles size: NSSize) -> CGFloat {
        max(0.05, min(size.width / viewport.width, size.height / viewport.height))
    }

    static func onEdge(_ point: NSPoint, of bounds: NSRect) -> Bool {
        bounds.insetBy(dx: -edge, dy: -edge).contains(point) && !bounds.insetBy(dx: edge, dy: edge).contains(point)
    }

    static func glide(reduced: Bool, seen: Bool) -> TimeInterval? {
        reduced || !seen ? nil : 0.26
    }

    static func changed(_ shape: CGFloat?, from was: CGFloat?) -> Bool {
        guard let shape, let was else { return (shape == nil) != (was == nil) }
        return abs(shape - was) > was * 0.01
    }

    static let read = """
    (function () {
      var one = document.querySelector('[data-broadway-tiles-screen]');
      if (!one) return -1;
      var kept = window.__broadwayCallScreen || {};
      var w = one.videoWidth || 0, h = one.videoHeight || 0;
      if (one.tagName === 'CANVAS') {
        if (getComputedStyle(one).objectFit === 'fill' && kept.shape > 0) { w = kept.shape; h = 1; } else { w = one.width; h = one.height; }
      }
      return w > 0 && h > 0 ? w / h : 0;
    })()
    """
}

@MainActor
final class CallSizing: NSObject, NSWindowDelegate {
    private let store: UserDefaults
    private weak var panel: NSWindow?
    private var clicks: Any?
    private var missed = 0
    private(set) var picture: CGFloat?
    var resized: ((CGFloat) -> Void)?

    init(store: UserDefaults = Store.settings) {
        self.store = store
    }

    var chosen: CGFloat {
        let kept = store.double(forKey: CallShape.widthKey)
        return kept > 0 ? CGFloat(kept) : CallShape.smallest
    }

    private var screen: NSRect? { (panel?.screen ?? NSScreen.main)?.frame }
    private var room: NSRect? { panel?.screen?.visibleFrame }

    func opening(on screen: NSScreen?) -> NSSize {
        let screen = screen ?? NSScreen.main
        return CallShape.size(width: chosen, picture: nil, screen: screen?.frame, room: screen?.visibleFrame)
    }

    func attach(_ panel: NSWindow) {
        self.panel = panel
        picture = nil
        missed = 0
        panel.delegate = self
        panel.minSize = NSSize(width: CallShape.smallest, height: CallShape.height(width: CallShape.smallest, shape: CallShape.widest))
        if let room { panel.setFrame(CallShape.held(panel.frame, in: room), display: false) }
        clicks = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.pressed(event) == true ? nil : event }
        }
    }

    func detach() {
        resized = nil
        if let clicks { NSEvent.removeMonitor(clicks) }
        clicks = nil
        picture = nil
        if let panel {
            panel.setFrame(CallShape.frame(panel.frame, size: fitting(panel.frame.width), in: room), display: false)
            if panel.delegate === self { panel.delegate = nil }
        }
        panel = nil
    }

    func follow(_ web: WKWebView, tilesOnly: Bool) {
        guard tilesOnly else { return heard(-1) }
        web.evaluateInSearch(CallShape.read) { [weak self] found in
            MainActor.assumeIsolated { self?.heard((found as? NSNumber)?.doubleValue ?? -1) }
        }
    }

    func heard(_ found: Double) {
        if found < 0 {
            missed += 1
            if missed >= CallShape.patience { show(nil) }
        } else {
            missed = 0
            if found > 0 { show(CGFloat(found)) }
        }
    }

    func show(_ shape: CGFloat?) {
        let shape = shape.map { CallShape.shape($0) }
        guard CallShape.changed(shape, from: picture) else { return }
        picture = shape
        guard let panel, !panel.inLiveResize else { return }
        settle(panel.frame.width)
    }

    func choose(width: CGFloat) {
        let wide = CallShape.width(width, screen: screen)
        store.set(Double(wide), forKey: CallShape.widthKey)
        settle(wide)
    }

    func shrink() { choose(width: CallShape.smallest) }

    private func fitting(_ width: CGFloat) -> NSSize {
        CallShape.size(width: width, picture: picture, screen: screen, room: room)
    }

    private func settle(_ width: CGFloat) {
        guard let panel else { return }
        let frame = CallShape.frame(panel.frame, size: fitting(width), in: room)
        guard frame != panel.frame else { return }
        guard let time = CallShape.glide(reduced: Motion.reduced, seen: panel.isVisible && panel.screen != nil) else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.kit(.easeInOut(time)) {
            panel.animator().setFrame(frame, display: true)
        }
    }

    private func pressed(_ event: NSEvent) -> Bool {
        guard let panel, event.window === panel, event.clickCount == 2, let view = panel.contentView,
              CallShape.onEdge(event.locationInWindow, of: view.frame) else { return false }
        shrink()
        return true
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        CallShape.dragged(from: sender.frame.size, to: frameSize, picture: picture, screen: screen, room: room)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        resized?(panel.frame.width)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel else { return }
        choose(width: panel.frame.width)
    }
}
