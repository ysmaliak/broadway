import AppKit
import Combine

final class PlusLayerView: NSView {
    let browser: Browser

    private var shown: NSMenu?
    private var watch: Set<AnyCancellable> = []

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        kitObserve(distinct: true, { [weak browser] in browser?.plusOpen ?? false }) { [weak self] open in
            DispatchQueue.main.async { open ? self?.start() : self?.stop() }
        }.store(in: &watch)
        kitObserve(initial: false, { [weak browser] in (browser?.activeID, browser?.spaceID) }) { [weak self] _ in self?.close() }
            .store(in: &watch)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func close() {
        if browser.plusOpen { browser.plusOpen = false }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func start() {
        guard browser.plusOpen, shown == nil, let window, let content = window.contentView else { return }
        let anchor: NSView
        let spot: NSRect
        if let door = browser.plusAnchor, door.window === window {
            anchor = door
            spot = door.bounds
        } else {
            let door = browser.plusDoor
            anchor = content
            spot = content.isFlipped ? door : NSRect(x: door.minX, y: content.bounds.height - door.maxY, width: door.width, height: door.height)
        }
        let made = PlusMenu.menu(for: browser)
        shown = made
        RunLoop.main.perform(inModes: [.default, .common]) { [weak self, weak anchor] in
            guard let self, self.shown === made, let anchor, anchor.window != nil else {
                self?.shown = nil
                self?.close()
                return
            }
            KitMenu.popUp(made, from: spot, of: anchor)
            guard self.shown === made else { return }
            self.shown = nil
            self.close()
        }
    }

    private func stop() {
        guard !browser.plusOpen else { return }
        let going = shown
        shown = nil
        going?.cancelTracking()
    }
}
