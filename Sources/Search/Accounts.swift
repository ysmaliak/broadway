import AppKit

final class AccountCardView: NSView {
    weak var browser: Browser?
    var asked: Browser.Suggesting? { didSet { if asked != oldValue { rebuild() } } }

    private let glass = KitGlass.floating(radius: 10)
    private let column = KitFlippedView()
    private var rows: [NSView] = []
    private let footer = AccountFooterView()

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        addSubview(glass)
        glass.contentView = column
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        var view = super.hitTest(point)
        while let found = view, found !== self {
            if found is KitButton { return found }
            view = found.superview
        }
        return self
    }

    var width: CGFloat { max(240, min(360, asked?.spot.width ?? 240)) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width, height: rows.reduce(0) { $0 + $1.fittingSize.height })
    }

    private func rebuild() {
        rows.forEach { $0.removeFromSuperview() }
        rows = []
        guard let asked, let browser else { return }
        func letter(_ user: String) -> AccountRowView.Mark { .letter(user.first.map { String($0).uppercased() } ?? "•") }
        if let strong = asked.strong {
            rows.append(AccountRowView(mark: .symbol("key.fill"), name: "Use Strong Password", detail: strong,
                                       detailFont: .monospacedSystemFont(ofSize: 11, weight: .regular)) { [weak browser] in
                browser?.chooseStrongPassword()
            })
        }
        for code in asked.codes {
            rows.append(AccountRowView(mark: .symbol("number"), name: "Use \(code.code)", detail: code.detail) { [weak browser] in browser?.choose(code) })
        }
        for passkey in asked.passkeys {
            rows.append(AccountRowView(mark: .symbol("person.badge.key"), name: passkey.name,
                                       detail: "Passkey" + (passkey.provider.map { " · \($0)" } ?? "")) { [weak browser] in browser?.choose(passkey) })
        }
        for login in asked.logins {
            rows.append(AccountRowView(mark: letter(login.user), name: login.user.isEmpty ? "No name" : login.user, detail: login.host) { [weak browser] in
                browser?.choose(login)
            })
        }
        for login in asked.apple {
            rows.append(AccountRowView(mark: letter(login.user), name: login.user.isEmpty ? "No name" : login.user, detail: "Apple Passwords") { [weak browser] in
                browser?.choose(login)
            })
        }
        if asked.appleConnect {
            rows.append(AccountRowView(mark: .symbol("key.icloud"), name: "Connect Apple Passwords…",
                                       detail: "Pair once with a code from your Mac") { [weak browser] in browser?.connectApplePasswords() })
        }
        if asked.appleOffer != nil, asked.strong == nil {
            rows.append(AccountOfferRowView(use: { [weak browser] in browser?.useApplePasswords() },
                                            never: { [weak browser] in browser?.neverOfferApplePasswords() }))
        }
        if let hint = asked.formHint, asked.strong == nil {
            rows.append(AccountRowView(mark: .symbol("text.badge.checkmark"), name: "Fill Whole Form", detail: "\(hint) · ⌥↩") { [weak browser] in
                browser?.chooseFormFill()
            })
        }
        if !Self.offerOnly(asked) {
            footer.text = Self.footer(asked)
            rows.append(footer)
        }
        rows.forEach { column.addSubview($0) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    static func offerOnly(_ asked: Browser.Suggesting) -> Bool {
        (asked.appleOffer != nil || asked.formHint != nil || !asked.codes.isEmpty || asked.strong != nil) && asked.logins.isEmpty && asked.passkeys.isEmpty
            && asked.apple.isEmpty && !asked.appleConnect
    }

    static func footer(_ asked: Browser.Suggesting) -> String {
        if asked.logins.isEmpty && asked.apple.isEmpty && !asked.appleConnect { return "Passkeys on this Mac" }
        if asked.logins.isEmpty { return "From Apple Passwords" }
        return asked.apple.isEmpty ? "From your keychain" : "From your keychain and Apple Passwords"
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        column.frame = bounds
        var y: CGFloat = 0
        for row in rows {
            let height = row.fittingSize.height
            row.frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            y += height
        }
    }
}

final class AccountRowView: KitButton {
    enum Mark { case letter(String), symbol(String) }

    private let tile = KitBox(fill: Palette.NS.wash, corners: .radius(6))
    private let glyph: NSView
    private let name: KitLabel
    private let detail: KitLabel
    private let ground = KitBox(fill: nil)

    init(mark: Mark, name: String, detail: String, detailFont: NSFont = .systemFont(ofSize: 11), pick: @escaping () -> Void) {
        switch mark {
        case .letter(let letter):
            let label = KitLabel(letter, font: .systemFont(ofSize: 11, weight: .medium))
            label.alignment = .center
            label.setAccessibilityElement(false)
            glyph = label
        case .symbol(let symbol):
            glyph = KitSymbol(symbol, style: KitSymbol.Style(size: 10, weight: .medium))
        }
        self.name = KitLabel(name, font: .systemFont(ofSize: 13))
        self.detail = KitLabel(detail, font: detailFont, color: KitColor.muted)
        super.init(.plain(press: 1), label: name, action: pick)
        addSubview(ground, positioned: .below, relativeTo: nil)
        addSubview(tile)
        tile.addSubview(glyph)
        addSubview(self.name)
        addSubview(self.detail)
        self.name.setAccessibilityElement(false)
        self.detail.setAccessibilityElement(false)
        setAccessibilityValue(detail)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let text = name.intrinsicContentSize.height + 1 + detail.intrinsicContentSize.height
        return NSSize(width: 240, height: 7 + max(22, text) + 7)
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func hoverChanged() {
        super.hoverChanged()
        ground.layer?.kitTransition(Motion.kitQuick)
        ground.fill = hovering ? Palette.NS.hover : nil
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        tile.frame = kitSnap(NSRect(x: 10, y: (bounds.height - 22) / 2, width: 22, height: 22))
        let size = glyph.intrinsicContentSize
        glyph.frame = glyph is KitLabel ? tile.bounds
            : NSRect(x: (22 - size.width) / 2, y: (22 - size.height) / 2, width: size.width, height: size.height)
        let nameHeight = name.intrinsicContentSize.height, detailHeight = detail.intrinsicContentSize.height
        let top = (bounds.height - (nameHeight + 1 + detailHeight)) / 2
        let x: CGFloat = 10 + 22 + 10
        let width = max(0, bounds.width - x - 10)
        name.frame = kitSnap(NSRect(x: x, y: top, width: width, height: nameHeight))
        detail.frame = kitSnap(NSRect(x: x, y: top + nameHeight + 1, width: width, height: detailHeight))
    }
}

final class AccountOfferRowView: KitHoverView {
    private let use: KitButton
    private let never: KitButton
    private let key = KitSymbol("key", style: KitSymbol.Style(size: 9, weight: .medium), tint: KitColor.muted)
    private let words = KitLabel("Use your Apple passwords?", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let cross = KitSymbol("xmark", style: KitSymbol.Style(size: 8, weight: .semibold), tint: KitColor.faint)
    private let crossGround = KitBox(fill: nil, corners: .capsule)
    private let ground = KitBox(fill: nil)

    init(use: @escaping () -> Void, never: @escaping () -> Void) {
        self.use = KitButton(.plain(press: 1), label: "Use your Apple passwords?", action: use)
        self.never = KitButton(.plain(press: 1), label: "Don't Offer Again", action: never)
        super.init(frame: .zero)
        addSubview(ground)
        addSubview(self.use)
        self.use.addSubview(key)
        self.use.addSubview(words)
        words.setAccessibilityElement(false)
        self.use.kitAccess(help: "Turns on Apple Passwords and pairs with a code from your Mac. Settings › Passwords turns it off.")
        addSubview(self.never)
        self.never.addSubview(crossGround)
        self.never.addSubview(cross)
        self.never.kitAccess(label: "Don't Offer Again", help: "Stops this offer from showing again")
        self.never.onHover = { [weak self] _ in self?.paint() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: 240, height: 6 + max(16, words.intrinsicContentSize.height) + 6)
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func hoverChanged() { paint() }

    private func paint() {
        ground.layer?.kitTransition(Motion.kitQuick)
        ground.fill = hovering ? Palette.NS.hover : nil
        let lit = hovering && !never.hovering
        let ink = lit ? KitColor.ink : KitColor.muted
        words.layer?.kitTransition(Motion.kitQuick)
        words.color = ink
        key.tint = ink
        crossGround.layer?.kitTransition(Motion.kitQuick)
        crossGround.fill = never.hovering ? KitColor.ink.withAlphaComponent(0.07) : nil
    }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let crossX = bounds.width - 8 - 16
        never.frame = NSRect(x: crossX - 4, y: 0, width: 24, height: bounds.height)
        crossGround.frame = NSRect(x: 4, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let crossSize = cross.intrinsicContentSize
        cross.frame = NSRect(x: crossGround.frame.midX - crossSize.width / 2, y: crossGround.frame.midY - crossSize.height / 2,
                             width: crossSize.width, height: crossSize.height)
        use.frame = NSRect(x: 10, y: 0, width: max(0, crossX - 8 - 10), height: bounds.height)
        let keySize = key.intrinsicContentSize
        key.frame = kitSnap(NSRect(x: (22 - keySize.width) / 2, y: (bounds.height - keySize.height) / 2, width: keySize.width, height: keySize.height))
        let wordsHeight = words.intrinsicContentSize.height
        words.frame = kitSnap(NSRect(x: 22 + 8, y: (bounds.height - wordsHeight) / 2, width: max(0, use.bounds.width - 30), height: wordsHeight))
    }
}

private final class AccountFooterView: NSView {
    var text = "" { didSet { words.text = text } }
    private let ground = KitBox(fill: Palette.NS.wash.withAlphaComponent(0.5))
    private let key = KitSymbol("key", style: KitSymbol.Style(size: 9, weight: .medium), tint: KitColor.faint)
    private let words = KitLabel("", font: .systemFont(ofSize: 11), color: KitColor.faint)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(ground)
        addSubview(key)
        addSubview(words)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: 240, height: 7 + max(key.image?.size.height ?? 0, words.intrinsicContentSize.height) + 7)
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func layout() {
        super.layout()
        ground.frame = bounds
        let keySize = key.image?.size ?? key.intrinsicContentSize
        key.frame = kitSnap(NSRect(x: 12, y: (bounds.height - keySize.height) / 2, width: keySize.width, height: keySize.height))
        let height = words.intrinsicContentSize.height
        let x = 12 + keySize.width + 6
        words.frame = kitSnap(NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 12), height: height))
    }
}

extension AccountCardView {
    static func surface(kind: String) -> NSView? {
        guard let browser = Browsers.front else { return nil }
        let spot = CGRect(x: 0, y: -36, width: 300, height: 30)
        var asked = Browser.Suggesting(tab: UUID(), spot: spot, logins: [], host: "example.com", clear: false)
        switch kind {
        case "offer":
            asked.appleOffer = "example.com"
        case "strong":
            asked.strong = StrongPassword.make()
        default:
            asked = Browser.Suggesting(tab: UUID(), spot: spot,
                                       logins: [Kept(host: "example.com", user: "ada@example.com"), Kept(host: "example.com", user: "")],
                                       host: "example.com", clear: false)
            asked.appleConnect = true
            asked.formHint = "Name, email and address"
        }
        let card = AccountCardView(browser: browser)
        card.asked = asked
        return card
    }
}
