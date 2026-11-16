import AppKit

final class KitPlatePage: KitFlippedView {
    static let titleFont = NSFont.systemFont(ofSize: 26, weight: .semibold)
    static let titleLine = ceil(titleFont.ascender - titleFont.descender + titleFont.leading)
    static let side: CGFloat = 24
    static let columnWidth: CGFloat = 640
    static let standardWidth: CGFloat = columnWidth + side * 2
    static let titleTop: CGFloat = 32
    static let titleGap: CGFloat = 16
    static let fieldGap: CGFloat = 12
    static let footGap: CGFloat = 12
    static let contentTop = titleTop + titleLine + titleGap

    static func column(in size: NSSize, width: CGFloat = standardWidth) -> NSRect {
        let outer = min(size.width, width)
        let x = ((size.width - outer) / 2).rounded(.down)
        return NSRect(x: x + side, y: 0, width: max(0, outer - side * 2), height: size.height)
    }

    let title: KitLabel
    let content: NSView
    let foot: NSView?
    var width: CGFloat { didSet { if width != oldValue { needsLayout = true } } }

    private let rule = KitBox(fill: .separatorColor)

    init(_ title: String, width: CGFloat = KitPlatePage.standardWidth, content: NSView, foot: NSView? = nil) {
        self.title = KitLabel(title, font: Self.titleFont, color: .labelColor)
        self.content = content
        self.foot = foot
        self.width = width
        super.init(frame: .zero)
        addSubview(self.title)
        addSubview(content)
        if let foot {
            addSubview(rule)
            addSubview(foot)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var column: NSRect { Self.column(in: bounds.size, width: width) }

    override func layout() {
        super.layout()
        let column = column
        let titleHeight = title.intrinsicContentSize.height
        title.frame = kitSnap(NSRect(x: column.minX, y: Self.titleTop, width: min(column.width, title.intrinsicContentSize.width), height: titleHeight))
        let top = Self.contentTop
        var bottom = bounds.height
        if let foot {
            let gap = Self.footGap
            let footHeight = foot.fittingSize.height
            foot.frame = NSRect(x: column.minX, y: bounds.height - gap - footHeight, width: column.width, height: footHeight)
            rule.frame = NSRect(x: column.minX, y: foot.frame.minY - gap - 1, width: column.width, height: 1)
            bottom = rule.frame.minY - gap
        }
        content.frame = NSRect(x: column.minX, y: top, width: column.width, height: max(0, bottom - top))
    }
}

enum KitPageRow {
    static let height: CGFloat = 40
    static let line: CGFloat = 28
    static let header: CGFloat = 28
    static let headerAir: CGFloat = 12
    static let iconSlot: CGFloat = 20
    static let textX: CGFloat = 32
    static let gap: CGFloat = 8
    static let between: CGFloat = 2
    static let titleFont = NSFont.systemFont(ofSize: 13)
    static let detailFont = NSFont.systemFont(ofSize: 12)
    static let headerFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
    static let footFont = NSFont.systemFont(ofSize: 12)

    @MainActor static let fieldHeight = KitSearchField(prompt: "").intrinsicContentSize.height

    static func icon(_ size: NSSize, in height: CGFloat) -> NSRect {
        NSRect(x: (iconSlot - size.width) / 2, y: (height - size.height) / 2, width: size.width, height: size.height)
    }

    @MainActor static func overhang(_ button: NSButton) -> CGFloat {
        let words = ceil(button.attributedTitle.size().width)
        return max(0, ((button.intrinsicContentSize.width - words) / 2).rounded(.down))
    }

    static func hair(_ view: NSView) -> CGFloat { 1 / (view.window?.backingScaleFactor ?? 2) }

    static func rule(in bounds: NSRect, hair: CGFloat) -> NSRect {
        NSRect(x: textX, y: bounds.height - hair, width: max(0, bounds.width - textX), height: hair)
    }

    static func lines(_ title: NSSize, _ detail: NSSize, in height: CGFloat) -> (title: CGFloat, detail: CGFloat) {
        let top = ((height - title.height - between - detail.height) / 2).rounded()
        return (top, top + title.height + between)
    }

    static func emptyFrame(in body: NSRect, fieldHeight: CGFloat) -> NSRect {
        let top = fieldHeight + KitPlatePage.fieldGap
        return NSRect(x: body.minX, y: body.minY + top, width: body.width, height: max(0, body.height - top))
    }

    @MainActor static func emptyFrame(for view: NSView, in body: NSView, fieldHeight: CGFloat) -> NSRect {
        let within = emptyFrame(in: body.bounds, fieldHeight: fieldHeight)
        var plate = body.superview
        while let next = plate, !(next is KitPlatePage) { plate = next.superview }
        guard let plate else { return within }
        let floor = body.convert(NSPoint(x: 0, y: plate.bounds.maxY), from: plate).y
        let whole = NSRect(x: within.minX, y: within.minY, width: within.width, height: max(0, floor - within.minY))
        return whole.midY + view.fittingSize.height / 2 <= within.maxY ? whole : within
    }
}
