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

/// What a tab wears beside its title, and what a pinned one is reduced to: a
/// letter, or the site's own icon.
enum Glyph: String, CaseIterable, Identifiable {
    case letters, icons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .letters: return "Letters"
        case .icons: return "Site icons"
        }
    }
}

/// Peek uses modified left clicks, leaving plain clicks and Control-click alone.
enum PeekClick: String, CaseIterable {
    case shift, optionShift, optionCommand

    var title: String {
        switch self {
        case .shift: return "Shift-click"
        case .optionShift: return "Option-Shift-click"
        case .optionCommand: return "Option-Command-click"
        }
    }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .optionShift: return [.option, .shift]
        case .optionCommand: return [.option, .command]
        }
    }
}

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

/// Where a new tab goes in the row (Settings › Tabs).
enum NewTabPlace: String {
    case next, top, end
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
    /// The column folded away whenever the pointer isn't at its edge,
    /// rather than only after ⌘S (see Fold.swift). Off unless asked for.
    var sideHides: Bool {
        didSet { store.set(sideHides, forKey: "sidebar.hides") }
    }
    var sideButton: Bool {
        didSet { store.set(sideButton, forKey: "sidebar.button") }
    }
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
    var glyph: Glyph {
        didSet { store.set(glyph.rawValue, forKey: "glyph") }
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
    var tabsGive: Bool {
        didSet { store.set(tabsGive, forKey: "tabs.give") }
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
    /// Tabs nobody has looked at for hours give their page back and
    /// keep where they were. On unless turned off.
    var sleepsTabs: Bool {
        didSet { store.set(sleepsTabs, forKey: "tabs.sleep") }
    }
    /// Tabs you haven't pinned, named or grouped close once left alone this
    /// long, as in Arc. Never unless asked for.
    var tabLife: TabLife {
        didSet { store.set(tabLife.rawValue, forKey: "tabs.close.after") }
    }
    /// How soon they do (see SleepPace). Normal unless chosen.
    var sleepPace: SleepPace {
        didSet { store.set(sleepPace.rawValue, forKey: SleepPace.key) }
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
    var asksLocalNetwork: Bool {
        didSet { store.set(asksLocalNetwork, forKey: LocalNetwork.settingKey); heard(\.asksLocalNetwork) }
    }
    var lazyTabs: Bool {
        didSet { store.set(lazyTabs, forKey: "tabs.lazy") }
    }
    /// Closing the last tab that isn't a pin, with pins beside it, leaves a
    /// new tab instead of taking you to a pin (see Browser.close, #537).
    /// Off unless asked for.
    var newTabAfterLast: Bool {
        didSet { store.set(newTabAfterLast, forKey: "tabs.newAfterLast") }
    }
    /// Closing the tab on screen goes back to the one viewed before it
    /// rather than the neighbour (see Browser.close). Off unless asked for.
    var closeGoesBack: Bool {
        didSet { store.set(closeGoesBack, forKey: "tabs.closeGoesBack") }
    }
    /// Where a new tab goes in the row. Next unless asked for.
    var newTabPlace: NewTabPlace {
        didSet {
            store.set(newTabPlace.rawValue, forKey: "tabs.newPlace")
            if newTabPlace != .next, newTabsAtBottom != (newTabPlace == .end) { newTabsAtBottom = newTabPlace == .end }
        }
    }
    var newTabsAtBottom: Bool {
        didSet {
            store.set(newTabsAtBottom, forKey: Preferences.newAtBottomKey)
            if newTabPlace != .next, (newTabPlace == .end) != newTabsAtBottom { newTabPlace = newTabsAtBottom ? .end : .top }
        }
    }
    nonisolated static let newAtBottomKey = "tabs.newAtBottom"
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
    /// Numbers beside tabs while Command is held. Off unless asked for.
    var showsTabShortcuts: Bool {
        didSet { store.set(showsTabShortcuts, forKey: "tabs.shortcuts") }
    }
    /// The tab you're on says where its page is, at rest, without a click:
    /// its site, from the address on screen (see AtRest.swift). On unless
    /// turned off.
    var showsAddress: Bool {
        didSet { store.set(showsAddress, forKey: "tabs.address") }
    }
    /// The ad blocker. On unless turned off; there is nothing else to it.
    var shielded: Bool {
        didSet { store.set(shielded, forKey: "shield"); heard(\.shielded) }
    }
    var shieldLists: Bool {
        didSet { store.set(shieldLists, forKey: "shield.lists") }
    }
    var offersDeveloperMode: Bool {
        didSet { store.set(offersDeveloperMode, forKey: "dev.offer") }
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
    /// Global Privacy Control sent with every request (see Privacy.swift).
    /// On unless turned off.
    var sendsPrivacySignal: Bool {
        didSet {
            store.set(sendsPrivacySignal, forKey: "privacy.gpc")
            PrivacySignal.on = sendsPrivacySignal
        }
    }
    /// Ad-click IDs taken off links before the page loads (see
    /// Privacy.swift). On unless turned off.
    var removesClickIDs: Bool {
        didSet {
            store.set(removesClickIDs, forKey: "privacy.clickIDs")
            ClickIDs.on = removesClickIDs
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
    var offersRecentFiles: Bool {
        didSet { store.set(offersRecentFiles, forKey: "downloads.recentFiles") }
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

    /// A click of the wheel scrolls the page as on Windows (see AutoScroll.swift).
    /// Off unless asked for.
    var autoScroll: Bool {
        didSet {
            store.set(autoScroll, forKey: "autoscroll")
            AutoScroll.on = autoScroll
            heard(\.autoScroll)
        }
    }
    var videoKeys: Bool {
        didSet {
            store.set(videoKeys, forKey: Tempo.key)
            Tempo.on = videoKeys
            heard(\.videoKeys)
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
    /// Pages draw at 120 frames a second on a screen that can (see FrameRate.swift).
    /// On power unless chosen otherwise.
    var fastPages: FastPages {
        didSet {
            store.set(fastPages.rawValue, forKey: "pages.120.mode")
            FrameRate.mode = fastPages
        }
    }
    /// Springs become a short ease-out in Low Power Mode (see Motion.light).
    /// Off unless turned on, and even then nothing changes until the Mac is
    /// asked to save power.
    var lightMotion: Bool {
        didSet { store.set(lightMotion, forKey: Motion.lightKey) }
    }
    /// The modifier chosen in Settings › Shortcuts; Shift-click by default.
    var peekClick: PeekClick {
        didSet { store.set(peekClick.rawValue, forKey: "links.peekClick") }
    }
    /// Open a clicked link over the page (see Peek.swift). On unless turned off.
    var peeksLinks: Bool {
        didSet { store.set(peeksLinks, forKey: "links.peek") }
    }
    /// Pins as in Arc: a link from a pinned tab to another site opens in a
    /// peek, so the pin stays on its page (see Peek.swift), and ⌘W takes it
    /// back to the page it was pinned at. Half of "Pins keep their site"
    /// (Preferences.pinsKeepSite), on unless turned off.
    var pinsPeek: Bool {
        didSet { store.set(pinsPeek, forKey: "pins.peek") }
    }
    /// The downloads button always in the chrome, not only while something
    /// downloads (see Fetching.swift). Off unless asked for.
    var alwaysShowsDownloads: Bool {
        didSet { store.set(alwaysShowsDownloads, forKey: "downloads.button") }
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
    /// A back or forward swipe held once armed shows the pages that way to
    /// pick from (see PageView.openList). On unless turned off.
    var holdsHistory: Bool {
        didSet {
            store.set(holdsHistory, forKey: "swipe.history")
            PageView.holdsHistory = holdsHistory
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
    var floatsAway: Bool {
        didSet { store.set(floatsAway, forKey: "float.away") }
    }
    /// Videos wait for a click instead of starting by themselves, as Safari's
    /// Never Auto-Play has it (see Web.configuration). Off unless asked for.
    var waitsForPlay: Bool {
        didSet { store.set(waitsForPlay, forKey: Preferences.waitsKey); heard(\.waitsForPlay) }
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
    /// Which window a floating video goes into: Search's own, as it always
    /// was, or macOS's picture in picture (see NativePiP.swift).
    var floatStyle: FloatStyle {
        didSet {
            store.set(floatStyle.rawValue, forKey: "float.style")
            NativePiP.allowEverywhere()
        }
    }
    /// Escape on a page filling the screen leaves only when pressed twice
    /// within two seconds, as in Arc; the first puts up a reminder (see
    /// FullScreenEscape). Off unless asked for: one press leaves, as in
    /// Safari.
    var escapeTwice: Bool {
        didSet { store.set(escapeTwice, forKey: "fullscreen.escapeTwice") }
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
    nonisolated static let suggestsLiveKey = "live.suggest"
    var meetingFolders: Bool {
        didSet { store.set(meetingFolders, forKey: Preferences.meetingFoldersKey) }
    }
    nonisolated static let meetingFoldersKey = "groups.meetings"
    nonisolated static func meetingFoldersOn(_ store: UserDefaults) -> Bool {
        store.object(forKey: meetingFoldersKey) as? Bool ?? true
    }
    /// Named, collapsible sections in the sidebar.
    /// Always on since the Settings rework (Drice, 24 Oct 2026): it only
    /// adds a command, so there is no switch. Still a property, for the
    /// code that asks and the tests that turn it off; never written.
    var usesTabGroups = true {
        didSet { heard(\.usesTabGroups) }
    }
    /// A pin goes back to the page it was pinned at when it is closed with
    /// ⌘W and when Search opens again, as Arc's pins do, rather than keeping
    /// wherever it was taken since. The other half of "Pins keep their
    /// site", on unless turned off.
    var pinsGoHome: Bool {
        didSet { store.set(pinsGoHome, forKey: "pins.home") }
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
    var ai: Bool {
        didSet { store.set(ai, forKey: "ai") }
    }
    var agentMode: AgentMode {
        didSet {
            if agentMode == .bypass, !AgentConsent.grantBypass() { agentMode = .auto }
            store.set(agentMode.rawValue, forKey: "agents.mode")
            if agentMode != .bypass { AgentConsent.revokeBypass() }
        }
    }
    var agentTabsClose: Int {
        didSet { store.set(agentTabsClose, forKey: "agents.tabsClose") }
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
    var aiPlan: Plan? {
        didSet { store.set(aiPlan?.rawValue, forKey: "ai.plan") }
    }
    private(set) var aiRoutes: [String: ModelChoice] {
        didSet { store.set(try? JSONEncoder().encode(aiRoutes), forKey: "ai.routes") }
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
    /// "settings", "new tab" and the like, typed alone in the address field,
    /// reach that part of the app instead of asking a search engine for the
    /// word (see AddressCommands.swift). Off unless asked for.
    var commandBar: Bool {
        didSet { store.set(commandBar, forKey: "commandbar") }
    }
    var nowRows: Bool {
        didSet { store.set(nowRows, forKey: "field.now") }
    }
    var nextMeeting: Bool {
        didSet { store.set(nextMeeting, forKey: "meetings.next") }
    }
    var remembersPageText: Bool {
        didSet {
            store.set(remembersPageText, forKey: "history.pageText")
            if !remembersPageText { Shared.history.pages.removeAll() }
        }
    }
    /// ⌘T raises the field over the page you are on, as in Arc, and a tab is
    /// only made once Return sends it somewhere. Escape, ⌘W or a click
    /// outside puts the field away and leaves you where you were. Off unless
    /// asked for.
    var addressBar: Bool {
        didSet { store.set(addressBar, forKey: "sidebar.address") }
    }
    var fullAddress: Bool {
        didSet { store.set(fullAddress, forKey: "sidebar.fullAddress") }
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
        sideHides = false
        sideButton = store.object(forKey: "sidebar.button") as? Bool ?? true
        addressBar = true
        fullAddress = false
        let width = store.object(forKey: "sidebar.width") as? Double ?? Double(Metrics.side)
        sideWidth = min(Metrics.sideMax, max(Metrics.sideMin, CGFloat(width)))
        cards = Store.testing ? store.object(forKey: "layout.cards") as? Bool ?? true : true
        glyph = .icons
        engine = store.string(forKey: "search.engine").flatMap(Engine.init) ?? .standard
        customEngine = store.string(forKey: "search.custom") ?? ""
        keywords = store.data(forKey: "search.keywords")
            .flatMap { try? JSONDecoder().decode([Keyword].self, from: $0) } ?? []
        tabsGive = true
        hoverCards = Store.testing ? store.object(forKey: "tabs.cards") as? Bool ?? true : true
        awakeSites = Preferences.seedAwakeSites(store)
        popupSites = Set(store.stringArray(forKey: "privacy.popupSites") ?? [])
        sleepsTabs = true
        tabLife = TabLife(rawValue: store.integer(forKey: "tabs.close.after")) ?? .never
        sleepPace = .normal
        lazyTabs = false
        newTabAfterLast = false
        closeGoesBack = false
        newTabPlace = .next
        newTabsAtBottom = true
        startsFresh = Store.testing && store.bool(forKey: Preferences.freshKey)
        confirmsQuit = store.bool(forKey: Preferences.confirmQuitKey)
        engineSuggests = Preferences.suggests(stored: store.object(forKey: "search.suggest"), testing: Store.testing)
        siteNotifications = store.object(forKey: "notifications.ask") as? Bool ?? true
        asksLocalNetwork = true
        showsTabShortcuts = false
        showsAddress = false
        shielded = store.object(forKey: "shield") as? Bool ?? true
        shieldLists = true
        offersDeveloperMode = true
        let keeps = store.bool(forKey: "sites.keep")
        keepsSignIns = keeps
        // Before the first page is loaded into the store.
        Store.keepsSignIns = keeps
        Spaces.everyStore.forEach(Store.followCookies)
        let signals = true
        sendsPrivacySignal = signals
        PrivacySignal.on = signals
        let removes = true
        removesClickIDs = removes
        ClickIDs.on = removes
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
        offersRecentFiles = true
        asksWhereToSave = store.bool(forKey: "downloads.ask")
        savesPasswords = store.object(forKey: "passwords.save") as? Bool ?? true
        fillsPasswords = store.object(forKey: "passwords.fill") as? Bool ?? true
        applePasswords = AppleHelper.available && store.bool(forKey: "passwords.apple")
        usesSpaces = Store.testing ? store.bool(forKey: "spaces") : true
        stackedSpaces = store.bool(forKey: Preferences.stackedKey)
        liveFolders = Store.testing ? store.bool(forKey: "live.on") : true
        suggestsLiveFolders = Store.testing ? store.bool(forKey: Preferences.suggestsLiveKey)
            : store.object(forKey: Preferences.suggestsLiveKey) as? Bool ?? true
        meetingFolders = Preferences.meetingFoldersOn(store)
        let keepsSite = true
        pinsGoHome = keepsSite
        ai = store.object(forKey: "ai") as? Bool ?? true
        agentMode = AgentMode.read(store.string(forKey: "agents.mode"), bypassConsent: AgentConsent.bypassGiven)
        agentTabsClose = 60
        agentsOn = store.bool(forKey: "agents.on") && AgentConsent.given
        aiPlan = store.string(forKey: "ai.plan").flatMap(Plan.init(rawValue:))
        aiRoutes = [:]
        commandBar = false
        nowRows = true
        nextMeeting = store.bool(forKey: "meetings.next")
        remembersPageText = store.object(forKey: "history.pageText") as? Bool ?? true
        floatingNewTab = store.object(forKey: "newtab.floating") as? Bool ?? false
        let history = true
        holdsHistory = history
        PageView.holdsHistory = history
        // On for everyone who never touched these three switches (Drice,
        // 27 Sep 2026); a choice made before stands.
        let flicks = store.object(forKey: "float.flicks") as? Bool ?? true
        floatFlicks = flicks
        Float.flicks = flicks
        floatsAway = true
        floatsOnLeave = Store.testing ? store.object(forKey: "float.leave") as? Bool ?? true : true
        panelSite = store.string(forKey: "panel.site") ?? ""
        floatStyle = .search
        escapeTwice = false
        waitsForPlay = false
        translateAlways = Set(store.stringArray(forKey: PageTranslator.alwaysKey) ?? [])
        peeksLinks = true
        peekClick = .shift
        pinsPeek = keepsSite
        bookmarksBar = store.bool(forKey: "bookmarks.bar")
        alwaysShowsDownloads = true
        let links = store.object(forKey: "links.show") as? Bool ?? true
        showsLinks = links
        HoveredLink.on = links
        let dusk = store.bool(forKey: "pages.dusk")
        darkensPages = dusk
        Dusk.shared.on = dusk
        let scrolls = false
        autoScroll = scrolls
        AutoScroll.on = scrolls
        let tempo = true
        videoKeys = tempo
        Tempo.on = tempo
        videoQuality = VideoQuality.choice(in: store)
        remembersSpeed = VideoSpeed.on(in: store)
        miniPlayer = store.object(forKey: Preferences.miniKey) as? Bool ?? true
        miniSkip = (store.object(forKey: Preferences.miniSkipKey) as? Int).flatMap { MiniRule.skips.contains($0) ? $0 : nil } ?? MiniRule.skipDefault
        miniSpoken = store.string(forKey: Preferences.miniSpokenKey).flatMap(MiniSpoken.init(rawValue:)) ?? .seconds
        miniSpeed = store.object(forKey: Preferences.miniSpeedKey) as? Bool ?? true
        let pulls = PullRefresh.on(in: store)
        pullsToRefresh = pulls
        PullRefresh.on = pulls
        let fast = FastPages.always
        fastPages = fast
        FrameRate.mode = fast
        lightMotion = false
        // Left behind by the Web Inspector's switch, from before it was
        // always there.
        store.removeObject(forKey: "inspector")
        let corrects = store.object(forKey: "autocorrect") as? Bool
            ?? NSSpellChecker.isAutomaticSpellingCorrectionEnabled
        autocorrect = corrects
        // Before the first web view exists: WebKit reads these once.
        Preferences.tellWebKit(autocorrect: corrects)
        Substitution.register()
        pageZoom = store.object(forKey: "pageZoom") as? Double ?? 1
        // Left behind by an assistant this browser no longer has.
        for key in ["mind.model", "mind.effort", "mind.acting", "mind.width", "mind.open"] {
            store.removeObject(forKey: key)
        }
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
