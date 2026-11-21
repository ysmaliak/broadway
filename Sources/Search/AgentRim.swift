import AppKit

extension Tab {
    var agentColour: NSColor? {
        guard agent, let task = agentTask, let link = AgentLinks.shared.links.first(where: { $0.id == task }), link.live else { return nil }
        return AgentCharacter.accentColor(link.accent)
    }
}

final class AgentRimView: NSView {
    static let width: CGFloat = 2
    static var fade: KitCurve { Motion.calm ? .easeOut(0.12) : .easeOut(0.22) }

    var corner: CGFloat = 0 { didSet { if corner != oldValue { needsLayout = true } } }
    private(set) var colour: NSColor?
    private let shape = CAShapeLayer()
    private var shownPath: (size: CGSize, corner: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        shape.fillRule = .evenOdd
        shape.opacity = 0
        shape.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer?.addSublayer(shape)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func ring(in bounds: CGRect, corner: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addPath(KitPath.continuous(bounds, radius: corner))
        path.addPath(KitPath.continuous(bounds.insetBy(dx: width, dy: width), radius: max(0, corner - width)))
        return path
    }

    override func layout() {
        super.layout()
        guard shownPath.map({ $0.size != bounds.size || $0.corner != corner }) ?? true else { return }
        shownPath = (bounds.size, corner)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = Self.ring(in: bounds, corner: corner)
        CATransaction.commit()
    }

    func wear(_ next: NSColor?, animated: Bool) {
        guard next != colour else { return }
        let was = colour
        colour = next
        let curve: KitCurve = animated && window != nil ? Self.fade : .none
        if let next {
            let fill = next.cgColor
            if was == nil || shape.opacity == 0 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                shape.removeAnimation(forKey: "fillColor")
                shape.fillColor = fill
                CATransaction.commit()
            } else {
                shape.kitAnimate("fillColor", to: fill, curve: curve)
            }
            shape.kitAnimate("opacity", to: Swift.Float(1), curve: curve)
        } else {
            shape.kitAnimate("opacity", to: Swift.Float(0), curve: curve)
        }
    }

    var fading: Bool { shape.animation(forKey: "opacity") != nil }

    var worn: [String: Any] {
        guard let colour = colour?.usingColorSpace(.sRGB) else { return ["on": false, "fading": fading] }
        return ["on": true, "colour": [colour.redComponent, colour.greenComponent, colour.blueComponent].map(Double.init),
                "width": Double(Self.width), "corner": Double(corner), "fading": fading]
    }
}

extension AgentRimView {
    static func bench(in root: NSView) -> [[String: Any]] {
        guard let window = root.window, let content = window.contentView else { return [] }
        return root.kitSubviews(of: AgentRimView.self).filter { !$0.isHiddenOrHasHiddenAncestor && ($0.colour != nil || $0.fading) }.map { rim in
            let frame = rim.convert(rim.bounds, to: nil)
            var said = rim.worn
            said["box"] = [frame.minX, content.bounds.height - frame.maxY, frame.width, frame.height].map(Double.init)
            return said
        }
    }
}

enum AgentChrome {
    @MainActor static func bench(_ browser: Browser) -> [String: Any] {
        guard let window = browser.window ?? Links.window, let content = window.contentView else { return ["window": false] }
        func box(_ view: NSView, _ rect: NSRect? = nil) -> [Double] {
            let frame = view.convert(rect ?? view.bounds, to: nil)
            return [frame.minX, content.bounds.height - frame.maxY, frame.width, frame.height].map(Double.init)
        }
        func shown<View: NSView>(_ kind: View.Type) -> [View] {
            content.kitSubviews(of: kind).filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
        }
        var said: [String: Any] = ["height": Double(content.bounds.height), "width": Double(content.bounds.width)]
        if let area = content.kitSubviews(of: AgentsAreaView.self).first(where: { $0.fixed == nil && $0.window != nil }) {
            var card = area.benchState
            if let column = area.superview { card["box"] = box(column, area.cardFrameInColumn) }
            said["card"] = card
        }
        if let mini = shown(MiniPlayerView.self).first, mini.item != nil { said["mini"] = box(mini.superview ?? mini, mini.cardFrameInColumn) }
        if let foot = shown(SpaceFootView.self).first { said["foot"] = box(foot) }
        if let update = shown(UpdateCardView.self).first, let card = update.benchState["card"] as? [CGFloat] {
            said["update"] = [card[0], content.bounds.height - card[1] - card[3], card[2], card[3]].map(Double.init)
        }
        said["pills"] = shown(AgentActingBadgeView.self).map { ["kind": "acting", "box": box($0)] as [String: Any] }
            + shown(AgentDrivingBarView.self).map { ["kind": "driving", "box": box($0)] as [String: Any] }
        said["bars"] = shown(OfferBarView.self).map { box($0) }
        said["rims"] = AgentRimView.bench(in: content)
        return said
    }
}
