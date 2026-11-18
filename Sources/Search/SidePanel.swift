import AppKit
import Observation
import WebKit
import Combine

// The side panel: beside the page on the side away from the column (on the
// right with the tabs across the top), closed until something asks for it,
// as wide as you last left it. With the page as a card it is a card of its
// own; edge to edge, it meets the page at a hairline. If it can't be made,
// the extension's panel opens as a tab of its own, as before there was one.
//
// What lives in it is an extension's panel (chrome.sidePanel): ChatGPT's,
// Claude's, Sider, Merlin — their page, made from the extension's own
// configuration so it is one of its pages in every way (runtime messages,
// storage), shown here rather than in a tab. From Office Search Community's
// work in progress (o5-panel).
//
// Or a website (idea 365), for whoever turns on Settings › General ›
// Websites in the side panel: Claude or ChatGPT kept beside the page
// without an extension. It is an ordinary page of the window's space, signed
// in where that space's tabs are, never a private tab's; its address is on
// the panel's own line, since it stays beside every tab. Links it opens in
// a new window go to a tab.
//
// Where the card goes, its gap, corners and the handle that resizes it are
// the window's layout (ContentView); what is in it is here.

enum SidePanelContent: Equatable {
    /// An extension's panel page. `tab`: the tab it was opened for, when the
    /// extension named one (setOptions with a tabId) — it goes with that tab,
    /// hidden on the others and back on it, as in Chrome. Nil: the window's.
    case page(extensionID: String, url: URL, tab: Tab.ID?)
    /// A website, in the space the window was in when it opened.
    case site(url: URL, space: UUID)
    case chat
}

/// The sites offered in View › Side Panel, as they are typed: a short list,
/// plus whatever page you are on.
enum PanelSites {
    static let offered: [(name: String, url: URL)] = [
        ("Claude", URL(string: "https://claude.ai/new")!),
        ("ChatGPT", URL(string: "https://chatgpt.com/")!),
        ("Gemini", URL(string: "https://gemini.google.com/app")!),
        ("Perplexity", URL(string: "https://www.perplexity.ai/")!),
    ]

    /// Only the web: never a file, a script or an extension's page.
    static func allowed(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }
}

extension Preferences {
    /// The side panel's width, as you last left it, within reason.
    static let sidePanelWidths: ClosedRange<CGFloat> = 300...640
    static let sidePanelStart: CGFloat = 380
}

/// What came of asking for the panel. `taken`: the panel dealt with it, up
/// or put away again. `noPanel`: none can be made in this window (a popup
/// window, a page that didn't load), and the caller opens the extension's
/// page as a tab instead, as it did before there was a panel. `notHere`:
/// the tab in front is private and the extension hasn't been let into
/// private tabs, so nothing opens at all, a tab least of all.
enum SidePanelAnswer: Equatable {
    case taken
    case noPanel
    case notHere
}

// MARK: - opening and closing

extension Browser {
    /// An extension's panel page in this window's side panel.
    @discardableResult
    func showSidePanel(_ context: WKWebExtensionContext, url: URL, for tab: Tab.ID? = nil) -> SidePanelAnswer {
        guard !isPopup else { return .noPanel }
        // An extension not let into private tabs is given nothing of one
        // (Extensions' `hidden`): no address, no title, no view to run a
        // script in. A panel of its own beside that page would be a panel
        // about a page it cannot see, so it doesn't open there.
        guard !Browser.holdsPanel(shy: panelPanes(tab).contains { $0.shy },
                                  letIn: Extensions.mayGoPrivate(context))
        else { return .notHere }
        let content = SidePanelContent.page(extensionID: context.uniqueIdentifier, url: url, tab: tab)
        guard SidePanelPages.shared.load(url, from: context, in: self) else { return .noPanel }
        if let tab { SidePanelPages.shared.bind(content, to: tab, in: self) }
        sidePanel = content
        sidePanelShown = true
        return .taken
    }

    /// The extension's button again, with its panel up: it goes, as a
    /// second press on a popup's button does.
    func toggleSidePanel(_ context: WKWebExtensionContext, url: URL, for tab: Tab.ID? = nil) -> SidePanelAnswer {
        if sidePanelShown, case .page(let id, _, _) = sidePanel, id == context.uniqueIdentifier {
            closeSidePanel()
            return .taken
        }
        return showSidePanel(context, url: url, for: tab)
    }

    /// The panel's page didn't load: it goes, and the page opens as a tab
    /// of its own instead, as before there was a panel.
    func sidePanelFailed(_ url: URL) {
        guard case .page(_, let shown, _) = sidePanel, shown == url else { return }
        closeSidePanel()
        guard (try? Extensions.mayOpen(url)) != nil else { return }
        open(url, foreground: true)
    }

    /// A website in this window's side panel, signed in as this space's tabs
    /// are (Settings › General › Websites in the side panel). The same site
    /// again closes it, as a second press on an extension's button does.
    @discardableResult
    func showSiteInPanel(_ url: URL) -> Bool {
        guard prefs.sitesInPanel, PanelSites.allowed(url), !keepsNothing else { return false }
        if sidePanelShown, case .site = sidePanel, SidePanelPages.shared.siteArrived(in: self)?.host() == url.host() {
            closeSidePanel()
            return true
        }
        if case .page(_, _, let tab?) = sidePanel { SidePanelPages.shared.unbind(tab, in: self) }
        SidePanelPages.shared.loadSite(url, space: spaceID, in: self)
        sidePanel = .site(url: url, space: spaceID)
        sidePanelShown = true
        prefs.panelSite = url.absoluteString
        return true
    }

    /// View › Side Panel › Show Side Panel: the site last there, or Claude,
    /// and closing whatever is there.
    func toggleSitePanel() {
        guard prefs.sitesInPanel else { return }
        if sidePanelShown, sidePanel != .chat { return closeSidePanel() }
        let last = URL(string: prefs.panelSite).flatMap { PanelSites.allowed($0) ? $0 : nil }
        showSiteInPanel(last ?? PanelSites.offered[0].url)
    }

    func panelStore(_ space: UUID) -> WKWebsiteDataStore {
        spaces.contains(where: { $0.id == space }) ? Spaces.store(for: space) : Store.websites
    }

    /// The tab's page into the side panel, from the tab's menu. Not a
    /// private tab's: the panel is signed in as the space is.
    func openInSidePanel(_ tab: Tab) {
        guard !tab.shy, let url = tab.address else { return }
        showSiteInPanel(url)
    }

    /// The site in the panel, as a tab of its own, and the panel closed.
    func sitePanelToTab() {
        guard case .site(let first, _) = sidePanel else { return }
        let url = SidePanelPages.shared.siteArrived(in: self) ?? first
        closeSidePanel()
        open(url, foreground: true)
    }

    /// The window went to another space: the site comes again, signed in as
    /// that space is.
    func sitePanelFollowsSpace() {
        guard case .site(let first, let space) = sidePanel, space != spaceID else { return }
        let url = SidePanelPages.shared.siteArrived(in: self) ?? first
        SidePanelPages.shared.loadSite(url, space: spaceID, in: self)
        sidePanel = .site(url: url, space: spaceID)
    }

    /// Closed: an extension's page is let go, as Chrome does.
    func closeSidePanel() {
        if case .page(_, _, let tab?) = sidePanel { SidePanelPages.shared.unbind(tab, in: self) }
        SidePanelPages.shared.drop(in: self)
        if sidePanel == .chat { ai.chatShown = false }
        sidePanelShown = false
        sidePanel = nil
    }

    /// Another tab in front: a panel opened for the tab just left goes
    /// with it, and one opened for this tab comes back. A panel whose
    /// extension may not see the tab arriving is neither of those: it is
    /// held back where it stands, which the window works out as it draws
    /// (`sidePanelHeld`).
    func sidePanelFollows(_ tab: Tab) {
        if case .page(_, _, let bound?) = sidePanel, bound != tab.id {
            SidePanelPages.shared.drop(in: self)
            sidePanelShown = false
            sidePanel = nil
        }
        sidePanelReturns(to: tab)
    }

    /// The switch in Settings > Extensions has moved for an extension: a
    /// panel bound to the tab in front comes back if it may be seen there
    /// now, and the window draws again for one let through or held back.
    /// `sidePanelHeld` is worked out, not kept, so every other way a tab
    /// comes to the front is right without knowing about the panel.
    func sidePanelPrivacyChanged() {
        if let active { sidePanelReturns(to: active) }
        revision &+= 1
    }

    /// A panel bound to this tab and not up: back, if this tab is one its
    /// extension may see.
    private func sidePanelReturns(to tab: Tab) {
        guard sidePanel == nil,
              case .page(let id, let url, _)? = SidePanelPages.shared.bound(to: tab.id, in: self),
              let context = Extensions.shared.contexts[id]
        else { return }
        showSidePanel(context, url: url, for: tab.id)
    }

    /// The panel is up and held back beside a private page: one of the
    /// pages on screen is a private tab, and its extension hasn't been let
    /// into private tabs. The window gives the panel's room to the page
    /// meanwhile, and the page in the panel is kept, so it comes back as
    /// you left it on a page the extension may see. An extension gone while
    /// its panel is up is held back too, having nothing left to say it may
    /// be there.
    var sidePanelHeld: Bool {
        _ = revision
        guard case .page(let id, _, _) = sidePanel, panelPanes().contains(where: { $0.shy })
        else { return false }
        guard let context = Extensions.shared.contexts[id] else { return true }
        return Browser.holdsPanel(shy: true, letIn: Extensions.mayGoPrivate(context))
    }

    /// The decision itself, away from a window: a private page on screen and
    /// an extension not let into private tabs hold its panel back.
    static func holdsPanel(shy: Bool, letIn: Bool) -> Bool { shy && !letIn }

    /// The pages a panel sits beside: the tab it was opened for, else the
    /// one in front, and in Split View the other half of its pair, since
    /// the panel stands beside both at once. A pair holds two tabs of the
    /// same kind today (`canSplit` asks for `first.shy == second.shy`), so
    /// the pair's half says nothing the tab in front hasn't already said;
    /// it is written on what is on screen rather than on that rule holding.
    /// `split(for:)` answers nothing while Split View is off, where a kept
    /// pair shows one page as any other tab does.
    private func panelPanes(_ tab: Tab.ID? = nil) -> [Tab] {
        guard let here = tabs.first(where: { $0.id == (tab ?? activeID) }) else { return [] }
        guard let pair = split(for: here), let other = pair.partner(of: here.id),
              let beside = tabs.first(where: { $0.id == other })
        else { return [here] }
        return [here, beside]
    }
}

// MARK: - the extension's page

/// Each window's panel page, and the panels bound to its tabs.
@MainActor
final class SidePanelPages: NSObject {
    static let shared = SidePanelPages()

    private final class Page {
        let web: WKWebView
        let delegate: NSObject
        init(web: WKWebView, delegate: NSObject) { self.web = web; self.delegate = delegate }
    }
    private var pages: [ObjectIdentifier: Page] = [:]
    private var bound: [ObjectIdentifier: [Tab.ID: SidePanelContent]] = [:]

    /// The page up in this window's panel, for SidePanelView and the bench.
    func web(in browser: Browser) -> WKWebView? { pages[ObjectIdentifier(browser)]?.web }

    /// A website's page that arrived (committed) in this window's panel: what
    /// its line names, what goes to a tab and what follows a space switch.
    /// Not where it is only on its way to.
    func siteArrived(in browser: Browser) -> URL? {
        (pages[ObjectIdentifier(browser)]?.delegate as? SitePanelDelegate)?.arrived
    }

    fileprivate func siteDelegate(in browser: Browser) -> SitePanelDelegate? {
        pages[ObjectIdentifier(browser)]?.delegate as? SitePanelDelegate
    }

    /// For the bench: the website's page as its line shows it, and how often
    /// it was made again after a crash.
    func siteReport(in browser: Browser) -> [String: Any] {
        guard let delegate = siteDelegate(in: browser) else { return [:] }
        return ["arrived": delegate.arrived?.absoluteString ?? "", "line": SidePanelContentView.host(delegate.arrived),
                "reloads": delegate.reloads, "gaveUp": delegate.gaveUp]
    }

    /// For the bench: WebKit's word that the page's process is gone, as a
    /// crash gives it.
    func siteCrashed(in browser: Browser) {
        guard let page = pages[ObjectIdentifier(browser)], let delegate = page.delegate as? SitePanelDelegate else { return }
        delegate.webViewWebContentProcessDidTerminate(page.web)
    }

    func load(_ url: URL, from context: WKWebExtensionContext, in browser: Browser) -> Bool {
        let key = ObjectIdentifier(browser)
        // The same page already up: left as it is.
        if let page = pages[key], page.web.url == url { return true }
        drop(in: browser)
        guard let configuration = context.webViewConfiguration else { return false }
        // No window opens from the panel without a click.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 600), configuration: configuration)
        let delegate = PanelDelegate(browser: browser, base: context.baseURL, first: url)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsMagnification = true
        web.isInspectable = true
        web.load(URLRequest(url: url))
        pages[key] = Page(web: web, delegate: delegate)
        return true
    }

    /// A website, in a page made as a tab's is in `space` (Web.configuration):
    /// its store, its user agent, extensions where tabs have them. Never a
    /// private tab's store. No window opens from it without a click.
    func loadSite(_ url: URL, space: UUID, in browser: Browser) {
        drop(in: browser)
        let configuration = Web.configuration(space: space, store: browser.panelStore(space))
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 380, height: 600), configuration: configuration)
        let delegate = SitePanelDelegate(browser: browser)
        delegate.watch(web)
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsMagnification = true
        web.allowsBackForwardNavigationGestures = true
        // The Web Inspector as for a tab, by the same rule (Web.inspectable).
        Web.inspectable(web)
        web.load(URLRequest(url: url))
        pages[ObjectIdentifier(browser)] = Page(web: web, delegate: delegate)
    }

    func drop(in browser: Browser) {
        guard let page = pages.removeValue(forKey: ObjectIdentifier(browser)) else { return }
        page.web.stopLoading()
        page.web.navigationDelegate = nil
        page.web.uiDelegate = nil
        page.web.removeFromSuperview()
    }

    func bind(_ content: SidePanelContent, to tab: Tab.ID, in browser: Browser) {
        bound[ObjectIdentifier(browser), default: [:]][tab] = content
    }

    func unbind(_ tab: Tab.ID, in browser: Browser) {
        bound[ObjectIdentifier(browser)]?[tab] = nil
    }

    func bound(to tab: Tab.ID, in browser: Browser) -> SidePanelContent? {
        bound[ObjectIdentifier(browser)]?[tab]
    }

    /// An extension gone: its panels with it.
    func forget(_ id: String) {
        for browser in Browsers.all {
            if case .page(let shown, _, _) = browser.sidePanel, shown == id { browser.closeSidePanel() }
            bound[ObjectIdentifier(browser)] = bound[ObjectIdentifier(browser)]?.filter {
                if case .page(let owner, _, _) = $0.value { return owner != id }
                return true
            }
        }
    }
}

/// A website in the panel: its own pages stay in it, a window it opens goes
/// to a tab, only on a click, and nothing but the web loads in it. It never
/// gets the camera, the microphone or the screen: it stays beside every tab,
/// so nobody could tell which page is listening.
@MainActor
@Observable
final class SitePanelDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    @ObservationIgnored weak var browser: Browser?
    init(browser: Browser) { self.browser = browser }

    /// The page that arrived: set when a main-frame navigation commits, and
    /// as the address moves inside the same site (a link the page handles
    /// itself, history.pushState). A page only asked for, or on its way,
    /// leaves it as it was, so the line never names a site not yet there.
    private(set) var arrived: URL?
    @ObservationIgnored private var watching: NSKeyValueObservation?

    func watch(_ web: WKWebView) {
        watching = web.observe(\.url, options: [.new]) { [weak self] web, _ in
            let now = web.url
            DispatchQueue.main.async {
                guard let self, let now, let was = self.arrived, Self.sameSite(now, was) else { return }
                self.arrived = now
            }
        }
    }

    static func sameSite(_ a: URL, _ b: URL) -> Bool {
        a.scheme?.lowercased() == b.scheme?.lowercased() && a.host()?.lowercased() == b.host()?.lowercased() && a.port == b.port
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        arrived = webView.url
    }

    /// Crashes in a row: the page is made again twice a minute at most, then
    /// left as it is (the panel's line still closes it or opens it in a tab).
    @ObservationIgnored private var crashes: [Date] = []

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { return decisionHandler(.cancel) }
        guard navigationAction.targetFrame?.isMainFrame == true else { return decisionHandler(.allow) }
        let url = navigationAction.request.url
        if PanelSites.allowed(url) || url?.scheme?.lowercased() == "about" { return decisionHandler(.allow) }
        decisionHandler(.cancel)
    }

    /// A link to a new window: a tab, after a click in the panel.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if PanelSites.allowed(navigationAction.request.url), let url = navigationAction.request.url {
            browser?.open(url, foreground: true)
        }
        return nil
    }

    /// No camera, no microphone.
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }

    /// No screen sharing: answered here, as no (0), so WebKit never shows
    /// its picker for the panel.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        decisionHandler(0)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        let now = Date()
        crashes = crashes.filter { now.timeIntervalSince($0) < 60 } + [now]
        guard crashes.count <= 2 else { return }
        reloads += 1
        webView.reload()
    }

    /// How many times the page was made again, for the bench.
    @ObservationIgnored private(set) var reloads = 0
    var gaveUp: Bool { crashes.count > 2 }
}

/// The panel page's own delegate: a link it opens elsewhere goes to a tab,
/// its camera and microphone are asked for as any extension page's are, and
/// recording the screen is Search's own call only (see ExtensionCapture).
@MainActor
private final class PanelDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var browser: Browser?
    /// The extension's own pages, the only ones the panel itself shows.
    let base: URL
    /// The touch a tab was last opened for: one click, one tab, whatever a
    /// script does with it in the second after.
    private var usedTouch: Date?
    /// The page the panel was opened on, a tab's if it fails to load.
    let first: URL
    /// The first page came up: a failure after it is the page's own.
    private var loaded = false
    init(browser: Browser, base: URL, first: URL) { self.browser = browser; self.base = base; self.first = first }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded = true }

    /// The panel's page never came up (a missing file, a page WebKit
    /// refuses): it opens as a tab instead, as it did before the panel.
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fellThrough(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fellThrough(error)
    }

    private func fellThrough(_ error: Error) {
        // Cancelled is the panel's own doing (a link sent to a tab, a
        // download refused), not a page that failed.
        guard !loaded, (error as NSError).code != NSURLErrorCancelled,
              (error as NSError).code != 102 // WebKitErrorFrameLoadInterruptedByPolicyChange
        else { return }
        loaded = true
        // After WebKit's turn: this delegate goes with the page it drops.
        let url = first
        DispatchQueue.main.async { [weak browser] in browser?.sidePanelFailed(url) }
    }

    /// Its web process gone: the page is made again where it was.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if loaded { webView.reload() } else { fellThrough(NSError(domain: "Search", code: 1)) }
    }

    /// The same rule as tabs.create and a popup's links: never a file on
    /// this Mac, never javascript:.
    private func openInTab(_ url: URL?) {
        guard let url, (try? Extensions.mayOpen(url)) != nil, let browser else { return }
        browser.open(url, foreground: true)
    }

    /// One of this extension's pages.
    private func own(_ url: URL) -> Bool {
        url.scheme?.lowercased() == base.scheme?.lowercased() && url.host?.lowercased() == base.host?.lowercased()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openInTab(navigationAction.request.url)
        return nil
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let browser else { return decisionHandler(.deny) }
        browser.askedForCapture(webView, origin: origin, frame: frame, type: type, decisionHandler: decisionHandler)
    }

    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func displayCapture(_ web: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, systemAudio: Bool,
                        decisionHandler: @escaping (Int) -> Void) {
        decisionHandler(ExtensionCapture.shared.displayDecision(for: web))
    }

    /// A download the panel starts is the browser's, as from any page. The
    /// panel itself only ever shows the extension's own pages: it has no
    /// address to read, and stays beside every tab, so a website in it would
    /// be a page nobody can tell the address of. A site the panel goes to
    /// opens in a tab instead. Frames inside the page are the page's business
    /// (ChatGPT's and Claude's panels show their site in one).
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload { return decisionHandler(.cancel) }
        guard navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url else {
            return decisionHandler(.allow)
        }
        if own(url) { return decisionHandler(.allow) }
        // A blank document, only as the extension's own page asks for one.
        if url.scheme?.lowercased() == "about",
           let from = navigationAction.sourceFrame.request.url, own(from) {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        // Into a tab only for a link followed or a form sent by a hand: a
        // real click or key in the panel this last second (a script's own
        // element.click() counts as a link too). A page setting `location`
        // over and over by itself would otherwise fill the window with tabs.
        guard [.linkActivated, .formSubmitted].contains(navigationAction.navigationType),
              let touch = base.host.flatMap({ Extensions.touched[$0] }),
              Date().timeIntervalSince(touch) < 1, touch != usedTouch
        else { return }
        usedTouch = touch
        openInTab(url)
    }
}

// MARK: - what the card shows

final class SidePanelContentView: NSView {
    let browser: Browser
    private let line = NSView()
    private let icon = NSImageView()
    private let name = KitLabel("", font: .systemFont(ofSize: 13, weight: .semibold))
    private let toTab: DoorView
    private let close: DoorView
    private let rule = KitBox(fill: KitColor.hairline)
    private let holder = NSView()
    private var watch: AnyCancellable?
    private var seen: AnyCancellable?
    private weak var seenDelegate: SitePanelDelegate?
    private var chat: ChatColumnView?

    static let lineHeight: CGFloat = 26 + 16

    init(browser: Browser) {
        self.browser = browser
        toTab = DoorView(icon: "arrow.up.forward.square", help: "Open in a New Tab", act: {})
        close = DoorView(icon: "xmark", help: "Close", act: {})
        super.init(frame: .zero)
        toTab.act = { [weak browser] in browser?.sitePanelToTab() }
        close.act = { [weak browser] in browser?.closeSidePanel() }
        icon.imageScaling = .scaleProportionallyUpOrDown
        for view in [icon, name, toTab, close] as [NSView] { line.addSubview(view) }
        for view in [line, rule, holder] as [NSView] { addSubview(view) }
        watch = kitObserve({ [weak browser] in (browser?.sidePanel, Extensions.shared.contexts.count) }) { [weak self] _ in self?.refresh() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func refresh() {
        switch browser.sidePanel {
        case .page(let id, _, _):
            icon.image = Extensions.shared.contexts[id]?.webExtension.icon(for: CGSize(width: 16, height: 16))
            icon.isHidden = icon.image == nil
            name.text = Browser.extensionName(id)
            name.overflow = .tail
            toTab.isHidden = true
            follow(nil)
        case .site:
            icon.isHidden = true
            toTab.isHidden = false
            name.overflow = .middle
            follow(SidePanelPages.shared.siteDelegate(in: browser))
        case .chat:
            follow(nil)
        case nil:
            follow(nil)
        }
        let chatting = browser.sidePanel == .chat
        if chatting, chat == nil {
            let made = ChatColumnView(browser: browser)
            addSubview(made)
            chat = made
        } else if !chatting, let shown = chat {
            shown.removeFromSuperview()
            chat = nil
        }
        line.isHidden = browser.sidePanel == nil || chatting
        rule.isHidden = browser.sidePanel == nil || chatting
        place(browser.sidePanel == nil || chatting ? nil : SidePanelPages.shared.web(in: browser))
        needsLayout = true
    }

    private func follow(_ delegate: SitePanelDelegate?) {
        guard delegate !== seenDelegate || (delegate == nil) != (seen == nil) else { return }
        seenDelegate = delegate
        seen = delegate.map { delegate in
            kitObserve({ [weak delegate] in delegate?.arrived }) { [weak self] url in
                self?.name.text = SidePanelContentView.host(url)
                self?.needsLayout = true
            }
        }
    }

    nonisolated static func host(_ url: URL?) -> String {
        guard let url, let host = url.host() else { return "" }
        return Address.withoutWWW(host) + (url.scheme?.lowercased() == "http" ? ", not secure" : "")
    }

    private func place(_ web: WKWebView?) {
        guard let web else {
            holder.subviews.forEach { $0.removeFromSuperview() }
            return
        }
        guard web.superview !== holder else { return }
        holder.subviews.forEach { $0.removeFromSuperview() }
        web.removeFromSuperview()
        web.frame = holder.bounds
        web.autoresizingMask = [.width, .height]
        holder.addSubview(web)
    }

    override func layout() {
        super.layout()
        chat?.frame = bounds
        let lineHeight = Self.lineHeight
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: lineHeight)
        rule.frame = NSRect(x: 0, y: lineHeight, width: bounds.width, height: 1)
        holder.frame = NSRect(x: 0, y: lineHeight + 1, width: bounds.width, height: max(0, bounds.height - lineHeight - 1))
        let side: CGFloat = 26
        var right = bounds.width - 12
        close.frame = NSRect(x: right - side, y: 8, width: side, height: side)
        right -= side + 8
        if !toTab.isHidden {
            toTab.frame = NSRect(x: right - side, y: 8, width: side, height: side)
            right -= side + 8
        }
        var x: CGFloat = 12
        if !icon.isHidden {
            icon.frame = NSRect(x: x, y: (lineHeight - 14) / 2, width: 14, height: 14)
            x += 14 + 8
        }
        let size = name.measure(width: max(0, right - x))
        name.frame = kitSnap(NSRect(x: x, y: (lineHeight - size.height) / 2, width: min(size.width, max(0, right - x)), height: size.height))
    }
}

final class SidePanelBesideView: NSView {
    let browser: Browser
    var onLeft = false { didSet { if onLeft != oldValue { needsLayout = true } } }
    var card = false { didSet { if card != oldValue { restyle() } } }
    var width: CGFloat = 320 { didSet { if width != oldValue { invalidateIntrinsicContentSize(); needsLayout = true } } }

    private let shade = NSView()
    private let content: SidePanelContentView
    private let hairline = KitBox(fill: KitColor.hairline)
    private let handle: PanelEdgeHandle
    private var lookWatch: AnyCancellable?
    private var chatWatch: AnyCancellable?

    init(browser: Browser) {
        self.browser = browser
        content = SidePanelContentView(browser: browser)
        handle = PanelEdgeHandle(prefs: browser.prefs)
        super.init(frame: .zero)
        shade.wantsLayer = true
        content.wantsLayer = true
        for view in [shade, content, hairline, handle] as [NSView] { addSubview(view) }
        restyle()
        lookWatch = kitObserve(initial: false, distinct: true, { [weak browser] in browser?.pageLook(in: nil) }) { [weak self] _ in
            self?.needsLayout = true
        }
        chatWatch = kitObserve({ [weak browser] in browser?.sidePanel == .chat }) { [weak self] chatting in
            self?.handle.isHidden = chatting
        }
    }

    var edgeInk: NSColor { PaneEdge.ink(browser.pageLook(in: nil), dark: kitDark) }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var edgeWidth: CGFloat { card ? Metrics.cardGap : 1 }

    override var intrinsicContentSize: NSSize { NSSize(width: width + edgeWidth, height: NSView.noIntrinsicMetric) }

    private func restyle() {
        guard let layer = content.layer, let shaded = shade.layer else { return }
        layer.backgroundColor = Palette.NS.ground.cgColor
        layer.cornerCurve = .continuous
        layer.cornerRadius = card ? Metrics.pageRadius : 0
        layer.masksToBounds = true
        layer.borderWidth = card ? PaneEdge.width : 0
        layer.borderColor = edgeInk.cgColor
        shaded.shadowColor = NSColor.black.cgColor
        shaded.shadowOpacity = card ? Swift.Float(CardEdge.shadow) : 0
        shaded.shadowRadius = 3
        shaded.shadowOffset = CGSize(width: 0, height: -1)
        hairline.isHidden = card
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { restyle() }
    }

    override func layout() {
        super.layout()
        handle.onLeft = onLeft
        let edge = edgeWidth
        let panelX = onLeft ? 0 : edge
        let edgeX = onLeft ? width : 0
        let panel = NSRect(x: panelX, y: 0, width: width, height: bounds.height)
        content.frame = panel
        shade.frame = panel
        effectiveAppearance.performAsCurrentDrawingAppearance {
            shade.layer?.shadowPath = card ? CGPath(roundedRect: shade.bounds, cornerWidth: Metrics.pageRadius,
                                                      cornerHeight: Metrics.pageRadius, transform: nil) : nil
            content.layer?.backgroundColor = Palette.NS.ground.cgColor
            content.layer?.borderColor = edgeInk.cgColor
        }
        hairline.frame = NSRect(x: edgeX, y: 0, width: 1, height: bounds.height)
        handle.frame = card ? NSRect(x: edgeX, y: 0, width: edge, height: bounds.height)
            : NSRect(x: edgeX + 0.5 - 3.5, y: 0, width: 7, height: bounds.height)
    }
}

final class PanelEdgeHandle: KitHoverView {
    let prefs: Preferences
    var onLeft = false
    private let pill = KitBox(fill: KitColor.faint, corners: .capsule)
    private var start: (width: CGFloat, x: CGFloat)?

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init(frame: .zero)
        pill.alphaValue = 0
        addSubview(pill)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var lit: Bool { hovering || start != nil }

    override func layout() {
        super.layout()
        place(animated: false)
    }

    private func place(animated: Bool) {
        let height = lit ? Grip.lit : Grip.rest
        let frame = NSRect(x: (bounds.width - Grip.width) / 2, y: (bounds.height - height) / 2, width: Grip.width, height: height)
        let apply = {
            self.pill.frame = frame
            self.pill.alphaValue = self.lit ? 1 : 0
            self.pill.fill = self.lit ? KitColor.muted : KitColor.faint
        }
        if animated, !Motion.reduced {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func hoverChanged() { place(animated: true) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            prefs.sidePanelWidth = Preferences.sidePanelStart
            return
        }
        start = (prefs.sidePanelWidth, event.locationInWindow.x)
        place(animated: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let moved = event.locationInWindow.x - start.x
        prefs.sidePanelWidth = start.width + (onLeft ? moved : -moved)
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
        place(animated: true)
    }
}
