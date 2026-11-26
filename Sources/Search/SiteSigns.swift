import AppKit
import Combine
import CoreText

class SignView: KitHoverView {
    weak var tab: Tab?
    let symbol: KitSymbol
    let ground = KitBox(fill: KitColor.ink, corners: .radius(4))
    var colour: NSColor = KitColor.muted { didSet { if colour != oldValue { paint(animated: false) } } }
    var ink: KitInk = .flat { didSet { if ink != oldValue { paint(animated: false) } } }
    var shown = false { didSet { if shown != oldValue { paint(animated: false) } } }
    var rest: Double = 0.75
    private(set) var popup: SignMenu?

    init(tab: Tab, symbol name: String, label: String) {
        self.tab = tab
        symbol = KitSymbol(name, style: KitSymbol.Style(size: 9, weight: .medium))
        super.init(frame: NSRect(x: 0, y: 0, width: 17, height: 15))
        wantsLayer = true
        ground.alphaValue = 0
        addSubview(ground)
        addSubview(symbol)
        kitAccess(label: label, role: .button)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 17, height: 15) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) != nil || KitReach.takes(point, for: self, reach: KitReach.least) ? self : nil
    }

    var lit: Bool { hovering || popup != nil || shown }

    func refresh() {
        paint(animated: false)
    }

    func menu(done: @escaping () -> Void) -> SignMenu? { nil }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let size = MenuMetrics.symbolSize(symbol)
        symbol.frame = kitSnap(NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                                      width: size.width, height: size.height))
    }

    override func hoverChanged() { paint(animated: true) }

    func paint(animated: Bool) {
        let lit = lit
        if animated { symbol.layer?.kitTransition(Motion.kitQuick) }
        symbol.ink = ink
        symbol.tint = lit ? KitColor.ink : colour
        symbol.opacity = lit ? 1 : rest
        ground.ink = ink
        let target: CGFloat = lit ? 0.07 : 0
        guard ground.alphaValue != target else { return }
        let from = ground.layer?.presentation()?.opacity ?? Swift.Float(ground.alphaValue)
        ground.alphaValue = target
        if animated, let animation = Motion.kitQuick.animation("opacity", from: from, to: Swift.Float(target)) {
            ground.layer?.add(animation, forKey: "lit")
        }
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        toggle()
        return true
    }

    func toggle() {
        if let popup { popup.menu.cancelTracking() } else { open() }
    }

    func open() {
        guard window != nil, let made = menu(done: {}) else { return }
        popup = made
        made.onClose = { [weak self, weak made] in
            guard let self, self.popup === made else { return }
            self.popup = nil
            self.paint(animated: false)
        }
        paint(animated: false)
        RunLoop.main.perform(inModes: [.default, .common]) { [weak self] in
            guard let self, self.popup === made, self.window != nil else {
                made.onClose?()
                return
            }
            KitMenu.popUp(made.menu, from: self.bounds, of: self)
        }
    }
}

@MainActor
class SignMenu: NSObject, NSMenuDelegate {
    struct Entry {
        let symbol: String
        let title: String
        var on: Bool?
        var help: String?
        let act: () -> Void
    }

    enum Part {
        case heading(String)
        case items([Entry])
        case divider
        case footnote(String)
    }

    let menu = NSMenu()
    var onClose: (() -> Void)?
    var follows = false
    private lazy var reads = KitReads { [weak self] in self?.rebuild() }

    override init() {
        super.init()
        menu.autoenablesItems = false
        menu.delegate = self
    }

    func parts() -> [Part] { [] }

    func rebuild() {
        menu.removeAllItems()
        for part in follows ? reads.track(parts) : parts() {
            switch part {
            case .heading(let text):
                menu.addItem(text.count <= 44 ? .sectionHeader(title: text) : KitMenu.note(text))
            case .items(let entries):
                for entry in entries {
                    let item = KitMenuAction(KitMenu.middle(entry.title, limit: 52), key: "", run: entry.act)
                    if let on = entry.on {
                        item.state = on ? .on : .off
                    } else {
                        item.image = KitGlyph.plain(entry.symbol)
                    }
                    item.toolTip = entry.help
                    item.setAccessibilityLabel(entry.title)
                    menu.addItem(item)
                }
            case .divider:
                menu.addItem(.separator())
            case .footnote(let text):
                menu.addItem(KitMenu.note(text))
            }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        reads.stop()
        DispatchQueue.main.async { [weak self] in self?.onClose?() }
    }
}

final class SiteWrapLabel: NSView {
    var text: String { didSet { if text != oldValue { changed() } } }
    var font: NSFont { didSet { if font != oldValue { changed() } } }
    var color: NSColor { didSet { if color != oldValue { needsDisplay = true } } }
    var oneLine = false { didSet { if oneLine != oldValue { changed() } } }

    init(_ text: String, font: NSFont, color: NSColor) {
        self.text = text
        self.font = font
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func changed() {
        setAccessibilityValue(text)
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    private func attributed(_ color: NSColor) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = oneLine ? .byTruncatingTail : .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    func measure(width: CGFloat) -> NSSize {
        let size = attributed(.black).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).size
        let scale = MenuMetrics.scale(self)
        return NSSize(width: ceil(size.width * scale) / scale, height: ceil(size.height * scale) / scale)
    }

    override var intrinsicContentSize: NSSize { measure(width: .greatestFiniteMagnitude) }

    override func draw(_ dirtyRect: NSRect) {
        attributed(KitInk.flat.onGlass(kitOnGlass).color(color, dark: kitDark))
            .draw(with: bounds, options: oneLine ? [.usesLineFragmentOrigin, .truncatesLastVisibleLine] : [.usesLineFragmentOrigin])
    }
}
