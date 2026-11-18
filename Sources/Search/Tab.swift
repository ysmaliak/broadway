import Combine
import Observation
import ImageIO
import WebKit

// One web view per tab, kept alive for as long as the tab is. Switching tabs
// takes the old view out of the window and puts the new one in — the page does
// not reload, does not lose its scroll position, and does not forget what you
// typed into it. That is the whole trick behind switching feeling instant.
//
// Kept alive, that is, while it is worth what it costs. A tab nobody has
// looked at for hours gives its view back (see `sleep(picture:)`) and
// keeps what it takes to come back exactly where it was.

enum Web {
    /// Where Search's own page scripts run, and where their messages come
    /// from: a world of their own beside the page's. They see the same page,
    /// and the page sees none of them — no variable of theirs, and no
    /// `window.webkit`, which Safari never shows a page and which sites read
    /// as an app's embedded web view rather than a browser. Google answered
    /// that with a CAPTCHA every few searches, and refused sign-ins as "not
    /// secure" (24 Sep 2026). Only Search's passkey patch has to stand in
    /// the page's own world, and nothing there leads back to it.
    @MainActor static let world = WKContentWorld.world(name: "Search")

    /// Every handler of Search's taken off a controller: in its own world,
    /// and in the page's, where they all were before 24 Sep 2026 — a tab
    /// opened by a link inherits its opener's configuration, handlers
    /// included, and registering a name twice is a hard crash.
    @MainActor static func release(_ controller: WKUserContentController) {
        for name in [ScrollRelay.name, VeilRelay.name, FormRelay.name, ImageRelay.name, MediaKeys.name,
                     StoreRelay.name, PasskeyRelay.name, MiddleRelay.name, IconRelay.name, PopupGestureRelay.name, DuskRelay.name,
                     TranslateRelay.name, FormFieldScript.relay, DevRelay.name, JSONRelay.name, PullPageRelay.name, Resume.name,
                     VideoDefaults.name] {
            controller.removeScriptMessageHandler(forName: name, contentWorld: world)
            controller.removeScriptMessageHandler(forName: name, contentWorld: .page)
        }
        controller.removeScriptMessageHandler(forName: HoveredLink.name, contentWorld: .defaultClient)
    }

    /// What every view says it is after "AppleWebKit … (KHTML, like Gecko)"
    /// — web tabs and extension views alike (see Extensions.init).
    ///
    /// The version is the Safari this Mac has, since its WebKit is the one
    /// every tab runs on. A fixed number went out of date with every macOS:
    /// a page told "Safari 26" by an engine that is Safari 18 sends what the
    /// engine can't run.
    static let userAgentName = "Version/\(safariVersion) Safari/605.1.15"

    private static var safariVersion: String {
        for path in ["/System/Cryptexes/App/System/Applications/Safari.app", "/Applications/Safari.app"] {
            if let version = Bundle(path: path)?.infoDictionary?["CFBundleShortVersionString"] as? String {
                return version
            }
        }
        // Safari can't be read: say the Safari this macOS shipped with, the
        // oldest its WebKit can be. Under-claiming gets a page older code
        // that still runs; over-claiming is what this avoids.
        //
        // This hardly ever runs. Safari can't be removed from modern macOS,
        // so reading the installed Safari above should always work. The
        // formula only matters if that read fails.
        //
        return "\(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).0"
    }

    /// One pool for every tab. The property is deprecated and said to do
    /// nothing now, but a configuration without it gets a pool of its own
    /// when its view is made — so every new tab started a web process from
    /// cold, fonts registered and all, on the main thread, before its page
    /// could begin: 41 to 59 ms from a bookmark or Return to the load
    /// starting, the window stuck meanwhile. Sharing one lets WebKit have
    /// the next process ready: 9 to 10 ms, for the same memory and the same
    /// number of processes (measured with ./bench bookmark URL new, 24 Sep 2026).
    /// It also carries Search's geolocation provider (see SiteLocation),
    /// which asks macOS nothing until a page you allowed wants a position.
    static let pool: WKProcessPool = {
        let pool = PreferredLanguages.launchPool()
        SiteLocation.provide(pool)
        return pool
    }()

    /// `space`: the space the tab belongs to, when it is not the one on
    /// screen — a parked row made ahead of time (see Spaces.swift).
    /// `store`: a shy tab's own, for one opened from it — a link followed
    /// out of a private page is still signed in to whatever that page was.
    static func configuration(shy: Bool = false, space: UUID? = nil, store: WKWebsiteDataStore? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        // The real store, not the ephemeral one: staying signed in between
        // launches is the difference between a browser and a preview pane. A
        // shy tab gets its own store, which exists only while it does — its own
        // cookies, its own sign-ins, and nothing left behind when it closes.
        // With spaces on, each space's tabs share a store of that space's.
        config.websiteDataStore = store ?? (shy ? .nonPersistent() : MainActor.assumeIsolated { Spaces.store(for: space ?? Spaces.current) })
        // Web notifications go through the store (see Notifications.swift);
        // a private tab's is left without, and a page there is refused.
        if !shy { let kept = config.websiteDataStore; MainActor.assumeIsolated { SiteNotifications.shared.attach(kept) } }
        config.processPool = Web.pool
        // A test run's pretend camera and microphone (see ExtensionCapture).
        if Store.testing { ExtensionCapture.mockDevices(config.preferences) }
        // Chrome extensions see every page but a private one, unless Settings
        // › Extensions lets one in, and WebKit then lets in only that one.
        // The controller has to be there when the view is made; it can't be
        // added after.
        MainActor.assumeIsolated {
            if !shy || Extensions.shared.contexts.values.contains(where: \.hasAccessToPrivateData) { Extensions.attach(config) }
        }

        // Left alone, WKWebView says only "AppleWebKit … (KHTML, like Gecko)" —
        // no browser, no version. Google reads that as something it doesn't
        // recognise and serves the stripped-back page from a decade ago:
        // no side panel, no dark mode, none of the modern tabs. Naming a
        // version turns it into the same string Safari sends, and the modern
        // page comes back.
        config.applicationNameForUserAgent = Web.userAgentName
        config.allowsAirPlayForMediaPlayback = true
        // Off by default on macOS, which is why a full-screen button on a video
        // did nothing at all: the page asks, and WebKit refuses without a word.
        config.preferences.isElementFullscreenEnabled = true
        // WebKit's synchronous popup check rejects async POST sign-ins.
        // The UI delegate instead consumes a recent trusted interaction
        // recorded in Search's isolated world (see PopupGesture.swift).
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        // Sound waits for a click, as everywhere; video too when Settings
        // says videos wait (Never Auto-Play, in Safari's words).
        config.mediaTypesRequiringUserActionForPlayback = Web.playback
        MainActor.assumeIsolated {
            PrivacySignal.apply(to: config, shy: shy)
            ClickIDs.apply(to: config.preferences, shy: shy)
        }
        if Store.testing, !Store.measuring { config.preferences.inactiveSchedulingPolicy = .none }
        inspector(config.preferences)
        NativePiP.allow(config.preferences)
        return config
    }

    /// What a page may not play until it is clicked or a key pressed: sound,
    /// and video as well with Settings › General › Videos wait for a click.
    static var playback: WKAudiovisualMediaTypes {
        Store.settings.bool(forKey: Preferences.waitsKey) ? .all : .audio
    }

    /// Every page view there is, for the bench.
    @MainActor static let pages = NSHashTable<PageView>.weakObjects()

    /// WebKit's "developer extras": Inspect Element in a page's right-click
    /// menu, and the Web Inspector the View menu opens (see Inspector.swift).
    /// isInspectable alone only lets Safari's Develop menu reach the page.
    /// The name is outside the public framework, so it is asked first.
    /// A page the Web Inspector reaches, as every tab's is: Safari's Develop
    /// menu and Inspect Element both. The side panel's website follows the
    /// same rule through this.
    @MainActor static func inspectable(_ web: WKWebView) {
        web.isInspectable = true
        inspector(web.configuration.preferences)
    }

    static func inspector(_ preferences: WKPreferences, on: Bool = true) {
        let set = NSSelectorFromString("_setDeveloperExtrasEnabled:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, on)
    }
}

/// WKWebView can pause a page's media, but not mute it and let it keep
/// playing, the one thing a tab's own speaker does everywhere else. WebKit
/// has that mute one call down from the public framework: the one Safari's
/// own tabs use, the page's JavaScript none the wiser. The names are asked
/// for first, the way `inspector(_:on:)` above asks, and a WebKit without
/// them leaves the tab heard rather than falling over.
enum Muter {
    /// `_mediaMutedState` is a bitmask. Its low bit is the page's own
    /// sound, the only one a tab's speaker should touch: the others are the
    /// camera and the microphone, someone else's to turn off.
    static func set(_ muted: Bool, on web: WKWebView) {
        let get = NSSelectorFromString("_mediaMutedState")
        let set = NSSelectorFromString("_setPageMuted:")
        guard web.responds(to: get), web.responds(to: set) else { return }
        typealias Read = @convention(c) (AnyObject, Selector) -> UInt
        typealias Write = @convention(c) (AnyObject, Selector, UInt) -> Void
        let state = unsafeBitCast(web.method(for: get), to: Read.self)(web, get)
        unsafeBitCast(web.method(for: set), to: Write.self)(web, set, muted ? state | 1 : state & ~UInt(1))
    }
}

/// Sites you let play sound by themselves, from the site card: Safari's
/// per-site Allow All Auto-Play (#223). Every other site keeps the default,
/// sound waiting for a click. Remembered for the site, as its zoom is, and
/// never from a private tab. Settings › Videos wait for a click wins: with
/// it on, no site plays by itself.
///
/// WebKit takes it for each page as it loads, through the page's own
/// preferences, under a name outside the public framework — asked for
/// first, as `Muter` asks, so a WebKit without it only leaves the site
/// waiting for a click. Its values, checked on macOS 26: 0 the default,
/// 1 allow, 2 allow without sound, 3 deny. Allow lets video play whatever
/// `mediaTypesRequiringUserActionForPlayback` says, which is why the
/// global switch is asked here and not left to that.
enum Autoplay {
    private static func key(_ host: String) -> String { "autoplay." + host }

    static func allowed(_ host: String) -> Bool {
        Store.settings.bool(forKey: key(host))
    }

    /// Off keeps nothing, as a site at the usual zoom keeps nothing.
    static func set(_ on: Bool, for host: String) {
        if on {
            Store.settings.set(true, forKey: key(host))
        } else {
            Store.settings.removeObject(forKey: key(host))
        }
    }

    /// For a page about to load at `url`, in a view made with `made`:
    /// allowed to play, held to what Settings › Videos wait for a click says
    /// now, or left alone. WebKit fixes `made` when the view is made, so a
    /// tab open before the switch moved — and a link opened from it, with a
    /// copy of its configuration — kept the old answer until it slept: with
    /// the switch off again, its videos still waited for a click. The page's
    /// own policy says what the switch says instead, from its next load.
    static func apply(to preferences: WKWebpagePreferences, for url: URL, shy: Bool, agent: Bool = false,
                      made: WKAudiovisualMediaTypes) {
        let waits = Store.settings.bool(forKey: Preferences.waitsKey)
        guard let policy = policy(for: url, shy: shy, agent: agent, waits: waits, made: made, allowed: allowed) else { return }
        let set = NSSelectorFromString("_setAutoplayPolicy:")
        guard preferences.responds(to: set) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(preferences.method(for: set), to: Setter.self)(preferences, set, policy)
    }

    static func policy(for url: URL, shy: Bool, agent: Bool, waits: Bool, made: WKAudiovisualMediaTypes,
                       allowed: (String) -> Bool) -> Int? {
        if CallSound.plays(url, agent: agent) { return 1 }
        if !waits, !shy, let host = url.host(), allowed(host) { return 1 }
        if waits, !made.contains(.video) { return 3 }
        if !waits, made.contains(.video) { return 2 }
        return nil
    }
}

@MainActor
@Observable
final class Tab: Identifiable {

    let id = UUID()

    static let letGo = NSHashTable<WKWebView>.weakObjects()

    /// The page. Built the first time anyone asks for it, not when the tab
    /// is — a session of twenty tabs coming back is twenty objects, not
    /// twenty web views and their processes fighting the first frame.
    var web: PageView {
        if let built { return built }
        let view = build()
        built = view
        return view
    }
    /// The web view if there is one yet, for the callers that must not be
    /// the reason there is.
    @ObservationIgnored private(set) var built: PageView?
    @ObservationIgnored private var configuration: WKWebViewConfiguration
    let extensionReturn = ExtensionReturnNavigation()

    /// Whether its page was made with the extension controller in it — every
    /// ordinary tab, and a private one only when extensions were allowed
    /// there as it was made (a controller can't be added to a page later).
    var carriesExtensions: Bool { configuration.webExtensionController != nil }
    /// Where its cookies and sign-ins are kept.
    var store: WKWebsiteDataStore { configuration.websiteDataStore }
    /// Whoever handles navigation and windows for this page; applied when
    /// the page is built, whenever that is.
    @ObservationIgnored weak var delegate: (WKNavigationDelegate & WKUIDelegate)? {
        didSet {
            built?.navigationDelegate = delegate
            built?.uiDelegate = uiDelegate(delegate)
        }
    }
    /// An extension's page answers WebKit's question about recording the
    /// screen itself (see ExtensionCapture); held here, as WebKit doesn't.
    @ObservationIgnored private var pageDelegate: NSObject?

    private func uiDelegate(_ delegate: (WKNavigationDelegate & WKUIDelegate)?) -> WKUIDelegate? {
        guard let pages = MainActor.assumeIsolated({ Extensions.pages }),
              configuration.userContentController === pages else { return delegate }
        let made = pageDelegate as? ExtensionPageDelegate ?? ExtensionPageDelegate()
        made.next = delegate
        pageDelegate = made
        return made
    }
    /// The stylesheet a page not yet built is to be armed with.
    @ObservationIgnored private var veils = ""

    private(set) var title = ""
    private(set) var heading: TabHeading = .blank
    @ObservationIgnored private var hinted = false
    @ObservationIgnored private var settle = TitleSettle()
    @ObservationIgnored private var settleWork: DispatchWorkItem?
    @ObservationIgnored private(set) var origin: URL?
    @ObservationIgnored var knowsTitle: ((URL) -> String?)?
    @ObservationIgnored private var lastLink: (href: String, words: String, at: Date)?
    private(set) var address: URL?
    /// The address of the page that is actually on screen. `address` moves
    /// to where the tab is going as soon as a load starts, while the page
    /// and its certificate are still the old one's: what is said about the
    /// connection, and which passwords a sign-in box is offered, go by this
    /// one, set when the new page has arrived.
    private(set) var committed: URL?
    /// The view has drawn its first frame; until then the peek shows its
    /// skeleton (see PeekSkeleton). True from the start on a WebKit that
    /// doesn't say when.
    private(set) var painted = false
    var pageAddress: URL? { committed ?? address }
    /// What the tab says at rest about where its page is (AtRest.swift):
    /// the document that arrived, never one only on its way. A page that
    /// opened this tab can write into it while the address it asked for is
    /// still loading, and that address must not vouch for what it wrote.
    /// A tab with no view (asleep, restored) has only its address to say.
    var restAddress: URL? { built == nil ? address : committed }

    func didCommit() {
        retryCommitted()
        fileClicks.committed()
        fileTyped = false
        if stuck.asked != nil { StuckRules.committed(&stuck) }
        settle.committed(at: CACurrentMediaTime())
        scheduleSettle()
        devLog.clear()
        fieldRelay.forgetAll()
        popupGesture.clear()
        // What the old page was refused went with it.
        if !blockedPopups.isEmpty { blockedPopups = [] }
        // A translated page is gone; its frames with it.
        if translator != nil || translation != nil || !translateFrames.isEmpty { translationGone(sleeping: false) }
        // A new document: whatever the old one waited for under its field
        // went with it.
        if let built { Passkeys.shared.forget(built) }
        // about:blank too: a document another page wrote into (an opener
        // sending its window there, then writing) is that page's, not the
        // one before it, and is offered nothing that belonged to it.
        if let url = built?.url { committed = url }
        if !ClickedWindow.blank(built?.url) { shownPage = true }
        dropFillMarks()
        // A page arrived after all: the address is its own again.
        if held != nil, let url = built?.url, url.absoluteString != "about:blank" {
            held = nil
            address = url
        }
    }

    /// An address the tab shows, and reports to extensions, without loading
    /// it (see ExtensionAuth.handOver). The page on screen stays. WebKit
    /// going back to that page's address as the cancelled load unwinds is not
    /// a move, so the observer below lets it pass. The page is WebKit's own
    /// current item, not `committed`, which a same-site load in progress has
    /// already moved on.
    @ObservationIgnored private(set) var held: URL?
    @ObservationIgnored private var heldOver: URL?

    func hold(_ url: URL) {
        held = url
        heldOver = built?.backForwardList.currentItem?.url
        address = url
        failure = nil
    }
    private(set) var progress: Double = 0
    private(set) var loading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// Set when the page never arrived — no host, no network, a refused
    /// connection. Shown in place of the page rather than in a dialog.
    var failure: String?
    @ObservationIgnored var retry = LoadRetry()
    @ObservationIgnored var fileClicks = FileClicks()
    @ObservationIgnored var fileTyped = false
    /// The site's icon, for tabs set to wear one. From the cache the moment
    /// the tab has an address, and from the page a moment after it loads.
    private var siteIcon: NSImage?
    var customIcon: TabIcon?
    var icon: NSImage? {
        get { customIcon?.image ?? siteIcon ?? (Self.bareHost(address) ? Self.networkMark : nil) }
        set { siteIcon = newValue }
    }

    static let networkMark: NSImage? = KitGlyph.plain("network")

    static func bareHost(_ address: URL?) -> Bool {
        guard let address, ["http", "https"].contains(address.scheme?.lowercased()),
              var host = address.host(percentEncoded: false)?.lowercased() else { return false }
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host.contains(":") { return host.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isASCII) && part.allSatisfy(\.isNumber) && (Int(part) ?? 256) <= 255
        }
    }

    /// The letter a pinned tab is reduced to, and what a tab shows in place of
    /// an icon it doesn't have yet.
    var monogram: String {
        if let page { return String(page.title.prefix(1)) }
        // A file on this Mac has no host: its name's first letter.
        if let address, address.isFileURL {
            let name = address.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/."))
            return name.first.map { String($0).uppercased() } ?? "•"
        }
        let host = address?.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
        return host.first.map { String($0).uppercased() } ?? "•"
    }

    func adoptIcon() {
        if let page {
            icon = page.glyph
            return
        }
        icon = Favicons.shared.cached(for: address, shy: shy)
    }

    /// True while the caret is in something on the page that takes typing.
    var typing = false
    /// True while the page has taken over the screen: from the moment
    /// WebKit has the page in its own full-screen window until it starts
    /// giving it back (see the fullscreenState watch in `build`), so the
    /// window's chrome steps aside and comes back while that window covers
    /// ours, and the page comes home once, at its own size.
    var immersed = false

    /// True while this tab's page is out in the little window.
    var floating = false

    /// A sideways swipe in progress, for the disc that shows it.
    var pull: Pull?

    @ObservationIgnored var leave: ((Bool) -> Bool)?

    /// What a site opens at until you zoom it yourself: Settings › General ›
    /// Page zoom. Read from the file, not from the one object the window holds.
    static var defaultZoom: CGFloat {
        CGFloat(Store.settings.object(forKey: "pageZoom") as? Double ?? 1)
    }

    /// Remembered for the site, not for the tab: setting a paper's type to
    /// 125% once should be the last time you think about it. A site at the
    /// size every site starts at keeps nothing, and follows that size.
    func rememberZoom() {
        guard let host = address?.host(), !shy else { return }
        if abs(zoom - Tab.defaultZoom) < 0.01 {
            Store.settings.removeObject(forKey: "zoom." + host)
        } else {
            Store.settings.set(Double(zoom), forKey: "zoom." + host)
        }
    }

    func applyRememberedZoom() {
        guard let host = address?.host() else { return }
        let kept = (Store.settings.object(forKey: "zoom." + host) as? Double).map { CGFloat($0) }
            ?? Tab.defaultZoom
        guard abs(kept - web.pageZoom) > 0.004 else { return }
        web.pageZoom = kept
        zoom = kept
    }

    /// How much bigger the page is being drawn. Not a magnifying glass over
    /// the rendered page — the page is laid out again at this size, so text
    /// stays as sharp at 200% as it was at 100%.
    private(set) var zoom: CGFloat = 1

    @ObservationIgnored var onZoom: ((Tab, CGFloat) -> Void)?
    /// The resolved address under the pointer, or nil when it leaves a link.
    @ObservationIgnored var onLink: ((Tab, String?) -> Void)?
    /// The page took the keys (see PageView.onKeys).
    @ObservationIgnored var onKeys: ((Tab) -> Void)?

    /// True while something on the page is making noise, so the row can say
    /// which tab it is coming from.
    var noisy = false { didSet { if noisy != oldValue { voiced() } } }
    var sound = MiniSound()
    @ObservationIgnored var soundFrames: [String: MiniHeard] = [:]
    @ObservationIgnored var soundWait: Timer?
    private(set) var speaks = false
    @ObservationIgnored private var lull: Timer?
    @ObservationIgnored private var tempoAt: TimeInterval = -.infinity
    var developerPanel = false
    var device: DeviceState?
    let devLog = DevLog()
    @ObservationIgnored private lazy var devRelay = DevRelay(log: devLog)
    /// Darkened by Search, as its page last said (see Dusk.swift).
    var dusked = false
    /// What the page measured: true, dark by itself; nil, not yet measured.
    @ObservationIgnored var duskNative: Bool?
    /// The page's frames that asked whether it is darkened, to be told
    /// when that changes. Let go of with the page (see Browser's
    /// decidePolicyFor).
    @ObservationIgnored var duskFrames: [WKFrameInfo] = []
    /// Silenced by hand from its speaker or its menu: the page plays on and
    /// is not heard. WebKit keeps the mute on the view from one page to the
    /// next, so it is set on a view built new before that view begins loading
    /// the tab's page (see build()).
    var muted = false

    struct Kicks: Equatable {
        var back = 0
        var forward = 0
        var reload = 0
        var stop = 0
        var copy = 0
    }

    var kicks = Kicks()
    var stuck = StuckState()
    @ObservationIgnored var stuckEnd: StuckEnd?
    @ObservationIgnored var stuckRedoing = false
    @ObservationIgnored var memoryOwed = false
    var leaveQuestion: LeaveQuestion?
    @ObservationIgnored var leaveClosing: LeaveClosing?
    @ObservationIgnored var leaveGranted = false
    @ObservationIgnored var leaveStayedAt: Date?
    @ObservationIgnored weak var leaveTried: WKWebView?
    @ObservationIgnored var leaveSettled = false
    @ObservationIgnored var memoryEnds = 0
    /// An extension is recording from this tab's page (see RecordingIndicator).
    var recording = false

    /// Not `web`: a tab asleep is muted without being woken, and hears of
    /// it when its page is built again.
    func toggleMute() {
        muted.toggle()
        if let built { Muter.set(muted, on: built) }
    }

    var speakerSymbol: String { muted ? "speaker.slash" : "speaker.wave.2" }

    func heardTempo(at now: TimeInterval = CACurrentMediaTime()) {
        tempoAt = now
    }

    private func voiced(at now: TimeInterval = CACurrentMediaTime()) {
        lull?.invalidate()
        lull = nil
        if noisy {
            speaks = true
            return
        }
        guard speaks else { return }
        let left = tempoAt + SideLook.speakerHold - now
        guard left > 0 else {
            speaks = false
            return
        }
        lull = Timer.scheduledTimer(withTimeInterval: left, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.settleSpeaks() }
        }
    }

    func settleSpeaks() {
        lull?.invalidate()
        lull = nil
        if speaks != noisy { speaks = noisy }
    }

    /// What the page hands back when you point at something and click it.
    @ObservationIgnored var onPick: ((Tab, String, String, String) -> Void)?
    /// The page has a sign-in on it; the page has just sent one.
    @ObservationIgnored var onSignIn: ((Tab) -> Void)?
    /// The caret has entered or left one of the sign-in boxes; where the box
    /// is, in the web view's points, or nil when it has left. Then whether
    /// it goes with a password, and whether it is a first step's name box,
    /// which takes the name alone.
    @ObservationIgnored var onField: ((Tab, CGRect?, Bool, Bool, Bool) -> Void)?
    /// The site the sign-in was sent from — not the one it landed on —
    /// then the name and the password, and whether that page came over
    /// plain http.
    @ObservationIgnored var onCredentials: ((Tab, String, String, String, Bool) -> Void)?
    @ObservationIgnored var onPickEnd: ((Tab) -> Void)?
    @ObservationIgnored var onPickTrouble: ((Tab, String) -> Void)?
    /// Right-click landed on an image. WebKit's own menu offers to copy or
    /// download it and then, on at least some sites, does neither — see
    /// ImageMenu.swift for why this is built rather than patched.
    @ObservationIgnored var onImageMenu: ((Tab, URL) -> Void)?
    /// WebKit's Copy Image (true) or Download Image (false) chosen over a
    /// picture that is also a link, done as the image menu does them.
    @ObservationIgnored var onImageItem: ((Tab, URL, Bool) -> Void)?
    @ObservationIgnored var onImageText: ((Tab, URL) -> Void)?
    /// Where the last image right-clicked came from (see ImageMenu.swift).
    var imageFrame: WKFrameInfo? { images.frame }
    @ObservationIgnored var imageTextTask: Task<Void, Never>?
    @ObservationIgnored var imageTextToken: UUID?
    @ObservationIgnored var searchName: (() -> String?)?
    @ObservationIgnored var onSearch: ((Tab, String) -> Void)?
    @ObservationIgnored var onStoreAdd: ((Tab) -> Void)?
    @ObservationIgnored var onPullState: ((Tab, URL, PullPageState) -> Void)?
    @ObservationIgnored var onPageActed: ((Tab, URL) -> Void)?
    @ObservationIgnored var onAddress: ((Tab, URL) -> Void)?
    @ObservationIgnored var cheer = false
    @ObservationIgnored var arrives = false
    /// The middle button was let go over a link. The browser opens it in a
    /// tab of its own beside this one, without leaving the page you are on.
    @ObservationIgnored var onMiddleClick: ((Tab, URL) -> Void)?
    /// A page on this Mac's link to another file, clicked: here, or in a
    /// tab of its own for target="_blank" (see MiddleRelay).
    @ObservationIgnored var onFileLink: ((Tab, URL, Bool) -> Void)?
    /// Sent where this tab's view can't go: from an extension's page to the
    /// web or another extension, or from the web to an extension's page.
    /// WebKit keeps each kind of view to its own pages, so the tab has to be
    /// swapped for one built for the address (see Browser.replace).
    @ObservationIgnored var onCross: ((Tab, URL) -> Void)?
    var storePlaced: String?

    private let relay = ScrollRelay()
    private let veils_ = VeilRelay()
    private let forms = FormRelay()
    let fieldRelay = FieldRelay()
    @ObservationIgnored var onFormEvent: ((Tab, FormEvent) -> Void)?
    @ObservationIgnored var focusedField: FormField?
    @ObservationIgnored var snippetFrame: WKFrameInfo?
    @ObservationIgnored var onSnippetFocus: (() -> Void)?
    var formPage: WebFormPage? { built.map { WebFormPage(web: $0, relay: fieldRelay) } }
    private let images = ImageRelay()
    private let media = MediaKeys()
    /// Counting down once the page's sound stops, to give the media keys
    /// back (see MediaKeys.swift). One at most.
    @ObservationIgnored private var quiet: Timer?
    /// For the bench.
    var hushing: Bool { quiet != nil }
    private let shop = StoreRelay()
    private let iconChanges = IconRelay()
    private let pullPage = PullPageRelay()
    private let middles = MiddleRelay()
    private let dusk = DuskRelay()
    @ObservationIgnored var popupGesture = PopupGesture()
    @ObservationIgnored var popupTrace: [[String: String]] = []
    @ObservationIgnored var heldTabUnder: HeldTabUnder?
    @ObservationIgnored var undoneBy: UUID?
    @ObservationIgnored var lastWindow: (url: URL?, at: TimeInterval)?
    /// Windows this page asked for and was refused, newest last, a few at
    /// most: the quiet sign beside its title offers them (BlockedPopups.swift).
    /// Gone with the page.
    var blockedPopups: [BlockedPopup] = []
    /// A private tab's own Always Allow: only for as long as the tab, never
    /// written anywhere, as its Keep This Site Awake.
    @ObservationIgnored var popupSites: Set<String> = []
    /// Translate Page (Translate.swift): what the sign beside the title
    /// shows, the run while there is one, the frames that said they're
    /// there, a private tab's own Always Translate, and the page a tab put
    /// to sleep translated was on. All in memory, gone with the tab.
    var translation: TranslationMark?
    @ObservationIgnored var translator: PageTranslator?
    @ObservationIgnored var translateFrames: [WKFrameInfo] = []
    @ObservationIgnored var translateLanguages: Set<String> = []
    @ObservationIgnored var translateOnWake: (url: URL, to: String)?
    private let translateRelay = TranslateRelay()
    private let jsonRelay = JSONRelay()
    private let passkeyRelay = PasskeyRelay()
    private let resume = ResumeRelay()
    private let video = VideoRelay()
    @ObservationIgnored var videoSpot: VideoSpot?
    @ObservationIgnored private var resumeArm: (spot: VideoSpot, at: Date)?
    private let hovered = HoveredLink()
    private let ears = AudioWatch()

    // Private exceptions belong only to this tab, never its session record.
    var awakeSites: Set<String> = []

    var awakeHost: String? {
        guard let address, ["http", "https"].contains(address.scheme?.lowercased()) else { return nil }
        return address.host()?.lowercased()
    }

    /// A tab that keeps nothing: its own cookies, no history, no place in the
    /// session. Signed in as nobody, and forgotten when it goes.
    let shy: Bool

    @ObservationIgnored var space: UUID?

    var languages: [String] { PreferredLanguages.list(for: space, shy: shy) }

    /// The account last filled here from Apple's Passwords app, so sending
    /// it isn't offered a second place in Search's keychain. A keyed hash of
    /// the password, never the password.
    @ObservationIgnored var appleFill: AppleFill?
    @ObservationIgnored var keptFill: FillMark?

    /// A tab a script opened through the bench, beside yours. Signed in as
    /// you, so it sees what you see — but never selected for you, never in
    /// the session or the history, and gone when the script is done.
    @ObservationIgnored var bench: Bool
    @ObservationIgnored var agent = false {
        didSet {
            if agent { Task { @MainActor in AgentAwake.refresh() } }
            if !agent {
                if let built { AgentDiagnostics.keepAwake(built, false) }
                agentDialog?.answer(ok: false)
                agentDialog = nil
            }
        }
    }
    @ObservationIgnored var agentDialog: PaneQuestion?
    var agentActing: String?
    @ObservationIgnored var agentActingUntil: Date?
    var driving = false
    @ObservationIgnored var handedBack = false
    @ObservationIgnored var agentFrames: [String: String] = [:]
    @ObservationIgnored private(set) var sealed: Set<String> = []
    @ObservationIgnored var agentTask: UUID?
    @ObservationIgnored var agentSeen = false
    @ObservationIgnored var agentFinished: Date?
    var agentMood: AgentMood?
    @ObservationIgnored var agentSteered: Date?

    /// The tab whose page opened this one, when a script did. Sign-in flows
    /// hand you back to it when they are done.
    @ObservationIgnored var opener: Tab.ID?
    @ObservationIgnored var openedByClick = false
    @ObservationIgnored private(set) var shownPage = false
    @ObservationIgnored var linkedFrom: Tab.ID?
    @ObservationIgnored var returnTo: Tab.ID?
    @ObservationIgnored var returnWay = TabReturn.front

    /// A window a page opened at a size of its own, or without a toolbar:
    /// a pop-up, not a link. It is named by its site, never by its title — a
    /// page that opens one can call it anything, "Sign in with Google" over
    /// somebody else's address included.
    @ObservationIgnored var popup = false

    /// One letter, when the tab has been pinned. A pinned tab keeps its place
    /// at the head of the row and gives up its title for that letter — which
    /// is all you need for the five or six pages you keep open all day.
    var pin: String? {
        didSet { if pin == nil, oldValue != nil { letGo = Date() } }
    }
    /// For a pin, the page it was pinned at: a double-click on it goes back
    /// there (Browser.goHome).
    @ObservationIgnored var home: URL?
    /// For a pin, which of the pins it is, in every window (see Pins.swift).
    @ObservationIgnored var pinID: UUID?
    /// For a pin, one every space shows (see Pins.shared). Set when the row
    /// is built; pins.json, not the session, says which pins these are.
    @ObservationIgnored var everywhere = false
    /// For a pin, the site a link from it was just peeked at, and when: the
    /// page's own script sending the pin there after all is turned away
    /// (see Browser.peek).
    @ObservationIgnored var peeked: (site: String, at: Date)?
    /// The group that holds this ordinary tab in the sidebar.
    var trimWords: [String]?
    @ObservationIgnored var liveKey: String?
    @ObservationIgnored var cameBack = false
    @ObservationIgnored var madeBy: (page: URL, name: String)?
    var liveItem: LiveItem?
    var unread = false
    var groupID: UUID? {
        didSet {
            if groupID == nil, oldValue != nil { letGo = Date() }
            if groupID != oldValue { trimWords = nil }
        }
    }

    /// A name you gave it, in place of whatever the page calls itself. It
    /// stays through navigation: a tab you named is a tab you are keeping for
    /// a job, not for a page.
    ///
    /// Pinned, grouped and named are the three ways of keeping a tab when
    /// tabs close themselves (see Closing.swift). A tab let go from any of
    /// them starts its time from then (letGo), not from whenever it was
    /// last left.
    var name: String? {
        didSet { if name == nil, oldValue != nil { letGo = Date() } }
    }

    /// When you last looked at it. The summon lists pages by this, because
    /// what you were just reading is what you are most likely to want back.
    /// Written into the session, so a tab's time away counts across quits.
    @ObservationIgnored private(set) var touched = Date()
    /// When it was last let go of: unpinned, taken out of its group, its
    /// name taken away. Kept apart from `touched`, which says when you last
    /// looked, for ⌃Tab and for where ⌘W on a pin lands; letting go of a
    /// tab isn't looking at it. In the session too (see Closing.swift).
    @ObservationIgnored var letGo: Date?
    /// Since when a tab that closes itself counts as left: the later of the
    /// last look and the last letting go.
    var leftSince: Date { max(touched, letGo ?? .distantPast) }

    /// What was typed into this blank tab's field and not sent, kept while
    /// another tab is in front: the field is one for every tab. Only ever in
    /// memory, and gone once the tab goes somewhere or closes.
    @ObservationIgnored var draft = ""

    /// Set on a tab brought back from the last session and not yet opened. It
    /// has a name and an address in the row, and costs nothing until you go to
    /// it — which is the difference between a browser that starts in half a
    /// second with twenty tabs and one that doesn't.
    private(set) var pending: URL?

    /// For a tab put to sleep for not being looked at: the page's own history
    /// — the back list, the page, where it was scrolled to — handed to the
    /// view built to wake it, so it opens exactly where this one was left.
    @ObservationIgnored private var memory: Any?
    /// The last picture of that page, compressed, for the moment it wakes.
    @ObservationIgnored private var picture: Data?
    /// That picture, over the stage while the page is rebuilt underneath it:
    /// coming back to a tab that slept starts from what you left, not white.
    private(set) var cover: NSImage?

    @ObservationIgnored private var watch: [NSKeyValueObservation] = []

    /// A tab that has never been anywhere shows the address field instead of a
    /// page. It still owns a web view — built now, warm by the time it's needed.
    var isBlank: Bool { address == nil && page == nil }
    /// A tab with a web page — loaded, on its way or asleep — as opposed to
    /// an empty one or one of Search's own pages.
    var isWeb: Bool { address != nil }

    // MARK: - Search's own pages (see InternalPages.swift)

    /// Settings, History and the rest, shown in this tab in place of a web
    /// page. Never with a web view behind it.
    private(set) var page: InternalPage?
    /// The pages Back and Forward go to, between Search's own pages.
    @ObservationIgnored private var trail: [InternalPage] = []
    @ObservationIgnored private var ahead: [InternalPage] = []
    /// The page this tab left for the web: Back from the first web page
    /// comes back to it, as Back from a link in chrome://history does.
    @ObservationIgnored private var behind: InternalPage?

    /// What the field shows for this tab, and what is copied.
    var shownURL: URL? { page?.url ?? address }

    /// Go to one of Search's own pages. `stepping`: whether the page it
    /// leaves is one Back comes back to — not for another section of the
    /// same page, which only moves the address.
    func show(_ next: InternalPage, stepping: Bool = true) {
        if let page, page != next, stepping, page.kind != next.kind {
            trail.append(page)
            ahead = []
        }
        // A web page in this tab is let go of: these pages have no web view
        // behind them, and a tab with both would have two things to go back to.
        if address != nil || built != nil {
            discard()
            address = nil
            committed = nil
            held = nil
            pending = nil
            memory = nil
            picture = nil
            cover = nil
            failure = nil
            loading = false
            progress = 0
            behind = nil
            trail = []
            ahead = []
        }
        draft = ""
        stopSettling()
        heading = .blank
        hinted = false
        origin = nil
        page = next
        title = next.title
        adoptIcon()
        steps()
    }

    /// Back and Forward as this tab has them now.
    private func steps() {
        let back = page != nil ? !trail.isEmpty : (built?.canGoBack ?? false) || behind != nil
        let forward = page != nil ? !ahead.isEmpty : built?.canGoForward ?? false
        if canGoBack != back { canGoBack = back }
        if canGoForward != forward { canGoForward = forward }
    }

    /// The title if the page has offered one, the address until it does. A tab
    /// that says nothing at all for the first second of every load is a tab you
    /// can't find your way back to.
    var label: String {
        if let name, !name.isEmpty { return name }
        if let page { return page.title }
        if popup, let host = address?.host(), !host.isEmpty {
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        switch heading {
        case .title(let text): return trimWords.map { SearchFolders.strip(text, words: $0) } ?? text
        case .address(let url): return Address.pretty(url)
        case .blank: return address.map(Address.pretty) ?? "New Tab"
        }
    }

    var titleSettled: Bool { !settle.booting }

    var savedTitle: String {
        if !title.isEmpty, titleSettled { return title }
        if hinted, case .title(let text) = heading { return text }
        return titleSettled ? title : ""
    }

    func takeOrigin() -> URL? {
        defer { origin = nil }
        return origin
    }

    func noteLink(href: String, words: String) {
        lastLink = (href, words, Date())
    }

    func linkWords(for url: URL) -> String? {
        guard let lastLink, lastLink.href == url.absoluteString, Date().timeIntervalSince(lastLink.at) < 3 else { return nil }
        return lastLink.words
    }

    private func lead(_ url: URL, known: String?) {
        heading = TitleSource.heading(known: known, url: url)
        hinted = known != nil
        origin = url
    }

    private func heard(_ raw: String) {
        if raw.isEmpty, loading { return }
        if let shown = settle.heard(raw, at: CACurrentMediaTime()) { settled(shown) } else { scheduleSettle() }
    }

    private func loadEnded() {
        if stuck.asked != nil { StuckRules.committed(&stuck) }
        if let shown = settle.loadEnded(at: CACurrentMediaTime()) { settled(shown) } else { scheduleSettle() }
    }

    private func scheduleSettle() {
        settleWork?.cancel()
        settleWork = nil
        guard let deadline = settle.deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let shown = self.settle.tick(at: CACurrentMediaTime()) { self.settled(shown) } else { self.scheduleSettle() }
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - CACurrentMediaTime()), execute: work)
    }

    private func settled(_ value: String) {
        settleWork?.cancel()
        settleWork = nil
        let text = value.isEmpty ? (built?.title ?? "") : value
        if text.isEmpty, loading { return }
        if title != text { title = text }
        if !text.isEmpty {
            if heading != .title(text) { heading = .title(text) }
        } else if !hinted {
            let fallback = TitleSource.heading(known: nil, url: address)
            if heading != fallback { heading = fallback }
        }
        hinted = false
    }

    private func stopSettling() {
        settle.stop()
        settleWork?.cancel()
        settleWork = nil
    }

    init(shy: Bool = false, bench: Bool = false, configuration: WKWebViewConfiguration? = nil) {
        self.shy = shy
        self.bench = bench
        self.configuration = configuration ?? Web.configuration(shy: shy)
        if Store.testing {
            Tab.live.add(self)
            TitleTrace.follow(self)
        }
    }

    /// Every tab still in memory, on a test run, for the bench's `alive`
    /// (Tests/memory_close.py): a tab closed and still counted here is
    /// held by something, and so may be its page.
    static let live = NSHashTable<Tab>.weakObjects()

    private func build() -> PageView {
        // Here rather than in Web.configuration: a tab's configuration is
        // made with the tab, often long before its page, and a site or an
        // extension can hand over one of its own.
        FrameRate.apply(to: configuration.preferences)
        ClickIDs.apply(to: configuration.preferences, shy: shy)
        let web = PageView(frame: .zero, configuration: bench ? AgentPageRoom.unseen(configuration) : configuration)
        // The trackpad pinch is WebKit's own: it magnifies what is on screen
        // and lets you move around inside it, the way pinching does everywhere
        // else on a Mac. ⌘+ and ⌘- are the other thing — they lay the page out
        // again at a bigger size — and both are worth having.
        web.allowsMagnification = true
        // WebKit's own two-finger swipe stays off. It drags the page across
        // the window with a picture of the last one behind it; ours is in
        // PageView, and it moves nothing but a disc.
        web.allowsBackForwardNavigationGestures = false
        Swipe.calm(web)
        web.onPull = { [weak self] pull in self?.pull = pull }
        web.refresh.onRefresh = { [weak self] in self?.reload() }
        web.refresh.allowed = { [weak self] in self?.floating == false }
        web.onTouch = { [weak self] in self?.uncover() }
        web.onMenuClosed = { [weak self] in self?.popupGesture.menuClosed() }
        web.onStep = { [weak self] back in self?.goingBack = back }
        web.leave = { [weak self] act in
            guard let self, self.leave?(false) == true else { return false }
            if act { DispatchQueue.main.async { [weak self] in _ = self?.leave?(true) } }
            return true
        }
        web.onKeys = { [weak self] in if let self { self.onKeys?(self) } }
        web.searchName = { [weak self] in self?.searchName?() }
        web.translating = { [weak self] in self.map { $0.translator != nil && $0.translation?.failed != true } ?? false }
        web.onTranslate = { [weak self] in self?.toggleTranslation() }
        web.readsIn = { [weak self] in PageTranslator.reader(for: self) }
        web.onImageText = { [weak self] url in
            guard let self else { return }
            self.onImageText?(self, url)
        }
        web.onImage = { [weak self] url, copy in
            guard let self else { return }
            self.onImageItem?(self, url, copy)
        }
        web.onSearch = { [weak self] text in
            guard let self else { return }
            self.onSearch?(self, text)
        }
        web.onFirstFrame = { [weak self] in self?.painted = true }
        web.onWindow = { [weak self] in self?.movedHouse() }
        web.holdForFirstFrame()
        painted = !web.unpainted
        // Pages follow the appearance of the window they are drawn in, and the
        // window follows Settings › Appearance — so a site that honours
        // prefers-color-scheme goes dark with the frame, and not otherwise.
        // Safari's Develop menu can reach it, and so can the page's own
        // Inspect Element — a configuration handed over by an opener included.
        Web.inspectable(web)
        Web.pages.add(web)
        NativePiP.allow(web.configuration.preferences)
        web.navigationDelegate = delegate
        web.uiDelegate = uiDelegate(delegate)
        ExtensionCapture.shared.watchScreen(web)
        if !shy { PageNotifications.provide(web) }

        // Each name is cleared before being claimed — registering one twice is
        // a hard crash rather than an error. A tab opened by a link gets a
        // controller of its own (Browser's createWebViewWith), never its
        // opener's.
        let controller = web.configuration.userContentController
        Web.release(controller)
        controller.add(relay, contentWorld: Web.world, name: ScrollRelay.name)
        controller.add(veils_, contentWorld: Web.world, name: VeilRelay.name)
        controller.add(images, contentWorld: Web.world, name: ImageRelay.name)
        controller.add(media, contentWorld: Web.world, name: MediaKeys.name)
        controller.add(shop, contentWorld: Web.world, name: StoreRelay.name)
        controller.add(iconChanges, contentWorld: Web.world, name: IconRelay.name)
        controller.add(pullPage, contentWorld: Web.world, name: PullPageRelay.name)
        controller.add(forms, contentWorld: Web.world, name: FormRelay.name)
        controller.add(fieldRelay, contentWorld: Web.world, name: FormFieldScript.relay)
        controller.addScriptMessageHandler(passkeyRelay, contentWorld: Web.world, name: PasskeyRelay.name)
        controller.addScriptMessageHandler(resume, contentWorld: Web.world, name: Resume.name)
        controller.addScriptMessageHandler(video, contentWorld: Web.world, name: VideoDefaults.name)
        hovered.tab = self
        controller.add(hovered, contentWorld: .defaultClient, name: HoveredLink.name)
        controller.add(middles, contentWorld: Web.world, name: MiddleRelay.name)
        controller.add(dusk, contentWorld: Web.world, name: DuskRelay.name)
        controller.add(translateRelay, contentWorld: Web.world, name: TranslateRelay.name)
        controller.add(jsonRelay, contentWorld: Web.world, name: JSONRelay.name)
        PopupGestureRelay.install(on: controller)
        Shield.shared.protect(controller)
        built = web
        // Set before loadAndVerify gives this view a page: a tab restored or
        // woken muted must not make its first sound while that page boots.
        if muted { Muter.set(true, on: web) }
        arm(hiding: veils)

        watch = [
            web.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.heard(self?.built?.title ?? "") }
            },
            web.observe(\.url, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let fresh = self.built?.url else { return }
                    // about:blank is never a destination. Putting a pinned tab
                    // to sleep loads it deliberately to make WebKit give the
                    // page back — and letting that overwrite the address is how
                    // a pinned tab lost the only thing that could bring it
                    // back, and vanished from the session altogether.
                    guard fresh.absoluteString != "about:blank" else { return }
                    if self.held != nil {
                        if fresh == self.heldOver { return }
                        self.held = nil
                    }
                    // By site, port included: localhost:3000 to localhost:5173
                    // is another project, with another icon. Another path on
                    // the same host may be another app, with one of its own.
                    let moved = Favicons.site(fresh) != self.address.flatMap(Favicons.site)
                        || fresh.path() != self.address?.path()
                    self.address = fresh
                    // Within the same origin — history.pushState, a fragment —
                    // the page on screen is the one at the new address.
                    if let now = self.committed, now.scheme == fresh.scheme, now.host() == fresh.host(), now.port == fresh.port {
                        self.committed = fresh
                    }
                    if moved {
                        self.adoptIcon()
                        self.onAddress?(self, fresh)
                    }
                    // A darkened page that moved to another address of its
                    // own is watched again for a while (see Dusk.swift).
                    if self.dusked, !moved { self.built?.evaluateInSearch("window.__officeDusk && window.__officeDusk.again()") }
                }
            },
            web.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.progress = self?.built?.estimatedProgress ?? 0 }
            },
            web.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.loading = self.built?.isLoading ?? false
                    if !self.loading { self.loadEnded() }
                }
            },
            web.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.steps() }
            },
            web.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.steps() }
            },
            // A page's full screen, as WebKit has it. In once its own window
            // has the page (a placeholder is left in ours, so the chrome going
            // away resizes nothing the page sees); back as soon as it starts
            // to give it back, while that window still covers ours: the
            // chrome is then in place before the page returns, and the page
            // is laid out once, at the size it had, where WebKit's animation
            // lands it. The page's own fullscreenchange (Forms.swift) comes
            // after each and changes nothing.
            web.observe(\.fullscreenState, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, let state = self.built?.fullscreenState else { return }
                    let on = state == .enteringFullscreen || state == .inFullscreen
                    if self.immersed != on { self.immersed = on }
                }
            },
        ]

        relay.tab = self
        veils_.tab = self
        forms.tab = self
        fieldRelay.tab = self
        images.tab = self
        media.tab = self
        resume.tab = self
        video.tab = self
        shop.tab = self
        iconChanges.tab = self
        pullPage.tab = self
        middles.tab = self
        dusk.tab = self
        translateRelay.tab = self
        ears.watch(web) { [weak self] on in self?.heard(on) }
        return web
    }

    /// Between two fifths and three times, which is as far as a page is worth
    /// pushing in either direction.
    func magnify(to value: CGFloat) {
        let wanted = min(3, max(0.4, value))
        guard abs(wanted - web.pageZoom) > 0.004 else { return }
        web.pageZoom = wanted
        zoom = wanted
        rememberZoom()
        onZoom?(self, wanted)
    }

    func magnify(by factor: CGFloat) { magnify(to: web.pageZoom * factor) }

    /// ⌘0 undoes both kinds of zoom at once — whichever one you reached for —
    /// back to the size every site starts at.
    func resetZoom() {
        magnify(to: Tab.defaultZoom)
        guard web.magnification != 1 else { return }
        web.magnification = 1
        onZoom?(self, 1)
    }

    // MARK: - taking things off the page

    /// What gets injected into the *next* document: the scroll reporter, the
    /// pointing mode, and this site's stylesheet of things you have hidden. The
    /// stylesheet goes in before the document has a body, so nothing is ever
    /// seen arriving and then leaving again.
    /// `to`: where the next document comes from, when that isn't the page up
    /// now (a navigation just decided). Dark pages hand that one site's
    /// answer over, and nothing at all to a page that isn't to be darkened.
    func arm(hiding css: String, to url: URL? = nil) {
        veils = css
        guard let built else { return }
        let controller = built.configuration.userContentController
        controller.removeAllUserScripts()
        if let script = PreferredLanguages.script(for: languages) { controller.addUserScript(script) }
        controller.addUserScript(FileInputCapture.script)
        controller.addUserScript(PopupGestureRelay.userScript)
        // At the start, so its pageshow runs ahead of the page's own
        // (see KeptScroll.swift).
        controller.addUserScript(
            WKUserScript(source: KeptScroll.script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: Veiling.picker, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: FormFieldScript.source, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: FormRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: IconRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: PullPageRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        if AutoScroll.on {
            controller.addUserScript(
                WKUserScript(source: AutoScroll.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
            )
        }
        // Every frame: a swipe over an embedded map is the map's, and only the
        // map's own document can say so.
        controller.addUserScript(
            WKUserScript(source: Swipe.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: PullRefresh.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: ImageRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // Every frame, in Search's world: a paused video gives the media keys
        // back (see MediaKeys.swift).
        controller.addUserScript(
            WKUserScript(source: MediaKeys.watch, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        controller.addUserScript(
            WKUserScript(source: Resume.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        if Shared.prefs.miniPlayer { for script in MiniScripts.scripts() { controller.addUserScript(script) } }
        controller.addUserScript(VideoDefaults.script())
        controller.addUserScript(VideoQuality.script(shy: shy))
        controller.addUserScript(VideoSpeed.script())
        controller.addUserScript(
            WKUserScript(source: StoreRelay.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: Web.world)
        )
        if Tempo.on {
            controller.addUserScript(
                WKUserScript(source: Tempo.script, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Web.world)
            )
        }
        controller.addUserScript(JSONView.script)

        // Only while Settings says so: off, pages get nothing at all.
        if HoveredLink.on {
            controller.addUserScript(WKUserScript(
                source: HoveredLink.script, injectionTime: .atDocumentStart,
                forMainFrameOnly: false, in: .defaultClient
            ))
        }
        // The main frame only: a middle-click on a link inside an ad iframe is
        // that frame's own business, and its link is not this tab's to open.
        controller.addUserScript(
            WKUserScript(source: MiddleRelay.watch, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
        // Every frame, in the page's own world and ahead of its scripts: a
        // live player's speed nudges go through it (see LiveRate.swift).
        controller.addUserScript(
            WKUserScript(source: LiveRate.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
        )
        controller.addUserScript(
            WKUserScript(source: PullPageRelay.acts, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)
        )
        controller.addUserScript(
            WKUserScript(source: PullPageRelay.heard, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
        // Every frame, in the page's own world: a page an extension lists
        // reaches it as chrome.runtime (see ExtensionExternal.swift).
        if let external = ExtensionExternal.script {
            controller.addUserScript(
                WKUserScript(source: external, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        }
        // Passkeys stand in the page's own world — they replace the page's
        // functions — and reach Search through a bridge in Search's, off or on:
        // an extension's page script can carry the patch either way (see
        // Passkeys.swift and ExtensionShims.passkeys).
        if !FormRelay.passkeysOffered {
            controller.addUserScript(
                WKUserScript(source: FormRelay.withoutPasskeys, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        } else {
            controller.addUserScript(
                WKUserScript(source: PasskeyRelay.page, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
            )
        }
        controller.addUserScript(
            WKUserScript(source: PasskeyRelay.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
        )
        // Every frame but the top, only while Translate Page is switched on:
        // a frame of another site says it's there, to be translated too.
        if PageTranslator.enabled {
            controller.addUserScript(
                WKUserScript(source: PageTranslator.announce, injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: Web.world)
            )
        }
        // Only while it is on and not paused: otherwise pages get nothing
        // (see Dusk.swift). Before the document, so a site known to be light
        // is never seen white. Every frame: a frame darkens its own document,
        // led by its page.
        if let dusk = Dusk.shared.script(for: Dusk.host(of: url ?? pageAddress)) {
            controller.addUserScript(
                WKUserScript(source: dusk, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: Web.world)
            )
        }
        // YouTube's ads, while Shield is on for the site this tab is on
        // (see YouTubeAds.swift). Every frame; each script does nothing in a
        // frame that isn't YouTube's.
        for script in YouTubeAds.scripts(for: Dusk.host(of: url ?? pageAddress)) {
            controller.addUserScript(script)
        }
        controller.removeScriptMessageHandler(forName: DevRelay.name, contentWorld: .page)
        if !shy, agent || Developer.shared.isOn(url ?? pageAddress) {
            controller.add(devRelay, contentWorld: .page, name: DevRelay.name)
            controller.addUserScript(Developer.script)
        }
        guard !css.isEmpty else { return }
        controller.addUserScript(
            WKUserScript(source: Veiling.style(css), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Web.world)
        )
    }

    /// The same stylesheet, for the page that is already up.
    func applyVeils(_ css: String) {
        built?.evaluateInSearch(Veiling.style(css))
    }

    func startPicking() { web.evaluateInSearch("window.__officeVeil && window.__officeVeil.on()") }
    func stopPicking() { web.evaluateInSearch("window.__officeVeil && window.__officeVeil.off()") }

    func foundSignIn() { onSignIn?(self) }

    /// From the page, in CSS pixels; passed on in points. Page zoom is the
    /// only scale between the two that matters here.
    /// `passwords`: a box of a sign-in with a password, not one only for
    /// passkeys. `name`: the name box of a sign-in that asks for the
    /// password on the next page.
    /// The host of the frame the sign-in box with the caret is in, when it
    /// isn't the page itself: an offer is only made from the page's own site
    /// (ApplePasswordsOffer). Set before `fieldFocused` by FormRelay.
    @ObservationIgnored var fieldFrameHost: String?
    @ObservationIgnored var freshField: Int?
    @ObservationIgnored var strongTaken: StrongTaken?

    /// `wide`: clearly a sign-in's box, so accounts kept for the site's
    /// other hosts (its registrable domain) may come; otherwise only this
    /// host's own.
    func fieldFocused(_ rect: CGRect?, passwords: Bool = true, name: Bool = false, wide: Bool = true) {
        guard let rect else {
            onField?(self, nil, false, false, false)
            return
        }
        let zoom = built?.pageZoom ?? 1
        onField?(self, CGRect(
            x: rect.minX * zoom, y: rect.minY * zoom,
            width: rect.width * zoom, height: rect.height * zoom
        ), passwords, name, wide)
    }

    /// The name a sign-in that asks for it first was just sent, for the
    /// page after it: that one asks for the password alone, with no box
    /// for the name, and a password saved without its name is half a
    /// login. In memory only — never written down — for this tab alone,
    /// a few minutes, and only for the same site: a private tab's name
    /// never reaches another tab, and another site never sees it.
    @ObservationIgnored private var named: (site: String, user: String, at: Date)?

    func gaveName(_ user: String) {
        guard !user.isEmpty, user.count <= 256,
              let host = pageAddress?.host()?.lowercased()
        else { return }
        named = (Vault.registrable(host), user, Date())
    }

    /// The name sent on the step before, if it was this site's and recent.
    func givenName() -> String? {
        guard let named, Date().timeIntervalSince(named.at) < 300,
              let host = pageAddress?.host()?.lowercased(),
              Vault.registrable(host) == named.site
        else { return nil }
        return named.user
    }

    /// A name and password the page has just sent — held, not yet offered.
    /// Whether the sign-in worked is only known afterwards: a page that
    /// comes back without a password box took it, one that still has the
    /// box refused it, and only the first is worth remembering.
    @ObservationIgnored private var sent: (host: String, user: String, password: String, clear: Bool, at: Date)?

    func sentSignIn(user: String, password: String) {
        // The host now, while the page is still the sign-in page: a moment
        // later it may be somewhere else entirely, and that is not where
        // the password belongs.
        guard let host = pageAddress?.host()?.lowercased() else { return }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        // A password page with no name on it: the name is the one the step
        // before was sent with.
        let user = user.isEmpty ? givenName() ?? "" : user
        sent = (bare, user, password, pageAddress?.scheme?.lowercased() == "http", Date())
    }

    /// The page has moved on — a new document has loaded, or the sign-in
    /// fields have gone. If a password went out recently and there is no
    /// longer a box for it, that is a sign-in that took.
    ///
    /// A new document is judged at once. Fields that a page removed by
    /// itself are given a moment first: a sign-in built into the page closes
    /// its form the instant you press the button and puts it back if the
    /// server says no — and offering in between is offering a password that
    /// may be wrong.
    func settleSignIn(navigated: Bool = true) {
        guard let sent else { return }
        guard Date().timeIntervalSince(sent.at) < 45 else {
            self.sent = nil
            dropFillMarks()
            return
        }
        guard navigated else {
            let stamp = sent.at
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                // Only if nothing newer went out in the meantime.
                guard let self, self.sent?.at == stamp else { return }
                self.settleSignIn(navigated: true)
            }
            return
        }
        web.evaluateInSearch("!!(window.__officeForms && window.__officeForms.hasPassword())") { [weak self] still in
            MainActor.assumeIsolated {
                guard let self, let sent = self.sent else { return }
                // The box is still there: a refused sign-in, or the second
                // step of one. Kept for a moment longer, in case the page is
                // still on its way.
                if (still as? Bool) == true { return }
                self.sent = nil
                self.named = nil
                self.onCredentials?(self, sent.host, sent.user, sent.password, sent.clear)
                self.dropFillMarks()
            }
        }
    }

    private func dropFillMarks() {
        guard sent == nil else { return }
        let host = pageAddress?.host()?.lowercased() ?? ""
        if appleFill?.covers(host) == false { appleFill = nil }
        if keptFill?.covers(host) == false { keptFill = nil }
    }

    /// Puts a remembered name and password where a person would have typed
    /// them. Nothing is echoed back and nothing is written down here.
    /// `done`, when given, hears back `false` for the one case worth saying
    /// something about: the sign-in fields that were there a moment ago,
    /// when this was offered, are gone by the time it actually runs.
    /// With `onlyOn`, the page checks for itself, when the script runs, that
    /// it is still that scheme and host: a document that changed after the
    /// last check on this side gets nothing.
    func fill(user: String, password: String, onlyOn page: URL? = nil, done: ((Bool) -> Void)? = nil) {
        seal(password)
        var still = ""
        if let page {
            guard let scheme = page.scheme?.lowercased(), let host = page.host()?.lowercased() else { done?(false); return }
            still = "location.protocol === `\(escape(scheme)):` && location.hostname.toLowerCase() === `\(escape(host))` && "
        }
        web.evaluateInSearch(
            "\(still)window.__officeForms && window.__officeForms.fill(`\(escape(user))`, `\(escape(password))`)"
        ) { result in
            done?((result as? Bool) ?? false)
        }
    }

    /// A first step's name alone, picked from the accounts under its box.
    func fillName(_ user: String, done: ((Bool) -> Void)? = nil) {
        web.evaluateInSearch(
            "window.__officeForms && window.__officeForms.name(`\(escape(user))`)"
        ) { result in
            done?((result as? Bool) ?? false)
        }
    }

    func picked(selector: String, label: String, note: String) {
        onPick?(self, selector, label, note)
    }

    /// Show one hidden thing while the pointer rests on its row in the list.
    func peek(_ selector: String, keeping css: String) {
        web.evaluateInSearch(
            "window.__officeVeil && window.__officeVeil.peek(`\(escape(css))`, `\(escape(selector))`)"
        )
    }

    func unpeek(_ css: String) {
        web.evaluateInSearch("window.__officeVeil && window.__officeVeil.unpeek(`\(escape(css))`)")
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
    }
    func pickingEnded() { onPickEnd?(self) }
    func pickingFailed(_ reason: String) { onPickTrouble?(self, reason) }

    func go(to url: URL, known: String? = nil) {
        if InternalPage(url: url) == nil, reach(.address(url)) { return }
        agentDialog?.answer(ok: false)
        agentDialog = nil
        goingBack = false
        if let own = InternalPage(url: url) {
            show(own)
            return
        }
        // Out of one of Search's own pages, onto the web: Back comes back.
        if let page {
            behind = page
            self.page = nil
            trail = []
            ahead = []
            icon = nil
        }
        // Judged by the page it shows, not by how it was made: a tab an
        // extension's page opened with window.open is built from that
        // extension's configuration too. A tab with no page yet was just
        // built for where it is going, so it goes there.
        if let onCross, let here = built?.url ?? address,
           Browser.extensionHost(of: here) != Browser.extensionHost(of: url) {
            onCross(self, url)
            return
        }
        // Set straight away rather than waiting for the observer: the tab has to
        // stop being blank in the same frame the field disappears, or the empty
        // state flashes back for an instant on its way out.
        address = url
        held = nil
        title = ""
        stopSettling()
        lead(url, known: TitleSource.best(history: knowsTitle?(url), named: known))
        failure = nil
        typing = false
        immersed = false
        draft = ""
        // Sent somewhere new, a sleeping tab is simply awake again — with
        // nothing of where it was before to bring back.
        pending = nil
        memory = nil
        picture = nil
        cover = nil
        adoptIcon()
        web.open(url)
        // Back, from a page that came out of one of Search's own, goes there.
        steps()
    }

    /// Brought back from the last session: everything the row needs to draw it,
    /// and nothing fetched.
    func restore(url: URL, title: String, name: String? = nil) {
        if let own = InternalPage(url: url) {
            self.name = name
            show(own)
            return
        }
        address = url
        self.title = title
        self.name = name
        lead(url, known: TitleSource.best(named: title) ?? knowsTitle?(url))
        pending = url
        adoptIcon()
    }

    /// True for a tab that has a place and an address but is holding no page —
    /// brought back from the last session, or put down with ⌘W while pinned.
    var asleep: Bool { pending != nil }

    /// ⌘W on a pinned tab. The letter keeps its place in the row and the
    /// address is remembered; everything the page was holding is let go, so a
    /// pin you are not reading costs a line in a file and nothing else.
    /// Given `home`, it is put down there instead of where it was: Arc's pin
    /// that goes back to its pinned page once closed (see Preferences.pinsGoHome).
    func rest(at home: URL? = nil) {
        guard let url = home ?? address else { return }
        // The title was the page it is leaving; the host stands in until the
        // pinned page is woken and names itself.
        if let home, address != home {
            address = home
            title = home.host ?? ""
            lead(home, known: knowsTitle?(home))
        }
        pending = url
        memory = nil
        picture = nil
        noisy = false
        settleSpeaks()
        stale = false
        pull = nil
        // Loading about:blank here looked like letting the page go, and
        // wasn't: WebKit keeps the document it just left in the back-forward
        // cache — alive, suspended, and still counted by its own origin as an
        // open tab. Coming back then started a second x.com beside a first
        // that would never answer, and the second waited for it until you
        // gave up and reloaded by hand. Only tearing the view down ends the
        // page; the next wake() builds a fresh one, and a fresh one boots.
        discard()
    }

    /// Nobody has looked at this page for a while. Its view goes, as with a
    /// pin put down by hand, but its history and a picture of it stay: the
    /// view built to wake it opens the same page, at the same place, with
    /// Back still going back. What was typed and not sent is the one thing
    /// that can't come back, which is why the browser asks `unsaved` first.
    func sleep(picture: Data?) {
        guard let url = address, let built else { return }
        memory = built.interactionState
        self.picture = picture
        pending = url
        stale = false
        pull = nil
        discard()
    }

    /// A page moved to another space must use that space's cookies. WebKit
    /// binds the store when the view is made, so keep its restorable state
    /// and build the view again with the destination's store.
    func rehome(in space: UUID) {
        if !shy { self.space = space }
        guard !shy, !bench, store !== Spaces.store(for: space) else { return }
        if let built {
            memory = built.isLoading ? nil : built.interactionState
            pending = address ?? built.url
            picture = nil
            cover = nil
            discard()
        }
        configuration = Web.configuration(space: space)
    }

    /// Settings › Videos wait for a click, changed: the page's next view
    /// is made the new way. One already made keeps what it was made with —
    /// WebKit fixes it then — and its next page follows through its own
    /// autoplay policy (see Autoplay.apply).
    func playbackChanged() {
        configuration.mediaTypesRequiringUserActionForPlayback = Web.playback
    }

    /// Whether the page holds something typed and not yet sent — a draft, a
    /// half-filled form. A page that can't answer is treated as holding
    /// nothing: a PDF, an image, a page whose process has already gone.
    func unsaved(_ done: @escaping (Bool) -> Void) {
        guard let built else { return done(false) }
        built.evaluateInSearch(
            "!!(window.__officeForms && window.__officeForms.unsaved && window.__officeForms.unsaved())"
        ) { value in
            MainActor.assumeIsolated { done((value as? Bool) == true) }
        }
    }

    /// The page as it looks right now, compressed. Drawn by the page's own
    /// process, so a view that is off screen — every tab but the one you are
    /// on — can still be pictured. Nil when there is nothing to draw.
    func snapshot(_ done: @escaping (Data?) -> Void) {
        guard failure == nil, let built, !built.unpainted else { return done(nil) }
        built.takeSnapshot(with: nil) { image, _ in
            guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                return done(nil)
            }
            DispatchQueue.global(qos: .utility).async {
                let data = Tab.jpeg(cg)
                DispatchQueue.main.async { done(data) }
            }
        }
    }

    /// A small picture of the page for the tab switcher. A sleeping tab's
    /// comes from the picture kept for waking it; a tab brought back from
    /// last time and not opened yet has none, rather than a page built for it.
    func preview(width: CGFloat, _ done: @escaping (NSImage?) -> Void) {
        if let picture {
            DispatchQueue.global(qos: .userInitiated).async {
                let source = CGImageSourceCreateWithData(picture as CFData, nil)
                let options = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(width * 2)
                ] as CFDictionary
                let thumbnail = source.flatMap { CGImageSourceCreateThumbnailAtIndex($0, 0, options) }
                DispatchQueue.main.async {
                    let image = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                    done(image)
                }
            }
            return
        }
        guard failure == nil, let built, !built.unpainted else { return done(nil) }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(width))
        built.takeSnapshot(with: configuration) { image, _ in done(image) }
    }

    nonisolated private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.55] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }

    /// What the store page's own button should say: added, on its way, or
    /// free to add.
    func tellStore(installed: [String], busy: String?) {
        guard let built,
              let data = try? JSONSerialization.data(withJSONObject: ["installed": installed, "busy": busy.map { $0 as Any } ?? NSNull()]),
              let json = String(data: data, encoding: .utf8)
        else { return }
        built.evaluateInSearch("window.__officeStore && window.__officeStore.state(\(json))")
    }

    /// The picture comes off the moment there is something better under it
    /// — the page, painted — or you reach for the page yourself.
    func uncover(after delay: TimeInterval = 0) {
        guard let shown = cover else { return }
        guard delay > 0 else {
            cover = nil
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.cover === shown else { return }
            self.cover = nil
        }
    }

    /// The page as it was when its video went out to the floating window,
    /// over it while it lands (see Browser.land).
    func cover(with picture: NSImage) {
        cover = picture
    }

    /// That picture off, if it is still the one up.
    func uncover(_ picture: NSImage) {
        guard cover === picture else { return }
        cover = nil
    }

    /// Set when WebKit said the page's process went away while nobody was
    /// looking at the tab. Coming back to it loads the page again rather
    /// than showing the white that is left.
    var stale = false

    /// The process behind this page just died while it was the one on
    /// screen. `reload()`/`reloadFromOrigin()` lean on state the dead
    /// process was keeping — asking for the address back instead is the
    /// same trick `revive()` and the hollow branch of `reload()` already
    /// use, and the one that doesn't depend on anything the crash took with
    /// it. Tried twice: right after a process dies, WebKit doesn't always
    /// accept the very next load, which is what a reload that looks like it
    /// did nothing actually was.
    func recoverFromCrash() {
        guard let address else { return }
        failure = nil
        loadAndVerify(address)
    }

    /// `web.load`, checked a moment later rather than trusted outright: a
    /// load handed to WebKit right after a process just died, or as the
    /// very first thing a freshly-built view is asked to do, doesn't always
    /// take — no error, no navigation, just a view that goes on sitting on
    /// about:blank with nothing left to say so. Still there, or still
    /// answering for a process that's already gone, is asked once more.
    private func loadAndVerify(_ url: URL, state: Any? = nil, tries: Int = 0) {
        // Wait for the stage to take the view back before loading into it. A
        // page loaded while its view is off any window boots as a hidden tab,
        // and a site that holds everything until it is shown — x.com does,
        // right down to making no request at all — can then miss being shown a
        // moment later and sit on its placeholder for good. Coming back to a
        // pinned tab after ⌘W is exactly that: select() asks for the view back
        // and wakes the page in the same breath, one synchronous step ahead of
        // SwiftUI actually putting the view on screen. Bounded at about a
        // second, so a wake with no stage waiting for it still loads rather
        // than hanging on one that will never come.
        let view = web
        if view.window == nil, tries < 50 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.loadAndVerify(url, state: state, tries: tries + 1)
            }
            return
        }
        // A tab that slept has its own history to go back to — the page, its
        // back list and its scroll position, in one. Anything else starts
        // from the address. A file does too: its history comes back without
        // the folder it may read, and showed nothing.
        if let state, !url.isFileURL {
            view.interactionState = state
        } else {
            view.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            guard built?.url?.absoluteString != "about:blank" else {
                web.open(url)
                return
            }
            web.evaluateJavaScript("document.readyState") { [weak self] _, error in
                MainActor.assumeIsolated {
                    guard let self, let error = error as NSError? else { return }
                    guard error.domain == WKErrorDomain,
                          error.code == WKError.webContentProcessTerminated.rawValue
                    else { return }
                    self.web.open(url)
                }
            }
        }
    }

    /// Coming back to a tab. A page whose process was taken away out of sight
    /// — memory pressure, a long sleep — comes back as a white rectangle, and
    /// WebKit does not always say so for a view that was out of its window.
    /// Asked anything at all, the page answers with one particular error, and
    /// the answer to that is to load it again.
    func revive() {
        cameForward()
        if stale {
            stale = false
            recoverFromCrash()
            return
        }
        guard isWeb, pending == nil, !loading, failure == nil else { return }
        // A view with no document behind an address: whatever emptied it, the
        // address is what to show, and reload alone would have nothing to do.
        if hollow, let address {
            web.open(address)
            return
        }
        web.evaluateJavaScript("document.readyState") { [weak self] _, error in
            MainActor.assumeIsolated {
                guard let self, let error = error as NSError? else { return }
                guard error.domain == WKErrorDomain,
                      error.code == WKError.webContentProcessTerminated.rawValue
                else { return }
                self.recoverFromCrash()
            }
        }
    }

    /// Opened for the first time since the app started, or coming back from
    /// ⌘W while pinned. Answers whether there was anything to wake — the
    /// caller's own `revive()`, right after this, is for a tab that went
    /// quiet a different way, and firing it too here raced this very load
    /// with a second one of its own for the same address.
    @discardableResult
    func wake() -> Bool {
        guard let url = pending else { return false }
        pending = nil
        typing = false
        immersed = false
        let state = memory
        memory = nil
        armResume(for: url)
        if let picture, let image = NSImage(data: picture) {
            cover = image
            // Whatever happens to the page, the picture doesn't outstay it.
            uncover(after: 4)
        }
        picture = nil
        loadAndVerify(url, state: state)
        return true
    }

    /// A tab opened by a link is not blank, even though WebKit hasn't started
    /// loading it yet. Saying so now keeps the empty state from flashing up in
    /// the frame between the tab appearing and the page committing.
    func setAddressOptimistically(_ url: URL, link: String? = nil) {
        address = url
        lead(url, known: TitleSource.best(history: knowsTitle?(url), link: link))
        failure = nil
        adoptIcon()
    }

    /// A new tab again: where it was going turned out to be a file, not a
    /// page, and an address kept for it downloads the file once more
    /// whenever the tab is opened (see Browser.dropEmpty).
    func forget() {
        address = nil
        heading = .blank
        hinted = false
        icon = nil
    }

    func touch(at when: Date = Date()) { touched = when }

    func seal(_ value: String) {
        guard value.count >= 4 else { return }
        sealed.insert(value)
    }

    /// True when the web view holds nothing — never loaded, or emptied —
    /// while the tab still names a page. The white page, in other words.
    var hollow: Bool {
        guard let built else { return address != nil }
        guard let there = built.url else { return address != nil }
        return there.absoluteString == "about:blank" && pending == nil && address != nil
    }

    /// A view that has lost its document is given the address back instead:
    /// there is nothing else for it to reload.
    func reload(fromOrigin: Bool = false) {
        if failure == MemoryWords.title {
            recoverFromCrash()
            return
        }
        if reach(.reload(fromOrigin: fromOrigin)) { return }
        kicks.reload += 1
        // Search's own pages are drawn from what is there now, always.
        guard page == nil else { return }
        let again = retry.tryAgain()
        // A pin put down with ⌘W has no view left to reload; waking it is
        // the reload.
        guard !wake() else { return }
        if let again {
            web.open(again)
            return
        }
        armResume(for: address)
        // A file is read again with the folder it may read (see open).
        if let address, hollow || address.isFileURL {
            web.open(address)
        } else if fromOrigin {
            web.reloadFromOrigin()
        } else {
            web.reload()
        }
    }
    func armResume(for url: URL?) {
        guard let spot = Resume.armed(videoSpot, for: url) else { return }
        resumeArm = (spot, Date())
    }

    func resumeAnswer(page: String, duration: Double, current: Double, now: Date = Date()) -> Double? {
        guard let arm = resumeArm else { return nil }
        let seek = Resume.seek(saved: arm.spot, armedAt: arm.at, page: page, duration: duration, current: current, now: now)
        if seek != nil || arm.spot.url != page || now.timeIntervalSince(arm.at) > Resume.within
            || Resume.decides(saved: arm.spot, duration: duration) {
            resumeArm = nil
        }
        return seek
    }

    func stop() {
        if reach(.stop) { return }
        kicks.stop += 1
        web.stopLoading()
    }
    private(set) var goingBack = false
    @ObservationIgnored private var headed: (from: URL?, type: WKNavigationType)?
    @ObservationIgnored private(set) var arrival = LiveArrival()

    func began(asked: Bool) {
        arrival = headed.map { LiveArrival(from: $0.from, type: $0.type, asked: asked) } ?? LiveArrival()
        headed = nil
    }

    func redirected() {
        arrival.redirected = true
    }

    func heads(_ action: WKNavigationAction, in web: WKWebView) {
        headsForRetry(action)
        headed = (committed, action.navigationType)
        switch action.navigationType {
        case .reload: armResume(for: action.request.url)
        case .linkActivated, .formSubmitted, .formResubmitted: resumeArm = nil
        default: break
        }
        switch action.navigationType {
        case .backForward:
            let list = web.backForwardList
            let left = committed ?? address
            if list.currentItem?.url == action.request.url {
                if list.forwardItem?.url == left { goingBack = true } else if list.backItem?.url == left { goingBack = false }
            } else if action.request.url == list.backItem?.url {
                goingBack = true
            } else if action.request.url == list.forwardItem?.url {
                goingBack = false
            }
        case .other where loading:
            break
        default:
            goingBack = false
        }
    }

    /// Straight through, every time. A page that has to be fetched again is
    /// fetched again — nothing is kept behind to make that look otherwise.
    func back() {
        if page == nil, reach(.back) { return }
        kicks.back += 1
        goingBack = true
        if let page {
            guard let last = trail.popLast() else { return }
            ahead.append(page)
            self.page = last
            title = last.title
            adoptIcon()
            steps()
            return
        }
        // At the first web page after one of Search's own: back to it.
        if let behind, built?.canGoBack != true {
            show(behind, stepping: false)
            return
        }
        web.goBack()
    }
    func forward() {
        if page == nil, reach(.forward) { return }
        kicks.forward += 1
        goingBack = false
        if let page {
            guard let next = ahead.popLast() else { return }
            trail.append(page)
            self.page = next
            title = next.title
            adoptIcon()
            steps()
            return
        }
        web.goForward()
    }
    /// Every page that way, nearest first, for the list a held Back or
    /// Forward shows: the web pages WebKit keeps. Nothing for a tab whose
    /// page was never built, or one showing a page of Search's own, whose
    /// steps are kept apart (`trail`, `ahead`).
    func pages(back: Bool) -> [WKBackForwardListItem] {
        guard let built, page == nil else { return [] }
        return back ? built.backForwardList.backList.reversed() : built.backForwardList.forwardList
    }
    /// Straight to a page several steps away, as one step.
    func go(to item: WKBackForwardListItem) {
        guard isStuck else {
            web.go(to: item)
            return
        }
        restart { [weak self] in self?.web.go(to: item) }
    }

    /// Called when the tab is thrown away. Without it the view keeps running
    /// whatever the page left behind — timers, video, sockets.
    func close() {
        cancelImageText()
        LocalNetworkGuard.shared.forget(tab: id)
        onZoom = nil
        onLink = nil
        onPick = nil
        onPickEnd = nil
        onSignIn = nil
        onField = nil
        onCredentials = nil
        Bench.forgetRow(id)
        // A peek or a small window put away: gone for the extensions too.
        Extensions.shared.closedAside(self)
        discard()
        // The last private tab gone, in every window: what its pages wore
        // goes with it.
        guard shy else { return }
        let others = Browsers.all.flatMap { $0.tabs + $0.parkedTabs }
        if !others.contains(where: { $0.shy && $0 !== self }) { Favicons.shared.forgetShy() }
    }

    /// The page's sound started or stopped. Stopped, after it had played,
    /// one timer counts down; started again, or the page gone, it is dropped.
    private func heard(_ on: Bool) {
        let was = noisy
        noisy = on
        soundChanged(noisy: true)
        quiet?.invalidate()
        quiet = nil
        guard was, !on else { return }
        quiet = Timer.scheduledTimer(withTimeInterval: MediaKeys.wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hush() }
        }
    }

    /// The page is going: its count and its frames with it.
    var mediaFrames: [WKFrameInfo] { media.frames }

    func leaving() {
        quiet?.invalidate()
        quiet = nil
        media.forget()
        forgetSound()
        devLog.clear()
        agentDialog?.answer(ok: false)
        agentDialog = nil
    }

    /// Quiet long enough: the paused media muted, in the page and in each
    /// frame that played, so the Mac hands the media keys back.
    private func hush() {
        quiet = nil
        guard !noisy, let built else { return }
        built.evaluateJavaScript(MediaKeys.hush, in: nil, in: Web.world) { _ in }
        for frame in media.frames {
            built.evaluateJavaScript(MediaKeys.hush, in: frame, in: Web.world) { _ in }
        }
    }

    private func movedHouse() {
        guard let built else { return }
        if bench { built.configuration.preferences.isElementFullscreenEnabled = !(built.window is AgentPageRoom) }
        guard agent, built.window == nil else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.agent, let built = self.built, built.window == nil else { return }
                Bench.shared.house(self)
            }
        }
    }

    /// The view and everything listening to it, gone — timers, video,
    /// sockets, and the document WebKit would otherwise keep in its
    /// back-forward cache. The tab keeps its address; `web` builds again the
    /// next time anyone asks for it.
    private func discard() {
        reachToEnd()
        (delegate as? Browser)?.dropLeave(self)
        stopSettling()
        cancelImageText()
        device = nil
        popupGesture.clear()
        if !blockedPopups.isEmpty { blockedPopups = [] }
        translationGone(sleeping: true)
        watch = []
        ears.stop()
        quiet?.invalidate()
        quiet = nil
        media.forget()
        forgetSound()
        guard let web = built else { return }
        web.stopAllMedia()
        if Store.testing { Tab.letGo.add(web) }
        (delegate as? Browser)?.cancelDisplay(for: web)
        built = nil
        Passkeys.shared.forget(web)
        let controller = web.configuration.userContentController
        Web.release(controller)
        controller.removeAllUserScripts()
        // Other extension tabs still use this controller. Their existing
        // listeners need the relay, and their next documents need its script.
        if controller === Extensions.pages {
            PopupGestureRelay.install(on: controller)
            controller.addUserScript(PopupGestureRelay.userScript)
        }
        web.onMenuClosed = nil
        web.onStep = nil
        web.leave = nil
        web.onPull = nil
        web.refresh.onRefresh = nil
        web.refresh.allowed = nil
        web.onTouch = nil
        web.onKeys = nil
        web.searchName = nil
        web.translating = nil
        web.onTranslate = nil
        web.readsIn = nil
        web.onImage = nil
        web.onSearch = nil
        web.onWindow = nil
        web.stopLoading()
        // Detaching a view doesn't end capture while something still holds it.
        web.setCameraCaptureState(.none, completionHandler: nil)
        web.setMicrophoneCaptureState(.none, completionHandler: nil)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        guard web.fullscreenState != .notInFullscreen else {
            web.removeFromSuperview()
            web.closePage()
            return
        }
        web.closeAllMediaPresentations {
            MainActor.assumeIsolated {
                web.removeFromSuperview()
                web.closePage()
            }
        }
    }
}

extension WKWebView {
    func stopAllMedia() {
        pauseAllMediaPlayback(completionHandler: nil)
        setAllMediaPlaybackSuspended(true, completionHandler: nil)
        closeAllMediaPresentations(completionHandler: nil)
    }

    func closePage() {
        let close = NSSelectorFromString("_close")
        guard responds(to: close) else { return }
        perform(close)
    }
}


/// Whether the page is making noise.
///
/// WebKit knows, but only says so through a name that isn't part of the public
/// framework — so it is asked whether it answers to that name at all before
/// anyone listens, and the tab simply goes without the indicator if it doesn't.
final class AudioWatch: NSObject {
    private static let key = "_isPlayingAudio"

    private weak var web: WKWebView?
    private var tell: ((Bool) -> Void)?

    func watch(_ web: WKWebView, _ tell: @escaping (Bool) -> Void) {
        guard web.responds(to: NSSelectorFromString(AudioWatch.key)) else { return }
        self.web = web
        self.tell = tell
        web.addObserver(self, forKeyPath: AudioWatch.key, options: [.new], context: nil)
    }

    func stop() {
        guard let web, tell != nil else { return }
        web.removeObserver(self, forKeyPath: AudioWatch.key)
        tell = nil
        self.web = nil
    }

    override func observeValue(
        forKeyPath path: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard path == AudioWatch.key else { return }
        let on = (change?[.newKey] as? Bool) ?? false
        DispatchQueue.main.async { self.tell?(on) }
    }

    deinit { stop() }
}

/// The middle button on a link, as the page reports it.
///
/// A middle-click on a link opens it beside the tab you are on, in every
/// other browser, and WebKit leaves that to the browser: it tells the page
/// about the click and hands this app no navigation action for it at all, the
/// way it does for ⌘-click (and where it does report a button, it answers
/// with a mask — 1 left, 2 right, 4 middle — so a check for the middle button
/// as 2 would catch the right one). The page can see the click, though, so
/// the page is asked: its own `auxclick` for the middle button names the link
/// under the pointer, and from there it is an ordinary address to open.
///
/// Only the main frame, only a real link to somewhere this browser
/// would go, and only the middle button. A page's own handler runs as it
/// always did — this says where to, and changes nothing about the click.
///
/// Two things are checked before anything is opened. The event has to carry a
/// real click: a synthesized `auxclick` is not one, so a page that dispatches
/// its own does not get a tab per dispatch. And it has to be unclaimed — a
/// click a page has called `preventDefault` on is a click it has dealt with,
/// which is why this listens as the event comes back up rather than on the
/// way down, where nothing has answered yet.
final class MiddleRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeMiddle"

    weak var tab: Tab?

    static let watch = """
    (function () {
      if (window.__officeMiddle) return;
      window.__officeMiddle = true;
      // Heard on the way down, before the page's own handlers, since some
      // stop the event there — YouTube's links did, and a middle-click on
      // them opened nothing, only some of the time. Whether the page wanted
      // the click for itself is asked once they have all run: a page that
      // prevented it keeps it, as in Chrome.
      // The link is found now: once the event is over its path is empty.
      window.addEventListener('auxclick', function (e) {
        if (e.button !== 1 || !e.isTrusted) return;
        var href = link(e);
        if (!href) return;
        setTimeout(function () {
          if (!e.defaultPrevented) window.webkit.messageHandlers.officeMiddle.postMessage({ href: href });
        }, 0);
      }, true);
      // A page on this Mac linking to another file. WebKit lets a file page
      // read only its own folder, and drops a click on a link out of it
      // before Search is asked: the page stayed where it was, and only the
      // address typed in opened it. Search opens it the way it opens a typed
      // one. A plain click the page hasn't claimed, to a file, not a jump
      // within the page and not a download.
      if (location.protocol === 'file:') window.addEventListener('click', function (e) {
        if (e.button !== 0 || !e.isTrusted || e.defaultPrevented) return;
        if (e.metaKey || e.ctrlKey || e.altKey || e.shiftKey) return;
        var a = anchor(e);
        if (!a || a.hasAttribute('download')) return;
        var target = (a.getAttribute('target') || '').toLowerCase();
        if (['', '_self', '_top', '_parent', '_blank'].indexOf(target) < 0) return;
        var href = a.href;
        if (typeof href !== 'string' || href.indexOf('file:') !== 0) return;
        if (href.split('#')[0] === location.href.split('#')[0]) return;
        e.preventDefault();
        window.webkit.messageHandlers.officeMiddle.postMessage({ file: href, blank: target === '_blank' });
      }, false);
      function words(e) {
        var a = anchor(e);
        if (!a || typeof a.href !== 'string' || !a.href) return;
        var target = (a.getAttribute('target') || '').toLowerCase();
        if (!(e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1 || target === '_blank')) return;
        var said = (a.getAttribute('title') || a.getAttribute('aria-label') || a.innerText || '').trim();
        if (said) window.webkit.messageHandlers.officeMiddle.postMessage({ link: a.href, words: said.slice(0, 300) });
      }
      window.addEventListener('click', function (e) { if (e.isTrusted) words(e); }, true);
      window.addEventListener('auxclick', function (e) { if (e.isTrusted && e.button === 1) words(e); }, true);
      function anchor(e) {
        var path = e.composedPath();
        for (var i = 0; i < path.length; i++) {
          var tag = path[i].tagName ? path[i].tagName.toLowerCase() : '';
          if (tag === 'a' || tag === 'area') return path[i];
        }
        return null;
      }
      function link(e) {
        // The path, not the parents: a link inside an open shadow root is
        // on it too. An <area> of an image map is a link, and so is an SVG
        // <a>, whose href is an object that holds the address as written.
        var path = e.composedPath();
        for (var i = 0; i < path.length; i++) {
          var el = path[i];
          var tag = el.tagName ? el.tagName.toLowerCase() : '';
          if (tag !== 'a' && tag !== 'area') continue;
          var href = el.href;
          if (href && typeof href === 'object') {
            try { href = href.baseVal ? new URL(href.baseVal, el.baseURI).href : ''; } catch (_) { href = ''; }
          }
          if (!href) continue;
          return href;
        }
        return '';
      }
    })();
    """

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // A file page's link to another file (see watch): only from a file
        // page's main frame, only to a file, which then gets the folder it
        // would have had typed in, and no more (WKWebView.open).
        if let body = message.body as? [String: Any], let file = body["file"] as? String {
            guard message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol == "file",
                  let url = URL(string: file), url.isFileURL
            else { return }
            let blank = body["blank"] as? Bool ?? false
            MainActor.assumeIsolated { [weak self] in
                guard let self, let tab, tab.address?.isFileURL == true else { return }
                tab.onFileLink?(tab, url, blank)
            }
            return
        }
        if let body = message.body as? [String: Any], let link = body["link"] as? String, let words = body["words"] as? String {
            guard message.frameInfo.isMainFrame else { return }
            MainActor.assumeIsolated { [weak self] in self?.tab?.noteLink(href: link, words: words) }
            return
        }
        guard let body = message.body as? [String: Any],
              message.frameInfo.isMainFrame,
              let href = body["href"] as? String,
              let url = URL(string: href),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return }
        MainActor.assumeIsolated { [weak self] in
            guard let self, let tab else { return }
            tab.onMiddleClick?(tab, url)
        }
    }
}

/// A web view that reads the two-finger swipe for itself.
final class PageView: WKWebView {
    override init(frame: NSRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var deviceSize: NSSize? {
        didSet { superview?.needsLayout = true }
    }

    var onMenuClosed: (() -> Void)?
    var onStep: ((Bool) -> Void)?
    var onWindow: (() -> Void)?
    private(set) weak var started: WKNavigation?

    @discardableResult
    override func load(_ request: URLRequest) -> WKNavigation? {
        let navigation = super.load(request)
        started = navigation
        return navigation
    }

    @discardableResult
    override func goBack() -> WKNavigation? {
        onStep?(true)
        return super.goBack()
    }

    @discardableResult
    override func goForward() -> WKNavigation? {
        onStep?(false)
        return super.goForward()
    }

    override func didCloseMenu(_ menu: NSMenu, with event: NSEvent?) {
        super.didCloseMenu(menu, with: event)
        onMenuClosed?()
    }

    /// The page's own right-click menu. WebKit puts extensions' items for the
    /// page in it itself; Search adding them again showed each one twice.
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        JSONView.addItems(to: menu, in: self)
        if let open = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLink" }) {
            menu.removeItem(open)
        }
        // WebKit names it for a window, but a new window's page arrives here
        // as a new tab (Browser's createWebViewWith), so it says so. The tab
        // stays behind this one, as in Safari and Chrome, and as a ⌘-click's
        // does; with ⌥ held the item becomes one that goes to it, WebKit's
        // own, as it always was. Without a mouse's middle button, this is
        // the way to a tab in the background that needs no key held.
        if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierOpenLinkInNewWindow" }) {
            let item = menu.items[index]
            if let front = item.copy() as? NSMenuItem {
                front.title = "Open Link in New Tab and Switch to It"
                front.keyEquivalentModifierMask = .option
                front.isAlternate = true
                menu.insertItem(front, at: index + 1)
            }
            // With Split View on, the link beside this page instead, the two
            // as a pair. A copy of WebKit's item, for what WebKit reads off
            // it when the action reaches it.
            if Shared.prefs.splitView, let beside = item.copy() as? NSMenuItem {
                beside.title = "Open Link in Split View"
                beside.identifier = NSUserInterfaceItemIdentifier("SearchOpenLinkInSplitView")
                beside.keyEquivalentModifierMask = []
                beside.isAlternate = false
                beside.target = self
                beside.action = #selector(openLinkBeside(_:))
                // After Open Link in New Tab and the item ⌥ turns it into.
                var at = index + 1
                while at < menu.items.count, menu.items[at].isAlternate { at += 1 }
                menu.insertItem(beside, at: at)
            }
            openLink = (item.target, item.action)
            item.title = "Open Link in New Tab"
            item.keyEquivalentModifierMask = []
            item.target = self
            item.action = #selector(openLinkBehind(_:))
        }
        // Copy Clean Link (#594): under WebKit's Copy Link, the same link
        // without its tracking parameters. On the page itself, under Reload,
        // only when the page's own address has some, as Safari does.
        if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyLink" }) {
            let item = menu.items[index]
            if let clean = item.copy() as? NSMenuItem {
                copyLink = (item.target, item.action)
                clean.title = "Copy Clean Link"
                clean.identifier = NSUserInterfaceItemIdentifier("SearchCopyCleanLink")
                clean.target = self
                clean.action = #selector(copyCleanLink(_:))
                menu.insertItem(clean, at: index + 1)
            }
        } else if let url, CleanLink.clean(url) != url,
                  let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierReload" }) {
            let clean = NSMenuItem(title: "Copy Clean Link", action: #selector(copyCleanPage(_:)), keyEquivalent: "")
            clean.identifier = NSUserInterfaceItemIdentifier("SearchCopyCleanLink")
            clean.target = self
            clean.representedObject = url
            menu.insertItem(clean, at: index + 1)
        }
        // A picture that is also a link keeps this menu (ImageRelay), and
        // with it WebKit's Copy Image and Download Image, which on some sites
        // do nothing: this app's own do them instead, as its picture menu
        // does. Told of the picture just before this menu, for this menu only.
        if let image = keptImage {
            keptImage = nil
            let copyText = NSMenuItem(title: "Copy Text", action: #selector(copyImageText(_:)), keyEquivalent: "")
            copyText.target = self
            copyText.representedObject = image
            let imageIndex = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopyImage" })
            menu.insertItem(copyText, at: imageIndex.map { $0 + 1 } ?? menu.items.count)
            for (id, action) in [("WKMenuItemIdentifierCopyImage", #selector(copyImage(_:))),
                                 ("WKMenuItemIdentifierDownloadImage", #selector(downloadImage(_:)))] {
                guard let item = menu.items.first(where: { $0.identifier?.rawValue == id }) else { continue }
                item.target = self
                item.action = action
                item.representedObject = image
            }
        }
        // The bench's linkmenu: the item it names is chosen as the menu
        // comes up, the way a hand would choose it, and the menu goes.
        if Store.testing, let title = PageView.picking {
            PageView.picking = nil
            RunLoop.main.perform(inModes: [.eventTracking, .default]) {
                if let index = menu.items.firstIndex(where: { $0.title == title }) { menu.performActionForItem(at: index) }
                menu.cancelTracking()
            }
        }
        let ids = Set(menu.items.compactMap { $0.identifier?.rawValue })
        let picked = ids.contains("WKMenuItemIdentifierCopy")
        let onLink = ids.contains("WKMenuItemIdentifierCopyLink")
        let onImage = ids.contains("WKMenuItemIdentifierCopyImage")
        let webKit = ids.contains { $0.hasPrefix("WKMenuItemIdentifier") }
        if picked {
            let markdown = NSMenuItem(title: "Copy Selection as Markdown", action: #selector(copyPageAsMarkdown(_:)), keyEquivalent: "")
            markdown.target = self
            let highlight = highlightItem()
            if let copy = menu.items.firstIndex(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }) {
                var at = copy + 1
                while at < menu.items.count, !menu.items[at].isSeparatorItem { at += 1 }
                menu.insertItem(markdown, at: at)
                if let highlight { menu.insertItem(highlight, at: at + 1) }
            } else {
                menu.addItem(markdown)
                if let highlight { menu.addItem(highlight) }
            }
        } else if webKit, !onLink, !onImage {
            let markdown = NSMenuItem(title: "Copy Page as Markdown", action: #selector(copyPageAsMarkdown(_:)), keyEquivalent: "")
            markdown.target = self
            let rows = [NSMenuItem.separator()] + [translateItem(), markdown].compactMap { $0 }
            var at = PageView.pageRowsIndex(menu.items.map { $0.identifier?.rawValue })
            for row in rows {
                menu.insertItem(row, at: at)
                at += 1
            }
            if at < menu.items.count { menu.insertItem(.separator(), at: at) }
        }
        var previous: NSMenuItem?
        for item in menu.items where !item.isHidden {
            if item.isSeparatorItem, previous?.isSeparatorItem ?? true { item.isHidden = true } else { previous = item }
        }
        while let last = menu.items.last(where: { !$0.isHidden }), last.isSeparatorItem {
            last.isHidden = true
        }
        if let item = menu.items.first(where: { $0.identifier?.rawValue == "WKMenuItemIdentifierSearchWeb" }),
           let name = searchName?() {
            webSearch = (item.target, item.action)
            selection = nil
            evaluateJavaScript(PageView.selected, in: nil, in: .defaultClient) { [weak self] result in
                self?.selection = (try? result.get()) as? String ?? ""
            }
            item.title = "Search with \(name)"
            item.target = self
            item.action = #selector(searchSelection(_:))
        }
    }

    static func pageRowsIndex(_ ids: [String?]) -> Int {
        ids.firstIndex(of: "WKMenuItemIdentifierInspectElement") ?? ids.count
    }

    /// Translate Page to <your language>, or Show Original once it is:
    /// nothing while the switch is off.
    func translateItem() -> NSMenuItem? {
        guard PageTranslator.enabled, let on = translating?() else { return nil }
        let language = PageTranslator.name(PageTranslator.code(readsIn?() ?? PageTranslator.reader))
        let item = NSMenuItem(title: on ? "Show Original" : "Translate Page to \(language)", action: #selector(translatePage(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func translatePage(_ item: NSMenuItem) { onTranslate?() }

    private func highlightItem() -> NSMenuItem? {
        guard let tab = owner()?.1, let url = tab.address, tab.page == nil,
              ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let item = NSMenuItem(title: "Copy Link to Highlight", action: #selector(copyLinkToHighlight(_:)), keyEquivalent: "")
        item.target = self
        item.identifier = NSUserInterfaceItemIdentifier("SearchCopyLinkToHighlight")
        return item
    }

    private func owner() -> (Browser, Tab)? {
        for browser in Browsers.all {
            if let tab = browser.tabs.first(where: { $0.built === self }) { return (browser, tab) }
        }
        return nil
    }

    @objc private func copyLinkToHighlight(_ item: NSMenuItem) {
        guard let (browser, tab) = owner() else { return }
        browser.copyLinkToHighlight(tab)
    }
    @objc private func copyPageAsMarkdown(_ item: NSMenuItem) {
        for browser in Browsers.all {
            if let tab = browser.tabs.first(where: { $0.built === self }) {
                browser.copyPageAsMarkdown(tab)
                return
            }
        }
    }
    /// Whether the page is translated, and Translate Page / Show Original.
    var translating: (() -> Bool)?
    var onTranslate: (() -> Void)?
    var readsIn: (() -> Locale.Language)?

    /// The item the bench's linkmenu will choose in the next menu.
    static var picking: String?
    var searchName: (() -> String?)?
    var onSearch: ((String) -> Void)?
    private var selection: String?

    /// The words selected where the right-click was, read when the menu
    /// opens. The selection of a text field is its own, not the page's, so a
    /// field with the caret in it is asked first; a frame with the caret in it
    /// is looked into when it is of the same site. One of another site can't
    /// be, and gives nothing, so WebKit's own action takes the click, as it
    /// always did. A password field gives nothing either.
    static let selected = """
    (function read(doc) {
      var el = doc.activeElement;
      if (el && /^(IFRAME|FRAME)$/.test(el.tagName)) {
        try { return el.contentDocument ? read(el.contentDocument) : ''; } catch (e) { return ''; }
      }
      if (el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && el.type !== 'password'))) {
        try {
          var from = el.selectionStart, to = el.selectionEnd;
          if (typeof from === 'number' && typeof to === 'number' && to > from) return el.value.slice(from, to);
        } catch (e) {}
      }
      if (el && el.tagName === 'INPUT' && el.type === 'password') return '';
      var s = doc.getSelection();
      return s ? s.toString() : '';
    })(document)
    """
    private var webSearch: (target: AnyObject?, action: Selector?) = (nil, nil)

    /// WebKit's Open Link in New Window, handed on once the tab it makes is
    /// marked to stay behind. WebKit asks for that tab a moment later, from
    /// the page's process (Browser's createWebViewWith), so the mark lasts a
    /// second and is used up by the first tab asked for.
    private var openLink: (target: AnyObject?, action: Selector?) = (nil, nil)
    private var behindSince: Date?

    @objc private func openLinkBehind(_ item: NSMenuItem) {
        guard let action = openLink.action else { return }
        behindSince = Date()
        NSApp.sendAction(action, to: openLink.target, from: item)
    }

    /// Whether the tab being made now is the menu's, to stay behind.
    func takeBehind() -> Bool {
        defer { behindSince = nil }
        return behindSince.map { Date().timeIntervalSince($0) < 1 } ?? false
    }

    /// WebKit's Copy Link, for Copy Clean Link to clean what it copies.
    private var copyLink: (target: AnyObject?, action: Selector?) = (nil, nil)

    @objc private func copyCleanLink(_ item: NSMenuItem) {
        guard let action = copyLink.action else { return }
        let count = NSPasteboard.general.changeCount
        NSApp.sendAction(action, to: copyLink.target, from: item)
        CleanLink.rewrite(since: count)
    }

    @objc private func copyCleanPage(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        CleanLink.copy(url)
    }

    /// The picture under the right-click, when this menu is WebKit's over
    /// one (see ImageRelay), or nil.
    var keptImage: URL?
    /// Copy Image (true) or Download Image (false), this app's own.
    var onImage: ((URL, Bool) -> Void)?
    var onImageText: ((URL) -> Void)?

    @objc private func copyImageText(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { onImageText?(url) }
    }

    @objc private func copyImage(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { onImage?(url, true) }
    }

    @objc private func downloadImage(_ item: NSMenuItem) {
        if let url = item.representedObject as? URL { onImage?(url, false) }
    }

    /// Open Link in Split View: the same action, the tab it makes marked to
    /// go beside this page, for a second, as the one behind is.
    private var besideSince: Date?

    @objc private func openLinkBeside(_ item: NSMenuItem) {
        guard let action = openLink.action else { return }
        besideSince = Date()
        NSApp.sendAction(action, to: openLink.target, from: item)
    }

    /// Whether the tab being made now is the menu's, to go beside this page.
    func takeBeside() -> Bool {
        defer { besideSince = nil }
        return besideSince.map { Date().timeIntervalSince($0) < 1 } ?? false
    }

    @objc private func searchSelection(_ item: NSMenuItem) {
        defer { selection = nil }
        guard let selection, !selection.isEmpty else {
            if let action = webSearch.action { NSApp.sendAction(action, to: webSearch.target, from: item) }
            return
        }
        let words = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty { onSearch?(words) }
    }

    /// Told where a sideways swipe has got to, and nil when there is none.
    var onPull: ((Pull?) -> Void)?
    lazy var refresh = PullRefresher(self)
    var leave: ((Bool) -> Bool)?
    /// Told the moment the page is reached for — a click, a scroll — so the
    /// picture of a tab waking up never stands between you and the page.
    var onTouch: (() -> Void)?
    /// The page's first frame is on screen (see showFirstFrame).
    var onFirstFrame: (() -> Void)?
    /// Told when the keys come to this page, however they got here — a
    /// click, or Tab walked past the other page's last field. With two
    /// pages up it makes this one the focused page (Browser.prepare), which
    /// is safe only because a page can't ask for the keys itself: Search
    /// doesn't implement WebKit's focus request, so element.focus() and
    /// window.focus() never make this view first responder. If that is ever
    /// added, it must not do so for the page that isn't focused.
    var onKeys: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onKeys?() }
        return took
    }

    static var webKitDecidesFirstMouse = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PageView.webKitDecidesFirstMouse ? super.acceptsFirstMouse(for: event) : true
    }

    func webKitAcceptsFirstMouse(for event: NSEvent?) -> Bool { super.acceptsFirstMouse(for: event) }

    override func mouseDown(with event: NSEvent) {
        // A press that reaches the page under a peek is a press beside the
        // panel, which puts the peek away (see Peek.swift); under the column
        // it is nobody's.
        if underCover(event) {
            if let browser, browser.peekTab != nil, browser.peekTab?.built !== self { browser.closePeek() }
            return
        }
        onTouch?()
        super.mouseDown(with: event)
    }

    // MARK: - a paused video filling the screen

    /// A video filling the screen and paused gets VisionKit's view laid over
    /// the whole page, a moment later: WebKit has looked into the frame on
    /// screen for text and a subject to lift (VKCImageAnalysisOverlayView).
    /// It has click recognizers of its own, and the one for a single click
    /// took every click, text under it or not: AppKit held the press back
    /// while it decided, the recognizer said yes, and the press never reached
    /// the page. The click that paused a YouTube video was the last the page
    /// heard: neither the video nor its play button played it again, only
    /// the space bar did. Hidden, it is out of the way of the clicks, and
    /// WebKit takes it away itself once the video plays. WebKit's switch
    /// for it (TextRecognitionInVideosEnabled) can't be turned off instead:
    /// the page's process asks all the same, and WebKit ends a process that
    /// asks for what is switched off, so the video's page crashed.
    private weak var hiddenAnalysis: NSView?

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        guard NSStringFromClass(type(of: subview)).hasPrefix("VKCImageAnalysisOverlayView") else { return }
        if fullscreenState != .notInFullscreen {
            subview.isHidden = true
            hiddenAnalysis = subview
        } else if subview === hiddenAnalysis {
            // The same view, back over a picture in the page: as WebKit has it.
            subview.isHidden = false
            hiddenAnalysis = nil
        }
    }

    // MARK: - under the column or a peek

    /// The pointer is over the page, but under something of the window's
    /// lying on it: the column out over the page while it is folded, or a
    /// peek and the dimming round it (Browser.covers). The window gives a
    /// click there to what is on top, but the page's own tracking area hears
    /// every move under it all the same — AppKit tracks by rectangle, not by
    /// what is in front — so WebKit went on lighting up links, opening menus
    /// that open on hover, showing their tooltips and turning the pointer
    /// into a hand or a caret over the column and the dimmed page (idea 418).
    /// Under cover the page is told once that the pointer has gone, and
    /// hears nothing more of it until it is back.
    private(set) var covered = false

    /// The browser of the window the page is in.
    private var browser: Browser? {
        guard let window else { return nil }
        return Browsers.all.first { $0.window === window }
    }

    /// Whether the event is under cover, and if so, the page told so.
    private func underCover(_ event: NSEvent) -> Bool {
        guard let window, event.window == nil || event.window === window,
              browser?.covers(self, at: event.locationInWindow) == true
        else {
            covered = false
            return false
        }
        guard !covered else { return true }
        covered = true
        // WebKit reads a pointer leaving as one more move, where it left:
        // told it left from far outside the page, nothing in the page is
        // under it any more, and the pointer goes back to an arrow.
        if let gone = NSEvent.enterExitEvent(
            with: .mouseExited, location: NSPoint(x: -10_000, y: -10_000), modifierFlags: [],
            timestamp: event.timestamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: 0, userData: nil
        ) {
            super.mouseExited(with: gone)
        }
        NSCursor.arrow.set()
        return true
    }

    /// Whether a move, an entry or a cursor update for the page is to go
    /// through: not under cover (see PointerGate).
    func hears(_ event: NSEvent) -> Bool { !underCover(event) }

    /// WebKit's tracking areas aren't the view's: their owner is an object of
    /// WebKit's own (WKMouseTrackingObserver) that hands each move straight
    /// to the page, past this view's mouseMoved. Each goes behind a gate of
    /// ours with the same rectangle and options, which asks the page first.
    private var gates: [PointerGate] = []

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        gateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        gateTrackingAreas()
        onWindow?()
    }

    func gateTrackingAreas() {
        for area in trackingAreas {
            guard let owner = area.owner, owner !== self, !(owner is PointerGate) else { continue }
            let gate = PointerGate(page: self, target: owner as AnyObject)
            removeTrackingArea(area)
            // One WebKit has made again replaces our gate for the old one.
            for old in trackingAreas where old.options == area.options && (old.owner as? PointerGate)?.target === owner {
                removeTrackingArea(old)
            }
            addTrackingArea(NSTrackingArea(rect: area.rect, options: area.options, owner: gate, userInfo: area.userInfo))
            gates.append(gate)
        }
        // Gates whose area WebKit has since taken away go too.
        let live = Set(trackingAreas.compactMap { $0.owner as? PointerGate }.map(ObjectIdentifier.init))
        gates.removeAll { !live.contains(ObjectIdentifier($0)) }
    }

    override func mouseMoved(with event: NSEvent) {
        if underCover(event) { return }
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        if underCover(event) { return }
        super.mouseEntered(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        if underCover(event) { return }
        super.rightMouseDown(with: event)
    }

    /// The side buttons a mouse has for back and forward — button 3 and 4.
    /// No standard hands out that numbering; it's the X11 button order
    /// (0 left, 1 right, 2 middle, 3 back, 4 forward) that most mouse
    /// drivers settled on regardless, so it's what a mouse's own firmware
    /// is tuned to send.
    override func otherMouseDown(with event: NSEvent) {
        if underCover(event) { return }
        switch event.buttonNumber {
        case 3 where canGoBack: goBack()
        case 3 where leave?(false) == true: _ = leave?(true)
        case 4 where canGoForward: goForward()
        default: super.otherMouseDown(with: event)
        }
    }

    /// Logi Options+ sends its Back/Forward buttons as a swipe, not buttons
    /// 3 and 4 — deltaX 1 for back, -1 for forward, as Safari reads it.
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0, canGoBack { goBack() }
        else if event.deltaX > 0, leave?(false) == true { _ = leave?(true) }
        else if event.deltaX < 0, canGoForward { goForward() }
        else { super.swipe(with: event) }
    }

    // MARK: - keys the page didn't use

    /// The keys lately handed to the page. WebKit sends a key the page didn't
    /// use back up the responder chain — the same event, a second time —
    /// where nothing takes it and macOS plays its "can't do that" sound.
    /// Editors that put the text in themselves (X's reply box, anything built
    /// on Draft.js) leave WebKit thinking their keys unused, and so does a
    /// game that moves on the arrows without saying so (#402). Safari keeps
    /// those quiet, and so does this view. The app's own shortcuts never get
    /// this far: its key monitor takes them before the page sees the key.
    ///
    /// Several, not the last one: WebKit answers a moment later, and keys
    /// pressed quickly — or held, repeating — arrive before the answer for
    /// the one before. Remembering only the last, every earlier key beeped.
    private var handed: [NSEvent] = []
    /// How many came back unused and were kept quiet, for the bench.
    static var quieted = 0

    override func keyDown(with event: NSEvent) {
        if let index = handed.firstIndex(where: { PageView.same($0, event) }) {
            handed.remove(at: index)
            PageView.quieted += 1
            return
        }
        handed.append(event)
        // A key the page did use never comes back: only the latest few are
        // kept, and none older than a couple of seconds.
        let now = event.timestamp
        handed.removeAll { now - $0.timestamp > 2 }
        if handed.count > 32 { handed.removeFirst(handed.count - 32) }
        super.keyDown(with: event)
    }

    /// The same key press: the event WebKit sends back is the one it was
    /// given, and no two presses share a timestamp.
    static func same(_ one: NSEvent, _ other: NSEvent) -> Bool {
        one === other || (one.timestamp == other.timestamp && one.keyCode == other.keyCode && one.type == other.type)
    }

    // MARK: - the first frame

    /// A web view that has never drawn is opaque white. In a dark window that
    /// is a flash of it between a link that opens a tab and the page arriving,
    /// so a fresh view starts unseen, over the window's own ground, and comes
    /// in once WebKit says there is something on it worth seeing.
    private(set) var unpainted = false

    /// WebKit says when the first frame is only through names outside the
    /// public framework, so it is asked whether it answers to them first. One
    /// that doesn't gets a view shown straight away, as before.
    func holdForFirstFrame() {
        let observe = NSSelectorFromString("_setObservedRenderingProgressEvents:")
        guard responds(to: observe) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, UInt) -> Void
        unsafeBitCast(method(for: observe), to: Setter.self)(self, observe, PageView.firstFrame)
        unpainted = true
        alphaValue = 0
    }

    /// In, quickly: the page is there, and the fade only covers the frame
    /// between WebKit laying it out and putting it on screen.
    func showFirstFrame() {
        guard unpainted else { return }
        unpainted = false
        onFirstFrame?()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PageView.firstFrameFade
            animator().alphaValue = 1
        }
        (superview as? StageView)?.painted(self)
    }

    static let firstFrameFade: TimeInterval = 0.12

    func showUnlessBlank() {
        guard unpainted else { return }
        guard url?.absoluteString == "about:blank" else { return showFirstFrame() }
        evaluateJavaScript(PageView.holdsAnything) { [weak self] value, _ in
            MainActor.assumeIsolated {
                if (value as? Bool) != false { self?.showFirstFrame() }
            }
        }
    }

    static let holdsAnything = "!!(document.body && (document.body.children.length || document.body.textContent.trim().length)) || !!(document.head && document.head.querySelector('style, link[rel=stylesheet]'))"

    /// _WKRenderingProgressEventFirstVisuallyNonEmptyLayout — the moment
    /// Safari takes down the picture it shows while a page comes back.
    static let firstFrame: UInt = 1 << 1

    // MARK: - two fingers sideways

    private enum Axis { case across, down }

    private var pinchOrigin: [Double]?
    private var pinchTicket = 0
    private var sideways: CGFloat = 0
    private var gatheredX: CGFloat = 0
    private var gatheredY: CGFloat = 0
    private var axis: Axis?
    /// Which way the gesture set off, decided once and kept. Turning round
    /// mid-swipe pulls the disc back; it never becomes the other disc.
    private var back = true
    /// The page's word on whether this swipe is its own. Nil until it says.
    private var free: Bool?
    private var asked: Date?
    /// Already went somewhere, or was refused: nothing more this gesture.
    private var spent = false
    private var armedNow = false
    private var showing = false
    private var going = false
    /// This gesture went back or forward. The glide that follows the fingers
    /// lifting arrives after the page has gone, and WebKit hands it to the
    /// page coming back: it pulled that page sideways past its edge, where it
    /// stayed, and scrolled it away from where it was being put back (a
    /// GitHub list came back 181 points to the side and 961 short of where it
    /// was left). So the glide goes to no page at all.
    private var went = false
    private var pulls = 0
    /// Armed and held there: in a moment the disc becomes the list of pages
    /// that way, and moving the fingers up or down picks one (as in Dia).
    private var holding: DispatchWorkItem?
    private var stops: [Stop]?
    private var items: [WKBackForwardListItem] = []
    private var picked = 0
    /// How far the fingers have gone up (or down, below nought) since the
    /// last step through the list.
    private var climbed: CGFloat = 0
    /// Settings › General › Hold a swipe to pick from history. Off unless
    /// asked for; off, a held swipe is a swipe like any other.
    static var holdsHistory = false
    /// How long armed before the list, and how far up or down a step is.
    private static let hold: TimeInterval = 0.45
    private static let step: CGFloat = 22

    /// How far the fingers travel before letting go means it. It was 110,
    /// and going back took a long reach across the trackpad — "too far",
    /// people said; Safari goes on less.
    static let arm: CGFloat = 70
    /// A quick flick goes too, short of that, as it does in Safari: at least
    /// this far, within `flickTime` of setting off.
    private static let flick: CGFloat = 30
    private static let flickTime: TimeInterval = 0.25
    /// Less than this and there is nothing to show yet — or nothing left to.
    private static let show: CGFloat = 6

    // MARK: - two fingers together

    // The pinch itself is WebKit's own: during the gesture it scales the
    // rendered layers on the GPU around the fingers and only lays the page
    // out again once they lift. Doing the same from here — a real change of
    // scale on every event — was measured at a few frames a second, and the
    // public `setMagnification(_:centeredAt:)` ignores its point and resets
    // the scroll besides, so the pinch stays with WebKit. What is handled
    // here is the one-shot gesture WebKit does not do well on its own.

    /// Two fingers, tapped twice: the block under them fills the width, the
    /// way Safari's smart zoom does; tapped again, the page is back at its
    /// own size with the same spot still under the fingers. The page picks
    /// the block — it is the only one that knows where a column ends.
    override func smartMagnify(with event: NSEvent) {
        guard allowsMagnification else {
            super.smartMagnify(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let js = PageView.smart(x: point.x, y: point.y, scale: magnification, width: bounds.width)
        evaluateJavaScript(js) { [weak self] value, _ in
            MainActor.assumeIsolated {
                guard let self, let text = value as? String, let data = text.data(using: .utf8),
                      let zoom = try? JSONDecoder().decode(SmartZoom.self, from: data)
                else { return }
                self.setMagnification(zoom.scale, centeredAt: point)
                self.evaluateJavaScript("window.scrollTo(\(zoom.x), \(zoom.y))")
            }
        }
    }

    private struct SmartZoom: Decodable {
        var scale: CGFloat
        var x: CGFloat
        var y: CGFloat
    }

    /// Where a smart zoom should land: the scale that fits the block under
    /// the fingers to the width, and the scroll that puts it there with the
    /// tapped spot at the same height. Zoomed in already, it is the way back.
    /// Scroll positions are CSS pixels of the whole page — `window.scrollTo`
    /// moves the magnified view here even on a page whose own overflow is
    /// hidden — and they are read before the scale changes, since the
    /// change itself sends the scroll to the corner.
    static func smart(x: CGFloat, y: CGFloat, scale: CGFloat, width: CGFloat) -> String {
        """
        (function (x, y, s, W) {
          var ox = window.scrollX, oy = window.scrollY;
          var cx = x / s, cy = y / s;
          if (s > 1.05) {
            return JSON.stringify({ scale: 1, x: Math.max(0, ox + cx - x), y: Math.max(0, oy + cy - y) });
          }
          var el = document.elementFromPoint(cx, cy);
          if (!el) return null;
          // The innermost block wide enough to be a column of something — a
          // paragraph's column, a card, a feed — rather than the whole page's
          // layout, which is what walking up to a wide ancestor finds.
          var vw = W / s, best = null, enough = Math.max(240, vw * 0.2);
          for (var e = el; e && e !== document.documentElement; e = e.parentElement) {
            var r = e.getBoundingClientRect();
            if (r.width < 80 || r.height < 16) continue;
            var d = getComputedStyle(e).display;
            if (d === 'inline' || d === 'contents') continue;
            if (!best) best = r;
            if (r.width >= enough) { best = r; break; }
          }
          if (!best) best = el.getBoundingClientRect();
          var pad = 12;
          var target = Math.max(1, Math.min(3, W / (best.width + 2 * pad)));
          if (target < 1.15) target = Math.min(3, s * 2);
          return JSON.stringify({
            scale: target,
            x: Math.max(0, ox + best.left - pad),
            y: Math.max(0, oy + cy - y / target)
          });
        })(\(x), \(y), \(scale), \(width))
        """
    }

    override func scrollWheel(with event: NSEvent) {
        onTouch?()
        if event.phase == .mayBegin || event.phase == .began {
            went = false
            Swipe.calm(self)
        }
        let pulled = refresh.reads(event)
        if went, event.momentumPhase != [] { return }
        // The page gets every event first and scrolls as it always did. The
        // swipe is only read, never taken — except while its list is open,
        // when up and down are picking a page, not scrolling this one. The
        // gesture's end still reaches the page, which saw it begin.
        if !pulled, stops == nil || event.phase == .ended || event.phase == .cancelled {
            super.scrollWheel(with: event)
        }
        // Only a live trackpad gesture — not its glide afterwards, and not a
        // mouse wheel, which has no beginning or end to speak of.
        guard event.momentumPhase == [] else { return }
        // And only while the Mac says a swipe may go between pages.
        guard Swipe.followsTheMac else { return }

        switch event.phase {
        case .mayBegin, .began:
            pinchTicket += 1
            let ticket = pinchTicket
            pinchOrigin = nil
            if magnification > 1.01 {
                evaluateJavaScript("[visualViewport.pageLeft, document.documentElement.clientWidth - visualViewport.width - visualViewport.pageLeft]") { [weak self] value, _ in
                    guard let self, self.pinchTicket == ticket, let origin = value as? [Double], origin.count == 2 else { return }
                    self.pinchOrigin = origin
                    if self.axis == .across, origin[self.back ? 0 : 1] > 1 {
                        self.answer(free: false)
                    }
                }
            }
            sideways = 0
            gatheredX = 0
            gatheredY = 0
            axis = nil
            free = nil
            asked = nil
            spent = false
            armedNow = false
            showing = false
            holding?.cancel()
            holding = nil
            stops = nil
            items = []
            // A disc still on its way out belongs to the last gesture. It is
            // already invisible; it is only taken off the stage so the next
            // one arrives fresh rather than fading back in.
            pulls += 1
            if going {
                going = false
                onPull?(nil)
            }
        case .changed:
            guard !spent else { return }
            if axis == nil {
                // A few points in, the gesture has shown which way it means
                // to go. Only a clearly sideways one is read further.
                gatheredX += abs(event.scrollingDeltaX)
                gatheredY += abs(event.scrollingDeltaY)
                sideways += event.scrollingDeltaX
                guard gatheredX + gatheredY > 6 else { return }
                axis = gatheredX > gatheredY * 1.3 ? .across : .down
                if axis == .down {
                    spent = true
                    return
                }
                back = sideways > 0
                if let pinchOrigin, pinchOrigin[back ? 0 : 1] > 1 {
                    spent = true
                    return
                }
                // Nowhere to go that way: nothing to show, and nothing more
                // to read from this gesture.
                if back ? !canGoBack && leave?(false) != true : !canGoForward {
                    spent = true
                    return
                }
                asked = Date()
                tell()
                return
            }
            sideways += event.scrollingDeltaX
            if stops != nil { climb(event) }
            tell()
        case .ended:
            release()
        case .cancelled:
            spent = true
            settle(nil)
        default:
            break
        }
    }

    /// The page has said whether the swipe would scroll something.
    func answer(free yes: Bool) {
        guard axis != .down, !spent else { return }
        guard yes else {
            free = false
            spent = true
            settle(nil)
            return
        }
        guard free == nil else { return }
        free = true
        tell()
    }

    /// Only the distance in the direction it set off in. Past the origin the
    /// other way is just nought.
    private var travel: CGFloat { max(0, back ? sideways : -sideways) }

    private func tell() {
        if free == nil, let asked, Date().timeIntervalSince(asked) > 0.18 {
            // A page that never answers — a PDF, a page that failed to load —
            // still has to be leavable by hand.
            free = true
        }
        guard free == true else { return }

        let travel = travel
        // Drawn all the way back, the disc goes; drawn out again, it returns.
        // Nothing is decided until the fingers lift.
        guard travel >= PageView.show else {
            if showing { settle(nil) }
            return
        }

        let armed = travel >= PageView.arm
        if PageView.holdsHistory, stops == nil, armed != armedNow {
            holding?.cancel()
            holding = nil
            if armed {
                let hold = DispatchWorkItem { [weak self] in self?.openList() }
                holding = hold
                DispatchQueue.main.asyncAfter(deadline: .now() + PageView.hold, execute: hold)
            }
        }
        if armed != armedNow, stops == nil {
            // Two different taps: one for reaching it, a lighter one for
            // stepping back from it, so you know without looking that
            // letting go now is safe.
            NSHapticFeedbackManager.defaultPerformer.perform(
                armed ? .levelChange : .alignment, performanceTime: .now
            )
        }
        armedNow = armed
        settle(Pull(back: back, travel: travel, armed: armed, going: false, stops: stops, picked: picked))
    }

    /// Held long enough: the pages that way, nearest to the fingers — at the
    /// bottom going back, at the top going forward — and that one picked.
    private func openList() {
        holding = nil
        guard !spent, armedNow, stops == nil else { return }
        let list = back ? Array(backForwardList.backList.suffix(8)) : Array(backForwardList.forwardList.prefix(8))
        guard list.count >= 2 else { return }
        items = list
        stops = list.map { Stop(title: $0.title ?? "", url: $0.url) }
        picked = back ? list.count - 1 : 0
        climbed = 0
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        tell()
    }

    /// Through the list a step at a time, the list sliding with the fingers
    /// under a light that stays put, as in Dia: down brings the row above
    /// under it — further back, or nearer going forward — and up the row
    /// below. With natural scrolling the deltas run with the fingers,
    /// without it against them.
    private func climb(_ event: NSEvent) {
        guard let stops else { return }
        let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        climbed += -sign * event.scrollingDeltaY
        var moved = false
        while climbed >= PageView.step, picked < stops.count - 1 {
            picked += 1
            climbed -= PageView.step
            moved = true
        }
        while climbed <= -PageView.step, picked > 0 {
            picked -= 1
            climbed += PageView.step
            moved = true
        }
        // At either end, the fingers going on further count for nothing.
        climbed = max(-PageView.step, min(PageView.step, climbed))
        if moved { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
    }

    private func release() {
        defer { spent = true }
        // Let go before the list came: it doesn't come now.
        holding?.cancel()
        holding = nil
        let flicked = !spent && free == true && travel >= PageView.flick
            && (asked.map { Date().timeIntervalSince($0) <= PageView.flickTime } ?? false)
        guard !spent, free == true, armedNow || flicked || stops != nil else {
            settle(nil)
            return
        }
        going = true
        went = true
        settle(Pull(back: back, travel: travel, armed: true, going: true, stops: stops, picked: picked))
        if stops != nil, items.indices.contains(picked) {
            go(to: items[picked])
        } else if back {
            if canGoBack || leave?(true) != true { goBack() }
        } else {
            goForward()
        }
        pulls += 1
        let mine = pulls
        DispatchQueue.main.asyncAfter(deadline: .now() + GestureDisc.lingers) { [weak self] in
            guard let self, pulls == mine else { return }
            going = false
            settle(nil)
        }
    }

    private func settle(_ pull: Pull?) {
        if pull == nil {
            holding?.cancel()
            holding = nil
            stops = nil
            items = []
        }
        showing = pull != nil
        onPull?(pull)
    }

}

/// The owner of one of a page's tracking areas in place of WebKit's own:
/// it hands WebKit's object each move, entry and cursor update the page
/// hears, and keeps back those under a peek or the column (idea 418).
/// Leaving always goes through, so nothing stays lit up.
final class PointerGate: NSResponder {
    private weak var page: PageView?
    private(set) weak var target: AnyObject?

    init(page: PageView, target: AnyObject) {
        self.page = page
        self.target = target
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    private func pass(_ selector: Selector, _ event: NSEvent, always: Bool = false) {
        guard let target, target.responds(to: selector) else { return }
        if !always, let page, !page.hears(event) { return }
        _ = target.perform(selector, with: event)
    }

    override func mouseMoved(with event: NSEvent) { pass(#selector(NSResponder.mouseMoved(with:)), event) }
    override func mouseEntered(with event: NSEvent) { pass(#selector(NSResponder.mouseEntered(with:)), event) }
    override func cursorUpdate(with event: NSEvent) { pass(#selector(NSResponder.cursorUpdate(with:)), event) }
    override func mouseExited(with event: NSEvent) { pass(#selector(NSResponder.mouseExited(with:)), event, always: true) }
}

/// A content controller holds its handlers strongly, so this stands between the
/// two rather than the tab registering itself — otherwise a closed tab is kept
/// alive by the very page it was told to stop showing.
final class ScrollRelay: NSObject, WKScriptMessageHandler {
    static let name = "officeScroll"

    weak var tab: Tab?

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        if let pull = body["pull"] as? String {
            MainActor.assumeIsolated {
                (message.webView as? PageView)?.refresh.heard(pull, at: body["at"] as? Double ?? 0, frame: message.frameInfo)
            }
            return
        }
        guard let side = body["side"] as? String else { return }
        MainActor.assumeIsolated { tab?.web.answer(free: side == "free") }
    }
}



extension WKWebView {
    /// An address, or a file on this Mac. WebKit reads a file only when told
    /// which folder the page may read from, and loads nothing at all
    /// otherwise: an .html double-clicked in the Finder, once Search is the
    /// Mac's browser, opened a tab that stayed empty.
    func open(_ url: URL) {
        if url.isFileURL {
            // Its folder, for the pictures and styles beside it — unless the
            // folder is the home folder, the disk or a volume, where the
            // file alone is what was opened.
            let folder = url.deletingLastPathComponent().standardizedFileURL
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let tooWide = folder == home || ["/", "/Users", "/Volumes"].contains(folder.path)
                || folder.deletingLastPathComponent().path == "/Volumes"
            loadFileURL(url, allowingReadAccessTo: tooWide ? url : folder)
        } else {
            load(URLRequest(url: url))
        }
    }

    /// JavaScript run in Search's own world (see Web.world), where its page
    /// scripts are, answered the way `evaluateJavaScript` answers: the value,
    /// or nil for none or an error.
    func evaluateInSearch(_ js: String, then: ((Any?) -> Void)? = nil) {
        evaluateJavaScript(js, in: nil, in: Web.world) { result in
            then?(try? result.get())
        }
    }
}
