import AppKit
import Observation
import WebKit

// Where a link goes, at the bottom of the page while the pointer is on it.
//
// Off unless turned on in Settings › General. Off, not a line of it reaches
// a page: the listener is only put into pages while the switch is on.

/// Reports the destination under the pointer to the tab that owns the page.
/// WebKit retains this relay; the tab is weak so closing it releases the page.
final class HoveredLink: NSObject, WKScriptMessageHandler {
    static let name = "link"
    /// Whether pages get the listener. Set from Settings.
    @MainActor static var on = false

    /// For a page already up when it is turned off: its listener goes quiet.
    static let off = "if (window.__searchLinks) window.__searchLinks.on = false;"

    // One passive listener in every frame reports the resolved link address
    // only when it changes. The isolated client world keeps it out of the page's reach.
    static let script = """
    (() => {
        // Turned back on over a page that already has it: the same listener
        // speaks again rather than a second one beside it.
        if (window.__searchLinks) { window.__searchLinks.on = true; return; }
        const state = { on: true };
        window.__searchLinks = state;
        let shown = '';

        function report(address) {
            if (!state.on || address === shown) return;
            shown = address;
            webkit.messageHandlers.link.postMessage(address);
        }

        // The composed path reaches links inside open shadow trees, where `target` stops at the host.
        function linkIn(path) {
            for (const node of path) {
                if (node.nodeType !== 1 || (node.localName !== 'a' && node.localName !== 'area')) continue;
                // An SVG link's href is an object, and its address may be relative.
                const href = typeof node.href === 'string' ? node.href : node.href && node.href.baseVal;
                if (!href) continue;
                try {
                    const address = new URL(href, node.baseURI).href;
                    // A script link goes nowhere worth showing.
                    return address.startsWith('javascript:') ? '' : address.slice(0, 600);
                } catch {
                    return '';
                }
            }
            return '';
        }

        addEventListener('mouseover', event => report(linkIn(event.composedPath())), { passive: true, capture: true });
        // Leaving the frame altogether: there is no next element to enter.
        addEventListener('mouseout', event => { if (!event.relatedTarget) report(''); }, { passive: true, capture: true });
        addEventListener('pagehide', () => report(''));
    })();
    """

    weak var tab: Tab?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let address = message.body as? String else { return }
        MainActor.assumeIsolated {
            guard let tab, message.webView === tab.built else { return }
            tab.onLink?(tab, address.isEmpty ? nil : address)
        }
    }
}

struct LinkShow: Equatable {
    static let grace: TimeInterval = 0.32

    private(set) var destination: String?
    private(set) var leavingAt: TimeInterval?

    var shown: Bool { destination != nil }

    mutating func point(at address: String?, now: TimeInterval) {
        if let address {
            destination = address
            leavingAt = nil
        } else if destination != nil, leavingAt == nil {
            leavingAt = now + Self.grace
        }
    }

    @discardableResult
    mutating func tick(_ now: TimeInterval) -> Bool {
        guard let leavingAt, now >= leavingAt - 0.001 else { return false }
        destination = nil
        self.leavingAt = nil
        return true
    }

    mutating func dismiss() {
        destination = nil
        leavingAt = nil
    }
}

/// Holds one link destination for the page overlay. Only a page's message
/// causes a redraw: nothing here watches the pointer move.
@MainActor
@Observable
final class LinkStatus {
    private(set) var destination: String?
    private(set) var onRight = false
    private(set) var page: ObjectIdentifier?
    private(set) var area: CGRect?
    private(set) var preview: IntegrationPreview?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var previewAim: String?
    @ObservationIgnored private var state = LinkShow()
    @ObservationIgnored private var hiding: DispatchWorkItem?

    func show(_ address: String?, over page: NSView?, space: UUID? = nil, privateTab: Bool = false) {
        pointPreview(address, space: space, privateTab: privateTab)
        state.point(at: address, now: CACurrentMediaTime())
        if address != nil {
            hiding?.cancel()
            hiding = nil
        } else if hiding == nil, state.leavingAt != nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hiding = nil
                self.state.tick(.infinity)
                self.publish()
            }
            hiding = work
            DispatchQueue.main.asyncAfter(deadline: .now() + LinkShow.grace, execute: work)
        }
        if address != nil {
            let id = page.map(ObjectIdentifier.init)
            if self.page != id { self.page = id }
            if let page { place(over: page) }
        }
        publish()
    }

    func dismiss() {
        pointPreview(nil, space: nil, privateTab: false)
        hiding?.cancel()
        hiding = nil
        state.dismiss()
        publish()
    }

    private func pointPreview(_ address: String?, space: UUID?, privateTab: Bool) {
        let target = privateTab ? nil : address.flatMap(IntegrationLink.init)
        let aim = target.flatMap { link in space.map { "\($0):\(link.identity)" } }
        guard aim != previewAim else { return }
        previewAim = aim
        previewTask?.cancel()
        previewTask = nil
        preview = nil
        guard let target, let space else { return }
        previewTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(HoverCards.dwell)) } catch { return }
            let found = await IntegrationPreviews.shared.read(target.url.absoluteString, space: space)
            guard !Task.isCancelled, self?.previewAim == aim else { return }
            self?.preview = found
        }
    }

    private func publish() {
        if destination != state.destination { destination = state.destination }
    }

    /// A link under the bubble's corner gets the bubble in the other one.
    /// The pointer is asked where it is once, as the link under it changes,
    /// rather than followed on every move.
    private func place(over page: NSView) {
        guard let window = page.window else { return }
        if let content = window.contentView {
            let box = content.convert(page.convert(page.bounds, to: nil), from: nil)
            let top = content.isFlipped ? box : CGRect(x: box.minX, y: content.bounds.height - box.maxY, width: box.width, height: box.height)
            if area != top { area = top }
        }
        let point = page.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let size = page.bounds.size
        let fromBottom = page.isFlipped ? size.height - point.y : point.y
        let right = fromBottom < 50 && point.x < min(size.width * 0.6, 640) + 22
        if onRight != right { onRight = right }
    }
}

final class LinkBubbleView: KitFlippedView {
    let status: LinkStatus

    private let bubble = KitFlippedView()
    private let glass = NSGlassEffectView()
    private let words = LinkWordsView()
    private var card: NSView?
    private var cardFor: IntegrationPreview?
    private var held = ""
    private var up: Bool?
    private var anchor = KitArrival.bottom

    init(status: LinkStatus) {
        self.status = status
        super.init(frame: .zero)
        wantsLayer = true
        bubble.wantsLayer = true
        addSubview(bubble)
        glass.tintColor = Palette.NS.glassTint
        bubble.addSubview(glass)
        bubble.addSubview(words)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }


    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let address = status.destination
        let right = status.onRight
        let area = status.area ?? bounds
        let preview = status.preview
        let text = address ?? held
        if text != held, up == true, !held.isEmpty { bubble.layer?.kitTransition(Motion.kitSettle) }
        if let address { held = address }
        let column = min(area.width * 0.6, 640)
        let fit = KitTruncate.middleParts(text, attributes: [.font: LinkWordsView.font], to: column - 22)
        words.show(text, head: fit.head, tail: fit.tail, cut: fit.cut)
        let natural = NSSize(width: ceil(fit.width), height: LinkWordsView.height)
        let pill = NSSize(width: natural.width + 22, height: 26)
        var cardSize = NSSize.zero
        if let preview {
            cardSize = NSSize(width: min(320, max(0, area.width - 20)), height: 148)
            if cardFor != preview {
                let made = LinkPreviewCard(preview: preview, size: cardSize)
                if let card { card.removeFromSuperview() } else if up == true { made.wantsLayer = true; made.layer?.kitTransition(Motion.kitSettle) }
                bubble.addSubview(made)
                card = made
                cardFor = preview
            }
        } else if let card {
            card.removeFromSuperview()
            self.card = nil
            cardFor = nil
            bubble.layer?.kitTransition(Motion.kitSettle)
        }
        let width = max(pill.width, cardSize.width)
        let height = pill.height + (card == nil ? 0 : cardSize.height + 8)
        let x = right ? area.maxX - 10 - width : area.minX + 10
        bubble.frame = kitSnap(NSRect(x: x, y: area.maxY - 10 - height, width: width, height: height))
        let lead: CGFloat = right ? width - pill.width : 0
        card?.frame = NSRect(x: right ? width - cardSize.width : 0, y: 0, width: cardSize.width, height: cardSize.height)
        glass.frame = kitSnap(NSRect(x: lead, y: height - pill.height, width: pill.width, height: pill.height))
        glass.cornerRadius = 13
        words.frame = kitSnap(NSRect(x: lead + 11, y: height - pill.height + (pill.height - natural.height) / 2,
                                     width: natural.width, height: natural.height))
        let shown = address != nil
        anchor = CGPoint(x: right ? 1 : 0, y: 1)
        if up != shown {
            bubble.kitArrive(shown, .rise(by: 12, from: anchor), animated: up != nil)
            up = shown
        } else if !shown {
            bubble.kitArrive(false, .rise(by: 12, from: anchor), animated: false)
        }
    }
}

extension LinkStatus {
    static func surface(_ address: String) -> NSView {
        let status = LinkStatus()
        status.show(address, over: nil)
        return BenchFloating.sized(LinkBubbleView(status: status), NSSize(width: 520, height: 64))
    }
}

final class LinkWordsView: NSView {
    static let font = NSFont.systemFont(ofSize: 12)
    static let height = ceil(font.ascender - font.descender + font.leading)

    private var parts: (head: String, tail: String, cut: Bool) = ("", "", false)
    private var full = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var allowsVibrancy: Bool { false }

    func show(_ text: String, head: String, tail: String, cut: Bool) {
        setAccessibilityValue(text)
        guard full != text || parts.head != head || parts.tail != tail || parts.cut != cut else { return }
        full = text
        parts = (head, tail, cut)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: KitColor.ink.kitResolved(dark: kitDark)]
        let text = NSAttributedString(string: parts.cut ? full : parts.head, attributes: attributes)
        let height = text.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        let y = (bounds.height - height) / 2
        guard parts.cut else {
            KitTruncate.draw(CTLineCreateWithAttributedString(text), at: CGPoint(x: 0, y: y), flipped: true, in: context)
            return
        }
        KitTruncate.drawMiddle(text, head: parts.head.utf16.count, tail: parts.tail.utf16.count, at: CGPoint(x: 0, y: y), flipped: true, in: context)
    }
}

@MainActor
final class LinkPreviewCard: KitFlippedView {
    private let glass = KitGlass.floating(radius: 14)
    private let inside = KitFlippedView()
    private let details: IntegrationPreviewDetailsView

    init(preview: IntegrationPreview, size: NSSize) {
        details = IntegrationPreviewDetailsView(preview: preview)
        super.init(frame: NSRect(origin: .zero, size: size))
        addSubview(glass)
        glass.hold(inside)
        inside.addSubview(details)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        glass.frame = bounds
        inside.frame = glass.bounds
        let width = max(0, bounds.width - 24)
        details.frame = CGRect(x: 12, y: 12, width: width, height: min(details.height(for: width), max(0, bounds.height - 24)))
    }
}
