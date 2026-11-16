import AppKit

final class NewTabSlot: NSView {
    private(set) var content: NSView?

    override var isFlipped: Bool { true }

    func show(_ view: NSView) {
        guard view !== content else { return }
        content?.removeFromSuperview()
        content = view
        addSubview(view)
        view.frame = bounds
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize { content?.intrinsicContentSize ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    override var fittingSize: NSSize {
        guard let content else { return .zero }
        let size = content.intrinsicContentSize
        let fitted = size.width < 0 || size.height < 0 ? content.fittingSize : .zero
        return NSSize(width: size.width < 0 ? fitted.width : size.width, height: size.height < 0 ? fitted.height : size.height)
    }

    override func layout() {
        super.layout()
        content?.frame = bounds
    }
}

@MainActor
enum NewTabHosts {
    static func make() -> NSView { NewTabSlot() }

    static func address(_ host: NSView, browser: Browser, tab: UUID, search: String?, prompt: String, lift: Double) {
        guard let slot = host as? NewTabSlot else { return }
        let field = slot.content as? AddressTextField ?? AddressTextField(keys: AddressFieldKeys(browser: browser), size: 20, prompt: prompt)
        slot.show(field)
        field.update(browser: browser, tab: tab, search: search, prompt: prompt, live: true)
    }

    static func site(_ host: NSView, site: SearchSite, lift: Double) {
        guard let slot = host as? NewTabSlot else { return }
        if let chip = slot.content as? SiteChipView { chip.site = site } else { slot.show(SiteChipView(site: site)) }
    }

    static func place(_ host: NSView, place: FieldPlace, lift: Double) {
        guard let slot = host as? NewTabSlot else { return }
        if let chip = slot.content as? PlaceChipView { chip.place = place } else { slot.show(PlaceChipView(place: place)) }
    }

    static func menu(_ host: NSView, menu: FieldMenu, rowHeight: CGFloat, headerHeight: CGFloat, lift: Double) {
        (host as? NewTabSlot)?.show(FieldMenuListView(menu: menu, rowHeight: rowHeight, headerHeight: headerHeight))
    }

    static func list(_ host: NSView, browser: Browser, rowHeight: CGFloat, headerHeight: CGFloat, lift: Double) {
        let list = FieldListView(browser: browser, rowHeight: rowHeight, headerHeight: headerHeight)
        list.headerMuted = true
        (host as? NewTabSlot)?.show(list)
    }
}
