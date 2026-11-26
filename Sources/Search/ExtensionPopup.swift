import AppKit
import WebKit

// An extension's popup, in a popover of the browser's own.
//
// WebKit offers a popover of its own for this, and it works for most
// extensions — but not all: for some, messages from WebKit's popup never
// reach the extension's worker, and the popup waits on a spinner for ever,
// while the very same page loaded in a view built from the extension's
// configuration talks to its worker perfectly well. So the popup page is
// loaded here, in such a view, in a popover that hangs from the button.
//
// Chrome sizes a popup to its content, between 25 and 800 points wide and
// up to 600 tall; the page is measured after it loads and again as it
// changes, and the popover follows. window.close() closes it.

@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate {
    static let shared = ExtensionPopup()

    private var popup: KitPopup?
    private var web: WKWebView?
    /// The popup as WebKit is told about it: a page it can find, belonging
    /// to the browser's window — Chrome gives a popup no window of its own,
    /// so "the current window" from a popup is the browser's, and so is the
    /// last focused one.
    private var page: PopupPage?
    private weak var pageContext: WKWebExtensionContext?
    private var measuring: Timer?
    private(set) var extensionID: String?
    /// The popup's web view, while one is up — for the bench.
    var view: WKWebView? { web }

    /// The popup asking for the camera or microphone: asked on the card of
    /// the window in front, named as the extension and remembered for it,
    /// as for any of its pages (see Browser.askedForCapture) — never
    /// WebKit's own dialog, and never without asking.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let browser = Browsers.front else { return decisionHandler(.deny) }
        browser.askedForCapture(webView, origin: origin, frame: frame, type: type, decisionHandler: decisionHandler)
    }

    /// Recording the screen from the popup: only Search's own call
    /// (ExtensionCapture), never the extension's on its own.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        decisionHandler(ExtensionCapture.shared.displayDecision(for: web))
    }

    /// On screen now.
    var isUp: Bool { popup?.isShown == true }

    /// The popup as its extension's worker finds it in clients.matchAll().
    func client(of id: String) -> [String: Any]? {
        guard extensionID == id, let url = web?.url else { return nil }
        return ["id": "popup", "url": url.absoluteString, "visible": isUp, "focused": isUp && web?.window?.isKeyWindow == true]
    }

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?) {
        close()
        guard let configuration = context.webViewConfiguration else { return }
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 25, height: 25), configuration: configuration)
        web.uiDelegate = self
        web.navigationDelegate = self
        web.alphaValue = 0
        web.load(URLRequest(url: url))

        let size = ExtensionPopup.lastSize[context.uniqueIdentifier] ?? NSSize(width: 360, height: 240)
        let stage = PopupStage(frame: NSRect(origin: .zero, size: size))
        stage.addSubview(web)
        stage.follow(web)

        self.web = web
        extensionID = context.uniqueIdentifier
        let page = PopupPage(web: web, owner: context.uniqueIdentifier)
        self.page = page
        pageContext = context
        context.didOpenTab(page)

        shown = false
        let closed: () -> Void = { [weak self, weak stage] in
            guard let self, let stage, self.popup?.content === stage else { return }
            self.measuring?.invalidate()
            self.measuring = nil
            self.forget()
        }
        if let anchor, anchor.window != nil {
            popup = KitPopup.show(stage, size: size, from: anchor.bounds, of: anchor, edge: .auto, focus: true, bleeds: true,
                                  onClose: closed)
        } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain && $0.frame.minX > -10_000 }))?.contentView {
            let bounds = content.bounds, flipped = content.isFlipped
            let spot = NSRect(x: bounds.minX + 24, y: flipped ? bounds.minY + 24 : bounds.maxY - 24, width: 1, height: 1)
            popup = KitPopup.show(stage, size: size, from: spot, of: content, edge: .below, focus: true, bleeds: true,
                                  onClose: closed)
        }
        popup?.panel?.makeFirstResponder(web)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak stage] in
            guard let self, let stage, self.popup?.content === stage else { return }
            self.firstMeasure()
            self.follow()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self, weak stage] in
            guard let self, let stage, self.popup?.content === stage else { return }
            self.reveal()
        }
    }

    /// Each extension's popup size, so the next opening starts there.
    private static var lastSize: [String: NSSize] = [:]

    static func forget(_ id: String) { lastSize[id] = nil }

    private var shown = false

    /// The page, at the popover's size, in view.
    private func reveal() {
        guard !shown, let web, let stage = popup?.content as? PopupStage else { return }
        shown = true
        stage.places = true
        web.frame = stage.bounds
        NSAnimationContext.kit(Motion.kitFade) {
            web.animator().alphaValue = 1
        }
    }

    /// From the page's first load: sized, then followed as it grows — a
    /// list filled in by a reply from the worker — for as long as it's open.
    private func follow() {
        guard measuring == nil else { return }
        if !shown { firstMeasure() }
        ticks = 0
        measuring = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.grow() }
        }
    }

    func close() {
        measuring?.invalidate()
        measuring = nil
        let closing = popup
        forget()
        closing?.close()
    }

    /// Tells WebKit the popup's window and tab are gone.
    private func forget() {
        if let page { pageContext?.didCloseTab(page, windowIsClosing: false) }
        page = nil
        pageContext = nil
        popup = nil
        web = nil
        extensionID = nil
    }

    func closes(_ id: String) -> Bool {
        guard popup != nil, extensionID == id else { return false }
        close()
        return true
    }

    static let named = """
    ((d, v) => {
      const m = window.__searchSizing || (window.__searchSizing = {}), w = d.getBoundingClientRect().width;
      if (Math.abs(w - v.clientWidth) > 1) return m.w = w;
      return m.w && Math.abs(m.w - v.clientWidth) <= 1 ? m.w : null;
    })
    """

    static let narrowest = """
    ((d) => {
      const saved = d.getAttribute("style");
      d.style.setProperty("width", "min-content", "important");
      const narrowest = d.getBoundingClientRect().width;
      saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      return narrowest >= 100 ? narrowest : Math.max(narrowest, d.scrollWidth);
    })
    """

    /// The size Chrome would give the popup (Blink's auto-size, between
    /// 25 × 25 and 800 × 600), worked out in the page while its view is
    /// still the 25-point square: the width the page names for itself if it
    /// names one, else its narrowest (min-content — what is positioned off
    /// to the side doesn't count), else, for a page with next to no width
    /// of its own, what its content spans; then, laid out at that width,
    /// the height it names or spans. Nothing of it is left on the page.
    static let preferred = """
    () => {
      const d = document.documentElement, v = document.compatMode === "BackCompat" ? document.body : d;
      if (!v) return null;
      const m = window.__searchSizing || (window.__searchSizing = {});
      const saved = d.getAttribute("style");
      const back = () => saved === null ? d.removeAttribute("style") : d.setAttribute("style", saved);
      let w = \(named)(d, v);
      if (w === null) w = \(narrowest)(d);
      const gutter = innerWidth - v.clientWidth;
      w = Math.min(800, Math.max(25, Math.ceil(w + gutter)));
      d.style.setProperty("width", (w - gutter) + "px", "important");
      let h = d.getBoundingClientRect().height;
      if (Math.abs(h - innerHeight) > 1) m.h = h;
      else if (m.h && Math.abs(m.h - innerHeight) <= 1) h = m.h;
      else {
        d.style.setProperty("height", "auto", "important");
        d.style.setProperty("min-height", "0", "important");
        h = d.getBoundingClientRect().height;
      }
      back();
      return [w, Math.min(600, Math.max(25, Math.ceil(h + innerHeight - v.clientHeight)))];
    }
    """

    /// The document is built — DOMContentLoaded, the moment Chrome sizes a
    /// popup, before the page's scripts look at the room they have (Proton
    /// Pass takes whatever size it finds then for good). WebKit tells a
    /// navigation delegate that has this method; the configuration
    /// extension pages share can't be given a script of our own.
    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web else { return }
        firstMeasure()
    }

    /// Measured while still the 25-point square and unseen, then shown at
    /// the size found.
    private func firstMeasure() {
        guard let web, !shown else { return }
        web.evaluateJavaScript("(\(ExtensionPopup.preferred))()") { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, web === self.web, !self.shown else { return }
                guard let pair = value as? [Double], pair.count == 2 else { return }
                self.apply(NSSize(width: pair[0], height: pair[1]))
            }
        }
    }

    private func apply(_ size: NSSize) {
        guard let popup else { return }
        let now = popup.size
        if abs(size.width - now.width) > 1 || abs(size.height - now.height) > 1 { popup.resize(to: size) }
        if let id = extensionID { ExtensionPopup.lastSize[id] = size }
        reveal()
    }

    /// How far the page reaches, as a function of "width" or "height":
    /// its own width if it names one wider than the view, else its
    /// narrowest (min-content — what is positioned off to the side doesn't
    /// count, as in Chrome's measure), else, for a page that only fills the
    /// view and has next to no width of its own, what its content spans.
    /// Height: all it spans.
    static let reach = """
    ((key) => {
      const d = document.documentElement, v = document.compatMode === "BackCompat" ? document.body : d;
      if (!v) return null;
      if (key === "height") return d.scrollHeight;
      const own = d.getBoundingClientRect().width, gutter = innerWidth - v.clientWidth;
      if (own > v.clientWidth + 1) return own + gutter;
      return \(narrowest)(d) + gutter;
    })
    """

    static let following = "[\(ExtensionPopup.reach)('width'), (() => { const d = document.documentElement; return d && d.scrollHeight > d.clientHeight ? d.scrollHeight : 0; })(), (() => { const d = document.documentElement, v = document.compatMode === 'BackCompat' ? document.body : d, w = \(named)(d, v), gutter = innerWidth - v.clientWidth; return w === null ? 0 : w + gutter; })()]"

    /// Measured again as the page builds itself, the way Chrome measures on
    /// each layout: for its first two seconds the popup follows it either
    /// way, after that it only grows — so a page that settles doesn't set
    /// it rocking.
    private var ticks = 0
    private func grow() {
        guard shown, let web, let popup else { return }
        ticks += 1
        if ticks <= 8 {
            web.evaluateJavaScript("(\(ExtensionPopup.preferred))()") { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let pair = value as? [Double], pair.count == 2 else { return }
                    let wanted = NSSize(width: pair[0], height: pair[1])
                    let now = popup.size
                    if abs(wanted.width - now.width) > 2 || abs(wanted.height - now.height) > 2 { self.apply(wanted) }
                }
            }
            return
        }
        // after its first six seconds, once a second is enough to follow it.
        if ticks > 24, ticks % 4 != 0 { return }
        // a width the page names for itself, remembered as the first measure does, is followed both ways:
        // Bitwarden's narrow setting shrinks it.
        web.evaluateJavaScript(ExtensionPopup.following) { value, _ in
            MainActor.assumeIsolated {
                guard let pair = value as? [Double], pair.count == 3 else { return }
                let now = popup.size
                let width = pair[2] > 0 ? max(25, pair[2].rounded(.up)) : max(now.width, pair[0])
                let wanted = NSSize(width: min(800, width), height: min(600, max(now.height, pair[1])))
                if wanted != now { self.apply(wanted) }
            }
        }
    }

    // MARK: - the page asking

    func webViewDidClose(_ webView: WKWebView) { close() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { follow() }

    /// A link that asks for a new window becomes a tab, and the popup goes —
    /// the way it does in Chrome when you follow a link out of one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // The same rule as tabs.create: never a file on this Mac, never javascript:.
        if let url = action.request.url, (try? Extensions.mayOpen(url)) != nil {
            Extensions.shared.browser?.open(url, foreground: true)
        }
        close()
        return nil
    }

}

/// The popup page, as WebKit finds it: in the browser's window, but not
/// among its tabs — which is where Chrome puts a popup too.
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?
    let owner: String

    init(web: WKWebView, owner: String) {
        self.web = web
        self.owner = owner
    }

    private func sealed(_ context: WKWebExtensionContext) -> Bool { context.uniqueIdentifier != owner }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? { Extensions.shared.window }
    func indexInWindow(for context: WKWebExtensionContext) -> Int { NSNotFound }
    func webView(for context: WKWebExtensionContext) -> WKWebView? { sealed(context) ? nil : web }
    func title(for context: WKWebExtensionContext) -> String? { sealed(context) ? nil : web?.title }
    func url(for context: WKWebExtensionContext) -> URL? { sealed(context) ? nil : web?.url }
    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { !(web?.isLoading ?? false) }
    func isSelected(for context: WKWebExtensionContext) -> Bool { false }
    func close(for context: WKWebExtensionContext) async throws { ExtensionPopup.shared.close() }
}

final class PopupStage: NSView {
    var places = false
    private var ground: NSKeyValueObservation?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func follow(_ web: WKWebView) {
        ground = web.observe(\.underPageBackgroundColor, options: [.initial, .new]) { [weak self] web, _ in
            MainActor.assumeIsolated {
                self?.layer?.backgroundColor = web.underPageBackgroundColor.cgColor
            }
        }
    }

    override func layout() {
        super.layout()
        guard window != nil else { return }
        if places { subviews.first?.frame = bounds }
    }
}
