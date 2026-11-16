import AppKit

final class FieldHostLayer: NSView {
    private let host: OmniboxView
    private(set) var shown = false
    private var ticket = 0

    static func showing(_ browser: Browser) -> Bool { browser.fieldShowing && !browser.newTabPageShown }

    init(browser: Browser) {
        host = OmniboxView(browser: browser)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.allowsGroupOpacity = true
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        shown ? super.hitTest(point) : nil
    }

    func set(_ now: Bool, animated: Bool) {
        guard now != shown || (!now && !isHidden && !animated) else { return }
        shown = now
        ticket += 1
        let ticket = ticket
        if now { isHidden = false }
        guard animated, !now, let seconds = Motion.fieldOutSeconds, let layer else {
            layer?.removeAnimation(forKey: "fade")
            alphaValue = now ? 1 : 0
            isHidden = !now
            return
        }
        let from = layer.animation(forKey: "fade") == nil ? Swift.Float(alphaValue) : layer.presentation()?.opacity ?? Swift.Float(alphaValue)
        alphaValue = now ? 1 : 0
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = from
        fade.toValue = Swift.Float(now ? 1 : 0)
        fade.duration = seconds
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ticket == ticket, !self.shown else { return }
                self.isHidden = true
            }
        }
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }
}

enum FieldHost {
    typealias Layer = FieldHostLayer
}
