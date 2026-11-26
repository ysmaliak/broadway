import Security
import Observation
import AppKit
import Combine

// Everything there is to set, in one observable place.
//
// Each of these is a line in the settings file and nothing more; the object
// exists so that a panel can bind to them and the rest of the window can
// redraw when one changes. Defaults are chosen so that a browser nobody has
// configured behaves the way it always did.

/// How long a tab you aren't keeping stays open once you leave it (see
/// Closing.swift): never, or one of Arc's four choices, counted in hours.
enum TabLife: Int, CaseIterable, Identifiable {
    case never = 0, halfDay = 12, day = 24, week = 168, month = 720

    var id: Int { rawValue }
    /// Nil when tabs never close.
    var interval: TimeInterval? { self == .never ? nil : TimeInterval(rawValue) * 60 * 60 }

    var title: String {
        switch self {
        case .never: return "Never"
        case .halfDay: return "After 12 hours"
        case .day: return "After a day"
        case .week: return "After a week"
        case .month: return "After a month"
        }
    }
}

/// Which edge the tab column sits on when tabs are arranged in a sidebar.
enum SidebarPosition: String, CaseIterable, Identifiable {
    case left, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

@MainActor
@Observable
final class Preferences {

    private let store = Store.settings
    @ObservationIgnored private var hearers: [Hearer] = []

    final class Hearer {
        nonisolated(unsafe) fileprivate var live = true
        fileprivate let key: PartialKeyPath<Preferences>
        fileprivate let act: @MainActor (Preferences) -> Void

        fileprivate init(key: PartialKeyPath<Preferences>, act: @escaping @MainActor (Preferences) -> Void) {
            self.key = key
            self.act = act
        }
    }

    func onSet<Value>(_ key: KeyPath<Preferences, Value>, _ act: @escaping (Value) -> Void) -> AnyCancellable {
        let hearer = Hearer(key: key) { prefs in act(prefs[keyPath: key]) }
        hearers.append(hearer)
        return AnyCancellable { hearer.live = false }
    }

    private func heard(_ key: PartialKeyPath<Preferences>) {
        hearers.removeAll { !$0.live }
        for hearer in hearers where hearer.live && hearer.key == key { hearer.act(self) }
    }

    /// A local socket a script can drive the browser through, in tabs of its
    /// own. Off unless asked for — in Settings, which is also what leaves
    /// the mark it needs at launch (see Bench.Consent).
    var bench: Bool {
        didSet {
            if bench, !Bench.Consent.grant() { bench = false }
            store.set(bench, forKey: "bench")
            if !bench { Bench.Consent.revoke() }
            heard(\.bench)
        }
    }
    /// The setting said on at launch with no mark from the switch behind it,
    /// and was put back to off.
    @ObservationIgnored private(set) var benchRefused = false
    /// Light, dark, or the Mac's own.
    var look: Look {
        didSet {
            store.set(look.rawValue, forKey: "look")
            look.apply()
            heard(\.look)
        }
    }
    var appIcon: AppIcon {
        didSet {
            store.set(appIcon.rawValue, forKey: AppIcon.key)
            AppIconShown.apply(appIcon)
            heard(\.appIcon)
        }
    }
    /// The side panel's width, as you last left it (see SidePanel.swift).
    var sidePanelWidth: CGFloat {
        didSet {
            let kept = min(max(sidePanelWidth, Preferences.sidePanelWidths.lowerBound), Preferences.sidePanelWidths.upperBound)
            if kept != sidePanelWidth { sidePanelWidth = kept; return }
            store.set(Double(sidePanelWidth), forKey: "sidepanel.width")
        }
    }
    /// Which side the column is on when it is shown vertically.
    var sidePosition: SidebarPosition {
        didSet { store.set(sidePosition.rawValue, forKey: "sidebar.position") }
    }
    var sideButton: Bool {
        didSet { store.set(sideButton, forKey: "sidebar.button") }
    }
    var selectedShortcut: Bool {
        didSet { store.set(selectedShortcut, forKey: "sidebar.selected") }
    }
    var hints: Bool {
        didSet { store.set(hints, forKey: Preferences.hintsKey) }
    }
    nonisolated static let hintsKey = "general.hints"
    var columnWidth: CGFloat { sideWidth }
    var sideRow: CGFloat { Metrics.sideRowHeight }
    let sideTitle: CGFloat = 13
    /// How wide the column is. Pulled by its edge, and remembered.
    var sideWidth: CGFloat {
        didSet { store.set(Double(sideWidth), forKey: "sidebar.width") }
    }
    /// With the tabs down the side, the page as a card: a little room
    /// around it and rounded corners (see CardEdge). On unless turned off,
    /// since 1.0.5 shipped with it; off, the page reaches the window's edges
    /// and the column is white with its hairline, as before 1.0.5 (#607).
    var cards: Bool {
        didSet { store.set(cards, forKey: "layout.cards") }
    }
    var engine: Engine {
        didSet { store.set(engine.rawValue, forKey: "search.engine") }
    }
    var customEngine: String {
        didSet { store.set(customEngine, forKey: "search.custom") }
    }
    /// Shortcuts to a site's own search, ahead of the default engine (see
    /// Keyword.swift). Empty until someone adds one.
    var keywords: [Keyword] {
        didSet { store.set((try? JSONEncoder().encode(keywords)) ?? Data(), forKey: "search.keywords") }
    }
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    var keepsSitesAwake = true
    /// A tab gives a little under the pointer while it is pressed, as Arc's
    /// do (see Give). Off unless turned on.
    var hoverCards: Bool {
        didSet { store.set(hoverCards, forKey: "tabs.cards") }
    }
    var awakeSites: Set<String> {
        didSet { store.set(Array(awakeSites).sorted(), forKey: "tabs.awakeSites") }
    }
    static let awakeSeeds: Set<String> = [
        "web.whatsapp.com", "web.telegram.org", "app.slack.com", "discord.com", "messenger.com",
        "teams.microsoft.com", "teams.cloud.microsoft", "mail.google.com", "open.spotify.com",
        "music.youtube.com", "music.apple.com",
    ]
    static let awakeSeededKey = "tabs.awakeSites.seeded"

    static func suggests(stored: Any?, testing: Bool) -> Bool {
        stored as? Bool ?? !testing
    }

    static func seedAwakeSites(_ store: UserDefaults) -> Set<String> {
        let kept = Set(store.stringArray(forKey: "tabs.awakeSites") ?? [])
        guard !store.bool(forKey: awakeSeededKey) else { return kept }
        let seeded = kept.union(awakeSeeds)
        store.set(Array(seeded).sorted(), forKey: "tabs.awakeSites")
        store.set(true, forKey: awakeSeededKey)
        return seeded
    }
    /// Sites whose pages may open windows without a click just before
    /// (BlockedPopups.swift), each a registrable domain. Empty until you
    /// choose Always Allow on one; Settings › Privacy lists them.
    var popupSites: Set<String> {
        didSet { store.set(Array(popupSites).sorted(), forKey: "privacy.popupSites") }
    }
    /// Tabs you haven't pinned, named or grouped close once left alone this
    /// long, as in Arc. Never unless asked for.
    var tabLife: TabLife {
        didSet { store.set(tabLife.rawValue, forKey: "tabs.close.after") }
    }
    /// A tab opened behind the page — ⌘-click, the middle button, a batch
    /// of links from another app — waits to load until it is gone to, as a
    /// tab brought back from the last session does (see Browser.open).
    /// Off unless asked for.
    /// Settings › Privacy › Let sites ask to send notifications. On: a site
    /// asks on a card, and only what you allow ever reaches the Mac.
    var siteNotifications: Bool {
        didSet { store.set(siteNotifications, forKey: "notifications.ask") }
    }
    /// Each launch starts with a fresh window: the pins stay, last time's
    /// other tabs don't come back (see Session.startFresh). Off unless
    /// asked for (#406).
    var startsFresh: Bool {
        didSet { store.set(startsFresh, forKey: Preferences.freshKey) }
    }
    nonisolated static let freshKey = "start.fresh"
    /// Ask before the Quit menu or ⌘Q closes the app. Off unless asked for.
    var confirmsQuit: Bool {
        didSet { store.set(confirmsQuit, forKey: Preferences.confirmQuitKey) }
    }
    nonisolated static let confirmQuitKey = "quit.confirm"
    /// Search a site from the address field: the start of its name, then
    /// Tab (see SiteSearch.swift).
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    var searchesSites = true
    /// Suggestions from the search engine under the address field, as you
    /// type (see EngineSuggest.swift).
    var engineSuggests: Bool {
        didSet { store.set(engineSuggests, forKey: "search.suggest") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield"); heard(\.shielded) }
    }
    /// Settings › Privacy › Prevent cross-site tracking, turned off: WebKit's
    /// tracking prevention off, as Safari's same switch does (see
    /// Store.keepsSignIns). On unless turned off.
    var keepsSignIns: Bool {
        didSet {
            store.set(keepsSignIns, forKey: "sites.keep")
            Store.keepsSignIns = keepsSignIns
        }
    }
    /// Whether sites may ask for a passkey here. Off sends them to the
    /// password instead — the only thing that works in a build without
    /// Apple's browser entitlement.
    var passkeys: Bool {
        didSet { store.set(passkeys, forKey: "passkeys"); heard(\.passkeys) }
    }
    /// Whether this build can actually do them: signed with the entitlement,
    /// its profile embedded. Fixed for the life of the process.
    let passkeysPossible: Bool

    /// Asked of the running process's own signature, which is the only thing
    /// that decides it — a profile file in the bundle proves nothing on its
    /// own, and an ad-hoc build has neither.
    static var entitledToPasskeys: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task, "com.apple.developer.web-browser.public-key-credential" as CFString, nil
        )
        return (value as? Bool) == true
    }
    var downloads: URL {
        didSet { store.set(downloads.path, forKey: "downloads") }
    }
    var asksWhereToSave: Bool {
        didSet { store.set(asksWhereToSave, forKey: "downloads.ask") }
    }
    /// Offer to keep a password the first time a site sees it.
    var savesPasswords: Bool {
        didSet { store.set(savesPasswords, forKey: "passwords.save") }
    }
    /// Put a kept name and password into a sign-in as soon as one appears.
    var fillsPasswords: Bool {
        didSet { store.set(fillsPasswords, forKey: "passwords.fill") }
    }
    /// Accounts from the Mac's Passwords app under the sign-in box too, by
    /// Apple's helper for its Chrome extension (ApplePasswords.swift). Off
    /// unless turned on: unofficial, and it pairs with a code.
    var applePasswords: Bool {
        didSet { store.set(applePasswords, forKey: "passwords.apple") }
    }
    var onePassword: Bool {
        didSet { store.set(onePassword, forKey: "passwords.onepassword") }
    }
    /// macOS's own autocorrect, inside web pages: the little "Not ×" that
    /// capitalises what you meant to leave lower-case. As the Mac has it
    /// (System Settings › Keyboard › Correct spelling automatically) until
    /// the switch here is used.
    var autocorrect: Bool {
        didSet {
            store.set(autocorrect, forKey: "autocorrect")
            Preferences.tellWebKit(autocorrect: autocorrect)
            heard(\.autocorrect)
        }
    }
    /// How big every site is drawn until it has been zoomed on its own.
    var pageZoom: Double {
        didSet { store.set(pageZoom, forKey: "pageZoom"); heard(\.pageZoom) }
    }
    /// The stops the setting steps through — every 5%, from as small as
    /// anyone reads to as big as a page is worth.
    static let miniKey = "mini.on"
    static let miniSkipKey = "mini.skip"
    static let miniSpokenKey = "mini.spoken"
    static let miniSpeedKey = "mini.speed"
    static let zooms: [Double] = stride(from: 50, through: 300, by: 5).map { Double($0) / 100 }

    /// Pages with no dark look of their own darkened while the frame is
    /// dark (see Dusk.swift). Off unless asked for.
    var darkensPages: Bool {
        didSet {
            store.set(darkensPages, forKey: "pages.dusk")
            Dusk.shared.on = darkensPages
        }
    }

    var videoQuality: VideoQuality.Choice {
        didSet {
            store.set(videoQuality.raw, forKey: VideoQuality.key)
            if VideoQuality.releases(from: oldValue, to: videoQuality) { VideoQuality.release(in: store) }
            heard(\.videoQuality)
        }
    }
    var remembersSpeed: Bool {
        didSet {
            store.set(remembersSpeed, forKey: VideoSpeed.key)
            heard(\.remembersSpeed)
        }
    }
    var miniPlayer: Bool {
        didSet {
            store.set(miniPlayer, forKey: Preferences.miniKey)
            heard(\.miniPlayer)
        }
    }
    var miniSkip: Int {
        didSet {
            store.set(miniSkip, forKey: Preferences.miniSkipKey)
            heard(\.miniSkip)
        }
    }
    var miniSpoken: MiniSpoken {
        didSet {
            store.set(miniSpoken.rawValue, forKey: Preferences.miniSpokenKey)
            heard(\.miniSpoken)
        }
    }
    var miniSpeed: Bool {
        didSet {
            store.set(miniSpeed, forKey: Preferences.miniSpeedKey)
            heard(\.miniSpeed)
        }
    }
    var pullsToRefresh: Bool {
        didSet {
            store.set(pullsToRefresh, forKey: PullRefresh.key)
            PullRefresh.on = pullsToRefresh
            heard(\.pullsToRefresh)
        }
    }
    /// The bookmarks bar above the page (see BookmarksBar.swift). Off
    /// unless asked for.
    var bookmarksBar: Bool {
        didSet { store.set(bookmarksBar, forKey: "bookmarks.bar") }
    }
    /// Where a link goes, at the bottom of the page while the pointer is on
    /// it (see StatusLine.swift). On unless turned off.
    var showsLinks: Bool {
        didSet {
            store.set(showsLinks, forKey: "links.show")
            HoveredLink.on = showsLinks
            heard(\.showsLinks)
        }
    }
    /// Two fingers flick the floating video to a corner (see Float.swift).
    /// On unless turned off.
    var floatFlicks: Bool {
        didSet {
            store.set(floatFlicks, forKey: "float.flicks")
            Float.flicks = floatFlicks
        }
    }
    nonisolated static let waitsKey = "media.click"
    /// The languages whose pages are translated as they open, chosen from
    /// the translated sign's menu (never from a private tab). None at first.
    var translateAlways: Set<String> {
        didSet { store.set(Array(translateAlways).sorted(), forKey: PageTranslator.alwaysKey) }
    }
    /// A video playing on a video site comes out into the floating window
    /// when you go to another tab (Browser.leaving). On, as it always was;
    /// the switch is for turning it off.
    var floatsOnLeave: Bool {
        didSet { store.set(floatsOnLeave, forKey: "float.leave") }
    }
    /// Websites in the side panel (SidePanel.swift).
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    var sitesInPanel = true
    /// The website last put in the side panel, for View › Side Panel.
    var panelSite: String {
        didSet { store.set(panelSite, forKey: "panel.site") }
    }
    /// A newer build is fetched, checked and put in place on its own, as it
    /// always was. Off, Search still looks every hour and says so, and waits
    /// for Install in Settings (see Updater.installsOnItsOwn).
    /// Separate sets of tabs, each with its own sign-ins (see Spaces.swift).
    /// Off unless asked for.
    var usesSpaces: Bool {
        didSet { store.set(usesSpaces, forKey: "spaces"); heard(\.usesSpaces) }
    }
    var stackedSpaces: Bool {
        didSet { store.set(stackedSpaces, forKey: Preferences.stackedKey) }
    }
    nonisolated static let stackedKey = "spaces.stacked"
    var stacksSpaces: Bool { usesSpaces && stackedSpaces }
    var liveFolders: Bool {
        didSet { store.set(liveFolders, forKey: "live.on") }
    }
    var suggestsLiveFolders: Bool {
        didSet { store.set(suggestsLiveFolders, forKey: Preferences.suggestsLiveKey) }
    }
    var liveEvery: LiveEvery {
        didSet { store.set(liveEvery.rawValue, forKey: LiveEvery.key) }
    }
    nonisolated static let suggestsLiveKey = "live.suggest"
    var meetingFolders: Bool {
        didSet { store.set(meetingFolders, forKey: Preferences.meetingFoldersKey) }
    }
    nonisolated static let meetingFoldersKey = "groups.meetings"
    nonisolated static func meetingFoldersOn(_ store: UserDefaults) -> Bool {
        store.object(forKey: meetingFoldersKey) as? Bool ?? true
    }
    /// A pin's ⌘ number pressed again, on that pin, goes back to the tab
    /// you were on before it.
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    var pinNumberGoesBack = true
    /// Pins every space shows above its own, as Arc's favourites sit above
    /// every space (see Pins.shared).
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    var sharesPins = true
    /// Whether the shared pins are in the rows: asked for, and with Spaces
    /// on. Off, they wait in pins.json for the switch to come back.
    var showsSharedPins: Bool { sharesPins && usesSpaces }
    var agentMode: AgentMode {
        didSet {
            if agentMode == .bypass, !AgentConsent.grantBypass() { agentMode = .auto }
            store.set(agentMode.rawValue, forKey: "agents.mode")
            if agentMode != .bypass { AgentConsent.revokeBypass() }
        }
    }
    var agentsOn: Bool {
        didSet {
            if agentsOn, !AgentConsent.grant() { agentsOn = false }
            store.set(agentsOn, forKey: "agents.on")
            if !agentsOn { AgentConsent.revoke() }
            agentSetup.turned(wasOn: oldValue, isOn: agentsOn)
        }
    }
    @ObservationIgnored var agentSetup = AgentSetup.shared
    var agentsAskSignIn: Bool {
        didSet { store.set(agentsAskSignIn, forKey: "agents.signIn") }
    }
    var agentsGivePasswords: Bool {
        didSet { store.set(agentsGivePasswords, forKey: "agents.give") }
    }

    /// Two pages share one place in the tab row.
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    var splitView = true {
        didSet { heard(\.splitView) }
    }
    /// ⌃W, ⌃R, ⌃M and ⌃O on the ⌃Tab switcher's card picked, with the keys
    /// listed under the tabs (see TabSwitcher.Action).
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    var switcherKeys = true
    var nextMeeting: Bool {
        didSet { store.set(nextMeeting, forKey: "meetings.next") }
    }
    var remembersPageText: Bool {
        didSet {
            store.set(remembersPageText, forKey: "history.pageText")
            if !remembersPageText { Shared.history.pages.removeAll() }
        }
    }
    var floatingNewTab: Bool {
        didSet { store.set(floatingNewTab, forKey: "newtab.floating") }
    }

    init() {
        // Carried over from when there were four ways of holding the browser
        // and this was one of them.
        // The Mac's own unless asked otherwise — a Mac in dark mode expects
        // a dark browser, pages included.
        SettingsCut.retire(store, folder: Store.folder)
        SettingsCut.migrate(store, testing: Store.testing)
        let scripted = store.bool(forKey: "bench")
        let allowed = scripted && (Store.testing || Bench.Consent.given)
        bench = allowed
        if scripted, !allowed {
            benchRefused = true
            store.set(false, forKey: "bench")
        }
        let chosen = store.string(forKey: "look").flatMap(Look.init) ?? .system
        look = chosen
        // Before the first window, and not deferred: the window that is about
        // to be made should be made in the right appearance. Through `shared`
        // rather than `NSApp`: on macOS 14 SwiftUI builds this before it has
        // made the application, and `NSApp` is still nil here.
        NSApplication.shared.appearance = chosen.appearance
        appIcon = AppIcon.named(store.string(forKey: AppIcon.key))
        sidePanelWidth = min(max(CGFloat(store.object(forKey: "sidepanel.width") as? Double ?? 380),
                                 Preferences.sidePanelWidths.lowerBound), Preferences.sidePanelWidths.upperBound)
        sidePosition = store.string(forKey: "sidebar.position").flatMap(SidebarPosition.init) ?? .left
        sideButton = store.object(forKey: "sidebar.button") as? Bool ?? true
        selectedShortcut = store.object(forKey: "sidebar.selected") as? Bool ?? false
        hints = store.object(forKey: Preferences.hintsKey) as? Bool ?? true
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        cards = Store.testing ? store.object(forKey: "layout.cards") as? Bool ?? true : true
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        keywords = store.data(forKey: "search.keywords")
            .flatMap { try? JSONDecoder().decode([Keyword].self, from: $0) } ?? []
        hoverCards = Store.testing ? store.object(forKey: "tabs.cards") as? Bool ?? true : true
        awakeSites = Preferences.seedAwakeSites(store)
        popupSites = Set(store.stringArray(forKey: "privacy.popupSites") ?? [])
        tabLife = TabLife(rawValue: store.integer(forKey: "tabs.close.after")) ?? .never
        liveEvery = LiveEvery.stored(store.integer(forKey: LiveEvery.key))
        startsFresh = Store.testing && store.bool(forKey: Preferences.freshKey)
        confirmsQuit = store.bool(forKey: Preferences.confirmQuitKey)
        engineSuggests = Preferences.suggests(stored: store.object(forKey: "search.suggest"), testing: Store.testing)
        siteNotifications = store.object(forKey: "notifications.ask") as? Bool ?? true
        shielded = store.object(forKey: "shield") as? Bool ?? true
        let keeps = store.bool(forKey: "sites.keep")
        keepsSignIns = keeps
        // Before the first page is loaded into the store.
        Store.keepsSignIns = keeps
        Spaces.everyStore.forEach(Store.followCookies)
        let entitled = Preferences.entitledToPasskeys
        passkeysPossible = entitled
        passkeys = entitled
        // A test run downloads into its own folder: ~/Downloads would have
        // macOS stop it to ask for access, with a dialog on the screen of
        // whoever is working beside it.
        let testDownloads = Store.folder.appendingPathComponent("Downloads", isDirectory: true)
        if Store.testing { try? FileManager.default.createDirectory(at: testDownloads, withIntermediateDirectories: true) }
        downloads = Store.testing
            ? testDownloads
            : (store.string(forKey: "downloads")).map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        applePasswords = AppleHelper.available && store.bool(forKey: "passwords.apple")
        onePassword = store.bool(forKey: "passwords.onepassword")
        usesSpaces = Store.testing ? store.bool(forKey: "spaces") : true
        stackedSpaces = store.bool(forKey: Preferences.stackedKey)
        liveFolders = Store.testing ? store.bool(forKey: "live.on") : true
        suggestsLiveFolders = Store.testing ? store.bool(forKey: Preferences.suggestsLiveKey)
            : store.object(forKey: Preferences.suggestsLiveKey) as? Bool ?? true
        meetingFolders = Preferences.meetingFoldersOn(store)
        agentMode = AgentMode.read(store.string(forKey: "agents.mode"), bypassConsent: AgentConsent.bypassGiven)
        agentsOn = store.bool(forKey: "agents.on") && AgentConsent.given
        agentsAskSignIn = store.bool(forKey: "agents.signIn")
        agentsGivePasswords = store.bool(forKey: "agents.give")
        nextMeeting = store.bool(forKey: "meetings.next")
        remembersPageText = store.object(forKey: "history.pageText") as? Bool ?? true
        floatingNewTab = store.object(forKey: "newtab.floating") as? Bool ?? false
        // On for everyone who never touched these three switches (Drice,
        // 27 Sep 2026); a choice made before stands.
        floatFlicks = true
        Float.flicks = true
        floatsOnLeave = Store.testing ? store.object(forKey: "float.leave") as? Bool ?? true : true
        panelSite = store.string(forKey: "panel.site") ?? ""
        translateAlways = Set(store.stringArray(forKey: PageTranslator.alwaysKey) ?? [])
        bookmarksBar = store.bool(forKey: "bookmarks.bar")
        showsLinks = true
        HoveredLink.on = true
        let dusk = store.bool(forKey: "pages.dusk")
        darkensPages = dusk
        Dusk.shared.on = dusk
        videoQuality = VideoQuality.choice(in: store)
        remembersSpeed = VideoSpeed.on(in: store)
        miniPlayer = store.object(forKey: Preferences.miniKey) as? Bool ?? true
        miniSkip = (store.object(forKey: Preferences.miniSkipKey) as? Int).flatMap { MiniRule.skips.contains($0) ? $0 : nil } ?? MiniRule.skipDefault
        miniSpoken = store.string(forKey: Preferences.miniSpokenKey).flatMap(MiniSpoken.init(rawValue:)) ?? .seconds
        miniSpeed = store.object(forKey: Preferences.miniSpeedKey) as? Bool ?? true
        FrameRate.mode = .always
        let pulls = PullRefresh.on(in: store)
        pullsToRefresh = pulls
        PullRefresh.on = pulls
        let corrects = store.object(forKey: "autocorrect") as? Bool
            ?? NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        Substitution.register()
        pageZoom = store.object(forKey: "pageZoom") as? Double ?? 1
    }

    /// WebKit's text checker takes its orders from the app's standard
    /// defaults — the real ones, not the test suite, because it is WebKit
    /// reading them and not us. Text replacement, smart quotes and smart
    /// dashes are Edit › Substitutions' (see Substitutions.swift).
    static func tellWebKit(autocorrect: Bool) {
        if Store.testing {
            var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            arguments["WebAutomaticSpellingCorrectionEnabled"] = autocorrect
            UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
            return
        }
        UserDefaults.standard.set(autocorrect, forKey: "WebAutomaticSpellingCorrectionEnabled")
    }
}
