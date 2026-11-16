import AppKit

class QuestionView: NSView {
    let glass: KitGlass
    let body = FlippedBody()
    let leading: CGFloat
    let trailing: CGFloat
    let vertical: CGFloat

    init(radius: CGFloat, leading: CGFloat, trailing: CGFloat, vertical: CGFloat) {
        glass = KitGlass.floating(radius: radius)
        self.leading = leading
        self.trailing = trailing
        self.vertical = vertical
        super.init(frame: .zero)
        addSubview(glass)
        glass.hold(body)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { fit(nil) }
    override var fittingSize: NSSize { fit(nil) }

    func fit(_ width: CGFloat?) -> NSSize {
        let inner = arrange(width.map { $0 - leading - trailing }, place: false)
        return NSSize(width: inner.width + leading + trailing, height: inner.height + vertical * 2)
    }

    func arrange(_ width: CGFloat?, place: Bool) -> NSSize { .zero }

    override func layout() {
        super.layout()
        glass.frame = bounds
        body.frame = glass.bounds
        _ = arrange(bounds.width - leading - trailing, place: true)
    }

    final class FlippedBody: KitFlippedView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    static func text(_ string: String) -> SiteWrapLabel {
        SiteWrapLabel(string, font: .systemFont(ofSize: 13), color: KitColor.ink)
    }

    static func width(_ label: SiteWrapLabel) -> CGFloat {
        label.measure(width: .greatestFiniteMagnitude).width
    }

    static func height(_ label: SiteWrapLabel, width: CGFloat) -> CGFloat {
        label.measure(width: width).height
    }

    func put(_ view: NSView, _ rect: NSRect) {
        view.frame = kitSnap(NSRect(x: leading + rect.minX, y: vertical + rect.minY, width: rect.width, height: rect.height))
    }

    func buttonsRow(_ keys: [KitGlassKey], spacing: CGFloat) -> CGFloat {
        keys.map(\.intrinsicContentSize.width).reduce(0, +) + spacing * CGFloat(max(0, keys.count - 1))
    }
}

class AskLine: QuestionView {
    let symbol: KitSymbol?
    let question: SiteWrapLabel
    var keySpacing: CGFloat = SurfaceLook.keyGap
    var keys: [KitGlassKey] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            keys.forEach(body.addSubview)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    init(symbol: String?, text: String, trailing: CGFloat) {
        self.symbol = symbol.map { KitSymbol($0, style: KitSymbol.Style(size: 11, weight: .medium), tint: KitColor.muted) }
        question = QuestionView.text(text)
        super.init(radius: 20, leading: 16, trailing: trailing, vertical: 9)
        if let symbol = self.symbol { body.addSubview(symbol) }
        body.addSubview(question)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var symbolSize: NSSize { symbol.map(MenuMetrics.symbolSize) ?? .zero }
    private var lead: CGFloat { symbol == nil ? 0 : symbolSize.width + 12 }
    private var keyHeight: CGFloat { keys.map(\.intrinsicContentSize.height).max() ?? 0 }

    override func arrange(_ width: CGFloat?, place: Bool) -> NSSize {
        let textWidth = QuestionView.width(question)
        let lineHeight = QuestionView.height(question, width: .greatestFiniteMagnitude)
        let actions = buttonsRow(keys, spacing: keySpacing)
        let wide = lead + textWidth + 12 + actions
        if width == nil || width! >= wide - 0.01 {
            let height = max(lineHeight, keyHeight, symbolSize.height)
            if place {
                if let symbol { put(symbol, NSRect(x: 0, y: (height - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height)) }
                put(question, NSRect(x: lead, y: (height - lineHeight) / 2, width: textWidth, height: lineHeight))
                var x = lead + textWidth + 12
                for key in keys {
                    let size = key.intrinsicContentSize
                    put(key, NSRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height))
                    x += size.width + keySpacing
                }
            }
            return NSSize(width: wide, height: height)
        }
        let width = width!
        let wrap = min(textWidth, max(1, width - lead))
        let textHeight = QuestionView.height(question, width: wrap)
        let top = max(textHeight, symbolSize.height)
        var y = top + 12
        var used = lead + wrap
        if place {
            if let symbol { put(symbol, NSRect(x: 0, y: (top - symbolSize.height) / 2, width: symbolSize.width, height: symbolSize.height)) }
            put(question, NSRect(x: lead, y: (top - textHeight) / 2, width: wrap, height: textHeight))
        }
        if actions <= width {
            if place {
                var x: CGFloat = 0
                for key in keys {
                    let size = key.intrinsicContentSize
                    put(key, NSRect(x: x, y: y + (keyHeight - size.height) / 2, width: size.width, height: size.height))
                    x += size.width + keySpacing
                }
            }
            used = max(used, actions)
            y += keyHeight
        } else {
            for (index, key) in keys.enumerated() {
                let size = key.intrinsicContentSize
                if index > 0 { y += 10 }
                if place { put(key, NSRect(x: 0, y: y, width: size.width, height: size.height)) }
                used = max(used, size.width)
                y += size.height
            }
        }
        return NSSize(width: used, height: y)
    }
}

final class CaptureQuestionView: AskLine {
    let browser: Browser
    var ask: Browser.CaptureAsk { didSet { if ask != oldValue { refresh() } } }

    init(browser: Browser, ask: Browser.CaptureAsk) {
        self.browser = browser
        self.ask = ask
        super.init(symbol: CaptureQuestionView.symbol(ask), text: CaptureQuestionView.words(ask), trailing: 9)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func symbol(_ ask: Browser.CaptureAsk) -> String {
        ask.wants == "location" ? "location" : ask.wants == "microphone" ? "mic" : ask.wants == "notifications" ? "bell"
            : ask.wants == LocalNetwork.kind ? "network" : "video"
    }

    static func words(_ ask: Browser.CaptureAsk) -> String {
        ask.wants == "location" ? "\(ask.host) wants to know your location"
            : ask.wants == "notifications" ? "\(ask.host) wants to send you notifications"
            : ask.wants == LocalNetwork.kind ? (ask.mac ? "\(ask.host) wants to reach apps on this Mac, at \(ask.reach)"
                                                        : "\(ask.host) wants to reach devices on your network, at \(ask.reach)")
            : "\(ask.host) wants to use your \(ask.wants)"
    }

    private func refresh() {
        symbol?.name = CaptureQuestionView.symbol(ask)
        question.text = CaptureQuestionView.words(ask)
        let ask = ask
        var keys = [KitGlassKey(title: "Don't Allow") { [weak browser] in browser?.denyCapture() }]
        if ask.once, ask.keeps {
            keys.append(KitGlassKey(title: "Always Allow") { [weak browser] in browser?.allowCapture() })
        }
        keys.append(KitGlassKey(title: ask.once ? "Allow Once" : "Allow", kind: .primary) { [weak browser] in
            ask.once ? browser?.allowCaptureOnce() : browser?.allowCapture()
        })
        self.keys = keys
    }
}

final class PasswordOfferView: AskLine {
    let browser: Browser
    var offer: Browser.Offer { didSet { if offer != oldValue { refresh() } } }

    init(browser: Browser, offer: Browser.Offer) {
        self.browser = browser
        self.offer = offer
        super.init(symbol: nil, text: PasswordOfferView.words(offer), trailing: 9)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func words(_ offer: Browser.Offer) -> String {
        let login = offer.login
        return offer.changed
            ? "Update the password for \(login.user) on \(login.host)?"
            : (login.user.isEmpty
                ? "Save this password for \(login.host)?"
                : "Save the password for \(login.user) on \(login.host)?")
    }

    private func refresh() {
        question.text = PasswordOfferView.words(offer)
        var keys: [KitGlassKey] = []
        if !offer.changed {
            keys.append(KitGlassKey(title: "Never Here") { [weak browser] in browser?.neverOffer() })
        }
        keys.append(KitGlassKey(title: "Not Now") { [weak browser] in browser?.dropOffer() })
        keys.append(KitGlassKey(title: offer.changed ? "Update" : "Save", kind: .primary) { [weak browser] in browser?.keepOffer() })
        self.keys = keys
    }
}

final class ScreenQuestionView: QuestionView {
    let browser: Browser
    let symbol = KitSymbol("macwindow.on.rectangle", style: KitSymbol.Style(size: 13), tint: KitColor.muted)
    let question: SiteWrapLabel
    let deny: KitGlassKey
    let screen: KitGlassKey
    let share: KitGlassKey
    var ask: Browser.CaptureAsk { didSet { question.text = ScreenQuestionView.words(ask); needsLayout = true; invalidateIntrinsicContentSize() } }
    static let most: CGFloat = 400

    init(browser: Browser, ask: Browser.CaptureAsk) {
        self.browser = browser
        self.ask = ask
        question = QuestionView.text(ScreenQuestionView.words(ask))
        deny = KitGlassKey(title: "Don't Allow") { [weak browser] in browser?.denyShare() }
        screen = KitGlassKey(title: "Share a Screen") { [weak browser] in browser?.shareScreen() }
        share = KitGlassKey(title: "Share a Window", kind: .primary) { [weak browser] in browser?.shareWindow() }
        super.init(radius: 16, leading: 16 + 14, trailing: 16 + 14, vertical: 14)
        [symbol, question, deny, screen, share].forEach(body.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static func words(_ ask: Browser.CaptureAsk) -> String {
        ask.sound ? "\(ask.host) wants to share your screen and your Mac's sound" : "\(ask.host) wants to share your screen"
    }

    override func layout() {
        super.layout()
        glass.frame = bounds.insetBy(dx: 16, dy: 0)
        body.frame = glass.bounds
        _ = arrange(bounds.width - leading - trailing, place: true)
    }

    override func put(_ view: NSView, _ rect: NSRect) {
        view.frame = kitSnap(NSRect(x: 14 + rect.minX, y: vertical + rect.minY, width: rect.width, height: rect.height))
    }

    override func arrange(_ width: CGFloat?, place: Bool) -> NSSize {
        let symbolSize = MenuMetrics.symbolSize(symbol)
        let lead = symbolSize.width + 10
        let keys = [deny, screen, share]
        let natural = max(lead + QuestionView.width(question), buttonsRow(keys, spacing: SurfaceLook.keyGap) + 8 + 12)
        let width = width.map { min(ScreenQuestionView.most, $0) } ?? min(ScreenQuestionView.most, natural)
        let wrap = max(1, width - lead)
        let textHeight = QuestionView.height(question, width: wrap)
        let top = max(textHeight, symbolSize.height + 2)
        let keyHeight = keys.map(\.intrinsicContentSize.height).max() ?? 0
        if place {
            put(symbol, NSRect(x: 0, y: 2, width: symbolSize.width, height: symbolSize.height))
            put(question, NSRect(x: lead, y: 0, width: wrap, height: textHeight))
            let y = top + 12
            let denySize = deny.intrinsicContentSize
            put(deny, NSRect(x: 0, y: y + (keyHeight - denySize.height) / 2, width: denySize.width, height: denySize.height))
            var x = width
            for key in [share, screen] {
                let size = key.intrinsicContentSize
                x -= size.width
                put(key, NSRect(x: x, y: y + (keyHeight - size.height) / 2, width: size.width, height: size.height))
                x -= SurfaceLook.keyGap
            }
        }
        return NSSize(width: width, height: top + 12 + keyHeight)
    }
}
