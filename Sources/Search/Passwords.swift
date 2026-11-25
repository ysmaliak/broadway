import AppKit

@MainActor
final class PasswordsPageView: KitFlippedView {
    let browser: Browser
    let body: PasswordsBody
    private var plate: KitPlatePage!

    init(browser: Browser) {
        self.browser = browser
        body = PasswordsBody(browser: browser)
        super.init(frame: .zero)
        plate = KitPlatePage("Passwords", content: body, foot: PasswordsFoot(browser: browser))
        kitPin(plate)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Passwords")
        identifier = NSUserInterfaceItemIdentifier("passwords.page")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@MainActor
final class PasswordsBody: KitFlippedView {
    let browser: Browser
    let hunt = KitSearchField(prompt: "Search sites and accounts", takesFocus: true)
    private let add = PagePill("Add")
    let more = KitButton(.plain(press: 1), label: "More")
    private let box = NSBox()
    private var form: PasswordsAddForm?
    private let none = KitEmptyView("No passwords yet", line: "Sign in somewhere and say yes when Broadway offers, or bring yours over below", symbol: "key")
    private let nothing = KitEmptyView("Nothing matches", line: "No site or account by that name", symbol: "magnifyingglass")
    let list: PasswordsList
    private let scroll = NSScrollView()
    private(set) var adding = false

    init(browser: Browser) {
        self.browser = browser
        list = PasswordsList(browser: browser)
        super.init(frame: .zero)
        hunt.stringValue = browser.hunting
        hunt.onChange = { [weak self] text in
            guard let self, browser.hunting != text else { return }
            browser.hunting = text
        }
        add.action = { [weak self] in self?.toggleAdding() }
        add.identifier = NSUserInterfaceItemIdentifier("passwords.add")
        more.content = KitSymbol("ellipsis.circle", style: .init(size: 15), tint: .secondaryLabelColor)
        more.action = { [weak self] in self?.popMore() }
        more.identifier = NSUserInterfaceItemIdentifier("passwords.more")
        box.boxType = .primary
        box.titlePosition = .noTitle
        box.isHidden = true
        scroll.documentView = list
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        for view in [hunt, more, add, box, none, nothing, scroll] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func moreItems() -> [KitMenuItem] {
        let browser = browser
        return [.action(PasswordsExport.menuTitle, enabled: !browser.saved.isEmpty, id: "passwords.export") { browser.exportPasswords() }]
    }

    private func popMore() {
        KitMenu.pop(moreItems(), below: more)
    }

    func toggleAdding() {
        adding.toggle()
        add.title = adding ? "Cancel" : "Add"
        if adding {
            let made = PasswordsAddForm(browser: browser) { [weak self] in
                guard let self, adding else { return }
                toggleAdding()
            }
            form = made
            box.contentView = made
            layer?.kitTransition(Motion.kitSettle)
            box.isHidden = false
        } else {
            layer?.kitTransition(Motion.kitSettle)
            box.isHidden = true
            box.contentView = NSView()
            form = nil
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let hunting = browser.hunting
        if hunt.currentEditor() == nil, hunt.stringValue != hunting { hunt.stringValue = hunting }
        let sites = browser.shownSites
        let empty = browser.saved.isEmpty
        list.show(sites)
        let width = bounds.width
        let fieldHeight = hunt.intrinsicContentSize.height
        let addSize = add.intrinsicContentSize
        add.frame = kitSnap(NSRect(x: width - addSize.width, y: (fieldHeight - addSize.height) / 2, width: addSize.width, height: addSize.height))
        let moreSide: CGFloat = 22
        more.frame = kitSnap(NSRect(x: add.frame.minX - KitPageRow.gap - moreSide, y: (fieldHeight - moreSide) / 2, width: moreSide, height: moreSide))
        hunt.frame = kitSnap(NSRect(x: 0, y: 0, width: max(0, more.frame.minX - KitPageRow.gap), height: fieldHeight))
        var y = fieldHeight + KitPlatePage.fieldGap
        if adding, let form {
            let height = form.height(for: width - 2 * PasswordsAddForm.inset) + 2 * PasswordsAddForm.inset
            box.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + 12
        }
        let rest = NSRect(x: 0, y: y, width: width, height: max(0, bounds.height - y))
        none.isHidden = !sites.isEmpty || !empty
        nothing.isHidden = !sites.isEmpty || empty
        scroll.isHidden = sites.isEmpty
        none.frame = adding ? rest : KitPageRow.emptyFrame(for: none, in: self, fieldHeight: fieldHeight)
        nothing.frame = adding ? rest : KitPageRow.emptyFrame(for: nothing, in: self, fieldHeight: fieldHeight)
        scroll.frame = rest
    }
}

@MainActor
final class PasswordsFoot: KitFlippedView {
    private let browser: Browser
    private let lead = KitLabel("Bring over from", font: KitPageRow.footFont, color: .secondaryLabelColor)
    private let another = PagePill("Another Browser")
    private let file = PagePill("File\u{2026}")
    private let remove = PagePill("Remove All\u{2026}", kind: .destructive)
    private let count = KitLabel("", font: KitPageRow.footFont, color: .secondaryLabelColor)
    private let note = KitLabel("macOS asks once for that browser's keychain key. That keychain stays as it is. Everything lands in your own keychain, under Broadway.",
                                font: KitPageRow.footFont, color: .secondaryLabelColor)

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        note.lines = 0
        another.action = { [weak browser] in browser?.lead(to: InternalPage(.importing)) }
        file.action = { [weak browser] in browser?.importFile() }
        remove.action = { [weak browser] in browser?.forgetShown() }
        another.identifier = NSUserInterfaceItemIdentifier("passwords.another")
        file.identifier = NSUserInterfaceItemIdentifier("passwords.file")
        remove.identifier = NSUserInterfaceItemIdentifier("passwords.remove")
        for view in [lead, another, file, remove, count, note] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var width: CGFloat {
        if bounds.width > 0 { return bounds.width }
        return (superview as? KitPlatePage)?.column.width ?? 0
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28 + 10 + ceil(note.measure(width: width).height))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed {
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let saved = browser.saved.count
        let shown = browser.shownSites.reduce(0) { $0 + $1.logins.count }
        let filtered = !browser.hunting.trimmingCharacters(in: .whitespaces).isEmpty
        remove.title = filtered ? "Remove \(shown)\u{2026}" : "Remove All\u{2026}"
        remove.isHidden = shown == 0
        remove.isEnabled = !browser.forgetting
        count.text = saved == 1 ? "1 password" : "\(saved) passwords"
        count.isHidden = saved == 0
        let row: [NSView] = [lead, another, file, remove, count].filter { !$0.isHidden }
        func item(_ view: NSView) -> KitFlex.Item {
            if let label = view as? KitLabel { return .fixed(label.pixelWidth) }
            return .fixed(view.intrinsicContentSize.width)
        }
        var views: [NSView?] = Array(row.prefix(3))
        var items = row.prefix(3).map(item)
        views.append(nil)
        items.append(.spacer(0))
        for view in row.dropFirst(3) {
            views.append(view)
            items.append(item(view))
        }
        KitFlex.lay(views, items, spacing: 8, in: NSRect(x: 0, y: 0, width: bounds.width, height: 28), snap: kitSnap)
        let noteHeight = ceil(note.measure(width: bounds.width).height)
        note.frame = kitSnap(NSRect(x: 0, y: 38, width: bounds.width, height: noteHeight))
    }
}

@MainActor
final class PasswordsAddForm: KitFlippedView {
    static let inset: CGFloat = 6
    private let browser: Browser
    private let done: () -> Void
    let site = KitField(placeholder: "Site", label: "Site")
    let user = KitField(placeholder: "Username", label: "Username")
    let password = KitField(placeholder: "Password", secure: true, label: "Password")
    private let save = PagePill("Save", kind: .primary)

    init(browser: Browser, done: @escaping () -> Void) {
        self.browser = browser
        self.done = done
        super.init(frame: .zero)
        site.identifier = NSUserInterfaceItemIdentifier("passwords.add.site")
        user.identifier = NSUserInterfaceItemIdentifier("passwords.add.user")
        password.identifier = NSUserInterfaceItemIdentifier("passwords.add.password")
        save.identifier = NSUserInterfaceItemIdentifier("passwords.add.save")
        for field in [site, user, password] {
            field.onChange = { [weak self] _ in self?.check() }
        }
        password.onSubmit = { [weak self] in self?.keep() }
        save.action = { [weak self] in self?.keep() }
        for view in [site, user, password, save] as [NSView] { addSubview(view) }
        check()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func height(for width: CGFloat) -> CGFloat { KitField.height(small: false) * 2 + 8 }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window else { return }
            window.makeFirstResponder(site.field)
        }
    }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: Self.inset, dy: Self.inset)
        let height = KitField.height(small: false)
        let half = (inner.width - 8) / 2
        site.frame = kitSnap(NSRect(x: inner.minX, y: inner.minY, width: half, height: height))
        user.frame = kitSnap(NSRect(x: inner.minX + half + 8, y: inner.minY, width: inner.width - half - 8, height: height))
        let saveSize = save.intrinsicContentSize
        let y = inner.minY + height + 8
        save.frame = kitSnap(NSRect(x: inner.maxX - saveSize.width, y: y + (height - saveSize.height) / 2, width: saveSize.width, height: saveSize.height))
        password.frame = kitSnap(NSRect(x: inner.minX, y: y, width: max(0, save.frame.minX - 8 - inner.minX), height: height))
    }

    private func check() {
        save.isEnabled = !Vault.host(of: site.text).isEmpty && !password.text.isEmpty
    }

    private func keep() {
        let host = Vault.host(of: site.text)
        guard !host.isEmpty, !password.text.isEmpty else { return }
        browser.keep(host: host, user: user.text.trimmingCharacters(in: .whitespaces), password: password.text)
        done()
    }
}

@MainActor
final class PasswordsSiteItem {
    let host: String
    var logins: [PasswordsAccountItem]

    init(host: String, logins: [PasswordsAccountItem]) {
        self.host = host
        self.logins = logins
    }
}

@MainActor
final class PasswordsAccountItem {
    let login: Kept
    var shown = false
    var secret: String?
    private var hide: DispatchWorkItem?
    var changed: (() -> Void)?

    init(login: Kept) { self.login = login }

    func reveal() {
        Vault.prove("show the password for \(login.host)") { [weak self] ok in
            guard ok, let self else { return }
            let login = login
            Task { @MainActor [weak self] in
                guard let password = await Vault.off({ Vault.secret(of: login) }), let self else { return }
                secret = password
                shown = true
                let work = DispatchWorkItem { [weak self] in self?.conceal() }
                hide?.cancel()
                hide = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
                changed?()
            }
        }
    }

    func conceal() {
        hide?.cancel()
        hide = nil
        let was = shown || secret != nil
        shown = false
        secret = nil
        if was { changed?() }
    }
}

@MainActor
final class PasswordsList: NSOutlineView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let browser: Browser
    private(set) var sites: [PasswordsSiteItem] = []
    private var open: String?
    private var said: [String] = []

    init(browser: Browser) {
        self.browser = browser
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("site"))
        column.resizingMask = .autoresizingMask
        addTableColumn(column)
        outlineTableColumn = column
        headerView = nil
        style = .plain
        backgroundColor = .clear
        selectionHighlightStyle = .none
        focusRingType = .none
        columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        usesAutomaticRowHeights = false
        rowHeight = KitPageRow.line
        indentationPerLevel = PasswordsSiteCell.separatorLead
        intercellSpacing = NSSize(width: 0, height: 0)
        dataSource = self
        delegate = self
        target = self
        action = #selector(pressed)
        setAccessibilityLabel("Passwords")
        identifier = NSUserInterfaceItemIdentifier("passwords.list")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ rows: [Browser.SiteRow]) {
        let next = rows.map { "\($0.host)\u{1}" + $0.logins.map(\.id).joined(separator: "\u{2}") }
        guard next != said else { return }
        said = next
        let old = Dictionary(uniqueKeysWithValues: sites.map { ($0.host, $0) })
        sites = rows.map { row in
            let kept = old[row.host].map { Dictionary(uniqueKeysWithValues: $0.logins.map { ($0.login.id, $0) }) } ?? [:]
            return PasswordsSiteItem(host: row.host, logins: row.logins.map { kept[$0.id] ?? PasswordsAccountItem(login: $0) })
        }
        reloadData()
        if let open, let site = sites.first(where: { $0.host == open }) {
            expandItem(site)
        } else {
            open = nil
        }
    }

    @objc private func pressed() {
        guard clickedRow >= 0, let site = item(atRow: clickedRow) as? PasswordsSiteItem else { return }
        toggle(site)
    }

    static let changeTitle = "Change Password on Site"

    static func changePage(for host: String) -> URL? {
        guard !host.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = "/.well-known/change-password"
        return parts.url
    }

    func menuItems(for item: Any?) -> [KitMenuItem] {
        let host = (item as? PasswordsSiteItem)?.host ?? (item as? PasswordsAccountItem)?.login.host
        guard let host, let page = Self.changePage(for: host) else { return [] }
        let browser = browser
        return [.action(Self.changeTitle) { _ = browser.open(page, foreground: true) }]
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let at = row(at: convert(event.locationInWindow, from: nil))
        guard at >= 0 else { return nil }
        let items = menuItems(for: item(atRow: at))
        return items.isEmpty ? nil : KitMenu.make(items)
    }

    func toggle(_ site: PasswordsSiteItem) {
        if isItemExpanded(site) { animator().collapseItem(site) } else { animator().expandItem(site) }
    }

    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        super.frameOfOutlineCell(atRow: row).offsetBy(dx: 0, dy: -0.5)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let site = item as? PasswordsSiteItem { return site.logins.count }
        return item == nil ? sites.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let site = item as? PasswordsSiteItem { return site.logins[index] }
        return sites[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is PasswordsSiteItem }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        PasswordsRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let site = item as? PasswordsSiteItem {
            return PasswordsSiteCell(site: site, open: isItemExpanded(site))
        }
        if let account = item as? PasswordsAccountItem {
            return PasswordsAccountCell(account: account, copy: { [weak self] in self?.browser.copy(account.login) },
                                        forget: { [weak self] in self?.browser.forget(account.login) })
        }
        return nil
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let site = notification.userInfo?["NSObject"] as? PasswordsSiteItem else { return }
        if let open, open != site.host, let other = sites.first(where: { $0.host == open }) { animator().collapseItem(other) }
        open = site.host
    }

    func outlineViewItemDidExpand(_ notification: Notification) { refreshCell(notification) }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let site = notification.userInfo?["NSObject"] as? PasswordsSiteItem else { return }
        if open == site.host { open = nil }
        site.logins.forEach { $0.conceal() }
        refreshCell(notification)
    }

    private func refreshCell(_ notification: Notification) {
        guard let site = notification.userInfo?["NSObject"] as? PasswordsSiteItem else { return }
        let row = row(forItem: site)
        guard row >= 0, let cell = view(atColumn: 0, row: row, makeIfNecessary: false) as? PasswordsSiteCell else { return }
        cell.open = isItemExpanded(site)
    }
}

final class PasswordsRowView: NSTableRowView {
    override func drawSeparator(in dirtyRect: NSRect) {}

    override func drawBackground(in dirtyRect: NSRect) {
        guard let outline = superview as? NSOutlineView else { return }
        let row = outline.row(for: self)
        guard row >= 0, row < outline.numberOfRows - 1 else { return }
        let cell = subviews.first { $0 is PasswordsSiteCell || $0 is PasswordsAccountCell }
        let lead = (cell?.frame.minX ?? 0) + (cell is PasswordsSiteCell ? PasswordsSiteCell.separatorLead : 0)
        let hair = KitPageRow.hair(self)
        NSColor.separatorColor.setFill()
        NSRect(x: lead, y: bounds.maxY - hair, width: max(0, bounds.width - lead), height: hair).fill()
    }
}

@MainActor
final class PasswordsSiteCell: NSTableCellView {
    static let markSide: CGFloat = 16
    static let markGap: CGFloat = 10
    static let separatorLead = markSide + markGap
    let site: PasswordsSiteItem
    private let mark: NSView
    private let name: KitLabel
    private let detail = KitLabel("", font: KitPageRow.detailFont, color: .secondaryLabelColor)
    var open: Bool { didSet { if open != oldValue { say() } } }

    init(site: PasswordsSiteItem, open: Bool) {
        self.site = site
        self.open = open
        mark = MarkView(icon: Favicons.shared.cached(site.host), letter: site.host.first.map { String($0).uppercased() } ?? "\u{2022}", size: 16)
        name = KitLabel(site.host, font: KitPageRow.titleFont, color: .labelColor)
        super.init(frame: .zero)
        detail.overflow = .middle
        for view in [mark, name, detail] { addSubview(view) }
        say()
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(site.host)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func say() {
        let logins = site.logins
        if logins.count > 1 {
            detail.text = "\(logins.count) accounts"
        } else if let only = logins.first, !only.login.user.isEmpty, !open {
            detail.text = only.login.user
        } else {
            detail.text = ""
        }
        setAccessibilityValue(detail.text)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let side = Self.markSide
        mark.frame = kitSnap(NSRect(x: 0, y: (height - side) / 2, width: side, height: side))
        let nameSize = NSSize(width: name.pixelWidth, height: name.intrinsicContentSize.height)
        let x = mark.frame.maxX + Self.markGap
        let nameWidth = min(nameSize.width, max(0, bounds.width - x - KitPageRow.gap))
        name.frame = kitSnap(NSRect(x: x, y: (height - nameSize.height) / 2, width: nameWidth, height: nameSize.height))
        let detailSize = NSSize(width: detail.pixelWidth, height: detail.intrinsicContentSize.height)
        let dx = name.frame.maxX + 10
        detail.isHidden = detail.text.isEmpty
        detail.frame = kitSnap(NSRect(x: dx, y: (height - detailSize.height) / 2, width: min(detailSize.width, max(0, bounds.width - dx)), height: detailSize.height))
    }
}

@MainActor
final class PasswordsAccountCell: NSTableCellView {
    let account: PasswordsAccountItem
    private let user: NSTextField
    private let secret = NSTextField(labelWithString: "")
    private let show = PasswordsQuick("Show")
    private let copy = PasswordsQuick("Copy")
    private let forget = PasswordsQuick("Remove", destructive: true)
    private let used = NSTextField(labelWithString: "")
    private var hovering = false { didSet { if hovering != oldValue { needsLayout = true } } }
    private var area: NSTrackingArea?

    init(account: PasswordsAccountItem, copy: @escaping () -> Void, forget: @escaping () -> Void) {
        self.account = account
        let login = account.login
        user = NSTextField(labelWithString: login.user.isEmpty ? "No username" : login.user)
        super.init(frame: .zero)
        user.font = KitPageRow.detailFont
        user.textColor = login.user.isEmpty ? .tertiaryLabelColor : .labelColor
        user.lineBreakMode = .byTruncatingMiddle
        user.isSelectable = true
        secret.isSelectable = true
        secret.lineBreakMode = .byTruncatingTail
        used.stringValue = login.agent?.words() ?? ""
        used.font = .systemFont(ofSize: 11)
        used.textColor = .tertiaryLabelColor
        used.lineBreakMode = .byTruncatingTail
        used.alignment = .right
        self.copy.press = copy
        self.forget.press = forget
        show.press = { [weak self] in
            guard let self else { return }
            if account.shown { account.conceal() } else { account.reveal() }
        }
        account.changed = { [weak self] in self?.needsLayout = true }
        for view in [user, secret, used, show, self.copy, self.forget] as [NSView] { addSubview(view) }
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(made)
        area = made
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { account.conceal() }
    }

    override func layout() {
        super.layout()
        let shown = account.shown
        secret.stringValue = shown ? (account.secret ?? "") : String(repeating: "\u{2022}", count: 10)
        secret.font = .monospacedSystemFont(ofSize: shown ? 13 : 10, weight: .regular)
        secret.textColor = shown ? .labelColor : .secondaryLabelColor
        show.title = shown ? "Hide" : "Show"
        let height = bounds.height
        let userSize = user.intrinsicContentSize
        let userWidth = max(120, min(userSize.width, bounds.width * 0.45))
        user.frame = kitSnap(NSRect(x: 0, y: (height - userSize.height) / 2, width: userWidth, height: userSize.height))
        let quick = hovering || shown
        var right = bounds.width + KitPageRow.overhang(forget)
        for button in [forget, copy, show] {
            button.isHidden = !quick
            let size = button.intrinsicContentSize
            right -= size.width
            button.frame = kitSnap(NSRect(x: right, y: (height - size.height) / 2, width: size.width, height: size.height))
            right -= 10
        }
        let x = user.frame.maxX + 10
        let secretSize = secret.intrinsicContentSize
        used.isHidden = quick || used.stringValue.isEmpty
        var limit = quick ? show.frame.minX - KitPageRow.gap : bounds.width
        if !used.isHidden {
            let usedSize = used.intrinsicContentSize
            let usedWidth = min(usedSize.width, max(0, bounds.width - x - secretSize.width - KitPageRow.gap))
            used.frame = kitSnap(NSRect(x: bounds.width - usedWidth, y: (height - usedSize.height) / 2, width: usedWidth, height: usedSize.height))
            limit = used.frame.minX - KitPageRow.gap
        }
        secret.frame = kitSnap(NSRect(x: x, y: (height - secretSize.height) / 2, width: max(0, min(secretSize.width, limit - x)), height: secretSize.height))
    }
}

final class PasswordsQuick: NSButton {
    var press: (() -> Void)?

    init(_ title: String, destructive: Bool = false) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        bezelStyle = .inline
        controlSize = .small
        font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        if destructive { contentTintColor = .systemRed }
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(fire)
        focusRingType = .none
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { press?() }
}

final class PagePill: KitBroadwayButton {}
