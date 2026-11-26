import AppKit
import Combine
import Observation

enum FormCapture {
    enum Keep: Equatable {
        case card(CardSecret)
        case address(AutofillAddress)

        var question: String {
            switch self {
            case .card(let card): return "Keep your \(CardNetwork.of(card.number).name) ending \(CardNumber.lastFour(card.number))?"
            case .address(let address): return "Keep \(address.line1) for next time?"
            }
        }
    }

    static func keep(_ fields: [FormField], values: [String: String]) -> Keep? {
        var found: [FormValueKind: String] = [:]
        for field in fields {
            guard case .fill(let kind) = FormClassifier.verdict(field), kind != .cardCode,
                  let value = values[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
            else { continue }
            found[kind] = field.type == "select" ? field.options.first { $0.value == value }?.text ?? value : value
        }
        if let number = found[.cardNumber], CardNumber.valid(number), let expiry = expiry(found) {
            return .card(CardSecret(number: CardNumber.digits(number), expiry: expiry, holder: found[.cardName] ?? ""))
        }
        let street = found[.addressLine1] ?? found[.street]
        guard let street, found[.city] != nil || found[.postal] != nil else { return nil }
        let name = found[.fullName] ?? [found[.givenName], found[.familyName]].compactMap { $0 }.joined(separator: " ")
        return .address(AutofillAddress(name: name, company: found[.organization] ?? "", line1: street, line2: found[.addressLine2] ?? "",
                                        city: found[.city] ?? "", region: found[.region] ?? "", postal: found[.postal] ?? "",
                                        country: found[.country] ?? "", phone: found[.phone] ?? ""))
    }

    private static func expiry(_ found: [FormValueKind: String]) -> CardExpiry? {
        if let both = found[.cardExpiry] { return CardExpiry(both) }
        guard let month = found[.cardExpiryMonth].flatMap({ Int($0) }), let raw = found[.cardExpiryYear], let year = Int(raw) else { return nil }
        return CardExpiry(month: month, year: raw.count == 2 ? 2000 + year : year)
    }
}

@MainActor
@Observable
final class FormFill {

    struct Preview: Equatable {
        let tab: Tab.ID
        let page: URL?
        let shy: Bool
        let fields: [FormField]
        var address: String?
        var card: String?
        var plan: FormPlan
    }

    struct Done: Equatable {
        let tab: Tab.ID
        let filled: Int
        let stays: Int
    }

    struct Offer: Equatable {
        let tab: Tab.ID
        let keep: FormCapture.Keep
    }

    private(set) var preview: Preview?
    private(set) var done: Done?
    private(set) var offer: Offer?
    @ObservationIgnored private(set) var lastReport: FormApplied?

    @ObservationIgnored weak var browser: Browser?
    @ObservationIgnored let book: AutofillBook
    @ObservationIgnored let answers: FormAnswers
    @ObservationIgnored var pageFor: (Tab) -> FormPageAccess? = { $0.formPage }
    @ObservationIgnored var askPrivate: (@escaping () -> Void) -> Void = { go in
        Ask.sure("Fill this form in a private window?", detail: "Your details go into this page. Broadway doesn't fill forms in private windows unless you say so.",
                 confirm: "Fill", then: go)
    }
    @ObservationIgnored var pause: (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    @ObservationIgnored private var heldTurn = 0
    @ObservationIgnored private var answeredTurn = 0

    init(book: AutofillBook = .shared, answers: FormAnswers = .shared) {
        self.book = book
        self.answers = answers
        Task { await answers.ready() }
    }

    private func tab(_ id: Tab.ID) -> Tab? { browser?.tabs.first { $0.id == id } }

    func begin() {
        if preview != nil { return confirm() }
        guard let tab = browser?.active else { return }
        guard let page = pageFor(tab) else { return }
        Task { await prepare(tab, page) }
    }

    func prepare(_ tab: Tab, _ page: FormPageAccess) async {
        let fields = await page.fields()
        let address = book.addresses.first?.id
        let card = book.cards.first?.id
        let plan = await plan(fields, page: tab.pageAddress, shy: tab.shy, address: address, card: card)
        guard !plan.rows.isEmpty else {
            browser?.announce(plan.note ?? "Nothing here for Broadway to fill")
            return
        }
        preview = Preview(tab: tab.id, page: tab.pageAddress, shy: tab.shy, fields: fields, address: address, card: card, plan: plan)
    }

    private func plan(_ fields: [FormField], page: URL?, shy: Bool, address: String?, card: String?) async -> FormPlan {
        let kept = await address.asyncMap { await book.fetched(address: $0) } ?? nil
        await answers.ready()
        let sources = FormSources(profile: await book.fetchedProfile(), address: kept,
                                  card: book.cards.first { $0.id == card }, remembered: answers.answers(for: page))
        return FormPlanner.plan(fields, page: page, privateTab: shy, sources: sources)
    }

    func choose(address: String?) async {
        guard var up = preview else { return }
        up.address = address
        up.plan = await plan(up.fields, page: up.page, shy: up.shy, address: address, card: up.card)
        if preview?.tab == up.tab { preview = up }
    }

    func choose(card: String?) async {
        guard var up = preview else { return }
        up.card = card
        up.plan = await plan(up.fields, page: up.page, shy: up.shy, address: up.address, card: card)
        if preview?.tab == up.tab { preview = up }
    }

    func cancel() { preview = nil }

    func confirm() {
        guard let up = preview, let tab = tab(up.tab) else {
            preview = nil
            return
        }
        guard tab.pageAddress == up.page, tab.shy == up.shy else {
            preview = nil
            return
        }
        preview = nil
        if up.shy {
            askPrivate { [weak self] in self?.release(up, tab) }
        } else {
            release(up, tab)
        }
    }

    private func release(_ up: Preview, _ tab: Tab) {
        guard up.plan.needsCard, let row = book.cards.first(where: { $0.id == up.card }) else {
            return write(up, tab, card: nil)
        }
        book.release(card: row) { [weak self] secret in
            guard let self else { return }
            guard let secret else {
                browser?.announce(Owner.cardRefusal(), kind: .error)
                return
            }
            guard tab.pageAddress == up.page else { return }
            write(up, tab, card: secret)
        }
    }

    private func write(_ up: Preview, _ tab: Tab, card: CardSecret?) {
        guard let page = pageFor(tab) else { return }
        let values = FormPlanner.values(up.plan, card: card)
        Task {
            let applied = await page.apply(values, fields: up.plan.fields)
            lastReport = applied
            if let card { tab.seal(card.number) }
            guard applied.filled > 0 else {
                browser?.announce("Couldn't find those boxes anymore", kind: .error)
                return
            }
            done = Done(tab: tab.id, filled: applied.filled, stays: max(0, up.plan.total - applied.filled))
        }
    }

    func show(filled applied: FormApplied, tab: Tab.ID) {
        lastReport = applied
        done = Done(tab: tab, filled: applied.filled, stays: 0)
    }

    func undo() {
        guard let up = done, let tab = tab(up.tab), let page = pageFor(tab) else { return }
        done = nil
        Task { await page.undo() }
    }

    func dismissDone() { done = nil }

    func heard(_ event: FormEvent, from tab: Tab) {
        switch event {
        case .typed, .undone:
            if done?.tab == tab.id { done = nil }
        case .enter:
            if let list = browser?.suggesting, list.tab == tab.id, let first = list.codes.first { browser?.choose(first) }
        case .sent(let fields, let values):
            held(fields, values: values, tab: tab)
        case .answered(let fields, let values):
            answered(fields, values: values, tab: tab)
        }
    }

    func hint(for tab: Tab, field: FormField?) -> String? {
        guard let field, field.count >= 3 else { return nil }
        if case .fill(let kind) = FormClassifier.verdict(field) {
            if kind.isCard {
                guard CardRules.fill(on: tab.pageAddress, privateTab: tab.shy) != .refused else { return nil }
                return book.cards.first?.title
            }
            if let kept = book.addresses.first?.note ?? (book.hasProfile ? "Your profile" : nil) { return kept }
        }
        return answers.answer(for: field, on: tab.pageAddress) == nil ? nil : FormMemory.help
    }

    private func answered(_ fields: [FormField], values: [String: String], tab: Tab) {
        guard !tab.shy, let page = tab.pageAddress, FormMemory.site(of: page) != nil else { return }
        let taken = FormMemory.taken(fields, values: values)
        guard !taken.isEmpty else { return }
        answeredTurn += 1
        let turn = answeredTurn
        let web = pageFor(tab) as? WebFormPage
        Task {
            for wait in [1.5, 3.5, 10] as [TimeInterval] {
                await pause(wait)
                guard turn == answeredTurn, self.tab(tab.id) != nil else { return }
                if await web?.answeredStill() != true {
                    await answers.remember(taken, on: page)
                    return
                }
            }
        }
    }

    private func isNew(_ keep: FormCapture.Keep) -> Bool {
        switch keep {
        case .card(let card):
            let last = CardNumber.lastFour(card.number)
            let network = CardNetwork.of(card.number)
            return !book.cards.contains { $0.last == last && $0.network == network }
        case .address(let address):
            return !book.addresses.contains {
                guard let kept = book.address($0.id) else { return false }
                return kept.line1.caseInsensitiveCompare(address.line1) == .orderedSame && kept.postal == address.postal
            }
        }
    }

    private func held(_ fields: [FormField], values: [String: String], tab: Tab) {
        guard CardRules.mayOfferToSave(on: tab.pageAddress, privateTab: tab.shy),
              let keep = FormCapture.keep(fields, values: values), isNew(keep)
        else { return }
        heldTurn += 1
        let turn = heldTurn
        let page = pageFor(tab) as? WebFormPage
        Task {
            for wait in [1.5, 3.5, 10] as [TimeInterval] {
                await pause(wait)
                guard turn == heldTurn, self.tab(tab.id) != nil else { return }
                if await page?.sentStill() != true {
                    offer = Offer(tab: tab.id, keep: keep)
                    return
                }
            }
        }
    }

    func keepOffer() {
        guard let up = offer else { return }
        offer = nil
        switch up.keep {
        case .card(let card): book.save(card: card)
        case .address(let address): book.save(address: address)
        }
        browser?.announce("Kept in your keychain")
    }

    func dropOffer() { offer = nil }
}

@MainActor
class FormGlassBar: NSView {
    let glass: KitGlass
    let inside = KitBox(fill: nil)
    var items: [NSView] = [] {
        didSet {
            oldValue.forEach { $0.removeFromSuperview() }
            items.forEach(inside.addSubview)
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }
    var lead: CGFloat = 16
    var trail: CGFloat = 9
    var spacing: CGFloat = 12

    init(radius: CGFloat = 20) {
        glass = KitGlass.floating(radius: radius)
        super.init(frame: .zero)
        addSubview(glass)
        glass.hold(inside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func gap(after index: Int) -> CGFloat {
        guard items.indices.contains(index + 1) else { return 0 }
        return items[index] is KitButton && items[index + 1] is KitButton ? SurfaceLook.keyGap : spacing
    }

    override var intrinsicContentSize: NSSize {
        let sizes = items.map(\.intrinsicContentSize)
        let gaps = items.indices.dropLast().map(gap(after:)).reduce(0, +)
        let width = lead + trail + sizes.map(\.width).reduce(0, +) + gaps
        return NSSize(width: ceil(width), height: (sizes.map(\.height).max() ?? 0) + 18)
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        inside.frame = glass.bounds
        var x = lead
        for (index, item) in items.enumerated() {
            let size = item.intrinsicContentSize
            item.frame = kitSnap(NSRect(x: x, y: (bounds.height - size.height) / 2, width: size.width, height: size.height))
            x += size.width + gap(after: index)
        }
    }
}

@MainActor
final class FormFillBar: FormGlassBar {
    enum Kind: Equatable {
        case none
        case done(FormFill.Done)
        case offer(FormFill.Offer)
    }

    private unowned let forms: FormFill
    var kind: Kind = .none { didSet { if kind != oldValue { rebuild() } } }

    init(forms: FormFill) {
        self.forms = forms
        super.init(radius: 20)
    }

    private func rebuild() {
        let font = NSFont.systemFont(ofSize: 13)
        switch kind {
        case .none:
            items = []
        case .done(let up):
            trail = 9
            items = [KitLabel(up.stays == 0 ? "Filled \(up.filled)" : "Filled \(up.filled) · \(up.stays) stay yours", font: font),
                     KitGlassKey(title: "Undo") { [weak forms] in forms?.undo() },
                     KitGlassKey(title: "Done", quiet: true) { [weak forms] in forms?.dismissDone() }]
        case .offer(let up):
            trail = 9
            items = [KitLabel(up.keep.question, font: font),
                     KitGlassKey(title: "Not Now") { [weak forms] in forms?.dropOffer() },
                     KitGlassKey(title: "Keep", kind: .primary) { [weak forms] in forms?.keepOffer() }]
        }
    }
}

@MainActor
final class FormFillCard: NSView {
    static let width: CGFloat = 360

    private unowned let forms: FormFill
    private let glass = KitGlass.floating(radius: 16)
    private let inside = KitBox(fill: nil)
    private let title = KitLabel("Fill this form", font: SurfaceLook.title)
    private let summary = KitLabel("", font: .systemFont(ofSize: 12), color: KitColor.muted)
    private let scroll = NSScrollView()
    private let list = KitBox(fill: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private let notNow: KitGlassKey
    private let fill: KitGlassKey
    private var address: NSPopUpButton?
    private var card: NSPopUpButton?
    private var rows: [FormFillRow] = []
    private var preview: FormFill.Preview?
    private var choices: ([(String, String)], [(String, String)]) = ([], [])

    init(forms: FormFill) {
        self.forms = forms
        notNow = KitGlassKey(title: "Not Now") { [weak forms] in forms?.cancel() }
        fill = KitGlassKey(title: "Fill", kind: .primary) { [weak forms] in forms?.confirm() }
        super.init(frame: .zero)
        addSubview(glass)
        glass.hold(inside)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.documentView = list
        note.font = .systemFont(ofSize: 12)
        note.textColor = KitColor.glassMuted
        for view in [title, summary, scroll, note, notNow, fill] as [NSView] { inside.addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ up: FormFill.Preview, addresses: [(String, String)], cards: [(String, String)]) {
        let same = preview == up && choices.0.map(\.0) == addresses.map(\.0) && choices.0.map(\.1) == addresses.map(\.1)
            && choices.1.map(\.0) == cards.map(\.0) && choices.1.map(\.1) == cards.map(\.1)
        guard !same else { return }
        preview = up
        choices = (addresses, cards)
        summary.text = up.plan.summary
        fill.title = up.plan.needsCard ? "Fill with Touch ID" : "Fill"
        address?.removeFromSuperview()
        card?.removeFromSuperview()
        address = addresses.count > 1 ? menu(addresses, picked: up.address, fallback: "Address") { [weak forms] id in
            Task { await forms?.choose(address: id) }
        } : nil
        card = cards.count > 1 ? menu(cards, picked: up.card, fallback: "Card") { [weak forms] id in
            Task { await forms?.choose(card: id) }
        } : nil
        rows.forEach { $0.removeFromSuperview() }
        rows = up.plan.rows.map(FormFillRow.init)
        rows.forEach(list.addSubview)
        note.stringValue = up.plan.note ?? ""
        note.isHidden = up.plan.note == nil
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    private func menu(_ items: [(String, String)], picked: String?, fallback: String, choose: @escaping (String) -> Void) -> NSPopUpButton {
        let made = NSPopUpButton(frame: .zero, pullsDown: true)
        made.isBordered = false
        made.font = .systemFont(ofSize: 12)
        made.addItem(withTitle: items.first { $0.0 == picked }?.1 ?? fallback)
        for item in items {
            let entry = KitMenuAction(item.1, key: "") { choose(item.0) }
            made.menu?.addItem(entry)
        }
        inside.addSubview(made)
        return made
    }

    private var inner: CGFloat { Self.width - 28 }
    private var listHeight: CGFloat {
        let content = rows.reduce(0) { $0 + $1.intrinsicContentSize.height } + 5 * CGFloat(max(0, rows.count - 1))
        return min(190, CGFloat(rows.count) * 21, content)
    }

    private func place(apply: Bool) -> CGFloat {
        var y: CGFloat = 14
        let head = max(title.intrinsicContentSize.height, summary.intrinsicContentSize.height)
        if apply {
            let size = title.intrinsicContentSize
            title.frame = kitSnap(NSRect(x: 14, y: y + (head - size.height) / 2, width: size.width, height: size.height))
            let other = summary.intrinsicContentSize
            summary.frame = kitSnap(NSRect(x: 14 + inner - other.width, y: y + (head - other.height) / 2, width: other.width, height: other.height))
        }
        y += head + 10
        for menu in [address, card].compactMap({ $0 }) {
            let size = menu.intrinsicContentSize
            if apply { menu.frame = NSRect(x: 14, y: y, width: min(inner, size.width), height: size.height) }
            y += size.height + 10
        }
        if apply {
            scroll.frame = NSRect(x: 14, y: y, width: inner, height: listHeight)
            var rowY: CGFloat = 0
            for row in rows {
                let height = row.intrinsicContentSize.height
                row.frame = NSRect(x: 0, y: rowY, width: inner, height: height)
                rowY += height + 5
            }
            list.frame = NSRect(x: 0, y: 0, width: inner, height: max(listHeight, rowY - 5))
        }
        y += listHeight + 10
        if !note.isHidden {
            note.preferredMaxLayoutWidth = inner
            let height = ceil(note.fittingSize.height)
            if apply { note.frame = NSRect(x: 12, y: y, width: inner + 4, height: height) }
            y += height + 10
        }
        let fillSize = fill.intrinsicContentSize
        let notSize = notNow.intrinsicContentSize
        if apply {
            fill.frame = NSRect(x: 14 + inner - fillSize.width, y: y, width: fillSize.width, height: fillSize.height)
            notNow.frame = NSRect(x: fill.frame.minX - SurfaceLook.keyGap - notSize.width, y: y, width: notSize.width, height: notSize.height)
        }
        return y + max(fillSize.height, notSize.height) + 14
    }

    override var intrinsicContentSize: NSSize { NSSize(width: Self.width, height: place(apply: false)) }

    override func layout() {
        super.layout()
        glass.frame = bounds
        inside.frame = glass.bounds
        _ = place(apply: true)
    }
}

private final class FormFillRow: NSView {
    private let dot = KitBox(fill: nil, corners: .capsule)
    private let title: KitLabel
    private let value: KitMiddleLine

    init(_ row: FormPlanRow) {
        title = KitLabel(row.field.title, font: .systemFont(ofSize: 12), color: KitColor.muted)
        value = KitMiddleLine(row.shown, font: .systemFont(ofSize: 12))
        super.init(frame: .zero)
        dot.fill = NSColor(formHex: row.source.dot)
        dot.toolTip = row.source.help
        for view in [dot, title, value] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(row.field.title): \(row.shown)")
        title.setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(title.intrinsicContentSize.height, value.intrinsicContentSize.height))
    }

    override func layout() {
        super.layout()
        let middle = bounds.height / 2
        dot.frame = kitSnap(NSRect(x: 0, y: middle - 3, width: 6, height: 6))
        let titleHeight = title.intrinsicContentSize.height
        title.frame = kitSnap(NSRect(x: 16, y: middle - titleHeight / 2, width: 130, height: titleHeight))
        let size = value.intrinsicContentSize
        value.frame = kitSnap(NSRect(x: 156, y: middle - size.height / 2, width: min(size.width, max(0, bounds.width - 156)), height: size.height))
    }
}

extension NSColor {
    convenience init(formHex: String) {
        let digits = Int(formHex.dropFirst(), radix: 16) ?? 0
        self.init(srgbRed: CGFloat(digits >> 16 & 255) / 255, green: CGFloat(digits >> 8 & 255) / 255, blue: CGFloat(digits & 255) / 255, alpha: 1)
    }
}

extension FormFill {
    static func surface(_ kind: String) -> NSView {
        let forms = FormFill()
        let tab = UUID()
        let view: NSView
        switch kind {
        case "done":
            let bar = FormFillBar(forms: forms)
            bar.kind = .done(Done(tab: tab, filled: 5, stays: 2))
            view = bar
        case "offer":
            let bar = FormFillBar(forms: forms)
            bar.kind = .offer(Offer(tab: tab, keep: .address(AutofillAddress(name: "Dana Scully", line1: "12 Orchard Lane", city: "Bristol", postal: "BS1 4DJ"))))
            view = bar
        default:
            let made: [(String, FormValueKind, FormSource, String)] = [
                ("Full name", .fullName, .profile, "Dana Scully"), ("Email", .email, .profile, "dana@example.test"),
                ("Street address", .addressLine1, .address, "12 Orchard Lane, a long way down the hill past the mill"),
                ("City", .city, .address, "Bristol"), ("Postcode", .postal, .address, "BS1 4DJ"),
            ]
            let rows = made.enumerated().map { index, row in
                FormPlanRow(field: FormField(index: index, label: row.0), kind: row.1, source: row.2, value: row.3, shown: row.3)
            }
            let plan = FormPlan(rows: rows, fields: rows.map(\.field), total: 7, note: "Two boxes ask for things Broadway doesn't keep")
            let card = FormFillCard(forms: forms)
            card.show(Preview(tab: tab, page: nil, shy: false, fields: plan.fields, plan: plan), addresses: [], cards: [])
            view = card
        }
        let size = view.intrinsicContentSize
        let stage = KitBox(fill: nil)
        stage.frame = NSRect(x: 0, y: 0, width: size.width + 16, height: size.height + 16)
        view.frame = NSRect(x: 8, y: 8, width: size.width, height: size.height)
        stage.addSubview(view)
        return KitFixedView(stage, keep: forms)
    }
}
