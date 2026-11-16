import AppKit

@MainActor
enum SideSurfaces {
    static let names = ["live-folder-rows"]

    static func make(_ name: String, _ request: [String: Any]) -> NSView? {
        guard let browser = Browsers.all.first else { return nil }
        switch name {
        case "live-folder-rows": return liveRows(browser, dark: request["look"] as? String == "dark")
        default: return nil
        }
    }

    private static func folder(_ name: String, _ browser: Browser, _ answer: LiveReader.Answer?, paused: Bool = false,
                               items: [LiveItem] = []) -> UUID {
        let live = LiveFolders.shared
        let made = live.add(name: name, source: .pullRequests, space: browser.spaceID)
        if !items.isEmpty { live.apply(.items(items, nil), to: made.id) }
        if let answer { live.apply(answer, to: made.id) }
        if paused { live.pause(made.id, true) }
        return made.id
    }

    static func liveRows(_ browser: Browser, dark: Bool) -> NSView {
        let fresh = [LiveItem(key: "a", title: "One", activity: Date()), LiveItem(key: "b", title: "Two", activity: Date())]
        let notes: [UUID] = [
            folder("Loading", browser, nil),
            folder("Empty", browser, .items([], nil)),
            folder("Paused", browser, nil, paused: true),
            folder("Sign In", browser, .signIn),
            folder("SSO", browser, .sso(LiveSSO(org: "Acme", url: "https://github.com/orgs/acme/sso"), [])),
            folder("Failed", browser, .failed),
        ]
        let statuses: [(UUID, Bool)] = [
            (folder("Fresh", browser, nil, items: fresh), true),
            (folder("Sign In", browser, .signIn, items: fresh), true),
            (folder("Paused", browser, nil, paused: true, items: fresh), true),
            (folder("Failed", browser, .failed, items: fresh), false),
        ]
        let ground = RowGround(greys: .white, ink: .flat, dark: dark, stops: nil)
        let width: CGFloat = 240
        let height = Metrics.sideRowHeight
        let stage = SurfaceColumn(frame: NSRect(x: 0, y: 0, width: width,
                                                height: CGFloat(notes.count) * (height + 4) + CGFloat(statuses.count) * 24))
        var y: CGFloat = 0
        for id in notes {
            let view = SideSigns.liveNote(browser: browser, id: id, height: height, interactive: true)
            SideSigns.update(view, colour: .ink, ground: ground)
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            stage.addSubview(view)
            y += height + 4
        }
        for (id, collapsed) in statuses {
            let view = SideSigns.liveStatus(browser: browser, id: id, collapsed: collapsed)
            SideSigns.update(view, colour: .ink, ground: ground)
            stage.addSubview(view)
            stage.ends.append((view, y))
            y += 24
        }
        return PieceSurfaces.sized(stage, width: width, height: y)
    }
}

private final class SurfaceColumn: NSView {
    var ends: [(NSView, CGFloat)] = []

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        for (view, y) in ends {
            let size = view.fittingSize
            view.frame = NSRect(x: bounds.width - 8 - size.width, y: y + (24 - size.height) / 2, width: size.width, height: size.height)
        }
    }
}

extension PieceSurfaces {
    static func groundLook(_ style: String?) -> SpaceLook {
        switch style {
        case "vivid": return SpaceLook(colours: ["000000"], intensity: SpaceLook.real)
        case "blend": return SpaceLook(colours: ["8BE33A", "7CC4F2", "7B3FE4"], intensity: 0.7)
        case "grain": return SpaceLook(colours: ["E8FF1A", "8BE33A"], intensity: 0.6, grain: 0.8)
        case "navy": return SpaceLook(colours: ["000354"], intensity: 1)
        default: return SpaceLook(colour: "sky")
        }
    }

    static func spaceGround(_ style: String?) -> NSView {
        let view = SpaceGroundView(look: groundLook(style), opaque: true)
        view.spansWindow = false
        return sized(view, width: 260, height: 120)
    }

    static func sized(_ view: NSView, width: CGFloat, height: CGFloat) -> NSView {
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: width), view.heightAnchor.constraint(equalToConstant: height)])
        return view
    }

    static let stackedSpaces = [
        Space(id: UUID(uuidString: "6B000000-0000-0000-0000-000000000002") ?? UUID(), name: "Work", colour: 0, icon: TabIcon(symbol: "briefcase")),
        Space(id: UUID(uuidString: "6B000000-0000-0000-0000-000000000003") ?? UUID(), name: "Travel plans for the long summer", colour: 0, icon: TabIcon(symbol: "airplane")),
        Space(id: UUID(uuidString: "6B000000-0000-0000-0000-000000000004") ?? UUID(), name: "Reading", colour: 0, icon: TabIcon(symbol: "book")),
    ]

    @MainActor static func stackedHeaders(_ browser: Browser, style: String?) -> NSView {
        let folds = StackedFolds()
        folds.set(stackedSpaces[1].id, folded: true)
        let surface = StackedHeadersSurface(browser: browser, folds: folds, look: style.map { groundLook($0) })
        return sized(surface, width: 260, height: surface.height)
    }

    @MainActor static func marks(lift: Double) -> NSView {
        let row = MarksSurface(lift: lift)
        return sized(row, width: row.width, height: row.height)
    }

    @MainActor static func newSpaceCard(_ browser: Browser) -> NSView {
        let card = NewSpaceCard(browser: browser, draft: NewSpaceAsk.draft(in: browser))
        return sized(card, width: NewSpaceCard.width, height: card.fit())
    }

    @MainActor static func spaceLookChooser(_ picked: String?) -> NSView {
        let chooser = SpaceLookChooser(picked: picked ?? "gray") { _ in }
        let size = chooser.intrinsicContentSize
        return sized(chooser, width: size.width, height: size.height)
    }

    @MainActor static func spaceLookEditor(_ browser: Browser, style: String?) -> NSView {
        if let style { browser.setSpaceLook(browser.space.id, to: groundLook(style), lasting: false) }
        return SpaceLookEditorView(browser: browser)
    }
}

private final class StackedHeadersSurface: NSView {
    let look: SpaceLook?
    private let ground: SpaceGroundView?
    private let column = KitFlippedView()
    private let headers: [StackedHeaderView]
    private let cuts = StackedCuts()

    init(browser: Browser, folds: StackedFolds, look: SpaceLook?) {
        self.look = look
        ground = look.map { SpaceGroundView(look: $0, opaque: true) }
        let spaces = PieceSurfaces.stackedSpaces
        let rows: [(Space, Int)] = [(browser.space, 3), (spaces[0], 12), (spaces[1], 7), (spaces[2], 4), (spaces[0], 12)]
        headers = rows.map { StackedHeaderView(browser: browser, folds: folds, space: $0.0, count: $0.1) }
        super.init(frame: .zero)
        if let ground {
            ground.spansWindow = false
            addSubview(ground)
        }
        addSubview(column)
        for header in headers { column.addSubview(header) }
        headers[3].lit = true
        headers[4].gathered = true
        for header in headers { header.cuts = cuts }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var pad: CGFloat { look == nil ? 0 : 8 }

    var height: CGFloat {
        pad * 2 + CGFloat(headers.count) * StackedHeaderView.height + CGFloat(headers.count - 1) * 4
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let base = kitDark
        let inkDark = look.map { $0.inkLight(dark: base) } ?? base
        let ink = look.map { KitInk(lift: $0.inkLift(dark: base)) } ?? .flat
        if let ground {
            ground.groundDark = base
            ground.frame = bounds
        }
        let named: NSAppearance.Name = inkDark ? .darkAqua : .aqua
        if column.appearance?.name != named { column.appearance = NSAppearance(named: named) }
        column.frame = bounds
        var y = pad
        for (index, header) in headers.enumerated() {
            header.onFrame = look != nil
            header.ink = ink
            if index == headers.count - 1, header.ground == nil {
                let lifted = SpaceGroundView(look: look ?? SpaceLook(), opaque: true)
                lifted.spansWindow = false
                header.ground = lifted
            }
            if let lifted = header.ground as? SpaceGroundView { lifted.groundDark = inkDark }
            header.lifted = index == headers.count - 1
            header.frame = NSRect(x: Metrics.sideInset, y: y, width: bounds.width - 2 * Metrics.sideInset, height: StackedHeaderView.height)
            y += StackedHeaderView.height + 4
        }
    }
}

private final class MarksSurface: NSView {
    private let marks: [MarkView]

    init(lift: Double) {
        let ink = KitInk(lift: lift)
        func mark(_ icon: NSImage?, _ letter: String, size: CGFloat = 16, dim: Bool = false, tiled: Bool = true, glyph: Bool = false,
                  letterSize: CGFloat? = nil, letterColour: NSColor = KitColor.muted) -> MarkView {
            let view = MarkView(icon: icon, letter: letter, size: size)
            view.ink = ink
            view.dim = dim
            view.tiled = tiled
            view.glyph = glyph
            view.letterSize = letterSize
            view.letterColour = letterColour
            return view
        }
        marks = [
            mark(nil, "A"), mark(nil, "G", size: 24), mark(nil, "W", size: 15, tiled: false),
            mark(BenchArt.colour, "C"), mark(BenchArt.colour, "C", size: 24, dim: true),
            mark(BenchArt.darkGlyph, "D"), mark(BenchArt.darkGlyph, "D", size: 24), mark(BenchArt.template, "T"),
            mark(BenchArt.colour, "G", size: 20, glyph: true), mark(nil, "L", size: 20, letterSize: 9, letterColour: KitColor.ink),
        ]
        super.init(frame: .zero)
        for view in marks { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var width: CGFloat { marks.reduce(0) { $0 + $1.size } + CGFloat(marks.count - 1) * 10 + 16 }
    var height: CGFloat { (marks.map(\.size).max() ?? 0) + 16 }

    override func layout() {
        super.layout()
        var x: CGFloat = 8
        for view in marks {
            view.frame = kitSnap(NSRect(x: x, y: (bounds.height - view.size) / 2, width: view.size, height: view.size))
            x += view.size + 10
        }
    }
}
