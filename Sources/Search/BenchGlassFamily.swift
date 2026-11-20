import AppKit

@MainActor
enum BenchGlassFamily {
    static let names = ["site-file", "announcement", "agent-ask-outside", "offer-bar", "link-preview", "update-card", "stuck-card"]

    static func make(_ name: String, _ request: [String: Any], browser: Browser?) -> NSView? {
        guard let browser else { return nil }
        switch name {
        case "site-file":
            let insecure = request["kind"] as? String == "insecure"
            let card = FileCard(kind: insecure ? .insecure : .site, site: "files.example.test", host: "files.example.test",
                                name: "quarterly-report.pdf", file: UUID(), more: request["more"] as? Bool ?? false)
            let view = SiteFileQuestionView(browser: browser, card: card)
            return BenchFloating.sized(view, view.fit((request["width"] as? Double).map { CGFloat($0) }))
        case "announcement":
            let note = CapsuleNote(request["text"] as? String ?? "Tab closed", size: 12, trailing: request["trailing"] as? String ?? "")
            return BenchFloating.sized(note, note.intrinsicContentSize)
        case "agent-ask-outside":
            var question = AgentQuestion(kind: .choice(["Use the work account", "Use the personal account", "Stop here"]),
                                         title: "Which account should this order go on?")
            question.asker = "Claude Code"
            AgentDesk.shared.benchAsk(question)
            let card = AgentCardView(browser: browser, desk: .shared)
            return BenchFloating.sized(card, NSSize(width: 460, height: card.intrinsicContentSize.height))
        case "update-card":
            let flow = UpdateFlow()
            flow.pretend(.available, found: UpdateFound(version: "0.7", build: "70"))
            let card = UpdateCardView(flow: flow)
            return BenchFloating.sized(BenchHovered(card), NSSize(width: 248, height: UpdateCardView.height + UpdateCardView.room + 8))
        case "stuck-card":
            guard let tab = browser.active else { return nil }
            let leave = request["kind"] as? String == "leave"
            let card = leave ? StuckCardView(tab: tab, browser: browser, words: .leave) { _ in } : StuckCardView(tab: tab, browser: browser)
            return BenchFloating.sized(card, NSSize(width: 440, height: 230))
        case "link-preview":
            let size = NSSize(width: 320, height: 148)
            return BenchFloating.sized(LinkPreviewCard(preview: IntegrationPreviewSurface.github, size: size), size)
        case "offer-bar":
            let bar = OfferBarView(request["text"] as? String ?? "Open links from Mail in this space?",
                                   choices: [.init("Not Now") {}, .init("Open Here", .primary) {}])
            return BenchFloating.sized(bar, bar.intrinsicContentSize)
        default:
            return nil
        }
    }
}

private final class BenchHovered: NSView {
    private let held: KitHoverView

    init(_ held: KitHoverView) {
        self.held = held
        super.init(frame: .zero)
        addSubview(held)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        held.frame = bounds.insetBy(dx: 4, dy: 4)
        guard let window else { return }
        held.layoutSubtreeIfNeeded()
        KitHoverView.pointerStandIn = (window, held.convert(NSPoint(x: held.bounds.midX, y: held.bounds.midY), to: nil))
        held.settleHover()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { KitHoverView.pointerStandIn = nil }
    }
}
