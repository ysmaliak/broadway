import Observation
import WebKit
import Combine
import UniformTypeIdentifiers

// Everything the window knows: which tabs exist, which one is showing, and
// whether the address field is up. Small enough to read in one sitting, which
// is the point of a browser with no features.

/// What every window shares: the settings, History, bookmarks, the
/// downloads list and the downloads under way, hidden elements, and the
/// one floating video. Each window's Browser holds only its own tabs and
/// what is drawn over them.
@MainActor
enum Shared {
    static let prefs = Preferences()
    static let curtain = Curtain()
    static let loot = Loot()
    static let floater = Float()
    static let fetches = Fetches()
    static let history = History()
    static let bookmarks = Bookmarks()
}

@MainActor
@Observable
final class Browser: NSObject {
    var revision = 0

    private static var activeFileImports: [UUID: ImportFile.Control] = [:]
    private static var fileImportTerminating = false

    static func cancelAllFileImports() -> Bool {
        fileImportTerminating = true
        for control in activeFileImports.values { control.cancel() }
        return !activeFileImports.isEmpty
    }

    static var hasActiveFileImports: Bool { !activeFileImports.isEmpty }
    private(set) var tabs: [Tab] = [] {
        didSet {
            meetingRowChanged(from: oldValue)
            arrangeGroupedTabs()
            if !selectedTabIDs.isEmpty {
                let valid = selectedTabIDs.intersection(Set(tabs.map(\.id)))
                if valid != selectedTabIDs { selectedTabIDs = valid }
            }
            if let selectionAnchor, !tabs.contains(where: { $0.id == selectionAnchor }) {
                self.selectionAnchor = nil
            }
        }
    }
    /// Tabs picked with Command or Shift. The active page remains where it is.
    private(set) var selectedTabIDs: Set<Tab.ID> = []
    @ObservationIgnored private var selectionAnchor: Tab.ID?
    private(set) var splits: [TabSplit] = []
    /// Named tab sections in the current space, in display order.
    var tabGroups: [TabGroup] = [] {
        didSet {
            let ordered = FolderTree.ordered(tabGroups)
            if ordered != tabGroups { tabGroups = ordered }
        }
    }
    var editingGroupID: UUID? {
        didSet {
            if let editingGroupID { AIGroups.shared.unveil(editingGroupID) }
            if oldValue != nil, oldValue != editingGroupID { AIGroups.shared.membershipChanged(in: self) }
        }
    }
    var editingLook = false
    @ObservationIgnored var pageBefore: Tab.ID?
    @ObservationIgnored var tabStep: AddressMove.TabStep?
    @ObservationIgnored var leftNewTabs: Set<Tab.ID> = []
    @ObservationIgnored private var choosing = false

    var activeID: Tab.ID? {
        didSet {
            fileChoice?.activeMoved(to: activeID)
            if activeID != oldValue { pageBefore = oldValue; SwitchFade.switching() }
            // The tab just left is the tab just looked at. Whether a tab has
            // gone unwatched long enough to sleep is counted from here, not
            // from when it was first picked.
            // A question the page asked while it was in the background.
            if let id = activeID, id != oldValue, let held = heldDialogs.removeValue(forKey: id) {
                DispatchQueue.main.async { held.forEach { $0.present() } }
            }
            guard oldValue != activeID else { return }
            loadOwedOnScreen()
            if let id = activeID, let shown = tabs.first(where: { $0.id == id }), shown.unread { shown.unread = false }
            // Going to another tab ends a page's run of links (see placeForLink).
            linkRun = nil
            keepReturns(leaving: oldValue)
            if displayTab?.id == oldValue { cancelDisplay() }
            clearTabSelection()
            // What was found belongs to the page just left; the words typed
            // go on to be looked for on this one.
            invalidateFindPage(retryOnActiveTab: true)
            let row = shownTabs.map(\.id)
            tabStep = AddressMove.TabStep(to: activeID, fromPlace: oldValue.flatMap { row.firstIndex(of: $0) },
                                          toPlace: activeID.flatMap { row.firstIndex(of: $0) })
            guard let old = oldValue else { return }
            noteLeft(old, words: choosing || summoning ? "" : typed)
            linkStatus.dismiss()
            let left = tabs.first { $0.id == old }
            left?.touch()
            if prefs.splitView, let pair = splits.first(where: { $0.contains(old) }),
               activeID.map({ !pair.contains($0) }) ?? true,
               let partner = tabs.first(where: { $0.id == pair.partner(of: old) }) {
                partner.touch()
            }
            // The page to come back to, when the pair is chosen again.
            if prefs.splitView, let id = activeID,
               let index = splits.firstIndex(where: { $0.contains(id) }), splits[index].focused != id {
                splits[index].focused = id
            }
            // The switcher's order and pictures, most recently used first.
            // Focus moving within a pair isn't leaving it; a pair left is
            // one entry, under its first page.
            if prefs.splitView, let pair = splits.first(where: { $0.contains(old) }) {
                if let id = activeID, pair.contains(id) { return }
                tabSwitcher.cancel()
                if let first = tabs.first(where: { $0.id == pair.left }) {
                    tabSwitcher.left(first, alive: Set((tabs + parkedTabs).map(\.id)))
                }
                return
            }
            tabSwitcher.cancel()
            if let left = left ?? parkedTabs.first(where: { $0.id == old }) {
                tabSwitcher.left(left, alive: Set((tabs + parkedTabs).map(\.id)))
            }
        }
    }

    var activeSplit: TabSplit? {
        guard prefs.splitView, let activeID else { return nil }
        return splits.first { $0.contains(activeID) }
    }

    /// The pair a tab is in, while Split View is on. Turned off, pairs are
    /// kept, as groups are, and nothing acts on them until it is back on.
    func split(for tab: Tab) -> TabSplit? {
        guard prefs.splitView else { return nil }
        return splits.first { $0.contains(tab.id) }
    }

    /// Whether a tab has a place of its own in the row: any tab but a
    /// pair's later pages, which share the first one's.
    func standsInRow(_ tab: Tab) -> Bool {
        split(for: tab).map { $0.left == tab.id } ?? true
    }

    var displayedTabs: [Tab] {
        guard prefs.splitView else { return tabs }
        return tabs.filter { tab in !splits.contains { $0.contains(tab.id) && $0.left != tab.id } }
    }

    var visibleTabIDs: Set<Tab.ID> {
        guard let activeID else { return [] }
        guard let pair = activeSplit else { return [activeID] }
        return Set(pair.tabs)
    }

    /// Whether a pair can stand as it is in a row: all its tabs there, next
    /// to each other in its order, none pinned, of one kind and one group.
    /// A pair kept while Split View was off may have come apart since.
    static func holds(_ pair: TabSplit, in row: [Tab]) -> Bool {
        let places = pair.tabs.compactMap { id in row.firstIndex { $0.id == id } }
        guard pair.tabs.count >= 2, places.count == pair.tabs.count, let first = places.first,
              places == Array(first..<first + places.count) else { return false }
        let members = places.map { row[$0] }
        return members.allSatisfy { tab in
            (tab.pin == nil) == (members[0].pin == nil) && !tab.bench && tab.shy == members[0].shy && tab.groupID == members[0].groupID
        }
    }

    let tabSwitcher = TabSwitcher()
    @ObservationIgnored lazy var hoverCards = HoverCards(browser: self)
    let iconPicker = IconPicker()

    /// The tab whose page is currently out in the little window. Nothing
    /// floating means no window: the two are checked against each other rather
    /// than trusted to stay in step.
    private(set) var floating: Tab.ID? {
        didSet {
            guard floating == nil, floater.showing else { return }
            floater.drop()
        }
    }

    /// Everything there is to set. Held here so the whole window redraws when
    /// one of them changes.
    let prefs = Shared.prefs
    let linkStatus = LinkStatus()
    /// Settings, in its own tab (see InternalPages.swift). True while the
    /// window has one; set, it is shown or closed.
    var tuning: Bool {
        get { pageTab(.settings) != nil }
        set { if newValue, SettingsWindow.stands { SettingsWindow.shared.open(self, section: settingsPage.rawValue) } else if newValue { show(InternalPage(.settings, settingsPage.rawValue)) } else { putAway(.settings) } }
    }
    // MARK: - bookmarks

    let bookmarks = Shared.bookmarks
    /// The full list, for taking things out, in a tab.
    var bookmarking: Bool {
        get { pageTab(.bookmarks) != nil }
        set { if newValue { show(InternalPage(.bookmarks)) } else { putAway(.bookmarks) } }
    }
    /// The dropdown off the button.
    var bookmarksOpen = false
    var downloadsOpen = false
    var downloadsDoor = CGRect.zero
    @ObservationIgnored weak var downloadsAnchor: NSView?
    @ObservationIgnored var downloadsShutBy: TimeInterval?
    var plusOpen = false
    @ObservationIgnored var plusDoor = CGRect.zero
    @ObservationIgnored weak var plusAnchor: NSView?
    @ObservationIgnored let spaceFeet = NSHashTable<SpaceFootView>.weakObjects()
    /// What hangs off the button instead of the list: the card for one
    /// bookmark, its name and folder, as ⇧⌘B opens it.
    var bookmarkCard: Bookmark.ID?

    /// The page you are on is kept, wherever it is filed.
    var pageKept: Bool {
        active?.address.map(bookmarks.contains) ?? false
    }

    /// ⇧⌘B. The page you are on, at the end of the list, and the card off
    /// the button to name it and file it — or the card for it, if it was
    /// kept already. Without the button on screen (the tabs folded away)
    /// there is nothing to hang the card from, and a word says what
    /// happened instead.
    func bookmarkCurrent() {
        guard let tab = active, let url = tab.address else { return }
        let kept = bookmarks.bookmark(for: url)
        guard let id = (kept ?? bookmarks.add(url, title: tab.savedTitle))?.id else { return }
        guard !folded else {
            announce(kept == nil ? "Bookmarked" : "Already a bookmark")
            return
        }
        bookmarkCard = id
        bookmarksOpen = true
    }

    /// Another browser's bookmarks, folders and all — one profile's, or
    /// every profile's when nil — and, behind them, the icons it had for
    /// those sites, so the menu wears them from the start instead of a
    /// letter each. Returns how many pages came over, and how many were
    /// here already. `replacing`: what came from this browser before —
    /// as recorded, nothing guessed — is taken out first, and these come
    /// fresh in its place.
    ///
    /// Only when every profile read cleanly: a file that didn't read is not
    /// an empty browser, and taking out what came before for it lost
    /// bookmarks for good (#375). Then what came before stays, what could be
    /// read is added as usual, and `kept` says so.
    @discardableResult
    func takeBookmarks(from source: ImportSource, profile: String? = nil, replacing: Bool = false) -> (added: Int, already: Int, kept: Bool) {
        let read = source.bookmarkRead(profile: profile)
        let found = read.nodes
        var kept = false
        if replacing, let earlier = ImportRecords.of(source.name), !earlier.bookmarkIDs.isEmpty {
            if read.complete {
                bookmarks.withdraw(earlier.bookmarkIDs)
                ImportRecords.forgetBookmarks(source.name)
            } else {
                kept = true
            }
        }
        let (count, already, ids) = bookmarks.takeNoting(found, from: source.name)
        ImportRecords.note(source.name, bookmarks: ids, bookmarks: count)
        announce(
            kept ? "Couldn't read all of \(source.name)'s bookmarks, so the ones from before were kept"
                : Bookmarks.count(found) == 0 ? "No bookmarks in \(source.name)"
                : count == 0 ? "Every bookmark from \(source.name) was already here"
                : already == 0 ? (count == 1 ? "1 bookmark from \(source.name)" : "\(count) bookmarks from \(source.name)")
                : (count == 1 ? "1 new bookmark from \(source.name), \(already) already here" : "\(count) new bookmarks from \(source.name), \(already) already here")
        )
        let urls = Bookmarks.urls(found)
        DispatchQueue.global(qos: .utility).async {
            let icons = source.icons(profile: profile, for: urls)
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                self.revision &+= 1
            }
        }
        return (count, already, kept)
    }

    /// Bring Things Over, in a tab, open while set: the browser it starts
    /// on by name, or "" for the first one found.
    var bringingIn: String? {
        get { pageTab(.importing).map { $0.page?.detail ?? "" } }
        set {
            if let newValue { show(InternalPage(.importing, newValue)) } else { putAway(.importing) }
        }
    }
    struct FileImportJob: Identifiable {
        let id: UUID
        let filename: String
        var message: String
        var completed = 0
        var total: Int?
        var cancelling = false
    }
    private(set) var fileImport: FileImportJob?
    @ObservationIgnored private var fileImportControl: ImportFile.Control?

    func cancelFileImport() {
        guard fileImport != nil else { return }
        fileImport?.cancelling = true
        fileImport?.message = "Cancelling…"
        fileImportControl?.cancel()
    }
    /// The sheet opened from Settings › Extensions: only the extensions
    /// ticked, on a browser that has some. Read once as it opens.
    @ObservationIgnored var bringingExtensions = false

    func searchURL(for text: String) -> URL? {
        Engine.url(for: text, template: prefs.engine.template(custom: prefs.customEngine))
    }

    func destination(for typed: String) -> URL? {
        if let site = siteChip { return site.url(for: typed) }
        if let url = Address.file(from: typed) ?? Address.url(from: typed) { return url }
        if let ref = issueRef(for: typed) { return ref.url }
        if let (keyword, rest) = Keyword.match(typed, in: prefs.keywords),
           let url = Engine.url(for: rest, template: keyword.template) {
            return url
        }
        return searchURL(for: typed)
    }

    /// ⌘S: the column folded away, and slid out over the page for a look
    /// while it is (see Fold.swift).
    var folded = false
    let columnPeek = ColumnPeek()
    var peeking: Bool {
        get { columnPeek.out }
        set { columnPeek.out = newValue }
    }

    /// The address field, raised over a page by ⌘L. A blank tab shows it
    /// without being asked — there is nothing else for that tab to show.
    let fieldState = FieldState()

    var editing: Bool {
        get { fieldState.editing }
        set {
            fieldState.editing = newValue
            if !editing, siteChip != nil { siteChip = nil }
            if !editing, fieldPlace != nil { fieldPlace = nil }
            if !editing, launching { launching = false }
        }
    }
    /// True while the field is up over a page for a tab that doesn't exist
    /// yet (Settings › General › New tab in a floating field): Return opens
    /// what was typed in a new tab, and putting the field away leaves the
    /// page you were on as it was.
    private(set) var launching: Bool {
        get { fieldState.launching }
        set { fieldState.launching = newValue }
    }
    /// The page links were last opened behind from, and the last of them:
    /// the next one from that page goes after it (see placeForLink).
    private struct LinkRun { let opener: Tab.ID; let last: Tab.ID }
    @ObservationIgnored private var linkRun: LinkRun?
    /// The run as it was when a page's script opened a tab in front, for the
    /// ⌘-click that tab turns out to be (see openClicked).
    @ObservationIgnored private var runBeforeScript: (tab: Tab.ID, run: LinkRun)?
    /// The site the list offers to search, for what has been typed so far
    /// (Settings › General › Search a site from the address field).
    private(set) var siteOffer: SearchSite? {
        get { fieldState.siteOffer }
        set { fieldState.siteOffer = newValue }
    }
    /// The site Tab put in the field: what is typed next searches it.
    var siteChip: SearchSite? {
        get { fieldState.siteChip }
        set {
            let old = fieldState.siteChip
            fieldState.siteChip = newValue
            if newValue != old { guess() }
        }
    }
    var fieldPlace: FieldPlace? {
        get { fieldState.fieldPlace }
        set {
            let old = fieldState.fieldPlace
            fieldState.fieldPlace = newValue
            if newValue != old, fieldShowing { guess() }
        }
    }
    private(set) var placeOffer: FieldPlace? {
        get { fieldState.placeOffer }
        set { fieldState.placeOffer = newValue }
    }
    /// What is in the field. Every change re-reads the history, because the
    /// list under the field and the grey ending inside it are both just
    /// answers to this string.
    var typed: String {
        get { fieldState.typed }
        set {
            fieldState.typed = newValue
            if !holdingOffers { guess() }
        }
    }
    @ObservationIgnored private var holdingOffers = false

    let history = Shared.history
    /// What the field is offering, best first.
    var offers: [Suggestion] {
        get { fieldState.offers }
        set { fieldState.offers = newValue }
    }
    var fieldSections: [FieldSection] {
        get { fieldState.fieldSections }
        set { fieldState.fieldSections = newValue }
    }
    @ObservationIgnored var pageQuestion: Task<Void, Never>?
    let fieldMenu = FieldMenu()
    /// The rest of the best match, drawn grey after the caret. Tab takes it.
    var ending: String? {
        get { fieldState.ending }
        set { fieldState.ending = newValue }
    }
    /// Which row the arrow keys have walked to, if any.
    var picked: Int? {
        get { fieldState.picked }
        set { fieldState.picked = newValue }
    }
    var pointed: Int? {
        get { fieldState.pointed }
        set { fieldState.pointed = newValue }
    }
    @ObservationIgnored var pointer = PointerWatch()
    /// Bumped when what was typed isn't an address and can't be searched for.
    private(set) var refusals: Int {
        get { fieldState.refusals }
        set { fieldState.refusals = newValue }
    }
    /// Bumped whenever the cursor should go back into the field.
    private(set) var focusRequest: Int {
        get { fieldState.focusRequest }
        set {
            fieldState.focusRequest = newValue
            focusAsked = CACurrentMediaTime()
            focusRequestedAt = focusAsked ?? 0
        }
    }
    @ObservationIgnored private(set) var focusRequestedAt: CFTimeInterval = 0
    /// When the field was last asked for the keys and hasn't taken them yet.
    @ObservationIgnored private var focusAsked: CFTimeInterval?
    @ObservationIgnored var guessedAt: CFTimeInterval = 0
    @ObservationIgnored var fieldTimes: (asked: CFTimeInterval, focused: CFTimeInterval?, drawn: CFTimeInterval?) = (0, nil, nil)
    /// What was typed in that moment, for the field once it has the keys.
    @ObservationIgnored private var heldKeys: [NSEvent] = []

    /// True while the field is a switcher rather than an address bar. ⌘K asks
    /// one question — which of the pages I already have open — and answering it
    /// with somewhere you went last week would be answering a different one.
    private(set) var summoning: Bool {
        get { fieldState.summoning }
        set { fieldState.summoning = newValue }
    }
    /// True between the first ⌘K and letting go of ⌘.
    @ObservationIgnored var cycling = false

    var active: Tab? { tabs.first { $0.id == activeID } }
    var fieldShowing: Bool { editing || active?.isBlank ?? true }

    /// Typed plus whatever the field is quietly finishing for you.
    var completed: String {
        if fieldPlace != nil { return typed }
        if let picked, offers.indices.contains(picked), fieldSections.isEmpty { return offers[picked].key }
        return typed + (ending ?? "")
    }

    // MARK: - looking for something on the page

    let findState = FindState()
    var finding: Bool {
        get { findState.on }
        set { if findState.on != newValue { findState.on = newValue } }
    }
    /// The AI panel's conversation about the page, while it is open.
    var ai = AIStage()
    /// The side panel, beside the page (see SidePanel.swift): up or
    /// not, and what is in it.
    var sidePanelShown = false
    var sidePanel: SidePanelContent?
    /// The Settings page it opens on next.
    var settingsPage: SettingsPage {
        get {
            SettingsPage.named( Store.settings.string(forKey: "settings.page") ?? "") ?? .general
        }
        set { Store.settings.set(newValue.rawValue, forKey: "settings.page") }
    }
    // The same words written back (the field does, as it appears) aren't
    // a Next: Return and the buttons ask for that themselves.
    var needle = "" {
        didSet { if !resettingFind, oldValue != needle { look(forward: true) } }
    }
    var matchCase = false {
        didSet { if !resettingFind, oldValue != matchCase { look(forward: true) } }
    }
    var wholeWords = false {
        didSet { if !resettingFind, oldValue != wholeWords { look(forward: true) } }
    }
    /// Set when the page doesn't hold what was asked for.
    private(set) var missed = false
    /// The count and which match is current, as the page last answered.
    private(set) var findResult: PageFind.Result?

    private let pageFind = PageFind()
    private struct FindSpec: Equatable {
        let tab: Tab.ID
        let query: String
        let matchCase: Bool
        let wholeWords: Bool
    }
    @ObservationIgnored private var findSpec: FindSpec?
    /// Goes up whenever what is looked for, or the page it is looked for on,
    /// changes: an answer for an older one is dropped.
    @ObservationIgnored private var findGeneration: UInt64 = 0
    /// One question to the page at a time. Letters typed while it answers
    /// wait here, and only the last of them is asked next: on a long page
    /// every letter would otherwise queue a whole search of its own.
    @ObservationIgnored private var findAsking: UInt64?
    @ObservationIgnored private var findAsked: UInt64 = 0
    /// A new search not yet asked, and Next / Previous presses not yet sent.
    @ObservationIgnored private var findFresh = false
    @ObservationIgnored private var findSteps = 0
    @ObservationIgnored var resettingFind = false
    @ObservationIgnored private weak var findWeb: WKWebView?

    /// A question to the page not answered yet, or one waiting to be asked.
    var findBusy: Bool { findAsking != nil || findFresh || findSteps != 0 }

    var findStatus: String? {
        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let result = findResult else { return nil }
        guard result.available else { return "Search unavailable" }
        if result.nativeFallback {
            if wholeWords && !result.wholeWordsAvailable { return "Whole words unavailable" }
            return result.found ? "Match found" : "No matches"
        }
        guard let index = result.index, let count = result.count, count > 0 else { return "No matches" }
        return "\(index) of \(count)\(result.more ? "+" : "")"
    }

    /// ⌘F on the Settings tab: its Find a setting field takes the keys.
    var settingsFind = 0
    var settingsAsked: SettingsPage?
    var settingsTyped: String?
    var settingsDrill: SettingsDetail?
    var settingsRule: UUID?
    var settingsLanguages: UUID?

    func openFind() {
        if SettingsWindow.shared.isKey {
            SettingsWindow.shared.focusSearch()
            return
        }
        if active?.page?.kind == .settings {
            settingsFind += 1
            return
        }
        guard active?.isWeb == true else { return }
        finding = true
        findState.focus += 1
    }

    func closeFind() {
        guard finding || !needle.isEmpty || findResult != nil else { return }
        // The page's own selection back, and the match's highlight gone.
        resetFindState()
        // The keyboard back to the page, as in Safari. Left with the window,
        // the Mac's keyboard navigation handed it to the first button next.
        if let web = active?.built, let window = web.window,
           window.firstResponder === window || window.firstResponder is NSText {
            window.makeFirstResponder(web)
        }
    }

    func look(forward: Bool) {
        guard let tab = active else {
            missed = false
            findResult = nil
            return
        }

        guard !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            missed = false
            findResult = nil
            guard findSpec != nil || findWeb != nil else { return }
            let web = findWeb ?? tab.built
            forgetFind()
            if let web { clearFind(on: web) }
            return
        }

        guard let web = tab.built else {
            missed = false
            findResult = nil
            return
        }
        let spec = FindSpec(tab: tab.id, query: needle, matchCase: matchCase, wholeWords: wholeWords)
        if findSpec != spec || findWeb !== web {
            findGeneration &+= 1
            findSpec = spec
            findWeb = web
            findFresh = true
            findSteps = 0
        } else {
            findSteps += forward ? 1 : -1
        }
        askFind()
    }

    /// Sends what is waiting to the page, unless a question is still out:
    /// its answer sends the next one.
    private func askFind() {
        guard findAsking == nil, let spec = findSpec, let web = findWeb,
              findFresh || findSteps != 0 else { return }
        findAsked &+= 1
        let asking = findAsked
        let generation = findGeneration
        let steps = findSteps
        findAsking = asking
        findFresh = false
        findSteps = 0
        Task { [weak self, weak web] in
            guard let self else { return }
            guard let web, self.activeID == spec.tab, self.active?.built === web else {
                if self.findAsking == asking { self.findAsking = nil }
                return
            }
            let result = await self.pageFind.update(
                on: web,
                query: spec.query,
                matchCase: spec.matchCase,
                wholeWords: spec.wholeWords,
                steps: steps,
                generation: generation
            )
            // Something newer took over while the page was answering.
            guard self.findAsking == asking else { return }
            self.findAsking = nil
            if !result.stale, self.findGeneration == generation, self.findSpec == spec,
               self.activeID == spec.tab, self.active?.built === web {
                self.findResult = result
                self.missed = result.available && !result.found
                    && (!result.nativeFallback || !spec.wholeWords || result.wholeWordsAvailable)
            }
            self.askFind()
        }
    }

    /// Nothing asked or waiting any more; whatever answer is out is dropped.
    private func forgetFind() {
        findGeneration &+= 1
        findSpec = nil
        findWeb = nil
        findAsking = nil
        findFresh = false
        findSteps = 0
    }

    private func clearFind(on web: WKWebView) {
        let generation = findGeneration
        Task { [pageFind] in _ = await pageFind.clear(on: web, generation: generation) }
    }

    private func resetFindState() {
        let web = findWeb
        forgetFind()
        resettingFind = true
        finding = false
        if !needle.isEmpty { needle = "" }
        if matchCase { matchCase = false }
        if wholeWords { wholeWords = false }
        resettingFind = false
        if findResult != nil { findResult = nil }
        if missed { missed = false }
        if let web { clearFind(on: web) }
    }

    /// A tab or document changed under an open find bar. Keep what was typed,
    /// but retire every result and callback tied to the page that just left.
    private func invalidateFindPage(retryOnActiveTab: Bool) {
        let web = findWeb
        forgetFind()
        findResult = nil
        missed = false
        if let web { clearFind(on: web) }
        guard retryOnActiveTab, finding,
              !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let tab = active, !tab.loading, tab.isWeb else { return }
        look(forward: true)
    }

    /// ⌘⇧M. Whatever is making noise in this tab stops making noise.
    var canPauseMedia: Bool { active?.noisy == true && active?.built != nil }

    func pauseMedia() {
        guard canPauseMedia, let web = active?.built else { return }
        web.pauseAllMediaPlayback()
        announce("Paused")
    }

    // MARK: - taking things off pages

    let curtain = Shared.curtain
    @ObservationIgnored var fileChoice: FileChoice?
    @ObservationIgnored var privateFileDownloads: [Keep] = []
    let loot = Shared.loot
    let floater = Shared.floater
    /// True while the pointer is picking things to hide.
    private(set) var veiling = false
    /// True while the list of what is hidden here is up.
    var reviewing = false {
        didSet { if !reviewing { stopPeeking() } }
    }

    var hereHost: String? { curtain.host(of: active?.address) }
    var hereVeils: [Veil] { curtain.veils(on: hereHost) }

    /// ⌘⇧H. Point at anything on the page and it goes, for good, on this site.
    func toggleHiding() {
        guard let tab = active, tab.isWeb else { return }
        if veiling {
            veiling = false
            tab.stopPicking()
        } else {
            reviewing = false
            veiling = true
            tab.startPicking()
        }
    }

    /// What a private tab took off its page, kept for that page only.
    @ObservationIgnored private var passingVeils: [Tab.ID: [String]] = [:]

    private func passingCSS(_ id: Tab.ID) -> String {
        (passingVeils[id] ?? []).map { "\n\($0) { display: none !important; }" }.joined()
    }

    /// ⌘Z, while pointing: the last thing you took off comes back.
    func undoHiding() {
        if let tab = active, tab.shy {
            guard var list = passingVeils[tab.id], !list.isEmpty else { return }
            list.removeLast()
            passingVeils[tab.id] = list
            tab.applyVeils(curtain.css(on: hereHost) + passingCSS(tab.id))
            announce("It's back")
            return
        }
        guard let host = hereHost, let back = curtain.undo(on: host) else { return }
        redress()
        announce("\(back.label) is back")
    }

    /// The pointer resting on a row in the list brings that one thing back,
    /// outlined, and scrolls the page to it.
    func peek(_ veil: Veil) {
        guard let tab = active else { return }
        tab.peek(veil.selector, keeping: curtain.css(on: hereHost, without: veil.selector))
    }

    func stopPeeking() {
        active?.unpeek(curtain.css(on: hereHost))
    }

    func restore(_ veil: Veil) {
        guard let host = hereHost else { return }
        curtain.restore(veil, on: host)
        redress()
    }

    func restoreAll() {
        guard let host = hereHost else { return }
        curtain.restoreAll(on: host)
        redress()
        reviewing = false
        announce("Everything is back")
    }

    /// Both the page in front of you and the one that loads next time.
    private func redress() {
        guard let tab = active else { return }
        let css = curtain.css(on: hereHost)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }

    // MARK: - passwords

    /// A name and password a page has just sent, waiting to be offered a place
    /// in the keychain. Held only until you answer.
    private(set) var offering: Offer?
    @ObservationIgnored private(set) var offeringTab: Tab.ID?

    struct Offer: Equatable {
        let login: Login
        /// The same account is already kept, with a different password.
        let changed: Bool
    }

    /// The accounts kept for the site whose sign-in box has the caret, and
    /// where that box is — a list hangs from it, and a click fills the form.
    /// Nothing is put into a page until you have pointed at it.
    private(set) var suggesting: Suggesting? {
        didSet {
            // The offer to use Apple Passwords went without a click on it
            // or its ✕: counted, and after twice it isn't made again.
            guard let site = oldValue?.appleOffer, suggesting?.appleOffer != site else { return }
            if offerAnswered { offerAnswered = false } else { applePasswordsOffer.unanswered() }
        }
    }
    /// The offer's row or its ✕ was clicked: not counted as unanswered.
    @ObservationIgnored private var offerAnswered = false
    /// Where "Use your Apple passwords?" was offered and answered
    /// (ApplePasswordsOffer). A test gives its own.
    @ObservationIgnored var applePasswordsOffer = ApplePasswordsOffer(store: Store.settings)

    struct Suggesting: Equatable {
        let tab: Tab.ID
        var spot: CGRect
        /// Without secrets: one is read only for the account picked.
        let logins: [Kept]
        /// The Mac's passkeys for a page waiting for one under its field.
        var passkeys: [Passkeys.Offered] = []
        /// The page the list was made for: its site, and whether it came in
        /// the clear. A click fills only a page that still is that one.
        let host: String
        let clear: Bool
        /// Hung from a first step's name box: a pick puts in the name alone.
        var nameOnly = false
        /// Accounts from the Mac's Passwords app (ApplePasswords.swift),
        /// names only, and the page host they were asked for. Set when the
        /// helper answers, after the list is up.
        var apple: [AppleLogin] = []
        var appleHost: String?
        /// Apple Passwords is on but not paired: a row to connect.
        var appleConnect = false
        /// Apple Passwords is off and Search keeps nothing for this site: a
        /// quiet row at the bottom offers it, once (ApplePasswordsOffer). The
        /// site it is counted against.
        var appleOffer: String?
        /// When it came up. A page can put the caret in a sign-in box
        /// itself, an invisible one under the pointer included: a click that
        /// was already on its way is not a choice, so the list takes none for
        /// its first half second, as Chrome's does.
        var shown = Date()
        /// Hung from a box that is clearly a sign-in's, with the site's
        /// other hosts' accounts; false: this host's alone.
        var wide = true
        var formHint: String?
        var codes: [OneTimeCode] = []
        var strong: String?
    }
    @ObservationIgnored lazy var codeWatch: CodeWatch = {
        let watch = CodeWatch()
        watch.browser = self
        return watch
    }()
    @ObservationIgnored lazy var forms: FormFill = {
        let forms = FormFill()
        forms.browser = self
        return forms
    }()
    /// Set once you have picked, so the list doesn't come straight back for
    /// the box you are still in. Cleared when the caret leaves the boxes.
    @ObservationIgnored private var pickedInto: Tab.ID?
    /// The list is taken down a beat after the caret leaves, not the same
    /// instant: clicking a row can take the caret out of the page first, and
    /// a list that vanished on the way down would never be clicked.
    @ObservationIgnored private var lowering: DispatchWorkItem?
    /// The page whose accounts were last looked up for the box the caret is
    /// in. The box reports where it is on every frame of a scroll so the
    /// list can follow it; the keychain is asked once per box, not per frame.
    @ObservationIgnored private var looked: (tab: Tab.ID, host: String, clear: Bool, name: Bool, wide: Bool, hint: String?, fresh: Int?)?
    /// The sign-in box the caret is in, for a list that changes while it is
    /// there: the page's passkeys arrive when they arrive.
    @ObservationIgnored private var field: (tab: Tab.ID, spot: CGRect, passwords: Bool, name: Bool)?
    /// Counts the boxes Apple Passwords was asked about: an answer for a box
    /// the caret has left since is dropped.
    @ObservationIgnored private var appleAsk = 0
    @ObservationIgnored private var keptAsk = 0

    func keepOffer() {
        guard let offer = offering else { return }
        offering = nil
        let login = offer.login
        Task { [weak self] in
            let saved = await Vault.off {
                Vault.save(host: login.host, user: login.user, password: login.password, used: Date(), clear: login.clear, port: login.port)
            }
            guard let self else { return }
            guard saved else { return announce("The keychain refused it", kind: .error) }
            relist()
            announce(offer.changed ? "Password updated for \(login.host)" : "Password saved for \(login.host)")
        }
    }

    func dropOffer() { offering = nil }

    /// Never for this site. Some sites you sign into on purpose with nothing
    /// you want remembered.
    func neverOffer() {
        guard let offer = offering else { return }
        Vault.never(offer.login.host)
        offering = nil
        announce("Won't offer to save for \(offer.login.host)")
    }

    /// The caret in a sign-in box: the accounts kept for this site, and the
    /// Mac's passkeys for a page waiting for one, hang from the box, and go
    /// when the caret does. Nothing is filled on its own — the way Safari
    /// does it, and what a person expects.
    private func hang(from tab: Tab, _ spot: CGRect?, passwords: Bool, name: Bool = false, wide: Bool = true) {
        guard let spot else {
            if field?.tab == tab.id { field = nil; appleAsk += 1 }
            if looked?.tab == tab.id { looked = nil }
            if pickedInto == tab.id { pickedInto = nil }
            codeWatch.left(tab)
            guard suggesting?.tab == tab.id else { return }
            lowering?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, suggesting?.tab == tab.id else { return }
                suggesting = nil
            }
            lowering = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return
        }
        lowering?.cancel()
        field = (tab.id, spot, passwords, name)
        guard tab.id == activeID, pickedInto != tab.id,
              let host = curtain.host(of: tab.pageAddress)
        else { return }
        codeWatch.focused(on: tab, field: tab.focusedField)
        // A page that came over plain http can have been written by
        // anyone on the way here — a café's network, a hotel's. It is
        // offered only what was kept from plain http too, never an
        // account kept from the https site of the same name.
        let inTheClear = tab.pageAddress?.scheme?.lowercased() == "http"
        // The same box, moved by a scroll: the list up follows it, keeping
        // its accounts and the moment it came up (a click is refused for
        // its first half second, which every frame used to start again);
        // a box with no accounts stays without, and the keychain isn't
        // asked again until the caret leaves.
        let hint = forms.hint(for: tab, field: tab.focusedField)
        if let looked, looked.tab == tab.id, looked.host == host, looked.clear == inTheClear, looked.name == name,
           looked.wide == wide, looked.hint == hint, looked.fresh == tab.freshField {
            if var up = suggesting, up.tab == tab.id, up.spot != spot {
                up.spot = spot
                suggesting = up
            }
            return
        }
        looked = (tab.id, host, inTheClear, name, wide, hint, tab.freshField)
        let wanted = prefs.fillsPasswords && passwords
        guard wanted, !Vault.rehearsing else {
            let found = wanted ? Vault.kept(matching: host, wide: wide) : []
            return raiseList(found, tab: tab, spot: spot, host: host, inTheClear: inTheClear, passwords: passwords,
                             name: name, wide: wide, hint: hint)
        }
        keptAsk += 1
        let ask = keptAsk
        Task { [weak self] in
            let found = await Vault.off { Vault.kept(matching: host, wide: wide) }
            guard let self, ask == keptAsk, let field, field.tab == tab.id, tab.id == activeID,
                  curtain.host(of: tab.pageAddress) == host
            else { return }
            raiseList(found, tab: tab, spot: field.spot, host: host, inTheClear: inTheClear, passwords: passwords,
                      name: name, wide: wide, hint: hint)
        }
    }

    private func raiseList(_ found: [Kept], tab: Tab, spot: CGRect, host: String, inTheClear: Bool, passwords: Bool,
                           name: Bool, wide: Bool, hint: String?) {
        var kept = found.filter { !inTheClear || $0.clear }
        // The account whose name the step before was sent with comes first:
        // the password page of a sign-in that asks for the name first.
        if let given = tab.givenName(),
           let at = kept.firstIndex(where: { $0.user.caseInsensitiveCompare(given) == .orderedSame }) {
            kept.insert(kept.remove(at: at), at: 0)
        }
        let known = Array(kept.prefix(5))
        let passkeys = Passkeys.shared.offered(in: tab.built)
        // The Mac's Passwords app, when turned on: an https page of an
        // ordinary tab only, asked about by its own host. Paired, its names
        // join the list when the helper answers; not yet, a row offers to
        // connect.
        let appleHost = AppleHelper.available && prefs.applePasswords && prefs.fillsPasswords && passwords
            ? ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) : nil
        let apple = applePasswords
        let connect = appleHost != nil && apple.state == .idle && applePairing?.tab != tab.id
        // Off, and nothing of Search's own for this site: the offer, once.
        // The row already up under this box stays up while it is there.
        let offer: String? = {
            guard AppleHelper.available else { return nil }
            if let up = suggesting, up.tab == tab.id, let site = up.appleOffer, site == Vault.registrable(host) { return site }
            return applePasswordsOffer.site(
                for: .init(page: tab.pageAddress, privateTab: tab.shy, frameHost: tab.fieldFrameHost,
                           passwords: passwords, kept: known.count),
                .init(appleOn: prefs.applePasswords, fills: prefs.fillsPasswords,
                      helper: ApplePasswordsOffer.benchHelper ?? ApplePasswordsOffer.helperHere,
                      testRun: Store.testing, benchAsks: ApplePasswordsOffer.benchAsks))
        }()
        appleAsk += 1
        // Asked only for the tab in front of you, in the window you are in.
        if let appleHost, apple.state == .paired, tab.built?.window?.isKeyWindow == true {
            lookUpApple(appleHost, in: tab, host: host, name: name, wide: wide)
        }
        let codes = codeWatch.offers(on: tab)
        let strong = strongPassword(for: tab, now: suggesting)
        guard !known.isEmpty || !passkeys.isEmpty || connect || offer != nil || hint != nil || !codes.isEmpty || strong != nil else {
            suggesting = nil
            return
        }
        // What is under the pointer changed: the half second starts again.
        if let up = suggesting, up.tab == tab.id, up.logins == known, up.passkeys == passkeys, up.nameOnly == name,
           up.appleConnect == connect, up.apple.isEmpty, up.wide == wide, up.appleOffer == offer, up.formHint == hint, up.codes == codes,
           up.strong == strong {
            suggesting?.spot = spot
            return
        }
        suggesting = Suggesting(tab: tab.id, spot: spot, logins: known, passkeys: passkeys, host: host, clear: inTheClear,
                                nameOnly: name, appleHost: appleHost, appleConnect: connect, appleOffer: offer, wide: wide, formHint: hint, codes: codes,
                                strong: strong)
        if let offer { applePasswordsOffer.shown(on: offer) }
    }

    /// Asks Apple's helper for the names it keeps for the page, and adds
    /// them under the box if the caret is still in it, on the same page.
    private func lookUpApple(_ appleHost: String, in tab: Tab, host: String, name: Bool, wide: Bool) {
        let ask = appleAsk
        Task { [weak self] in
            // A page that moves the caret from box to box queues no backlog:
            // a question the caret has already left is never sent.
            guard let keeper = self?.applePasswords else { return }
            let found = await keeper.logins(for: appleHost, tab: tab.id) { [weak self] in
                self?.appleAsk == ask
            }
            guard let self, ask == appleAsk, let field, field.tab == tab.id, tab.id == activeID,
                  ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) == appleHost
            else { return }
            let mine = suggesting?.tab == tab.id ? suggesting?.logins ?? [] : []
            let apple = Array(found
                .filter { ApplePasswords.belongs($0.sites, to: appleHost, wide: wide) }
                .filter { theirs in !mine.contains { $0.user.caseInsensitiveCompare(theirs.user) == .orderedSame } }
                .prefix(5))
            guard !apple.isEmpty else { return }
            if var up = suggesting, up.tab == tab.id {
                up.apple = apple
                up.appleHost = appleHost
                up.appleConnect = false
                // New rows under the pointer: the half second starts again.
                up.shown = Date()
                suggesting = up
            } else {
                suggesting = Suggesting(tab: tab.id, spot: field.spot, logins: [], host: host, clear: false,
                                        nameOnly: name, apple: apple, appleHost: appleHost)
            }
        }
    }

    /// One of the Passwords app's accounts, picked by name. Its password is
    /// asked for now (macOS may want Touch ID), put into the page if it is
    /// still the page it was asked for, and not kept.
    func choose(_ apple: AppleLogin) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }), let appleHost = list.appleHost else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        guard ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) == appleHost,
              ApplePasswords.belongs(apple.sites, to: appleHost)
        else { return }
        pickedInto = tab.id
        if list.nameOnly {
            tab.fillName(apple.user) { [weak self] worked in
                if !worked { self?.announce("The sign-in fields are gone") }
            }
            return
        }
        Task { [weak self] in
            guard let keeper = self?.applePasswords else { return }
            let found = await keeper.password(for: apple.user, host: appleHost, tab: tab.id)
            guard let self else { return }
            guard let found else {
                announce("Apple Passwords didn't hand that password over", kind: .error)
                return
            }
            // Touch ID can take a while: the page must still be the one
            // asked for, in front, and the account still this site's.
            guard tabs.contains(where: { $0 === tab }), tab.id == activeID,
                  ApplePasswords.offers(on: tab.pageAddress, privateTab: tab.shy) == appleHost,
                  ApplePasswords.belongs(found.sites, to: appleHost)
            else { return }
            tab.appleFill = AppleFill(host: appleHost, user: apple.user, password: found.password)
            // Over https only, on that host (Tab.fill checks both in the page).
            tab.fill(user: apple.user, password: found.password, onlyOn: URL(string: "https://\(appleHost)/")) { [weak self] worked in
                if !worked { self?.announce("The sign-in fields are gone") }
            }
        }
    }

    /// The row that connects Apple Passwords: the pairing starts, and the
    /// code is typed into a small card of Search's own where the list was,
    /// not in Settings. Once paired, the caret goes back to the box and the
    /// accounts come up under it.
    func connectApplePasswords() {
        lowering?.cancel()
        // The same half second as any row: a click already on its way when
        // a page put the caret in a box isn't a choice.
        guard AppleHelper.available, let list = suggesting, Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        beginApplePairing(on: list.tab, at: list.spot)
    }

    /// "Use your Apple passwords?" clicked: the switch turned on, as in
    /// Settings › Passwords, and the pairing card where the list was. Once
    /// paired, the caret goes back to the box and the accounts come up.
    func useApplePasswords() {
        lowering?.cancel()
        guard AppleHelper.available, let list = suggesting, list.appleOffer != nil, Date().timeIntervalSince(list.shown) > 0.5 else { return }
        offerAnswered = true
        suggesting = nil
        prefs.applePasswords = true
        beginApplePairing(on: list.tab, at: list.spot)
    }

    /// The offer's ✕: "don't offer again", anywhere. The rest of the list
    /// stays.
    func neverOfferApplePasswords() {
        lowering?.cancel()
        guard var list = suggesting, list.appleOffer != nil, Date().timeIntervalSince(list.shown) > 0.5 else { return }
        applePasswordsOffer.dismissed()
        offerAnswered = true
        list.appleOffer = nil
        let empty = list.logins.isEmpty && list.passkeys.isEmpty && list.apple.isEmpty && !list.appleConnect
        suggesting = empty ? nil : list
    }

    /// For a test run only: the offer under a box of `tab`, as `hang` puts
    /// it up, `age` seconds ago; or (nil) the list taken down as the caret
    /// leaving takes it.
    func testOffer(on tab: Tab.ID?, site: String = "example.com", age: TimeInterval = 1) {
        guard Store.testing else { return }
        guard let tab else { suggesting = nil; return }
        var list = Suggesting(tab: tab, spot: CGRect(x: 40, y: 120, width: 280, height: 30), logins: [], host: site,
                              clear: false, appleOffer: site)
        list.shown = Date().addingTimeInterval(-age)
        suggesting = list
        applePasswordsOffer.shown(on: site)
    }

    /// Pairing with Apple Passwords from under a sign-in box: the card that
    /// takes the code, over the page it was asked from. Native, never in the
    /// page; the page learns nothing of it.
    private(set) var applePairing: ApplePairing?

    struct ApplePairing: Equatable {
        let tab: Tab.ID
        let spot: CGRect
    }

    /// The Passwords app's connection. One for the whole app; a test gives
    /// its own, with a made-up helper.
    @ObservationIgnored var applePasswords = ApplePasswords.shared
    @ObservationIgnored private var pairingWatch: AnyCancellable?

    func beginApplePairing(on tab: Tab.ID, at spot: CGRect) {
        guard AppleHelper.available else { return }
        let apple = applePasswords
        applePairing = ApplePairing(tab: tab, spot: spot)
        pairingWatch = kitObserve(initial: false, { [apple] in apple.state }) { [weak self] state in
            if state == .paired { self?.endApplePairing(paired: true) }
        }
        if apple.state == .idle { Task { await apple.connect() } }
    }

    /// The card goes. Paired: the caret back in the page's box, which says
    /// so again (focusin), and its accounts are asked for. Cancelled: the
    /// helper is stopped and its window with it.
    func endApplePairing(paired: Bool) {
        guard let pairing = applePairing else { return }
        applePairing = nil
        pairingWatch = nil
        if !paired, applePasswords.state != .paired { applePasswords.disconnect() }
        // Only the page it was asked from, still in front: never another.
        guard pairing.tab == activeID, let tab = tabs.first(where: { $0.id == pairing.tab }),
              let web = tab.built, let window = web.window
        else { return }
        looked = nil
        pickedInto = nil
        window.makeFirstResponder(web)
    }

    /// One of the accounts in the list, picked by name.
    func choose(_ login: Kept) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }) else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        // The tab may have gone somewhere else while the list was up: a
        // redirect, a script. What was offered for one site is never put
        // into another's page.
        guard curtain.host(of: tab.pageAddress) == list.host,
              (tab.pageAddress?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        // A first step: the name alone, the password waits for its page.
        if list.nameOnly {
            tab.fillName(login.user) { [weak self] worked in
                if !worked { self?.announce("The sign-in fields are gone") }
            }
            return
        }
        let page = tab.pageAddress
        Task { [weak self] in
            let read = await Vault.off { Vault.login(login) }
            guard let self else { return }
            guard let read else { return announce("The keychain refused it", kind: .error) }
            guard tabs.contains(where: { $0 === tab }), tab.pageAddress == page else { return }
            tab.keptFill = FillMark(host: list.host, user: read.user, password: read.password)
            tab.fill(user: read.user, password: read.password, onlyOn: page) { [weak self] worked in
                if !worked { self?.announce("The sign-in fields are gone") }
            }
            await Vault.off { Vault.touch(read) }
        }
    }

    /// One of the passkeys in the list: the Mac's sheet for it, and the
    /// page's request answered with it.
    func choose(_ passkey: Passkeys.Offered) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }), let web = tab.built else { return }
        guard Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        guard curtain.host(of: tab.pageAddress) == list.host,
              (tab.pageAddress?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        Passkeys.shared.sign(in: web, with: passkey.id)
    }

    func offerCodes(_ codes: [OneTimeCode], on tab: Tab) {
        guard let field, field.tab == tab.id, tab.id == activeID, pickedInto != tab.id,
              let host = curtain.host(of: tab.pageAddress)
        else { return }
        lowering?.cancel()
        if var up = suggesting, up.tab == tab.id {
            up.codes = codes
            up.shown = Date()
            suggesting = up
        } else {
            suggesting = Suggesting(tab: tab.id, spot: field.spot, logins: [], host: host, clear: false, codes: codes)
        }
    }

    func choose(_ code: OneTimeCode) {
        lowering?.cancel()
        guard let list = suggesting, let tab = tabs.first(where: { $0.id == list.tab }),
              Date().timeIntervalSince(list.shown) > 0.5
        else { return }
        guard curtain.host(of: tab.pageAddress) == list.host else {
            suggesting = nil
            return
        }
        suggesting = nil
        pickedInto = tab.id
        codeWatch.use(code, in: tab)
    }

    func chooseStrongPassword() {
        lowering?.cancel()
        guard let list = suggesting, let password = list.strong, let tab = tabs.first(where: { $0.id == list.tab }),
              Date().timeIntervalSince(list.shown) > 0.5
        else { return }
        suggesting = nil
        guard curtain.host(of: tab.pageAddress) == list.host,
              (tab.pageAddress?.scheme?.lowercased() == "http") == list.clear
        else { return }
        pickedInto = tab.id
        takeStrongPassword(password, in: tab, host: list.host, clear: list.clear)
    }

    func chooseFormFill() {
        lowering?.cancel()
        guard let list = suggesting, Date().timeIntervalSince(list.shown) > 0.5 else { return }
        suggesting = nil
        pickedInto = list.tab
        forms.begin()
    }

    func dropChoice() { suggesting = nil }

    // The list of what is kept.

    /// Passwords, in a tab. The list is read again each time it is asked for.
    var managing: Bool {
        get { pageTab(.passwords) != nil }
        set { if newValue { show(InternalPage(.passwords)) } else { putAway(.passwords) } }
    }
    /// The list, without secrets: see `Kept` and `Vault.all()`.
    private(set) var saved: [Kept] = []
    var hunting = ""
    /// A Remove All… under way, off the main thread (see `forgetShown`).
    private(set) var forgetting = false

    struct SiteRow {
        let host: String
        let logins: [Kept]
    }

    /// Grouped by site, filtered by what has been typed.
    var shownSites: [SiteRow] {
        let needle = hunting.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = needle.isEmpty ? saved : saved.filter {
            $0.host.contains(needle) || $0.user.lowercased().contains(needle)
        }
        let groups = Dictionary(grouping: rows, by: \.host)
        return groups.keys.sorted().map { host in
            SiteRow(host: host, logins: groups[host]!.sorted { $0.user < $1.user })
        }
    }

    func stage(saved list: [Kept]) { if Store.testing { saved = list } }

    func relist() {
        guard !Store.testing, !Vault.rehearsing else {
            saved = Vault.all()
            return
        }
        Task { [weak self] in
            let all = await Vault.off { Vault.all() }
            self?.saved = all
        }
    }

    func keep(host: String, user: String, password: String) {
        guard Vault.save(host: host, user: user, password: password) else {
            announce("The keychain refused it", kind: .error)
            return
        }
        relist()
        announce("Password saved for \(host)")
    }

    func forget(_ login: Kept) {
        Vault.forget(host: login.host, user: login.user)
        relist()
    }

    /// The panel's Remove All…, or Remove N… while its search narrows the
    /// list: every account the list shows, out of the keychain, once asked.
    /// Only what is shown, so a search for one site never takes the rest
    /// with it. For moving what is kept to a manager of one's own: all at
    /// once, rather than one Remove at a time (#469). Asked, then proved the
    /// way showing one is, since it can't be undone; Return is Cancel's.
    func forgetShown() {
        let shown = shownSites.flatMap(\.logins)
        guard !shown.isEmpty, !forgetting else { return }
        let count = shown.count
        let many = count == 1 ? "1 password" : "\(count) passwords"
        Ask.sure(
            count == 1 ? "Remove 1 password?" : "Remove \(count) passwords?",
            detail: "They're taken out of your keychain. Only the passwords Broadway keeps are removed. Password managers, other apps and other browsers keep theirs. This can't be undone.",
            confirm: "Remove",
            returnCancels: true
        ) { [weak self] in
            Vault.prove("remove \(many)") { ok in
                guard ok, let self, !self.forgetting else { return }
                // A keychain delete is a few milliseconds, a few hundred of
                // them a second: off the main thread, as imports are (#380).
                self.forgetting = true
                DispatchQueue.global(qos: .userInitiated).async {
                    // Counted as the keychain answers, not as asked: one
                    // it kept is not reported gone.
                    let gone = shown.filter { Vault.forget(host: $0.host, user: $0.user) }.count
                    DispatchQueue.main.async {
                        self.forgetting = false
                        self.relist()
                        let removed = gone == 1 ? "1 password" : "\(gone) passwords"
                        self.announce(gone == count ? "Removed \(removed)"
                            : gone == 0 ? "The keychain refused them"
                            : "Removed \(gone) of \(many)")
                    }
                }
            }
        }
    }

    /// A password copied is asked for the way one shown is. It goes on this
    /// Mac's clipboard only, not to your other devices', marked concealed
    /// and transient, which is what clipboard managers go by to keep it out
    /// of their history, and it is taken off again after a minute and a
    /// half unless something else has been copied since.
    func copy(_ login: Kept) {
        Vault.prove("copy the password for \(login.host)") { [weak self] ok in
            guard ok, let self else { return }
            Task { [weak self] in
                let read = await Vault.off { Vault.secret(of: login) }
                guard let self else { return }
                guard let password = read else { return announce("The keychain refused it", kind: .error) }
                let board = NSPasteboard.general
                board.prepareForNewContents(with: .currentHostOnly)
                board.setString(password, forType: .string)
                board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
                let copied = board.changeCount
                DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
                    if board.changeCount == copied { board.clearContents() }
                }
                announce("Password copied")
            }
        }
    }

    /// What came back from another browser's store, put in the keychain,
    /// with the sites it was told never to ask about. Saving one already
    /// kept updates it, so bringing the same in again adds nothing twice.
    /// Returns how many were kept.
    func keep(_ found: Chromium.Found) -> Int {
        var kept = 0
        for login in found.logins
        where Vault.save(host: login.host, user: login.user, password: login.password, used: login.used, clear: login.clear) {
            kept += 1
        }
        var never = Vault.never
        found.never.forEach { never.insert($0) }
        Vault.never = never
        relist()
        return kept
    }

    /// The same, said as it lands.
    func took(_ outcome: Result<Chromium.Found, Error>, from name: String) {
        switch outcome {
        case .success(let found):
            let kept = keep(found)
            ImportRecords.note(name, passwords: kept)
            let locked = found.undecrypted > 0 ? ", \(found.undecrypted) couldn't be decrypted" : ""
            announce((kept == 0 ? "Nothing new in \(name)" : kept == 1 ? "1 password from \(name)" : "\(kept) passwords from \(name)") + locked)
        case .failure(Chromium.Trouble.noPassphrase):
            announce("\(name) didn't give up its keychain key", kind: .error)
        case .failure(Mozilla.Trouble.primaryPassword):
            announce("\(name) has a primary password. Export your passwords from its Settings › Passwords › ⋯ › Export, then bring in the CSV file.")
        case .failure:
            announce("Nothing readable in \(name)")
        }
    }

    /// The other browser's history, into this one's. Off the main thread for
    /// the reading; the merge itself is a moment.
    func takePlaces(from source: ImportSource, profile: String? = nil, then done: @escaping (Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let places = source.places(profile: profile)
            DispatchQueue.main.async {
                for place in places {
                    self.history.take(place.url, title: place.title, count: place.count, last: place.last)
                }
                self.history.settle()
                ImportRecords.note(source.name, places: places.count)
                done(places.count)
            }
        }
    }

    /// Something another browser exported: a bookmarks page, a passwords
    /// file, or Safari's own export (see ImportFile). Read once, never copied.
    func importFile() {
        guard fileImport == nil, let url = Browser.askForExportFile() else { return }
        Task { announce((await takeFile(url)).said) }
    }

    static func askForExportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html, .commaSeparatedText, .plainText, .zip, .json]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Bring In"
        panel.message = "A file another browser exported: bookmarks as .html, passwords as .csv, or the .zip from Safari's File › Export Browsing Data"
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    /// The file's bookmarks, history and passwords, taken in as a browser's
    /// are: bookmarks merged without doubles, history counted once. Says
    /// what came in, and after Safari's export, that the file holds your
    /// passwords in the clear.
    struct FileTake {
        let said: String
        let bookmarks: Int
        let already: Int
        let places: Int
        let kept: Int
        let skipped: Int
        let cancelled: Bool
    }

    @discardableResult
    func takeFile(_ url: URL) async -> FileTake {
        guard !Browser.fileImportTerminating, fileImport == nil else { return FileTake(said: "An import is already running", bookmarks: 0, already: 0, places: 0, kept: 0, skipped: 0, cancelled: false) }
        let id = UUID()
        fileImport = FileImportJob(id: id, filename: url.lastPathComponent, message: "Reading…")
        let control = ImportFile.Control { [weak self] progress in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.fileImport?.id == id, self.fileImport?.cancelling == false else { return }
                self.fileImport?.message = progress.message
                self.fileImport?.completed = progress.completed
                self.fileImport?.total = progress.total
            }
        }
        fileImportControl = control
        Browser.activeFileImports[id] = control
        defer {
            Browser.activeFileImports[id] = nil
            if fileImport?.id == id { fileImport = nil; fileImportControl = nil }
        }
        var added = 0, already = 0, places = 0, kept = 0, skipped = 0
        var safari = false
        var failed = false
        var mergedBookmarks = false
        do {
            let found: ImportFile.Found = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try ImportFile.read(url, control: control)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            safari = found.fromSafari
            try control.checkCancellation()
            let name = found.fromSafari ? "Safari" : url.deletingPathExtension().lastPathComponent
            if !found.bookmarks.isEmpty {
                fileImport?.message = "Merging bookmarks…"
                fileImport?.completed = 0
                fileImport?.total = nil
                let result = try await bookmarks.takeFile(found.bookmarks, from: name, control: control)
                mergedBookmarks = true
                added = result.added
                already = result.already
            }
            if !found.places.isEmpty {
                fileImport?.message = "Adding history…"
                fileImport?.completed = 0
                fileImport?.total = found.places.count
                for batch in stride(from: 0, to: found.places.count, by: 200) {
                    guard !control.isCancelled else { break }
                    let end = min(batch + 200, found.places.count)
                    for place in found.places[batch..<end] {
                        history.take(place.url, title: place.title, count: place.count, last: place.last)
                        places += 1
                    }
                    fileImport?.completed = places
                    fileImport?.total = found.places.count
                    await Task.yield()
                }
                if places > 0 { history.settle() }
            }
            if !found.passwords.isEmpty && !control.isCancelled {
                fileImport?.message = "Saving passwords…"
                fileImport?.completed = 0
                fileImport?.total = nil
                for text in found.passwords {
                    guard !control.isCancelled else { break }
                    let result = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async {
                            continuation.resume(returning: Vault.take(csv: text, control: control))
                        }
                    }
                    kept += result.kept
                    skipped += result.skipped
                }
            }
        } catch {
            failed = !control.isCancelled
        }
        if kept > 0 || skipped > 0 {
            saved = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: Vault.all())
                }
            }
        }
        func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        var parts: [String] = []
        if added > 0 || already > 0 {
            parts.append(already == 0 ? count(added, "bookmark", "bookmarks") : "\(count(added, "new bookmark", "new bookmarks")), \(already) already here")
        }
        if places > 0 { parts.append(count(places, "place", "places")) }
        if kept > 0 || skipped > 0 {
            parts.append(skipped == 0 ? count(kept, "password", "passwords") : "\(count(kept, "password", "passwords")), \(skipped) skipped")
        }
        var said = parts.joined(separator: " · ")
        if control.isCancelled {
            said = said.isEmpty ? (mergedBookmarks ? "Import cancelled after merging bookmarks" : "Import cancelled. Nothing was changed.") : "Import cancelled after " + said
        }
        else if failed { said = said.isEmpty ? "That file couldn't be read" : "Import stopped after " + said }
        else if said.isEmpty { said = mergedBookmarks ? "Bookmark folders imported" : "Nothing to bring in from that file" }
        if safari, kept > 0 {
            said = "\(said.fullStopped) The exported file holds your passwords in the clear, so delete it now."
        }
        return FileTake(said: said, bookmarks: added, already: already, places: places, kept: kept, skipped: skipped, cancelled: control.isCancelled)
    }

    // MARK: - what is kept, and getting rid of it

    enum RecallMode {
        case history, clearing
    }

    // One state keeps closing History from leaving its clearing controls open.
    var recallMode: RecallMode?
    /// History, in a tab.
    var recalling: Bool {
        get { pageTab(.history) != nil }
        set { if newValue { show(InternalPage(.history)) } else { putAway(.history) } }
    }
    /// Downloads, in a tab.
    var filing: Bool {
        get { pageTab(.files) != nil }
        set { if newValue { show(InternalPage(.files)) } else { putAway(.files) } }
    }

    var hoarding: Bool {
        get { pageTab(.downloads) != nil }
        set { if newValue { show(InternalPage(.downloads)) } else { putAway(.downloads) } }
    }
    var recallHunt = ""

    /// History › Clear Browsing Data…, from the menu, its shortcut, or
    /// ⇧⌘Delete with a page editor focused. The clearing controls are part
    /// of History, so the page comes out first; History opening afresh puts
    /// the mode back to its list (see show), so the mode is set after it is
    /// out, not before (#749).
    func clearBrowsingData() {
        recalling = true
        recallMode = .clearing
    }

    /// Cookies, caches, local storage — everything a site left on this Mac,
    /// in every space. Clearing it signs you out of everything, which is
    /// the point.
    func clearSites() {
        DownloadTrace.forget()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        CertificateTrust.clearEverything()
        for store in Spaces.spaceStores() {
            SignInKeeper.shared.clearing(store)
            store.removeData(ofTypes: types, modifiedSince: .distantPast) { SignInKeeper.shared.cleared(store) }
        }
        announce("Signed out of everything")
    }

    /// Only what was fetched to draw pages, not what identifies you.
    func clearCache() {
        DownloadTrace.forget()
        let types: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeOfflineWebApplicationCache,
        ]
        for store in Spaces.spaceStores() {
            store.removeData(ofTypes: types, modifiedSince: .distantPast) {}
        }
        announce("Cache cleared")
    }

    enum Clearing: String, CaseIterable {
        case history = "clear.history"
        case sites = "clear.cookies"
        case cache = "clear.cache"

        var title: String {
            switch self {
            case .history: "Clear history?"
            case .sites: "Sign out of every site?"
            case .cache: "Clear cache?"
            }
        }

        var row: String {
            switch self {
            case .history: "Clear History…"
            case .sites: "Sign Out of Every Site…"
            case .cache: "Clear Cache…"
            }
        }

        var detail: String {
            switch self {
            case .history: "Every address you have been to, in every space, is removed from this Mac, with the text kept from those pages, the sites' icons, the searches learned from sites and the video speeds kept for them. Open tabs, bookmarks and sign-ins stay. This can't be undone."
            case .sites: "Cookies, sign-ins and everything sites keep on this Mac are removed from every space, so you are signed out everywhere. History, tabs and bookmarks stay. This can't be undone."
            case .cache: "The copies of pages and images kept to draw sites faster are removed from every space. Sign-ins, cookies, history and tabs stay."
            }
        }

        var confirm: String {
            switch self {
            case .history: "Clear History"
            case .sites: "Sign Out"
            case .cache: "Clear Cache"
            }
        }
    }

    func askToClear(_ what: Clearing, over window: NSWindow? = nil) {
        Ask.sure(what.title, detail: what.detail, confirm: what.confirm, returnCancels: true, over: window) { [weak self] in
            self?.clear(what)
        }
    }

    func clear(_ what: Clearing) {
        switch what {
        case .history: clearHistory()
        case .sites: clearSites()
        case .cache: clearCache()
        }
    }

    func clearHistory() {
        DownloadTrace.forget()
        history.forget()
        // The sites' icons are a list of where you have been, too, and so
        // are the searches learned from sites visited (SiteSearch.swift).
        Favicons.shared.forgetAll()
        SiteSearch.forget()
        SiteNameBook.forget()
        forms.answers.forgetAll()
        forgetVideoTraces()
        announce("History cleared")
    }

    func forgetVideoTraces(of host: String? = nil, since date: Date? = nil) {
        if let host {
            VideoSpeed.forget(under: host)
            if YouTubeAds.hosts.contains(where: { VideoSpeed.covers(host, Address.withoutWWW($0)) }) { VideoQuality.forgetLast() }
        } else if let date {
            VideoSpeed.forget(since: date)
            VideoQuality.forgetLast(since: date)
        } else {
            VideoSpeed.forgetAll()
            VideoQuality.forgetLast()
        }
        VideoSpeedBook.shared.changed()
    }

    /// The last few places, for the History menu.
    var recentlyVisited: [History.Trace] {
        history.recent()
    }

    // MARK: - the camera and the microphone

    /// A page asking to see or hear you, waiting for an answer. WebKit hands
    /// over a decision handler and holds the page until it is called — so this
    /// keeps the handler and the question together, and never drops either.
    struct CaptureAsk: Equatable, Identifiable {
        let host: String
        let wants: String
        /// Location is also given for this once, and kept only when you say
        /// always; in a private tab it is never kept.
        var once = false
        var keeps = true
        var screen = false
        /// The page also asks for the Mac's own sound with the screen.
        var sound = false
        var reach = ""
        var mac = false
        /// When it came up. A page can time a click to land where Allow is
        /// about to be: the card takes none in its first half second.
        var shown = Date()
        var id: String { host + wants }
    }

    private(set) var asking: CaptureAsk?
    @ObservationIgnored private var decide: ((WKPermissionDecision) -> Void)?
    /// WebKit's screen-sharing answers: deny (0), screen (1), window (2).
    @ObservationIgnored private var decideDisplay: ((Int) -> Void)?
    @ObservationIgnored private weak var displayTab: Tab?
    @ObservationIgnored private var displayHeld: HeldQuestion?
    @ObservationIgnored private var displayRequest: UUID?
    private var permissionBusy: Bool { decide != nil || decideDisplay != nil }
    private(set) static var displayAnswered: Int?
    @ObservationIgnored private var askedAbout = ""

    func allowCapture() { answerCapture(.grant) }
    func allowCaptureOnce() { answerCapture(.grant, keep: false) }
    func denyCapture() { answerCapture(.deny) }

    func shareScreen() { answerDisplay(1) }
    func shareWindow() { answerDisplay(2) }
    func denyShare() { answerDisplay(0) }

    private func answerDisplay(_ decision: Int) {
        guard decideDisplay != nil, let asking, asking.screen,
              Date().timeIntervalSince(asking.shown) > 0.5 else { return }
        finishDisplay(decision)
    }

    func cancelDisplay(for webView: WKWebView? = nil) {
        guard webView == nil || displayTab?.built === webView else { return }
        finishDisplay(0)
    }

    private func finishDisplay(_ decision: Int) {
        guard let reply = decideDisplay else { return }
        decideDisplay = nil
        displayRequest = nil
        if let tab = displayTab, let held = displayHeld {
            heldDialogs[tab.id]?.removeAll { $0 === held }
        }
        displayHeld = nil
        displayTab = nil
        if asking?.screen == true { asking = nil }
        // A test records the choice without ever opening the system picker.
        if Store.testing { Browser.displayAnswered = decision }
        reply(Store.testing ? 0 : decision)
    }

    /// A page or popup going away must settle its permission callback too,
    /// the screen's included.
    func cancelCapture() {
        cancelDisplay()
        let pending = decide
        decide = nil
        askedAbout = ""
        asking = nil
        pending?(.deny)
    }

    private func answerCapture(_ decision: WKPermissionDecision, keep: Bool = true) {
        guard let decide, let asking, Date().timeIntervalSince(asking.shown) > 0.5 else { return }
        // Remembered per site, so a call you take every week asks once.
        if keep, !askedAbout.isEmpty { Store.settings.set(decision == .grant, forKey: "capture." + askedAbout) }
        self.decide = nil
        askedAbout = ""
        self.asking = nil
        decide(decision)
    }

    /// Everything a site has been allowed or refused, for the day you want to
    /// change your mind.
    func forgetCaptureChoices() {
        for key in Store.settings.dictionaryRepresentation().keys
        where key.hasPrefix("capture.") || key.hasPrefix(Grounded.prefix) {
            Store.settings.removeObject(forKey: key)
        }
        VideoSpeed.forgetAll()
        LocalNetworkGuard.shared.refitAll()
        SiteNotifications.shared.changed()
        VideoSpeedBook.shared.changed()
        announce("Camera, microphone, location, notification and video speed choices forgotten")
    }

    /// What was last answered to a page asking where you are, in a test run
    /// — which never goes on to ask the Mac: that would put macOS's own
    /// question on the screen of whoever is working beside it.
    private(set) static var locationAnswered: String?

    // MARK: - pinning

    /// The pinned tab whose letter is being typed over, in place. There is no
    /// dialog: pinning happens at once, with a letter guessed from the address,
    /// and that letter arrives selected so the next keystroke replaces it.
    var editingPin: Tab.ID?

    var pinnedCount: Int { tabs.filter { $0.pin != nil }.count }

    var squarePins: [Tab] { tabs.filter { $0.pin != nil && standsInRow($0) } }

    func pin(_ tab: Tab) {
        let mark = beginStep("Pin Tab")
        defer { endStep(mark) }
        // Drawn again even when the tab stays where it is (see unpin).
        revision &+= 1
        // Pins are the space's, kept on disk and shown in every window: a
        // private tab can't be one, or its page would outlive it there.
        guard !tab.shy, tab.page == nil, pinnedSplit(of: tab) == nil else { return }
        detachSplit(tab)
        if tab.pin == nil {
            moving(tab) {
                let previousGroup = tab.groupID
                tab.groupID = nil
                letGoLive(tab, from: previousGroup)
                removeEmptyGroup(previousGroup)
                tab.pin = tab.monogram
                tab.home = tab.pending ?? tab.address
                settlePin(tab)
            }
            if pinnedCount == 1 { Delight.shared.first(.firstPin, in: self) }
        }
        // No dialog and no waiting cursor: the letter is taken from the
        // address and applied. Changing it is a separate act, for the day it
        // matters — which is why it is not folded into this one.
        writeSession(now: true)
    }

    @ObservationIgnored var pinFlight: ((Tab, () -> Void) -> Bool)?
    @ObservationIgnored weak var pinFlightOwner: AnyObject?

    private func moving(_ tab: Tab, _ change: () -> Void) {
        if pinFlight?(tab, change) != true { change() }
    }

    private func settlePin(_ tab: Tab) {
        guard let here = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        var row = tabs
        row.remove(at: here)
        row.insert(tab, at: row.filter { $0.pin != nil }.count)
        if !row.elementsEqual(tabs, by: { $0.id == $1.id }) { tabs = row }
    }

    /// A pin's page, from the session: the one it was pinned at, or — for a
    /// pin from before pins kept theirs — where it was when it came back.
    static func home(of entry: Session.Entry, at url: URL) -> URL? {
        guard entry.pin != nil else { return nil }
        return entry.home.flatMap(URL.init(string:)) ?? url
    }

    /// A double-click on the pin you are on: back to the page it was pinned
    /// at, as a pin in Arc goes home (#141). Already there, the double-click
    /// changes its letter, as it always did.
    func goHome(_ tab: Tab) {
        guard tab.pin != nil else { return }
        guard let home = tab.home, !Browser.samePage(home, tab.address) else { return editLetter(tab) }
        tab.go(to: home)
        rememberSession()
    }

    /// The same page, give or take a trailing slash.
    static func samePage(_ one: URL, _ other: URL?) -> Bool {
        guard let other else { return false }
        func bare(_ url: URL) -> String {
            var text = url.absoluteString
            while text.hasSuffix("/") { text.removeLast() }
            return text
        }
        return bare(one) == bare(other)
    }

    /// Change Letter, or a double-click on the square itself.
    func editLetter(_ tab: Tab) {
        guard tab.pin != nil else { return }
        editingPin = tab.id
    }

    /// Typed into the square. Empty leaves the letter as it was — a pinned tab
    /// with nothing on it would be a blank square you could never identify.
    func letter(_ typed: String, for tab: Tab) {
        guard let first = typed.trimmingCharacters(in: .whitespacesAndNewlines).first else {
            return
        }
        tab.pin = String(first).uppercased()
    }

    func endPinEdit() {
        guard editingPin != nil else { return }
        editingPin = nil
        writeSession(now: true)
    }

    func unpin(_ tab: Tab) {
        let mark = beginStep("Unpin Tab")
        defer { endStep(mark) }
        if editingPin == tab.id { editingPin = nil }
        unpinningLeaves(tab)
        // The row is drawn again whether or not the tab moves. Unpinning the
        // only tab, or the last pin, leaves it where it is; `tabs` didn't
        // change, only the tab did, and the column went on drawing it as a
        // pinned square — with no letter left, an empty tile — and never as
        // a row (from X).
        revision &+= 1
        if tab.everywhere, let id = tab.pinID {
            // One every space shows: out of them all, as unpinning in one
            // window is out of every window.
            tab.everywhere = false
            Pins.setShared(Pins.shared().filter { $0.id != id }, from: self)
            for space in Array(parked.keys) { pinsChanged(in: space) }
        }
        defer { writeSession(now: true) }
        moving(tab) {
            tab.pin = nil
            tab.home = nil
            tab.pinID = nil
            if let here = tabs.firstIndex(where: { $0.id == tab.id }) {
                let home = pinnedCount
                if here != home {
                    tabs.move(fromOffsets: IndexSet(integer: here), toOffset: home > here ? home + 1 : home)
                }
            }
        }
        rememberSession()
    }

    // MARK: - carried onto the pins, and off them

    /// Whether a tab carried onto the pins may become one there. Not a
    /// private tab (see pin), and not a pair: pinning one half would undo
    /// the pair under the hand. Pin Tab in the menu still pins the half
    /// it was asked for.
    func pinsByDrag(_ tab: Tab) -> Bool {
        tab.pin == nil && !tab.shy && split(for: tab) == nil && tabs.contains { $0.id == tab.id }
    }

    func pinSlot(_ tab: Tab, proposed: Int) -> Int {
        let tier = squarePins.filter { $0.id != tab.id }
        let shared = prefs.showsSharedPins ? tier.prefix(while: \.everywhere).count : 0
        let low = tab.everywhere ? 0 : shared
        let high = tab.everywhere ? shared : tier.count
        return min(max(proposed, low), high)
    }

    @discardableResult
    func pinDropped(_ tab: Tab, at slot: Int) -> Bool {
        let mark = beginStep(tab.pin == nil ? "Pin Tab" : "Move Tab")
        defer { endStep(mark) }
        if tab.pin == nil {
            guard pinsByDrag(tab) else { return false }
            pin(tab)
            guard tab.pin != nil else { return false }
        }
        placePin(tab, atSquare: pinSlot(tab, proposed: slot))
        writeSession(now: true)
        return true
    }

    /// A pin carried out among the tabs and let go there: unpinned as Unpin
    /// unpins it — a pin every space shows leaves them all, as it does from
    /// the menu — and put at `slot` among the tabs in no group, or into
    /// `group`. The page stays as it is.
    @discardableResult
    func unpinDropped(_ tab: Tab, at slot: Int, group: UUID? = nil) -> Bool {
        let mark = beginStep("Unpin Tab")
        defer { endStep(mark) }
        guard tab.pin != nil, tabs.contains(where: { $0.id == tab.id }) else { return false }
        if let pair = shownPinnedSplit(of: tab) { unpinSplit(pair) } else { unpin(tab) }
        if let group, prefs.usesTabGroups, tabGroups.contains(where: { $0.id == group }) {
            move(tab, toGroup: group)
        } else if prefs.usesTabGroups {
            let peers = tabs(in: nil).filter(standsInRow)
            move(tab, within: nil, to: min(max(0, slot), peers.count - 1))
        } else {
            moveDisplayedTab(tab, to: min(squarePins.count + max(0, slot), displayedTabs.count - 1))
        }
        writeSession(now: true)
        return true
    }

    // MARK: - the address, in the tab itself

    /// Clicking the tab you are already on turns it into the address, short
    /// form, ready to be changed.
    private(set) var editingTab: Tab.ID?
    var tabDraft = ""
    /// Set while that field is being used to name the tab rather than to go
    /// somewhere: the same field, the same keys, a different thing at the end.
    private(set) var renamingTab = false
    /// What the field in the tab offers as you type, as ⌘L's does (#534),
    /// and the row the arrow keys are on.
    private(set) var tabOffers: [Suggestion] = []
    private(set) var tabPicked: Int?
    @ObservationIgnored var tabPointer = PointerWatch()
    /// The address the edit began with: nothing is offered for that.
    @ObservationIgnored private var tabOriginal = ""

    func beginTabEdit(_ tab: Tab) {
        guard let url = tab.shownURL else {
            edit()
            return
        }
        renamingTab = false
        tabDraft = Address.editable(url)
        tabOriginal = tabDraft
        tabOffers = []
        tabPicked = nil
        editingTab = tab.id
    }

    /// Typed into the field in the tab: its list, and the rest of the
    /// address the field completes to, if any.
    func tabTyped(_ text: String) -> String? {
        tabPicked = nil
        let words = text.trimmingCharacters(in: .whitespaces)
        guard editingTab != nil, !renamingTab, !words.isEmpty, text != tabOriginal else {
            tabOffers = []
            return nil
        }
        let (offers, ending) = placeOffers(for: text)
        tabOffers = offers
        return ending
    }

    /// ↓ and ↑ in the tab's field, off either end and back to what was typed.
    func walkTab(_ step: Int) {
        guard !tabOffers.isEmpty else { return }
        switch tabPicked {
        case nil: tabPicked = step > 0 ? 0 : tabOffers.count - 1
        case let here?:
            let next = here + step
            tabPicked = (next < 0 || next >= tabOffers.count) ? nil : next
        }
    }

    func pointTab(at index: Int) {
        guard tabPointer.moved() else { return }
        tabPicked = index
    }

    /// A row of the tab's list, clicked or walked to and Return pressed.
    func takeTabOffer(_ offer: Suggestion) {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        cancelTabEdit()
        if case .command(let command) = offer.kind {
            command.run(on: self)
        } else if let open = offer.tab, let other = tabs.first(where: { $0.id == open }) {
            select(other)
        } else {
            tab.go(to: offer.url)
        }
    }

    /// Rename. The name the tab is wearing arrives selected, so typing
    /// replaces it; emptying the field gives the page its own title back.
    func beginTabRename(_ tab: Tab) {
        renamingTab = true
        tabDraft = tab.label
        editingTab = tab.id
    }

    func commitTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            let mark = beginStep("Rename Tab")
            defer { endStep(mark) }
            let typed = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            tab.name = typed.isEmpty ? nil : typed
            cancelTabEdit()
            writeSession(now: true)
            return
        }
        if let picked = tabPicked, tabOffers.indices.contains(picked) {
            takeTabOffer(tabOffers[picked])
            return
        }
        guard let url = destination(for: tabDraft) else {
            // Stay put and say so, rather than quietly throwing the edit away.
            refusals += 1
            return
        }
        editingTab = nil
        tabOffers = []
        tabPicked = nil
        tab.go(to: typedAddress(url, picked: nil, typed: tabDraft))
    }

    func cancelTabEdit() {
        if editingTab != nil { editingTab = nil }
        if renamingTab { renamingTab = false }
        if !tabDraft.isEmpty { tabDraft = "" }
        if !tabOffers.isEmpty { tabOffers = [] }
        if tabPicked != nil { tabPicked = nil }
    }

    /// A click somewhere else — the page, the column below, the rest of the
    /// strip — while a tab's address or name is being edited in the tab: what
    /// was typed is kept, as Return keeps it. An address left as it was loads
    /// nothing again, and a field left empty is let go.
    func finishTabEdit() {
        guard let id = editingTab, let tab = tabs.first(where: { $0.id == id }) else { return }
        if renamingTab {
            commitTabEdit()
            return
        }
        let draft = tabDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.isEmpty || tab.address.map({ Address.editable($0) == draft }) == true
            || destination(for: draft) == nil {
            cancelTabEdit()
            return
        }
        commitTabEdit()
    }

    // MARK: - saying so

    /// A line that rises from the bottom, says one thing, and leaves.
    private(set) var announcement: String?
    /// The file a "Saved …" line is about: clicked, the line shows it in
    /// the Finder, and it stays long enough to be clicked.
    private(set) var announcedFile: URL?
    private(set) var announcedUndo: (@MainActor () -> Void)?
    var linkNotice: LinkNotice?
    @ObservationIgnored var linkNoticeHush: NoticeClock?
    var newTabs: NewTabsNotice?
    @ObservationIgnored var newTabsHush: NoticeClock?
    @ObservationIgnored var newTabsWatch: AnyCancellable?
    @ObservationIgnored var quietOpens: Set<Tab.ID> = []
    /// Downloads while they happen (see Fetching.swift).
    let fetches = Shared.fetches
    @ObservationIgnored lazy var mini = MiniPlayer(self)
    @ObservationIgnored lazy var hints = HintWatch(self)
    @ObservationIgnored var floatMiss: FloatMiss?

    /// ⌘⇧C. The address, in the clipboard, and a line that says as much.
    func copyAddress() {
        copyLinks(.address)
        active?.kicks.copy += 1
    }

    /// ⌥⇧⌘C. The address without its tracking parameters (CleanLink).
    func copyCleanLink() {
        copyLinks(.clean)
    }

    /// For pasting into notes and messages that read Markdown: a title that
    /// links, not a bare address to explain in your own words.
    func copyMarkdownLink() {
        copyLinks(.markdown)
    }

    static func markdownLink(_ title: String, _ url: URL) -> String {
        LinkCopy.markdown(title, url)
    }

    func announce(_ text: String, file: URL? = nil, undo: (@MainActor () -> Void)? = nil, kind: NoticeKind? = nil, seconds: TimeInterval? = nil) {
        announcement = text
        announcedFile = file
        announcedUndo = undo
        let kind = kind ?? (file == nil && undo == nil ? .note : .action)
        let view = hush?.view
        hush?.cancel()
        let clock = NoticeClock(kind, window: { [weak self] in self?.window }, seconds: seconds) { [weak self] in
            self?.announcement = nil
            self?.announcedFile = nil
            self?.announcedUndo = nil
        }
        clock.view = view
        hush = clock
    }

    var announcedKind: NoticeKind? { announcement == nil ? nil : hush?.kind }

    func dismissAnnounced() {
        hush?.cancel()
        announcement = nil
        announcedFile = nil
        announcedUndo = nil
    }

    func undoAnnounced() {
        guard let undo = announcedUndo else { return }
        hush?.cancel()
        announcement = nil
        announcedFile = nil
        announcedUndo = nil
        undo()
    }

    /// The names extensions asked their downloads to be saved under.
    @ObservationIgnored var namedDownloads: [URL: String] = [:]

    /// Tabs you closed, newest last, so ⌘⇧T can put them back where they were
    /// and the History menu can offer them by name.
    private(set) var ghosts: [Ghost] = []

    /// Groups closed with Close Group, kept while a tab they held can still
    /// come back with ⌘⇧T: the first one back brings its group back too,
    /// named as it was and where it was among the others.
    @ObservationIgnored private var closedGroups: [UUID: (group: TabGroup, at: Int, left: [Tab.ID])] = [:]
    @ObservationIgnored private var loneHolds = 0
    @ObservationIgnored private var lonesWaiting: Set<UUID> = []

    enum CloseKind {
        case group, tabs
    }

    struct Ghost: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let title: String
        let index: Int
        let groupID: UUID?
        /// When it was closed, to weigh against a window closed since.
        var at = Date()
        /// The other page of the pair it was in, and whether it was on that
        /// page's left: ⇧⌘T puts it back beside it, while that page is alone.
        var partner: Tab.ID? = nil
        var onLeft = false
        /// The tab it was, so a pair closed together finds its other half
        /// again when both come back (see reopen(batch:)).
        var was: Tab.ID? = nil
        /// The bulk close it went with: one ⇧⌘T brings back the whole of it.
        var batch: UUID? = nil
        var kind: CloseKind = .tabs
        /// The tab you were on, which comes back in front.
        var front = false
        /// Silenced by hand when it closed, so it comes back the same way.
        var muted = false
        var split: TabSplit? = nil
        var live: LiveDismissal? = nil

        var label: String { title.isEmpty ? Address.pretty(url) : title }
    }

    /// The bulk close under way, whose tabs are remembered
    /// together (see closingTogether).
    @ObservationIgnored private var batching: (id: UUID, kind: CloseKind)?
    @ObservationIgnored private var offeredBatch: UUID?
    var closingNow: Bool { batching != nil }
    @ObservationIgnored var undoSteps: [UndoStep] = []
    @ObservationIgnored var undoScope: UndoScope?
    @ObservationIgnored var undoQuiet = 0
    @ObservationIgnored var cameBackAs: [Tab.ID: Tab.ID] = [:]

    @ObservationIgnored private var bag = Set<AnyCancellable>()
    @ObservationIgnored private var liveWatchers: [AnyObject] = []
    /// The minute-by-minute look for tabs to put to sleep, and the ear for
    /// macOS saying memory is short. See Sleep.swift.
    @ObservationIgnored var dozing: Timer?
    @ObservationIgnored var pressure: DispatchSourceMemoryPressure?
    @ObservationIgnored var squeezed = false
    /// Downloads still under way. See `keep(_:)`.
    @ObservationIgnored var downloading: [WKDownload] = []
    @ObservationIgnored var speculating: [ObjectIdentifier: Speculation] = [:]
    /// alert(), confirm() and prompt() from tabs that weren't in front,
    /// waiting for them to be (see Dialogs.swift).
    @ObservationIgnored var heldDialogs: [Tab.ID: [HeldQuestion]] = [:]
    /// Questions asked by a page of the pair on screen, each drawn over its
    /// own page, oldest first (see Dialogs.swift).
    var paneQuestions: [PaneQuestion] = []
    /// What handOff decided, in a test run, for the bench.
    static var handedOff: [String] = []
    /// Downloads from private tabs, which the Downloads list never shows.
    @ObservationIgnored var unlisted: Set<ObjectIdentifier> = []
    /// The Chrome Web Store's pages, told when installs come and go. See StoreRelay.swift.
    @ObservationIgnored var storeWatch: AnyCancellable?
    @ObservationIgnored private(set) var hush: NoticeClock?
    @ObservationIgnored private var zoomShown = 100
    @ObservationIgnored private var remembering = false
    /// Spaces (see Spaces.swift): every one, the one on screen, and the
    /// rows of tabs of the others.
    var spaces: [Space]
    var spaceID = Space.firstID
    var parked: [UUID: Parked] = [:]
    /// How far the column's rows have followed two fingers sideways, and
    /// whether the card for a new space stands in for them (see SpaceSwipe).
    let spaceMotion = SpaceMotion()
    let columnMemory = ColumnMemory()
    let spacePictures = SpacePictures()
    let spaceNeighbour = SpaceNeighbour()
    let spacePages = SpacePages()
    var spaceNext: Int? {
        get { spaceNeighbour.index }
        set {
            guard spaceNeighbour.index != newValue else { return }
            if makingSpace || newValue == spaces.count || spaceNeighbour.index == spaces.count { revision &+= 1 }
            spaceMotion.alone = newValue == nil
            spaceNeighbour.index = newValue
        }
    }
    var spaceShown: Int? {
        get { spaceNeighbour.shown }
        set {
            guard spaceNeighbour.shown != newValue else { return }
            spaceNeighbour.shown = newValue
        }
    }
    var makingSpace = false
    var spaceDraftIcon: TabIcon?
    let spaceDraftName = SpaceDraftName()
    let spaceAsk = NewSpaceAsk()
    /// A tab being sent into the Space being made from its context menu.
    @ObservationIgnored var afterSpaceCreated: ((Space) -> Void)?
    /// A link's page, peeked at over this one (see Peek.swift).
    var peekTab: Tab?
    /// The tab the peek was opened from: a pin wears the peek's icon while
    /// it is up (see PeekBadge).
    var peekFrom: UUID?
    /// Which way the last change of space went: 1 to the next, -1 back.
    @ObservationIgnored var spaceStep = 1
    var stackedScroll = StackedScroll()

    // MARK: - beginning and ending

    /// In SwiftUI's own window rather than one made for it (see Windows.swift).
    @ObservationIgnored var inScene = false
    /// Its window, once it has one.
    @ObservationIgnored weak var window: NSWindow? {
        didSet { if window != nil { shut = false } }
    }
    /// Its window closed and kept: the last one, closed with the app running.
    /// Its tabs sleep meanwhile (see sleepShut); back, the ones it shows wake.
    @ObservationIgnored var shut = false {
        didSet { if oldValue, !shut { wakeShown() } }
    }
    /// Its window is there to be seen — on screen, or behind a hidden app.
    var isOpen: Bool { window != nil && !shut }
    /// Its window fills the screen. macOS takes the window's buttons away
    /// then, so the room kept for them at the top goes too (idea 184).
    var fullScreen = false
    /// The page as a card on the window's ground, the one switch for it
    /// (see CardEdge): with the tabs down the side, unless Settings › Tabs ›
    /// The page as a card is off, and never with the window filling the
    /// screen, where the page goes edge to edge (#607). A page's own video
    /// filling the screen is the window's to add (see ContentView.cards).
    var asCards: Bool { prefs.cards && !fullScreen }
    /// The extension a popup window was opened for (windows.create with
    /// type "popup"), or nil for a browser window. Such a window is small,
    /// the page under a thin line with its site; it is never saved, never
    /// brought back, and never the window menus act on (see Windows.swift).
    @ObservationIgnored var extensionPopup: String?
    var isPopup: Bool { extensionPopup != nil }
    let privateStore: WKWebsiteDataStore?
    var isPrivate: Bool { privateStore != nil }
    var keepsNothing: Bool { isPopup || isPrivate || era != Browser.era }

    private(set) static var era = 0
    private let era = Browser.era

    static func nextEra() {
        precondition(Store.unitTests)
        era += 1
    }
    /// Its saved state, for a window other than the oldest (see Windows.swift).
    @ObservationIgnored var record = WindowRecord()
    /// Whether its rows are the session files' — the oldest window's — or
    /// its own line in windows.json.
    @ObservationIgnored private(set) var usesFiles = false
    /// The first browser does what is done once for the app.
    private static var booted = false

    var commandHeld = false

    /// Another app in front: the video comes along, as in Arc (Settings ›
    /// General). Only one lifted this way goes home on its own when Search
    /// comes back.
    @ObservationIgnored private var liftedAway = false
    @ObservationIgnored private var outOfSight = false
    @ObservationIgnored private var sightLook: DispatchWorkItem?
    @ObservationIgnored var sightForBench: Bool?
    @ObservationIgnored private(set) var sightJudged: [String: Any] = [:]

    /// The tab whose video Search last sent to macOS's picture in picture
    /// (Settings › General › The floating video), to bring back when you
    /// return to it, as Search's own window lands.
    @ObservationIgnored private(set) var pictured: Tab.ID?

    @ObservationIgnored private var leftAs: (tab: Tab.ID, picture: NSImage)?
    @ObservationIgnored private var floatPicture: CGRect?
    @ObservationIgnored private var floatFrame: WKFrameInfo?

    /// The tab covered now, and with what, until its page has settled.
    @ObservationIgnored private var landed: (tab: Tab.ID, picture: NSImage)?
    private let landing = Settling()

    let snippetField = SnippetField()

    /// Asks the engine for the words it would suggest, when Settings ›
    /// General › Suggestions from your search engine is on and these words
    /// may leave the Mac (EngineSuggest.sendable). What it said for the
    /// words before stays, those that still fit, until it answers these:
    /// rows that came and went with every key would be a list nobody could
    /// read.
    let suggester = EngineSuggester()
    /// The engine's last words, and what they answered.
    @ObservationIgnored private var engineWords: (asked: String, words: [String]) = ("", [])

    /// The first window: yesterday's tabs, from the session files.
    override convenience init() { self.init(record: nil) }

    /// `record`: another window's, from windows.json or ⇧⌘T, or a new
    /// window's, empty.
    init(record: WindowRecord?, privateStore: WKWebsiteDataStore? = nil) {
        let shown = record?.space ?? Store.settings.string(forKey: "space.current").flatMap(UUID.init) ?? Space.firstID
        let loaded = Spaces.read()
        spaces = loaded
        spaceID = prefs.usesSpaces && privateStore == nil ? loaded.first?.id ?? Space.firstID : Space.firstID
        self.privateStore = privateStore
        super.init()
        let first = !Browser.booted
        Browser.booted = true
        usesFiles = privateStore == nil && (record == nil || !Browsers.all.contains { $0.usesFiles && !$0.keepsNothing })
        history.placeOldVisits(for: self)
        if first {
            Shield.shared.enabled = prefs.shielded
            Shield.shared.compile()
            LocalNetworkGuard.shared.enabled = prefs.asksLocalNetwork
            LocalNetworkGuard.shared.compile()
            Extensions.shared.start(for: self)
            AgentSocket.shared.start(for: self)
            Knowledge.start(for: self)
            if prefs.bench {
                Bench.shared.start(for: self)
            } else if prefs.benchRefused {
                announce("“Let a script drive Broadway” can only be turned on in Settings")
            }
            FormRelay.passkeysOffered = prefs.passkeys
            // An icon that arrives is looked for again by every tab showing
            // that site, in every window, not only the one that asked for it:
            // each puts on its own page's, or its nearest neighbour's.
            Favicons.shared.arrived = { site in
                let lower = site.lowercased()
                for browser in Browsers.all {
                    for tab in browser.tabs + browser.parkedTabs {
                        guard let tabHost = tab.address.flatMap(Favicons.site) else { continue }
                        if tabHost == lower || tabHost == "www." + lower || lower == "www." + tabHost {
                            tab.adoptIcon()
                        }
                    }
                }
            }
            // What a deleted space left behind, if WebKit wouldn't let it go then.
            Spaces.sweep()
        }
        // Asked to stay out of the way: it starts that way (see Fold.swift).
        folded = prefs.sideHides

        // A page's passkeys for under its field, arriving while the caret
        // is already there, or going with the page's request.
        NotificationCenter.default.publisher(for: Passkeys.offeredChanged)
            .sink { [weak self] note in
                guard let self, let web = note.object as? WKWebView, let field, let tab = tab(for: web),
                      tab.id == field.tab
                else { return }
                looked = nil
                hang(from: tab, field.spot, passwords: field.passwords, name: field.name)
            }
            .store(in: &bag)

        // So are the pins.
        NotificationCenter.default.publisher(for: Pins.changed)
            .sink { [weak self] note in
                guard let self, !keepsNothing, (note.object as? Browser) !== self else { return }
                if note.userInfo?["shared"] as? Bool == true {
                    return sharedPinsChanged()
                }
                guard let space = note.userInfo?["space"] as? UUID else { return }
                pinsChanged(in: space)
            }
            .store(in: &bag)

        // The spaces are every window's: one renamed, added or taken away in
        // another window is so here too.
        NotificationCenter.default.publisher(for: Spaces.changed)
            .sink { [weak self] note in
                guard let self, let all = note.object as? [Space] else { return }
                guard !keepsNothing else { return }
                let list = Spaces.read()
                guard list != spaces, !list.isEmpty, all.contains(where: { $0.id == list[0].id }) else { return }
                spaces = list
                if !list.contains(where: { $0.id == self.spaceID }) { enter(list[0].id) }
            }
            .store(in: &bag)

        // Yesterday's tabs, or one empty one. Either way a web view is built
        // now, which starts a content process while the window is still being
        // drawn — so the first address you type navigates instead of waiting
        // for WebKit to get up.
        defer {
            follow()
            if !isPopup { watchForSleep() }
            // Before the first frame: tabs whose time ran out while Search
            // was quit are gone, rather than drawn and taken away a minute on.
            if !isPopup { closeLeftAlone() }
        }

        if isPrivate {
            frontBlank()
            return
        }
        if let record {
            // Another window: the space it showed, and its own rows.
            self.record = record
            if prefs.usesSpaces, spaces.contains(where: { $0.id == record.space }) { spaceID = record.space }
            if usesFiles {
                for (key, row) in record.rows {
                    guard let space = UUID(uuidString: key), spaces.contains(where: { $0.id == space }) else { continue }
                    Session.write(now: true, space: space, row)
                }
                self.record.rows = [:]
            }
        } else if prefs.usesSpaces, spaces.contains(where: { $0.id == shown }) {
            // The space you were in, when there are spaces (see Spaces.swift).
            spaceID = shown
        }
        if record == nil { Spaces.current = spaceID }
        restoreSession()
        for watcher in watchLiveFolders() { liveWatchers.append(watcher) }
        if showsSpaces { preloadSpaces() }
    }
}

extension Browser {
    /// The floating video's buttons answer the window whose video it is:
    /// set as it comes out of one (see lift).
    var floatingTab: Tab? {
        floating.flatMap { id in (tabs + parkedTabs).first { $0.id == id } }
    }

    private func ownFloater() {
        floater.onReturn = { [weak self] in
            guard let self else { return }
            // The window closes first, and unconditionally. Hanging that on
            // finding the tab again is how a little window survives the button
            // meant to dismiss it.
            let came = self.floatingTab
            self.land()
            if let came {
                if let space = self.space(holding: came.id) { self.enter(space) }
                if let tab = self.tabs.first(where: { $0.id == came.id }) { self.select(tab) }
            }
            // Never a test run's: a probe started hidden stays off every screen.
            guard !Store.testing else { return }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.contentView != nil }?.makeKeyAndOrderFront(nil)
        }
        floater.onSkip = { [weak self] seconds in
            guard let self, let tab = self.floatingTab
            else { return }
            self.inFloat(tab, Isolate.skip(seconds))
        }
        floater.onProgress = { [weak self] answer in
            guard let self, let tab = self.floatingTab
            else { return }
            self.inFloat(tab, Isolate.media) { found in
                answer(FloatMediaState(found as? [String: Any] ?? [:]))
            }
        }
        floater.onSeek = { [weak self] fraction in
            guard let self, let tab = self.floatingTab
            else { return }
            self.inFloat(tab, Isolate.seek(fraction))
        }
        floater.onRate = { [weak self] rate, answer in
            guard let self, let tab = self.floatingTab
            else { answer(nil); return }
            self.inFloat(tab, VideoSpeed.said, search: true)
            self.inFloat(tab, Isolate.rate(rate)) { value in answer(value as? Double) }
        }
        floater.onCaptions = { [weak self] choice in
            guard let self, let tab = self.floatingTab else { return }
            self.inFloat(tab, Isolate.captions(choice))
        }
        floater.onMute = { [weak self] in
            guard let self, let tab = self.floatingTab else { return }
            self.inFloat(tab, Isolate.mute, search: true)
        }
        floater.home = { [weak self] in self?.floatHome() }
        floater.onPlayPause = { [weak self] answer in
            guard let self, let tab = self.floatingTab
            else { return }
            self.inFloat(tab, Isolate.toggle, search: true) { playing in answer((playing as? Bool) ?? true) }
        }
        floater.onClose = { [weak self] in self?.land() }
    }

    /// The row of tabs the space on screen had last time, or one empty tab.
    /// The pins are every window's (see Pins.swift): a window new to this
    /// space has them too, before an empty tab.
    func restoreSession() {
        let saved = readRow(spaceID)
        tabGroups = FolderTree.lasting(saved.groups ?? [], holding: Set(saved.tabs.compactMap(\.groupID)))
        let restored = restoreRow(saved, space: spaceID, groups: tabGroups)
        splits = restored.splits
        tabs += restored.tabs
        dissolveLoneFolders()
        // No tab in front (a fresh start, see Session.startFresh): an empty
        // one beside the pins.
        let front = saved.tabs.isEmpty || saved.active < 0 ? nil
            : restored.active.flatMap { id in tabs.first { $0.id == id } } ?? tabs.first { $0.pin == nil } ?? tabs.first
        guard let first = front else {
            frontBlank()
            return
        }
        activeID = first.id
        // Only the one you were looking at actually loads. Started hidden,
        // it waits for the extensions, which load at once then, so that
        // their scripts meant to run before the page's do (#199); a
        // visible launch keeps loading it alongside the first frame.
        if NSApp.isHidden, Extensions.shared.starting {
            Extensions.shared.whenStarted(within: 1.5) { [weak self] in
                guard let self else { return }
                for tab in self.tabs where self.visibleTabIDs.contains(tab.id) { _ = tab.wake() }
            }
        } else {
            for tab in tabs where visibleTabIDs.contains(tab.id) { _ = tab.wake() }
        }
    }

    /// An empty tab at the end of the row, in front: a row with nothing in
    /// front (a fresh start, see Session.startFresh) opens on one, beside its
    /// pins, rather than on the first of them.
    func frontBlank() {
        // A blank tab costs nothing until it is asked for its page. Its
        // web view — and with it WebKit's helper processes — is built a
        // moment after the window is up, so that the first address typed
        // finds everything already running, and the first frame never
        // had to share the CPU with it.
        let tab = makeTab()
        adopt(tab)
        activeID = tab.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak tab] in
            guard let tab, tab.isBlank else { return }
            _ = tab.web
        }
    }

    /// The few settings that something else has to be told about. The rest are
    /// read where they are used.
    private func follow() {
        followStore()
        // Spaces turned off: back to the first, whose tabs are the ones there
        // were before (see Spaces.swift).
        prefs.onSet(\.usesSpaces) { [weak self] on in
                guard let self else { return }
                guard !keepsNothing else { return }
                if on { preloadSpaces() } else { leaveSpaces() }
            }
            .store(in: &bag)
        // Pins in every space, or Spaces, switched: every row takes the
        // shared pins or lets them go. Received on the next turn of the run
        // loop, once the setting has changed, so the rows are built from
        // what it is now.
        kitObserve(initial: false, { [prefs] in (prefs.sharesPins, prefs.usesSpaces) }) { [weak self] _ in self?.sharedPinsChanged() }
            .store(in: &bag)
        prefs.onSet(\.usesTabGroups) { [weak self] on in
                guard let self, on else { return }
                // Sent before the setting changes, so it is passed on.
                arrangeGroupedTabs(on)
                writeSession(now: true)
            }
            .store(in: &bag)
        prefs.onSet(\.splitView) { [weak self] on in
                // Off, the pairs stay, as groups do; back on, the ones that
                // came apart meanwhile go. The others' files are looked at
                // when their spaces come back (see restoreRow).
                guard let self else { return }
                // Off, no page is drawn over on its own: what a page asked
                // is answered as dismissed rather than left unanswered.
                guard on else { return dropQuestions() }
                splits = splits.filter { Browser.holds($0, in: self.tabs) }
                for key in parked.keys {
                    if let row = parked[key] { parked[key]?.splits = row.splits.filter { Browser.holds($0, in: row.tabs) } }
                }
                writeSession(now: true)
            }
            .store(in: &bag)
        prefs.onSet(\.asksLocalNetwork) { on in
                LocalNetworkGuard.shared.enabled = on
                LocalNetworkGuard.shared.refitAll()
            }
            .store(in: &bag)
        prefs.onSet(\.shielded) { [weak self] on in
                guard let self else { return }
                Shield.shared.enabled = on
                Shield.shared.applyEverywhere()
                announce(on ? "Ads, trackers and cookie notices blocked" : "Blocking is off. Reload to see the difference.")
            }
            .store(in: &bag)

        // The look changes — from Settings, or from the Mac while set to
        // System — and the icons a site keeps for each scheme change with it.
        // A beat after, so the appearance has actually turned over.
        prefs.onSet(\.look) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)
        DistributedNotificationCenter.default().publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard self?.prefs.look == .system else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.relook() }
            }
            .store(in: &bag)

        prefs.onSet(\.bench) { [weak self] on in
                guard let self else { return }
                if on { Bench.shared.start(for: self) } else { Bench.shared.stop() }
                announce(on ? "Scripts can drive Broadway" : "Scripts can no longer drive Broadway")
            }
            .store(in: &bag)

        // Every tab's next page, and the page each is showing now (see AutoScroll.swift).
        prefs.onSet(\.autoScroll) { [weak self] on in
                guard let self else { return }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateInSearch(on ? AutoScroll.script : AutoScroll.off)
                }
            }
            .store(in: &bag)

        prefs.onSet(\.videoKeys) { [weak self] on in
                guard let self else { return }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateInSearch(on ? Tempo.script : Tempo.off)
                }
                if on { DispatchQueue.main.async { [weak self] in Extensions.shared.handOffTempo(in: self) } }
            }
            .store(in: &bag)

        // Dark pages (see Dusk.swift), turned on or off, paused, or switched
        // for a site: every tab's next page, and the page each is showing now.
        kitObserve(initial: false, { Dusk.shared.revision }) { [weak self] _ in
                // Published before it is set; the pages read the set one.
                DispatchQueue.main.async { self?.redusk() }
            }
            .store(in: &bag)
        // Every tab's next page, and the page each is showing now.
        prefs.onSet(\.showsLinks) { [weak self] on in
                guard let self else { return }
                if !on { linkStatus.dismiss() }
                for tab in tabs + parkedTabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                    tab.built?.evaluateJavaScript(on ? HoveredLink.script : HoveredLink.off, in: nil, in: .defaultClient)
                }
            }
            .store(in: &bag)

        // Every open page that hasn't a size of its own takes the new one.
        // Asleep, a tab has no page to resize; it takes it on waking.
        prefs.onSet(\.pageZoom) { [weak self] _ in
                // Published before it is stored; the tabs read the stored one.
                DispatchQueue.main.async {
                    guard let self else { return }
                    for tab in self.tabs + self.parkedTabs where tab.built != nil { tab.applyRememberedZoom() }
                }
            }
            .store(in: &bag)

        prefs.onSet(\.passkeys) { [weak self] on in
                guard let self else { return }
                FormRelay.passkeysOffered = on
                // Each tab keeps whatever is hidden on the site it is showing:
                // re-arming with nothing would quietly restore every element
                // this person had taken off, everywhere.
                for tab in tabs {
                    tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
                }
                announce(on ? "Passkeys are offered again. Reload the page." : "Sites will ask for a password instead")
            }
            .store(in: &bag)

        // Videos waiting for a click: every tab's next page view follows.
        prefs.onSet(\.waitsForPlay) { [weak self] _ in
                guard let self else { return }
                DispatchQueue.main.async { for tab in self.tabs + self.parkedTabs { tab.playbackChanged() } }
            }
            .store(in: &bag)

        // WebKit read the defaults once at the start and keeps its own copy.
        // The only way to change its mind while running is the same action
        // the Edit menu would send it, which also writes the default back.
        prefs.onSet(\.autocorrect) { [weak self] on in
                guard let self, let web = active?.built else { return }
                let selector = NSSelectorFromString("toggleAutomaticSpellingCorrection:")
                guard web.responds(to: selector) else { return }
                // Toggling is all there is, so it is only sent when the two
                // actually disagree.
                if UserDefaults.standard.bool(forKey: "WebAutomaticSpellingCorrectionEnabled") != on {
                    web.perform(selector, with: nil)
                }
                Preferences.tellWebKit(autocorrect: on)
                announce(on ? "Autocorrect on" : "Autocorrect off")
            }
            .store(in: &bag)
    }

    /// Edit › Substitutions: whether one is on in pages. WebKit keeps a
    /// single answer for every page, so the tab in front's view speaks for
    /// all of them.
    func substitutes(_ kind: Substitution) -> Bool {
        kind.isOn(in: active?.built)
    }

    /// Edit › Substitutions: one switched for every page. Sent to the page's
    /// view rather than to whatever has the keyboard, so the address field
    /// having the caret doesn't make it switch only that field.
    func toggleSubstitution(_ kind: Substitution, in web: WKWebView? = nil) {
        kind.toggle(in: web ?? active?.built ?? (tabs + parkedTabs).lazy.compactMap(\.built).first)
        revision &+= 1
    }

    private func relook() {
        Favicons.shared.relook(tabs.filter { !$0.asleep })
        // Dark pages are only ever put into a page while Search is dark: a
        // change of look takes them in, or lets them go.
        redusk()
    }

    func writeSession(now: Bool = false) {
        guard !keepsNothing else { return }
        // The pins as they are here, for the other windows (see Pins.swift):
        // the space's own, and the ones every space shows (only from a row
        // that holds them: see Pins.sharedToWrite).
        if prefs.showsSharedPins { keepBlocks() }
        let defs = pinDefs(tabs)
        let everywhere = Set(tabs.filter(\.everywhere).compactMap(\.pinID))
        let parts = Pins.split(defs, shared: everywhere)
        Pins.set(spaceID, parts.own, from: self)
        if let shared = Pins.sharedToWrite(parts.shared, showing: prefs.showsSharedPins),
           Pins.setShared(shared, from: self) {
            for space in Array(parked.keys) { pinsChanged(in: space) }
        }
        writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups, splits: splits), now: now)
    }

    // MARK: - pins, the same in every window

    /// What makes this row's pinned tabs pins, in their order.
    private func pinDefs(_ row: [Tab]) -> [PinDef] {
        row.compactMap { tab -> PinDef? in
            guard let letter = tab.pin, !tab.shy else { return nil }
            if tab.pinID == nil { tab.pinID = UUID() }
            return PinDef(id: tab.pinID ?? UUID(), letter: letter,
                          home: (tab.home ?? tab.pending ?? tab.address)?.absoluteString ?? "",
                          title: tab.savedTitle, name: tab.name, icon: tab.customIcon, split: pinSplitDef(for: tab))
        }
    }

    /// A row with the space's pins as they are now: this window's own tab
    /// for each, relettered and in order, one made asleep at its page for a
    /// pin new to this window, and the tab of a pin taken away closed. A
    /// pinned tab from before pins had ids is matched by letter and page,
    /// then by place.
    func reconcilePins(_ row: [Tab], space: UUID) -> [Tab] {
        let showing = prefs.showsSharedPins
        let shared = showing ? Pins.shared() : []
        let sharedIDs = Set(shared.map(\.id))
        let defs = Pins.row(own: Pins.defs(space), shared: shared, showing: showing)
        var pinned = row.filter { $0.pin != nil && !$0.shy }
        let loose = row.filter { $0.pin == nil || $0.shy }
        var out: [Tab] = []
        for def in defs {
            let found = pinned.first { $0.pinID == def.id }
                ?? pinned.first { $0.pinID == nil && $0.pin == def.letter && ($0.home?.absoluteString ?? "") == def.home }
                ?? pinned.first { $0.pinID == nil }
            let tab: Tab
            if let found {
                pinned.removeAll { $0 === found }
                tab = found
            } else {
                tab = makeTab(space: space)
                prepare(tab)
                tab.restore(url: URL(string: def.home) ?? URL(string: "about:blank")!, title: def.title, name: def.name)
            }
            tab.pinID = def.id
            tab.everywhere = sharedIDs.contains(def.id)
            if tab.pin != def.letter { tab.pin = def.letter }
            if tab.name != def.name { tab.name = def.name }
            if tab.customIcon != def.icon { tab.customIcon = def.icon }
            tab.home = URL(string: def.home)
            out.append(tab)
        }
        for gone in pinned { gone.close() }
        // In the order they were written, which already holds it; a file
        // put together by hand, or an import, may not.
        return out + loose
    }

    /// Another window changed a space's pins: this window's row there follows.
    func pinsChanged(in space: UUID) {
        guard !keepsNothing else { return }
        if space == spaceID {
            // Drawn again even when only a pin's letter or name changed.
            revision &+= 1
            let row = reconcilePins(tabs, space: space)
            if row.map(\.id) != tabs.map(\.id) { tabs = row }
            if !tabs.contains(where: { $0.id == activeID }) {
                activeID = tabs.first { $0.pin == nil }?.id ?? tabs.first?.id
                if activeID == nil { newTab() }
            }
            splits.removeAll { pair in
                !pair.tabs.allSatisfy { id in tabs.contains { $0.id == id } }
            }
            splits = pinSplits(tabs, keeping: splits, space: space)
            writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups, splits: splits), now: false)
        } else if var row = parked[space] {
            row.tabs = reconcilePins(row.tabs, space: space)
            row.splits.removeAll { pair in
                !pair.tabs.allSatisfy { id in row.tabs.contains { $0.id == id } }
            }
            row.splits = pinSplits(row.tabs, keeping: row.splits, space: space)
            if let active = row.active, !row.tabs.contains(where: { $0.id == active }) {
                row.active = row.tabs.first { $0.pin == nil }?.id ?? row.tabs.first?.id
            }
            parked[space] = row
        }
    }

    private func keepBlocks() {
        let pinned = tabs.filter { $0.pin != nil && !$0.shy }
        let loose = tabs.filter { $0.pin == nil || $0.shy }
        let blocked = pinned.filter(\.everywhere) + pinned.filter { !$0.everywhere }
        if !blocked.elementsEqual(pinned, by: { $0.id == $1.id }) { tabs = blocked + loose }
    }

    /// The shared pins changed, here or in another window: every row this
    /// window holds follows, the one on screen and every space parked.
    func sharedPinsChanged() {
        for space in Array(parked.keys) { pinsChanged(in: space) }
        pinsChanged(in: spaceID)
    }

    /// Pin menu › Keep in Every Space: this space's pin, shown by every
    /// space from now on, after the shared ones. This tab stays as it is;
    /// the other spaces make theirs, asleep at the pin's page.
    func shareEverywhere(_ tab: Tab) {
        guard prefs.showsSharedPins, tab.pin != nil, !tab.everywhere, !tab.shy else { return }
        writeSession(now: true)
        guard let id = tab.pinID else { return }
        let moved = Pins.share(id, own: Pins.defs(spaceID), shared: Pins.shared())
        // The shared list first: in between, the pin is in both lists, which
        // Pins.row counts once, so every other window keeps its tab for it.
        // The other way round it was in neither, and they closed theirs.
        Pins.setShared(moved.shared, from: self)
        Pins.set(spaceID, moved.own, from: self)
        sharedPinsChanged()
        writeSession(now: true)
    }

    /// Pin menu › Only in This Space: a shared pin kept by this space alone,
    /// first among its own. The other spaces close theirs.
    func keepHere(_ tab: Tab) {
        guard tab.everywhere, let id = tab.pinID else { return }
        let moved = Pins.unshare(id, own: Pins.defs(spaceID), shared: Pins.shared())
        Pins.set(spaceID, moved.own, from: self)
        Pins.setShared(moved.shared, from: self)
        sharedPinsChanged()
        writeSession(now: true)
    }

    @discardableResult
    func takeArc(_ sidebar: ArcSidebar, routing: ArcRouting? = nil, links: LinkRules? = nil,
                 from source: ImportSource? = nil, profile: String? = nil)
        -> (spaces: Int, pins: Int, tabs: Int, rules: Int, leftOut: Int) {
        var made = 0, pins = 0, added = 0
        // Every address this brings in, for its icon below.
        var brought: [URL] = []
        var targets: [(id: UUID, space: ArcSidebar.Space?)] = []
        if sidebar.spaces.count > 1 || (prefs.usesSpaces && !sidebar.spaces.isEmpty) {
            if !prefs.usesSpaces { prefs.usesSpaces = true }
            var all = Spaces.read()
            for arc in sidebar.spaces {
                if let same = all.first(where: { $0.name.localizedCaseInsensitiveCompare(arc.name) == .orderedSame }) {
                    targets.append((same.id, arc))
                } else {
                    let icon = arc.emoji.flatMap { $0.isEmpty ? nil : TabIcon(emoji: $0) }
                        ?? TabIcon(symbol: Arc.known(emoji: arc.emoji, name: arc.name) ?? Spaces.leastWorn(in: all))
                    let look = arc.colours.isEmpty ? nil : SpaceLook(colours: arc.colours, intensity: SpaceLook.bold)
                    let space = Space(id: UUID(), name: arc.name, colour: 0, icon: icon, look: look, sharesSignIns: true)
                    all.append(space)
                    targets.append((space.id, arc))
                    made += 1
                }
            }
            if all.count != Spaces.read().count {
                Spaces.write(all)
                spaces = Spaces.read()
            }
        } else {
            targets = [(spaceID, sidebar.spaces.first)]
        }
        for target in targets {
            var defs = Pins.defs(target.id)
            // The pins this space had before any of this, for telling a
            // favourite that is already here from one this import is adding.
            let had = defs
            // A space's own profile's favourites, as Arc shows them above it.
            let favourites = target.space.flatMap { sidebar.favoritesByProfile[$0.profile] } ?? sidebar.favorites
            // A favourite whose site is already pinned is the pin you have,
            // however far it has gone from the address it was pinned at: Gmail
            // pinned at mail.google.com answers at mail.google.com/mail/u/0/,
            // and comparing the two as strings brought it in a second time.
            // Only against the pins that were already here: two favourites of
            // Arc's own on one site are two favourites, and stay two.
            for favourite in favourites where !had.contains(where: { Browser.samePin($0, favourite.url) })
                && !defs.contains(where: { $0.home == favourite.url.absoluteString }) {
                let host = favourite.url.host()?.replacingOccurrences(of: "www.", with: "") ?? ""
                defs.append(PinDef(id: UUID(), letter: host.first.map { String($0).uppercased() } ?? "•",
                                   home: favourite.url.absoluteString, title: favourite.title, name: nil))
                pins += 1
                brought.append(favourite.url)
            }
            let pinned = Browser.opened(target.space?.pinned ?? [])
            brought += pinned.map(\.item.url)
            Pins.set(target.id, defs, from: self)
            pinsChanged(in: target.id)
            added += takeAsleep(pinned, into: target.id)
        }
        adoptIcons(for: brought, from: source, profile: profile)
        var rules = 0, leftOut = 0
        if let routing {
            let links = links ?? LinkRules.shared
            var ids: [String: UUID] = [:]
            for target in targets where prefs.usesSpaces {
                if let id = target.space?.id, ids[id] == nil { ids[id] = target.id }
            }
            let found = Arc.linkRules(routing, spaces: ids, have: links.rules)
            for rule in found.rules { links.add(rule) }
            rules = found.rules.count
            leftOut = found.leftOut
        }
        return (made, pins, added, rules, leftOut)
    }

    /// The icons for what Arc's side of the import brought in, from Arc's own
    /// cache, as the bookmarks take theirs (see takeBookmarks). A pin and a
    /// tab read the icon cache as they are made, and these were made a moment
    /// ago, when nothing had been put there for them yet: without this every
    /// one of them wears a letter until its page is opened, which is the only
    /// other way an icon arrives (see Favicons.fetch).
    private func adoptIcons(for urls: [URL], from source: ImportSource?, profile: String?) {
        guard let source, !urls.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            let icons = source.icons(profile: profile, for: urls)
            guard !icons.isEmpty else { return }
            Task { @MainActor in
                for (host, data) in icons { await Favicons.shared.adopt(data, for: host) }
                // The ones made before the icons arrived, now that they are here.
                for tab in self.tabs + self.parkedTabs where tab.icon == nil { tab.adoptIcon() }
                self.revision &+= 1
            }
        }
    }

    /// Whether a pin is the one a favourite would make: the same site, and
    /// one address inside the other (mail.google.com and
    /// mail.google.com/mail/u/0/), or failing a site to compare (a file, an
    /// about: page), the same address. github.com/me and github.com/work are
    /// two pins, and stay two. A site is its host without the www. that is
    /// not part of who it is, as a pin's letter already reads it, and its
    /// port: localhost:3000 and localhost:5173 are two sites.
    static func samePin(_ pin: PinDef, _ url: URL) -> Bool {
        guard let home = URL(string: pin.home), let mine = site(of: url), let theirs = site(of: home) else {
            return pin.home == url.absoluteString
        }
        guard mine == theirs else { return false }
        let a = folder(of: url), b = folder(of: home)
        return a.hasPrefix(b) || b.hasPrefix(a)
    }

    private static func site(of url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return url.port.map { "\(name):\($0)" } ?? name
    }

    /// The path, ending in a slash, so that /me is never taken for the start of /media.
    private static func folder(of url: URL) -> String {
        let path = url.path().lowercased()
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// Arc's pinned list, folders opened out in their order, each page with
    /// the top folder it came from: a tab group's name, when groups are on.
    private static func opened(_ nodes: [ArcSidebar.Node], in folder: String? = nil) -> [(item: ArcSidebar.Item, folder: String?)] {
        nodes.flatMap { node -> [(item: ArcSidebar.Item, folder: String?)] in
            switch node {
            case .item(let item): [(item, folder)]
            case .folder(let inner): opened(inner.items, in: folder ?? inner.title)
            }
        }
    }

    /// Pages as tabs at the end of a space's row, asleep: the row on
    /// screen, a parked one, or the one saved for a space not brought up.
    /// With tab groups on, a page from one of Arc's folders goes into the
    /// group of that name in the space, made if there is none; with them
    /// off, the folders stay opened out. Groups are never turned on here.
    private func takeAsleep(_ items: [(item: ArcSidebar.Item, folder: String?)], into space: UUID) -> Int {
        func asleep(_ item: ArcSidebar.Item) -> Tab {
            let tab = makeTab(space: space)
            prepare(tab)
            tab.restore(url: item.url, title: item.title)
            tab.cameBack = true
            return tab
        }
        func fresh(_ have: [String]) -> [(item: ArcSidebar.Item, folder: String?)] {
            var seen = Set(have)
            return items.filter { seen.insert($0.item.url.absoluteString).inserted }
        }
        /// The group a folder's pages go into, by name, made if missing.
        /// Kept whether or not tab groups are turned on, as the session keeps
        /// them (see Session.Shape.groups): a folder Arc had is a name this
        /// import is the only chance to learn, and turning groups on later
        /// finds it waiting rather than gone.
        func group(_ folder: String?, in groups: inout [TabGroup]) -> UUID? {
            guard let folder else { return nil }
            if let same = groups.first(where: { $0.name == folder }) { return same.id }
            let made = TabGroup(id: UUID(), name: folder, collapsed: false)
            groups.append(made)
            return made.id
        }
        if space == spaceID {
            let new = fresh(tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString })
            var groups = tabGroups
            tabs += new.map { page in
                let tab = asleep(page.item)
                tab.groupID = group(page.folder, in: &groups)
                return tab
            }
            if groups != tabGroups {
                tabGroups = groups
                arrangeGroupedTabs()
            }
            writeRow(spaceID, session(tabs, active: activeID, groups: tabGroups, splits: splits), now: true)
            return new.count
        }
        // A parked row's groups are the ones saved for it (see allRows).
        var saved = readRow(space)
        var groups = parked[space]?.groups ?? saved.groups ?? []
        if var row = parked[space] {
            let new = fresh(row.tabs.compactMap { ($0.pending ?? $0.address)?.absoluteString })
            row.tabs += new.map { page in
                let tab = asleep(page.item)
                tab.groupID = group(page.folder, in: &groups)
                return tab
            }
            row.groups = groups
            parked[space] = row
            if groups != (saved.groups ?? []) {
                saved.groups = groups
                writeRow(space, saved, now: true)
            }
            return new.count
        }
        let new = fresh(saved.tabs.map(\.url))
        saved.tabs += new.map { page in
            Session.Entry(url: page.item.url.absoluteString, title: page.item.title,
                          groupID: group(page.folder, in: &groups))
        }
        saved.groups = groups
        writeRow(space, saved, now: true)
        return new.count
    }

    // MARK: - this window's rows, wherever they are kept

    /// A space's row as saved: the session files' for the oldest window,
    /// this window's own record for any other.
    func readRow(_ space: UUID) -> Session.Shape {
        usesFiles ? Session.read(space: space) : (record.rows[space.uuidString] ?? Session.Shape(tabs: [], active: 0))
    }

    func writeRow(_ space: UUID, _ shape: Session.Shape, now: Bool) {
        if usesFiles {
            Session.write(now: now, space: space, shape)
        } else {
            record.rows[space.uuidString] = shape
            if now { Browsers.save(now: true) } else { Browsers.saveSoon() }
        }
    }

    /// Every row this window has, by space: the one on screen, the parked
    /// ones, and those saved but not brought up this time.
    func allRows() -> [String: Session.Shape] {
        var rows: [String: Session.Shape] = [:]
        for space in spaces {
            let saved = readRow(space.id)
            if !saved.tabs.isEmpty { rows[space.id.uuidString] = saved }
        }
        rows[spaceID.uuidString] = session(tabs, active: activeID, groups: tabGroups, splits: splits)
        for (space, row) in parked {
            rows[space.uuidString] = session(row.tabs, active: row.active, groups: row.groups ?? readRow(space).groups, splits: row.splits)
        }
        return rows
    }

    /// The oldest window closed: this one is the oldest now, and its rows go
    /// into the session files, every space's — an empty row where it has
    /// none, or the closed window's would come back there.
    func becomePrimary() {
        guard !isPrivate else { return }
        takeFiles()
        Store.settings.set(spaceID.uuidString, forKey: "space.current")
        // SwiftUI's window, opened next launch, comes back where this one is.
        window?.saveFrame(usingName: Browsers.sceneID)
    }

    func takeFiles() {
        guard !usesFiles, !keepsNothing else { return }
        let rows = allRows()
        usesFiles = true
        for space in spaces {
            Session.write(now: true, space: space.id, rows[space.id.uuidString] ?? Session.Shape(tabs: [], active: 0))
        }
        record.rows = [:]
    }

    func leaveFiles() {
        guard usesFiles else { return }
        flushSession()
        record.rows = allRows()
        usesFiles = false
    }

    /// Its window closed for good, with others open: every page let go.
    func closeAll() {
        fileChoice?.cancel()
        SaveAsk.shared.tabClosed(Set((tabs + parkedTabs).map(\.id)))
        SiteFileAsk.shared.tabClosed(Set((tabs + parkedTabs).map(\.id)))
        privateFileDownloads = []
        cancelDisplay()
        cancelCapture()
        for questions in heldDialogs.values { questions.forEach { $0.dismiss() } }
        heldDialogs = [:]
        dropQuestions()
        if floating != nil { land(covering: false) }
        if peekTab != nil { closePeek() }
        for tab in tabs + parkedTabs { tab.close() }
        Bench.shared.closeEmptyRoom()
        parked = [:]
        splits = []
        tabs = []
    }

    private func session(_ tabs: [Tab], active id: Tab.ID?, groups: [TabGroup]? = nil, splits: [TabSplit] = []) -> Session.Shape {
        var entries: [Session.Entry] = []
        // A row with nothing in front — a space not yet gone to since a fresh
        // start — stays that way in its file, rather than its first tab (a
        // pin) coming to the front next time.
        var active = id == nil ? -1 : 0
        var indices: [Tab.ID: Int] = [:]
        for tab in tabs {
            guard kept(tab), let url = tab.pending ?? tab.address ?? tab.page?.url else { continue }
            if tab.id == id { active = entries.count }
            indices[tab.id] = entries.count
            entries.append(Session.Entry(
                url: url.absoluteString, title: tab.savedTitle, pin: tab.pin, name: tab.name,
                home: tab.pin == nil ? nil : tab.home?.absoluteString, groupID: tab.groupID,
                pinID: tab.pin == nil ? nil : tab.pinID,
                // A page on screen is being looked at now, not when it was
                // arrived at: quitting on it is leaving it.
                touched: visibleTabIDs.contains(tab.id) ? Date() : tab.touched,
                letGo: tab.pin == nil ? tab.letGo : nil,
                muted: tab.muted,
                trim: tab.trimWords,
                live: tab.liveKey,
                icon: tab.customIcon,
                video: Resume.armed(tab.videoSpot, for: url)
            ))
        }
        // The tab you were on isn't kept — a private one: the one kept just
        // before it comes back in front, not the first of the row. An empty
        // one stays an empty one, beside the pins (see frontBlank): the tab
        // just before it is the last of the row, often the last page of a
        // folded group, which then came out of its folder in front.
        if let id, let at = tabs.firstIndex(where: { $0.id == id }), indices[id] == nil {
            active = tabs[at].isBlank && !tabs[at].shy ? -1 : max(0, tabs[..<at].filter(kept).count - 1)
        }
        let keptGroups = groups.map { FolderTree.lasting($0, holding: Set(entries.compactMap(\.groupID))) }
        // Only a pair that is whole in the file: one with an empty page, or
        // a private one, isn't written, and its other page comes back alone.
        let savedSplits = splits.filter { !Browser.wholePinned($0, in: tabs) }.compactMap { pair -> Session.Split? in
            let places = pair.tabs.compactMap { indices[$0] }
            guard places.count == pair.tabs.count, places.count >= 2,
                  places == Array(places[0]..<places[0] + places.count) else { return nil }
            return Session.Split(tabs: places, axis: pair.axis, sizes: pair.sizes,
                                 focused: pair.focused.flatMap { indices[$0] })
        }
        return .init(tabs: entries, active: active, groups: keptGroups, splits: savedSplits)
    }

    /// Whether a tab goes into the session: not a private one or the
    /// bench's, and only a web page, local file or one of Search's own pages.
    /// A sleeping view is blank, so `pending` must win or its page disappears.
    private func kept(_ tab: Tab) -> Bool {
        // A tab holding an extension's sign-in answer (Tab.hold) carries its
        // code in the address: that is never written down.
        let url = tab.pending ?? tab.address
        return !tab.shy && !tab.bench && tab.held == nil
            && (url?.scheme?.hasPrefix("http") == true || url?.isFileURL == true || tab.page != nil)
    }

    var tabsInSession: Set<Tab.ID> { Set(tabs.filter(kept).map(\.id)) }

    /// Another space's row. Its groups are the ones in its own file, the
    /// only place a space off screen keeps them: written without them, the
    /// space would lose every group it had.
    func writeSession(now: Bool, space: UUID, row: Parked) {
        let groups = row.groups ?? readRow(space).groups
        writeRow(space, session(row.tabs, active: row.active, groups: groups, splits: row.splits), now: now)
    }

    /// The session written a moment from now, for other files.
    func writeSessionSoon() { rememberSession() }

    private func rememberSession() {
        guard !remembering else { return }
        remembering = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            remembering = false
            writeSession()
        }
    }

    /// The app is quitting. Whatever the debounce above was waiting out, it
    /// stops waiting: this writes straight to disk, on the thread asking to
    /// quit, before there is a process left to finish the wait on its behalf.
    func flushSession() {
        writeSession(now: true)
    }

    // MARK: - tabs

    /// A pin can be split with: its page goes into the pair as a tab of its
    /// own, and the pin stays where it is (see splittable).
    func canSplit(_ first: Tab, with second: Tab) -> Bool {
        prefs.splitView && first.id != second.id && !first.bench && !second.bench
            && first.shy == second.shy
            && tabs.contains(where: { $0.id == first.id })
            && tabs.contains(where: { $0.id == second.id })
    }

    /// Zen's rule for pins: a pin never goes into a pair — it keeps its
    /// place among the pins, in every window (Pins.swift) — but its page
    /// does, as a new tab beside the other page. Anything else is itself.
    private func splittable(_ tab: Tab) -> Tab {
        guard tab.pin != nil, let url = tab.address ?? tab.home else { return tab }
        let copy = makeTab()
        prepare(copy)
        tabs.insert(copy, at: tabs.count)
        copy.go(to: url)
        return copy
    }

    func pair(_ dragged: Tab, with target: Tab, onLeft: Bool) {
        guard canSplit(dragged, with: target) else { return }
        if floating == dragged.id || floating == target.id { land() }
        let dragged = splittable(dragged)
        let target = splittable(target)
        detachSplit(dragged)
        detachSplit(target)
        let oldGroup = dragged.groupID
        dragged.groupID = target.groupID
        letGoLive(dragged, from: oldGroup)
        var row = tabs.filter { $0.id != dragged.id }
        guard let index = row.firstIndex(where: { $0.id == target.id }) else { return }
        row.insert(dragged, at: onLeft ? index : index + 1)
        let left = onLeft ? dragged : target
        let right = onLeft ? target : dragged
        splits.append(Browser.pairing(dragged.id, with: target.id, onLeft: onLeft))
        tabs = row
        removeEmptyGroup(oldGroup)
        focusPane(dragged)
        for pane in [left, right] where !pane.isBlank {
            if !pane.wake() { pane.revive() }
        }
        rememberSession()
    }

    static func pairing(_ dragged: Tab.ID, with target: Tab.ID, onLeft: Bool) -> TabSplit {
        TabSplit(tabs: onLeft ? [dragged, target] : [target, dragged], focused: dragged)
    }

    func replacePage(_ target: Tab, with source: Tab) {
        guard canSplit(source, with: target) else { return }
        guard split(for: target) != nil else { return select(source) }
        if pinnedSplit(of: target) != nil { return pair(source, with: target, onLeft: false) }
        if floating == source.id || floating == target.id { land() }
        let source = splittable(source)
        detachSplit(source)
        let oldGroup = source.groupID
        source.groupID = target.groupID
        letGoLive(source, from: oldGroup)
        var row = tabs.filter { $0.id != source.id }
        guard let index = row.firstIndex(where: { $0.id == target.id }) else { return }
        row[index] = source
        let partner = split(for: target)?.tabs.first { $0 != target.id }
        let end = row.firstIndex { $0.id == partner }.map { max($0, index) } ?? index
        row.insert(target, at: end + 1)
        replaceSplitMember(target.id, with: source.id)
        tabs = row
        removeEmptyGroup(oldGroup)
        focusPane(source)
        if !source.isBlank, !source.wake() { source.revive() }
        rememberSession()
    }

    func startSplit() {
        // Two tabs picked in the column: those two side by side.
        if pickedPair != nil { return pairPickedTabs() }
        guard prefs.splitView, let shown = active, !shown.bench else { return }
        if let pair = activeSplit {
            if let right = tabs.first(where: { $0.id == pair.right }) { focusPane(right) }
            return
        }
        if floating == shown.id { land() }
        let current = splittable(shown)
        let right = makeTab()
        prepare(right)
        right.groupID = current.groupID
        guard let index = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        splits.append(TabSplit(tabs: [current.id, right.id], focused: right.id))
        tabs.insert(right, at: index + 1)
        focusPane(right)
        editing = true
        typed = ""
        focusRequest += 1
        rememberSession()
    }

    func putBackSplit(_ pair: TabSplit) {
        guard Browser.holds(pair, in: tabs), !splits.contains(where: { $0.id == pair.id }) else { return }
        splits.append(pair)
    }

    func detachSplit(_ tab: Tab) {
        guard let index = splits.firstIndex(where: { $0.contains(tab.id) }) else { return }
        let pair = splits.remove(at: index)
        leftSplit(pair, page: tab)
        rememberSession()
    }

    func leaveSplit(_ tab: Tab) {
        guard let pair = split(for: tab) else { return }
        let stays = pair.tabs.first { $0 != tab.id }.flatMap { id in tabs.first { $0.id == id } }
        detachSplit(tab)
        if let stays { select(stays) }
    }

    /// Once a drag of the divider is over, or once an arrow key moved it:
    /// the drag itself is followed by the stage alone (see PaneStage).
    func setSplitFraction(_ id: UUID, fraction: Double) {
        guard fraction.isFinite, let index = splits.firstIndex(where: { $0.id == id }) else { return }
        let sizes = TabSplit.clamp([fraction, 1 - fraction])
        guard splits[index].sizes != sizes else { return }
        splits[index].sizes = sizes
        rememberSession()
    }

    func focusPane(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        if let pair = split(for: tab), activeSplit?.id == pair.id {
            guard activeID != tab.id else { return }
            if peekTab != nil { closePeek() }
            // Find stays open with what it was looking for, and looks in
            // this page instead (see activeID).
            cancelTabEdit()
            summoning = false
            suggesting = nil
            looked = nil
            editing = false
            typed = ""
            activeID = tab.id
            tab.touch()
            rememberSession()
        } else {
            select(tab)
        }
    }

    /// An extension asking for a tab to be the one in front. A page of the
    /// pair on screen is in view already: the keys stay where they are, so
    /// an extension can't move typing from one page to the other.
    func activateForExtension(_ tab: Tab) {
        if let pair = activeSplit, pair.contains(tab.id) { return }
        select(tab)
    }

    /// ⌃⌘← and ⌃⌘→: the page on that side.
    func focusPane(onLeft: Bool) {
        guard let pair = activeSplit,
              let tab = tabs.first(where: { $0.id == (onLeft ? pair.left : pair.right) }) else { return }
        focusPane(tab)
    }

    /// A tab's menu › Open in Split View: that tab beside the page on
    /// screen. Asked of the page on screen itself, an empty page beside it.
    func openInSplit(_ tab: Tab) {
        guard prefs.splitView, let current = active else { return }
        if tab.id == current.id { return startSplit() }
        guard split(for: tab)?.contains(current.id) != true else { return focusPane(tab) }
        guard canSplit(tab, with: current) else { return }
        pair(tab, with: current, onLeft: false)
    }

    func opensBesideOnOptionClick(_ tab: Tab) -> Bool {
        guard prefs.splitView, tab.id != activeID, split(for: tab) == nil, !tab.bench, let current = active else { return false }
        return canSplit(tab, with: current)
    }

    /// The tabs picked in the column (⌘- or ⇧-click) that are shown, in the
    /// column's order.
    var pickedTabs: [Tab] {
        selectableTabs.filter { selectedTabIDs.contains($0.id) }
    }

    /// Exactly two tabs picked, and already the two pages of one pair.
    var pickedTabsArePaired: Bool {
        let picked = pickedTabs
        return picked.count == 2 && split(for: picked[0])?.contains(picked[1].id) == true
    }

    /// Exactly two tabs picked that can go side by side: what Open 2 Tabs in
    /// Split View and ⌥⌘N pair. More than two isn't a pair — Split View holds
    /// two pages — so the menu's item is off then and ⌥⌘N does what it does
    /// without a selection.
    var pickedPair: (left: Tab, right: Tab)? {
        let picked = pickedTabs
        guard prefs.splitView, picked.count == 2, !pickedTabsArePaired,
              canSplit(picked[0], with: picked[1]) else { return nil }
        return (picked[0], picked[1])
    }

    /// The two picked tabs side by side, the first in the column on the
    /// left. Both keep their pages (nothing loads again); either one in
    /// another pair leaves it first, as a drag onto a page's edge does; a
    /// pin stays a pin and its page goes in as a tab (see splittable). The
    /// pair lands where the left one was — where the right one was when the
    /// left is a pin — and the tab asked from has the keys. The selection
    /// is done with.
    func pairPickedTabs(focus asked: Tab? = nil) {
        guard let (left, right) = pickedPair else { return }
        clearTabSelection()
        if left.pin != nil && right.pin == nil {
            pair(left, with: right, onLeft: true)
        } else {
            pair(right, with: left, onLeft: false)
        }
        if let asked, let made = split(for: asked), activeSplit?.id == made.id {
            focusPane(asked)
        }
    }

    /// The divider's menu › Swap Pages.
    func swapSplit() {
        guard let pair = activeSplit, pair.tabs.count == 2 else { return }
        reorderSplit(pair.id, moving: pair.left, to: 1)
    }

    func reorderSplit(_ id: UUID, moving tab: Tab.ID, to place: Int) {
        guard let index = splits.firstIndex(where: { $0.id == id }) else { return }
        let pair = splits[index]
        var moved = pair
        guard moved.move(tab, to: place) else { return }
        let members = moved.tabs.compactMap { id in tabs.first { $0.id == id } }
        guard members.count == pair.tabs.count, let start = tabs.firstIndex(where: { $0.id == pair.left }) else { return }
        var row = tabs.filter { !pair.contains($0.id) }
        row.insert(contentsOf: members, at: min(start, row.count))
        splits[index] = moved
        tabs = row
        rememberSession()
    }

    /// The divider's menu › Even Out, or a double-click on it.
    func evenSplit() {
        guard let pair = activeSplit else { return }
        setSplitFraction(pair.id, fraction: 0.5)
    }

    /// The divider's menu › Close Both.
    func closeSplit() {
        guard let pair = activeSplit else { return }
        let members = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        for tab in members { close(tab) }
    }

    /// An empty page of a pair given an open tab: the tab takes its place,
    /// and the empty one goes. Chosen from the list the empty page shows.
    func fill(_ blank: Tab, with tab: Tab) {
        guard let pair = split(for: blank), blank.isBlank, tab.id != blank.id, !pair.contains(tab.id),
              !tab.bench, tab.shy == blank.shy,
              let at = tabs.firstIndex(where: { $0.id == blank.id }) else { return }
        let tab = splittable(tab)
        detachSplit(tab)
        let oldGroup = tab.groupID
        tab.groupID = blank.groupID
        var row = tabs.filter { $0.id != tab.id }
        let place = row.firstIndex(where: { $0.id == blank.id }) ?? min(at, row.count)
        row[place] = tab
        replaceSplitMember(blank.id, with: tab.id)
        tabs = row
        removeEmptyGroup(oldGroup)
        blank.close()
        activeID = tab.id
        editing = false
        typed = ""
        if !tab.wake() { tab.revive() }
        rememberSession()
    }

    func focusOtherPane() {
        guard let pair = activeSplit,
              let other = tabs.first(where: { $0.id == (activeID == pair.left ? pair.right : pair.left) }) else { return }
        focusPane(other)
    }

    func moveDisplayedTab(_ tab: Tab, to index: Int) {
        let mark = beginStep("Move Tab")
        defer { endStep(mark) }
        let shown = displayedTabs
        guard shown.indices.contains(index),
              let representative = split(for: tab)?.left ?? (tabs.contains(where: { $0.id == tab.id }) ? tab.id : nil),
              let from = shown.firstIndex(where: { $0.id == representative }), from != index else { return }
        let anchor = shown[index]
        let moving = split(for: tab).map { pair in tabs.filter { pair.contains($0.id) } } ?? [tab]
        guard moving.allSatisfy({ ($0.pin == nil) == (anchor.pin == nil) }) else { return }
        let ids = Set(moving.map(\.id))
        var row = tabs.filter { !ids.contains($0.id) }
        guard let target = row.firstIndex(where: { $0.id == anchor.id }) else { return }
        let targetSize = split(for: anchor) == nil ? 1 : 2
        row.insert(contentsOf: moving, at: from < index ? target + targetSize : target)
        tabs = row
        rememberSession()
    }

    func dropTabIntoStrip(_ tab: Tab, before target: Tab?) {
        let mark = beginStep("Move Tab")
        defer { endStep(mark) }
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let target {
            guard target.id != tab.id,
                  let targetIndex = tabs.firstIndex(where: { $0.id == target.id }),
                  split(for: tab)?.contains(target.id) != true,
                  (tab.pin == nil) == (target.pin == nil) else { return }
            let targetStart = split(for: target).flatMap { pair in tabs.firstIndex { $0.id == pair.left } } ?? targetIndex
            detachSplit(tab)
            let previousGroup = tab.groupID
            tab.groupID = target.groupID
            letGoLive(tab, from: previousGroup)
            var row = tabs.filter { $0.id != tab.id }
            row.insert(tab, at: sourceIndex < targetStart ? targetStart - 1 : targetStart)
            tabs = row
            removeEmptyGroup(previousGroup)
        } else {
            detachSplit(tab)
            var row = tabs
            row.remove(at: sourceIndex)
            row.insert(tab, at: tab.pin == nil ? row.count : row.filter { $0.pin != nil }.count)
            tabs = row
        }
        rememberSession()
    }

    /// ⌘T, the + button and the menu. With the floating field turned on and
    /// a page in front, the field comes up over that page instead of a blank
    /// tab: the tab is made by Return, not by asking for one. Anywhere else
    /// — a blank tab already in front, an extension's new tab page you
    /// chose, or one still to be asked about, whose page needs the tab to
    /// show in — it is an ordinary new tab. From a private tab the field
    /// still comes up for one to be asked about: a private new tab never
    /// asks.
    func launch() {
        guard prefs.floatingNewTab, let tab = active, !tab.isBlank, peekTab == nil else {
            newTab()
            return
        }
        if !tab.shy, Extensions.shared.newTabPage != nil || Extensions.shared.newTabUnaskedAsker != nil {
            newTab()
            return
        }
        // Again while it is up: it stays, with what was typed cleared.
        if reviewing { reviewing = false }
        cancelTabEdit()
        if summoning { summoning = false }
        if siteChip != nil { siteChip = nil }
        if fieldPlace != nil { fieldPlace = nil }
        fieldTimes = (CACurrentMediaTime(), nil, nil)
        typed = ""
        if !editing { editing = true }
        if !launching { launching = true }
        focusRequest += 1
    }

    func newTab() {
        if isPrivate {
            newPrivateTab()
            return
        }
        // An extension's new tab page, if one asked and you said yes. One
        // added since that also asks is still asked, over the page it would
        // take the place of: which one has new tabs stays yours to say.
        if let page = Extensions.shared.newTabPage {
            let tab = open(page, foreground: true, front: true)
            summoning = false
            rememberSession()
            Extensions.shared.offerNewTabPage(into: tab)
            return
        }
        // Reuse an empty tab at the chosen position, clearing its draft:
        // repeated ⌘T must not leave a row of identical empty tabs.
        if let blank = tabs.last(where: { $0.isBlank && !$0.bench && !$0.shy && split(for: $0) == nil }) {
            placeBlank(blank)
            if activeID != blank.id { leaving() }
            noteReturn(blank, front: true, from: nil, once: true)
            activeID = blank.id
            summoning = false
            typed = ""
            blank.draft = ""
            editing = false
            focusRequest += 1
            rememberSession()
            // Asked here too: the blank a window opens with is the one the
            // first ⌘T after adding an extension lands on.
            Extensions.shared.offerNewTabPage(into: blank)
            return
        }
        let tab = makeTab()
        prepare(tab)
        tabs.insert(tab, at: placeForFront())
        leaving()
        noteReturn(tab, front: true, from: nil, once: true)
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
        rememberSession()
        Extensions.shared.offerNewTabPage(into: tab)
    }

    func newTabInFolder(_ id: UUID? = nil) {
        let folder = id ?? active.flatMap { group(of: $0) }
        guard prefs.usesTabGroups, !isPrivate, let folder,
              let index = tabGroups.firstIndex(where: { $0.id == folder && !$0.live }) else { return launch() }
        if id == nil, let here = active, here.isBlank {
            editing = false
            focusRequest += 1
            return
        }
        let tab = makeTab()
        prepare(tab)
        tab.groupID = folder
        let place: Int
        if id == nil, let here = active, let at = tabs.firstIndex(where: { $0.id == here.id }) {
            place = (split(for: here).flatMap { pair in tabs.firstIndex { $0.id == pair.right } } ?? at) + 1
        } else {
            place = tabs.lastIndex { $0.pin == nil && $0.groupID == folder }.map { $0 + 1 } ?? tabs.count
        }
        tabs.insert(tab, at: max(place, pinnedCount))
        tabGroups[index].held = false
        unfoldFolder(folder)
        arrangeGroupedTabs()
        leaving()
        noteReturn(tab, front: true, from: nil, once: true)
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
        rememberSession()
        writeSession(now: true)
    }

    /// A new tab given an extension's new tab page, whether blank or showing
    /// another extension's: the page needs a view built from that
    /// extension's configuration, so it is a new tab in the old one's place.
    func replaceNewTab(_ tab: Tab, with url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let url = Browser.page(url)
        let page = makeTab(configuration: Browser.extensionConfiguration(for: url))
        prepare(page)
        page.groupID = tab.groupID
        page.bornIn = tab.bornIn
        replaceSplitMember(tab.id, with: page.id)
        carryReturn(from: tab, to: page)
        tabs[index] = page
        page.go(to: url)
        if activeID == tab.id { activeID = page.id; editing = false }
    }

    func select(_ tab: Tab, floatPrevious: Bool = true, unfoldGroup: Bool = true, arrived: Bool = false) {
        if let pair = split(for: tab), activeSplit?.id == pair.id, activeID != tab.id {
            focusPane(tab)
            return
        }
        // A folded group opens for the tab you go to in it. With groups off,
        // they are kept as they were and nothing about them is saved.
        if unfoldGroup, prefs.usesTabGroups, let id = tab.groupID,
           let folder = tabGroups.first(where: { $0.id == id }),
           folder.collapsed || FolderTree.ancestors(of: id, in: tabGroups).contains(where: \.collapsed) {
            unfoldFolder(id)
            writeSession(now: true)
        }
        if unfoldGroup, prefs.usesTabGroups { unfoldStack(holding: tab) }
        if let key = tab.liveKey {
            LiveFolders.shared.opened(key, space: spaceID)
        } else if prefs.liveFolders, let url = tab.address {
            LiveFolders.shared.landed(url, space: spaceID)
        }
        // A peek is over the tab it was opened from; another tab puts it away.
        if peekTab != nil, tab.id != activeID { closePeek() }
        // Before ⌘K is put away below: its words were for finding a tab, not
        // a draft for the blank one it was pressed on.
        if tab.id != activeID, !summoning, let here = active, here.isBlank { here.draft = typed }
        cancelTabEdit()
        summoning = false
        suggesting = nil
        // Back on a tab with the caret still in a box, the list may come again.
        looked = nil
        guard tab.id != activeID || arrived else { return }
        tab.agentSeen = true
        // An extension's panel opened for one tab goes and comes with it.
        sidePanelFollows(tab)
        // Coming back to the tab whose video is out brings it home first, so
        // it is never lifted and landed in the same breath.
        if floating == tab.id { land() }
        if pictured == tab.id { unpicture() }
        if floatPrevious { leaving() }
        choosing = true
        activeID = tab.id
        choosing = false
        tab.touch()
        // A tab brought back from last time, or waking from ⌘W while pinned,
        // opens the moment you look at it — and only if there was nothing to
        // wake is this the other case, one whose page quietly died while you
        // were elsewhere, which revive() checks for on its own.
        if !tab.wake() {
            tab.revive()
            livePullShown(tab)
        }
        if let pair = activeSplit,
           let other = tabs.first(where: { $0.id == (pair.left == tab.id ? pair.right : pair.left) }),
           !other.isBlank, !other.wake() { other.revive() }
        rememberSession()
        editing = false
        typed = tab.isBlank ? tab.draft : ""
    }

    /// ⌘W closes what is in front: a peek, then a card over the page (What's
    /// New), then the tabs picked in the column, or else the tab. Settings,
    /// History and the rest are tabs of their own, as in Chrome, and ⌘W on
    /// one closes it. Escape puts things away in the same order, so the two
    /// keys agree on what is in front.
    func closeFront() {
        // The floating new tab is the thing in front: ⌘W takes it away and
        // leaves the page under it.
        if launching { dismiss(); return }
        if peekTab != nil { closePeek() }
        else if !pickedTabs.isEmpty { closePickedTabs() }
        else if let tab = active, !CallFloat.shared.asksBeforeClosing(tab, in: self) { closeTab(tab) }
    }

    func closeTab(_ tab: Tab) {
        guard mayLeave([tab], again: { [weak self] in self?.closeTab(tab) }) else { return }
        if putsAway(tab) { putAway(tab) } else { close(tab) }
    }

    /// Whether Close Tab puts this tab away rather than closing it: a page
    /// open in a group, with groups on. Not an empty tab, which has nothing
    /// to come back to, nor one already put away or asleep: that one goes.
    func putsAway(_ tab: Tab) -> Bool {
        guard prefs.usesTabGroups, let folder = group(of: tab) else { return false }
        return FolderTree.raised(folder, in: tabGroups) && !tab.asleep && !tab.isBlank && !tab.bench && tab.address != nil
    }

    /// A grouped tab's page let go where it stands, as a pin is put down:
    /// out of its pair, if it was in one, the row left in the group, and you
    /// on whatever you were looking at before. It comes back at the address
    /// it had: a tab in a group keeps no page of its own to go home to, as a
    /// pin does, so this is where it was, not where it was when grouped.
    func putAway(_ tab: Tab) {
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        detachSplit(tab)
        heldDialogs.removeValue(forKey: tab.id)?.forEach { $0.dismiss() }
        dropQuestions(for: tab.id)
        if floating == tab.id { land(covering: false) }
        tab.rest()
        if activeID == tab.id { leave(tab) }
        writeSession(now: true)
    }

    /// Off a pin or a grouped tab just put away, onto the tab looked at last.
    /// Ordinary tabs first. Falling back to the most recent tab of any kind
    /// meant closing one pin landed you on another pin, and ⌘W bounced
    /// between the two instead of getting you out of them.
    private func leave(_ tab: Tab) {
        if let back = returning(from: tab) { return select(back) }
        let others = tabs.filter { $0.id != tab.id && !$0.asleep && !$0.agent && !$0.bench }
        let loose = others.filter { $0.pin == nil }
        if let back = (loose.isEmpty ? others : loose).max(by: { $0.touched < $1.touched }) {
            select(back)
        } else {
            newTab()
        }
    }

    /// ⇧⌘W: the whole window, its tabs with it, as the red button closes it.
    func closeWindow() {
        window?.performClose(nil)
    }

    /// ⌘W, or the cross on the tab. Closing the last one leaves a blank tab
    /// behind; closing that blank tab closes the window.
    func replaceRow(_ row: [Tab]) { tabs = row }
    func replaceSplits(_ list: [TabSplit]) { splits = list }

    func close(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if putsDownPinnedSplit(tab) { return }
        LiveFolders.shared.signOnTabClosed(tab.id)
        var live: LiveDismissal?
        if let key = tab.liveKey, !LiveFolders.shared.syncing {
            if let folder = tab.groupID, let made = LiveFolders.shared.hide(key, in: folder, item: tab.liveItem) {
                live = made
            } else {
                LiveFolders.shared.hide(key, space: spaceID)
            }
        }
        let pair = split(for: tab)
        let partner = pair.flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        detachSplit(tab)
        heldDialogs.removeValue(forKey: tab.id)?.forEach { $0.dismiss() }
        dropQuestions(for: tab.id)
        SaveAsk.shared.tabClosed([tab.id])
        SiteFileAsk.shared.tabClosed([tab.id])

        // A tab whose page is out in the little window takes the window with
        // it. Left alone, the window would go on holding a page belonging to a
        // tab that no longer exists.
        if floating == tab.id { land(covering: false) }

        // A pinned tab is not closed by ⌘W — it is put down. The letter keeps
        // its place, the page is let go, and you land on whatever you were
        // looking at before. Only Unpin takes it out of the row.
        if tab.pin != nil {
            // Put down is also gone home with Settings › Tabs › Pins stay on
            // their site, as Arc's pins are: the pin wakes on the page it was
            // pinned at, not wherever its links had taken it.
            tab.rest(at: prefs.pinsGoHome || prefs.pinsPeek ? tab.home : nil)
            leave(tab)
            writeSession(now: true)
            return
        }

        if tabs.count == 1 {
            if tab.isBlank {
                NSApp.keyWindow?.performClose(nil)
            } else {
                let fresh = makeTab()
                remember(tab, at: 0, live: live)
                tab.close()
                adopt(fresh)
                tabs = [fresh]
                activeID = fresh.id
                typed = ""
                removeEmptyGroup(tab.groupID)
            }
            return
        }

        // The last tab that isn't a pin, on screen, with only pins left
        // beside it: with Settings › Tabs › Leave a new tab when the last
        // tab closes, the same as the only tab. Landing on its neighbour
        // takes you into a pin you had not asked for, and wakes it if it was
        // asleep. The pins stay where they are; a new tab takes this one's
        // place. Off, the neighbour is picked as before (#537).
        //
        // Tabs in groups are kept as pins are, as Arc keeps its folders: the
        // last loose tab closed beside them leaves a new tab too, switch or
        // no switch. Its neighbour was a page out of a folder, the folder
        // opened for it, and ⌘T then floated its field over that page
        // rather than giving a new tab. An empty tab closed
        // there stays: it is already the new tab closing it would leave, and
        // the window, holding the groups, stays open.
        let kept: (Tab) -> Bool = { $0.pin != nil || self.group(of: $0) != nil }
        let besideGroups = tabs.contains { $0.id != tab.id && $0.pin == nil && self.group(of: $0) != nil }
        let onlyPins = prefs.newTabAfterLast && !tabs.contains { $0.id != tab.id && $0.pin == nil }
        let onlyKept = besideGroups && !kept(tab) && !tabs.contains { $0.id != tab.id && !kept($0) }
        if activeID == tab.id, onlyPins || onlyKept, returning(from: tab) == nil {
            if tab.isBlank {
                if besideGroups {
                    typed = ""
                    tab.draft = ""
                    editing = false
                    focusRequest += 1
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
                return
            }
            let fresh = makeTab()
            prepare(fresh)
            remember(tab, at: index, partner: partner?.id, onLeft: pair?.left == tab.id, split: pair, live: live)
            tab.close()
            tabs[index] = fresh
            activeID = fresh.id
            typed = ""
            removeEmptyGroup(tab.groupID)
            rememberSession()
            return
        }

        let next = activeID == tab.id ? partner ?? successor(of: tab) : nil
        remember(tab, at: index, partner: partner?.id, onLeft: pair?.left == tab.id, split: pair, live: live)
        tab.close()
        tabs.remove(at: index)
        removeEmptyGroup(tab.groupID)
        if let next {
            settle(on: next)
        } else if activeID == tab.id {
            settle(on: tabs[min(index, tabs.count - 1)])
        }
        rememberSession()
    }

    /// Everything but this one. Pinned tabs are put down rather than removed —
    /// they are not open pages so much as places kept.
    func closeOthers(but keep: Tab) {
        let partner = split(for: keep).flatMap { $0.partner(of: keep.id) }
        guard mayLeave(tabs.filter { $0.id != keep.id && $0.id != partner }, again: { [weak self] in self?.closeOthers(but: keep) }) else { return }
        select(keep)
        // The list is read once: closing walks the row and can add to it.
        for tab in tabs.filter({ $0.id != keep.id && $0.id != partner }) {
            close(tab)
        }
        select(keep)
    }

    /// The row already follows the groups' order, including folded members.
    /// Both pages of the clicked split stay; pins keep their places too.
    func tabsBelow(_ tab: Tab) -> [Tab] {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return [] }
        let partner = split(for: tab).flatMap { $0.partner(of: tab.id) }
        let end = max(index, tabs.firstIndex(where: { $0.id == partner }) ?? index)
        return tabs.dropFirst(end + 1).filter { $0.pin == nil }
    }

    func tabsAbove(_ tab: Tab) -> [Tab] {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return [] }
        let partner = split(for: tab).flatMap { $0.partner(of: tab.id) }
        let start = min(index, tabs.firstIndex(where: { $0.id == partner }) ?? index)
        let own = group(of: tab).map { FolderTree.root(of: $0, in: tabGroups) }
        return tabs.prefix(start).filter { page in
            guard page.pin == nil else { return false }
            guard let id = group(of: page), FolderTree.raised(id, in: tabGroups) else { return true }
            return FolderTree.root(of: id, in: tabGroups) == own
        }
    }

    func closeTabsAbove(_ tab: Tab) {
        guard mayLeave(tabsAbove(tab), again: { [weak self] in self?.closeTabsAbove(tab) }) else { return }
        closeTogether(tabsAbove(tab), keeping: tab)
    }

    func closeTabsBelow(_ tab: Tab) {
        guard mayLeave(tabsBelow(tab), again: { [weak self] in self?.closeTabsBelow(tab) }) else { return }
        closeTogether(tabsBelow(tab), keeping: tab)
    }

    private func closeTogether(_ going: [Tab], keeping tab: Tab) {
        guard !going.isEmpty else { return }
        closingTogether(.tabs) { _ in
            // Move off a page being closed before walking the row, so its
            // neighbours do not wake only to be closed in turn.
            if going.contains(where: { $0.id == activeID }) { select(tab) }
            // Undo inserts in reverse closing order. Closing from the bottom
            // brings them back in order even if tabs above have since gone.
            for page in going.reversed() {
                // A whole group below goes too. Remember it just before its
                // last member leaves, at its place among the groups still here.
                if let id = group(of: page), tabs(in: id).count == 1,
                   let at = tabGroups.firstIndex(where: { $0.id == id }) {
                    closedGroups[id] = (tabGroups[at], at, [])
                }
                close(page)
            }
        }
    }

    /// ⌘W, or the tab menu's Close Tabs, with tabs picked in the column (⌘-
    /// or ⇧-click): each one closed as ⌘W closes it — a pin put down, a tab
    /// in a group put away — and all remembered as one, so one ⇧⌘T brings
    /// them back. The pages on screen go last: closed first, a neighbour
    /// would wake only to be closed.
    func closePickedTabs() {
        let going = pickedTabs, onScreen = visibleTabIDs
        guard !going.isEmpty else { return }
        guard mayLeave(going, again: { [weak self] in self?.closePickedTabs() }) else { return }
        clearTabSelection()
        closingTogether(.tabs) { _ in
            for tab in going where !onScreen.contains(tab.id) { closeTab(tab) }
            for tab in going where onScreen.contains(tab.id) { closeTab(tab) }
        }
    }

    /// Tabs closed as one act: remembered together, so
    /// that one ⇧⌘T brings every one of them back (see reopen(batch:)), and
    /// the one you were on, if it went too, in front.
    func closingTogether(_ kind: CloseKind, _ close: (UUID) -> Void) {
        let batch = UUID(), was = activeID
        batching = (batch, kind)
        defer {
            batching = nil
            if let at = ghosts.lastIndex(where: { $0.batch == batch && $0.was == was }) { ghosts[at].front = true }
            settleLoneFolders()
        }
        close(batch)
    }

    /// A link let go of over the tabs becomes a tab among them.
    func take(_ providers: [NSItemProvider]) -> Bool {
        var took = false
        for provider in providers where !InternalDrag.isInternal(provider) {
            if provider.canLoadObject(ofClass: URL.self) {
                took = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    // A page decides what a link dragged out of it carries: never
                    // script, nor an extension's page, which would open with
                    // that extension's own powers.
                    guard let url, !InternalDrag.isInternal(url.absoluteString),
                          !["javascript", "chrome-extension", "webkit-extension"].contains(url.scheme?.lowercased() ?? "")
                    else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            } else if provider.canLoadObject(ofClass: String.self) {
                took = true
                _ = provider.loadObject(ofClass: String.self) { text, _ in
                    guard let text, !InternalDrag.isInternal(text), let url = Address.url(from: text),
                          !["javascript", "chrome-extension", "webkit-extension"].contains(url.scheme?.lowercased() ?? "")
                    else { return }
                    DispatchQueue.main.async { self.open(url, foreground: true) }
                }
            }
        }
        return took
    }

    /// ⌘⇧T. Back into the row at the place it left.
    func reopen() {
        // A window closed after the last tab was: the window comes back, as
        // in Safari and Chrome (see Windows.swift).
        if let window = Browsers.lastClosedAt, window > (ghosts.last?.at ?? .distantPast), Browsers.reopenWindow() { return }
        guard let ghost = ghosts.last else { return }
        reopen(ghost)
    }

    /// Each bulk close has one place in History, however many tabs it held.
    var recentlyClosed: [Ghost] {
        var batches = Set<UUID>()
        return ghosts.reversed().filter { ghost in
            guard let batch = ghost.batch else { return true }
            return batches.insert(batch).inserted
        }
    }

    func closedTitle(for ghost: Ghost) -> String {
        guard let batch = ghost.batch else { return ghost.label }
        let count = ghosts.filter { $0.batch == batch }.count
        switch ghost.kind {
        case .group: return "Closed Group"
        case .tabs: return count == 1 ? "Closed Tab" : "\(count) Closed Tabs"
        }
    }

    /// What ⇧⌘T brings back: one bulk close, or the last tab or window.
    var reopenTitle: String {
        guard let last = ghosts.last, last.batch != nil,
              (Browsers.lastClosedAt ?? .distantPast) <= last.at else { return "Reopen Closed Tab" }
        return "Reopen \(closedTitle(for: last))"
    }

    private func reopen(batch: UUID) {
        let members = ghosts.filter { $0.batch == batch }
        ghosts.removeAll { $0.batch == batch }
        var back: [Tab.ID: Tab] = [:]
        var front: Tab?
        var regrouped = false
        for ghost in members.reversed() {
            if let tab = reopenLive(ghost) {
                noteCameBack(ghost.was, as: tab)
                if let was = ghost.was { back[was] = tab }
                if ghost.front { front = tab }
                continue
            }
            let tab = makeTab()
            prepare(tab)
            let group = regroup(ghost)
            tab.groupID = group.id
            regrouped = regrouped || group.back
            tab.muted = ghost.muted
            tab.restore(url: ghost.url, title: ghost.title)
            tab.cameBack = true
            tabs.insert(tab, at: safeInsertionIndex(ghost.index))
            noteCameBack(ghost.was, as: tab)
            if let was = ghost.was { back[was] = tab }
            if ghost.front { front = tab }
            // A pair cleared together: its other half came back just before,
            // beside it already. Made a pair again as it stands, not through
            // pair(), which would take the focus and wake both pages.
            if ghost.split == nil, let id = ghost.partner, let partner = back[id],
               split(for: partner) == nil, canSplit(tab, with: partner) {
                let pair = TabSplit(tabs: ghost.onLeft ? [tab.id, partner.id] : [partner.id, tab.id], focused: tab.id)
                if Browser.holds(pair, in: tabs) { splits.append(pair) }
            }
        }
        for ghost in members {
            guard let saved = ghost.split else { continue }
            func restoredTab(_ id: Tab.ID) -> Tab? { back[id] ?? tabs.first { $0.id == id } }
            let restored = saved.tabs.compactMap(restoredTab)
            guard restored.count == saved.tabs.count, restored.allSatisfy({ split(for: $0) == nil }) else { continue }
            let pair = TabSplit(tabs: restored.map(\.id), axis: saved.axis, sizes: saved.sizes,
                                focused: saved.focused.flatMap { restoredTab($0)?.id })
            if Browser.holds(pair, in: tabs) { splits.append(pair) }
        }
        if regrouped { arrangeGroupedTabs() }
        if let front { select(front) }
        rememberSession()
    }

    /// One tab or bulk close, from the History menu.
    func reopen(_ ghost: Ghost) {
        if let batch = ghost.batch {
            reopen(batch: batch)
            return
        }
        ghosts.removeAll { $0.id == ghost.id }
        if let tab = reopenLive(ghost) {
            noteCameBack(ghost.was, as: tab)
            select(tab)
            return
        }
        let tab = makeTab()
        noteCameBack(ghost.was, as: tab)
        prepare(tab)
        let group = regroup(ghost)
        tab.groupID = group.id
        tab.muted = ghost.muted
        tab.cameBack = true
        leaving()
        tabs.insert(tab, at: safeInsertionIndex(ghost.index))
        if group.back { arrangeGroupedTabs() }
        activeID = tab.id
        editing = false
        typed = ""
        tab.go(to: ghost.url)
        // Back into its pair, if the page it was beside is still alone.
        if let id = ghost.partner, let partner = tabs.first(where: { $0.id == id }),
           split(for: partner) == nil, canSplit(tab, with: partner) {
            pair(tab, with: partner, onLeft: ghost.onLeft)
        }
    }

    /// The group a tab coming back goes into: its own, while groups are on
    /// and it is there to go into. A group Close Group took comes back first
    /// (closedGroups), named as it was and where it was, opened; `back` says
    /// so, for the row to be arranged around it.
    private func reopenLive(_ ghost: Ghost) -> Tab? {
        guard let live = ghost.live, prefs.liveFolders, prefs.usesTabGroups,
              tabGroups.contains(where: { $0.id == live.folder && $0.live }),
              LiveFolders.shared.restore(live) else { return nil }
        syncLive()
        return tabs.first { $0.groupID == live.folder && $0.liveKey == live.item.key }
    }

    private func regroup(_ ghost: Ghost) -> (id: UUID?, back: Bool) {
        guard ghost.live == nil else { return (nil, false) }
        var back = false
        if prefs.usesTabGroups, let id = ghost.groupID, !tabGroups.contains(where: { $0.id == id }),
           let closed = closedGroups.removeValue(forKey: id) {
            var group = closed.group
            group.collapsed = false
            tabGroups.insert(group, at: min(closed.at, tabGroups.count))
            let left = Set(closed.left.map(resolved))
            for tab in tabs where left.contains(tab.id) && tab.pin == nil && tab.groupID == group.parent { tab.groupID = id }
            back = true
        }
        let id = prefs.usesTabGroups && tabGroups.contains(where: { $0.id == ghost.groupID }) ? ghost.groupID : nil
        return (id, back)
    }

    private func remember(_ tab: Tab, at index: Int, partner: Tab.ID? = nil, onLeft: Bool = false, split: TabSplit? = nil,
                          live: LiveDismissal? = nil) {
        guard !tab.shy, tab.liveKey == nil || live != nil, !tab.agent, let url = tab.address else { return }
        ghosts.append(Ghost(url: url, title: tab.savedTitle, index: index, groupID: tab.groupID,
                            partner: partner, onLeft: onLeft, was: tab.id, batch: batching?.id,
                            kind: batching?.kind ?? .tabs, muted: tab.muted, split: split, live: live))
        var steps = Set<UUID>()
        let count = ghosts.reduce(0) { total, ghost in
            guard let batch = ghost.batch else { return total + 1 }
            return steps.insert(batch).inserted ? total + 1 : total
        }
        if count > Browser.undoLength, let oldest = ghosts.first {
            if let batch = oldest.batch { ghosts.removeAll { $0.batch == batch } } else { ghosts.removeFirst() }
        }
        closedGroups = closedGroups.filter { id, _ in ghosts.contains { $0.groupID == id } }
        offerUndo(for: ghosts[ghosts.count - 1])
    }

    private func offerUndo(for ghost: Ghost) {
        guard let undo = window?.undoManager else { return }
        if let batch = ghost.batch, offeredBatch == batch {
            undo.setActionName(Browser.undoName(for: ghost, among: ghosts))
            return
        }
        offeredBatch = ghost.batch
        offerStep(Browser.undoName(for: ghost, among: ghosts)) { $0.undoClose() }
    }

    static func undoName(for ghost: Ghost, among ghosts: [Ghost]) -> String {
        guard let batch = ghost.batch else { return "Close Tab" }
        if ghost.kind == .group { return "Close Group" }
        let count = ghosts.filter { $0.batch == batch }.count
        return count == 1 ? "Close Tab" : "Close \(count) Tabs"
    }

    func undoClose() {
        guard let ghost = ghosts.last else { return }
        reopen(ghost)
    }

    /// Dragged from one place in the row to another.
    func move(_ tab: Tab, to index: Int) {
        guard tabs.indices.contains(index) else { return }
        let target = tabs[index]
        let representative = split(for: target)?.left ?? target.id
        guard let destination = displayedTabs.firstIndex(where: { $0.id == representative }) else { return }
        moveDisplayedTab(tab, to: destination)
    }

    /// Put a tab in another space. If its store changes, ask only when the
    /// page has unsaved form entries; the new view then opens in that space.
    func move(_ tab: Tab, toSpace id: UUID, then: (() -> Void)? = nil) {
        guard showsSpaces, id != spaceID,
              spaces.contains(where: { $0.id == id }),
              tabs.contains(where: { $0.id == tab.id }), !tab.bench,
              tab.address.flatMap({ Browser.extensionHost(of: $0) }) == nil
        else { return }

        let complete: () -> Void = { [weak self, weak tab] in
            guard let self, let tab, self.finishMove(tab, toSpace: id) else { return }
            then?()
        }
        guard !tab.shy, tab.store !== Spaces.store(for: id) else {
            complete()
            return
        }
        let from = spaceID
        tab.unsaved { [weak self, weak tab] unsaved in
            guard let self, let tab, self.spaceID == from,
                  self.tabs.contains(where: { $0.id == tab.id }),
                  let destination = self.spaces.first(where: { $0.id == id })
            else { return }
            if unsaved {
                Ask.sure(
                    "Move tab?",
                    detail: "This page has unsaved form entries. It will reopen in “\(destination.name)” with that space's accounts, so the entries may be lost.",
                    confirm: "Move",
                    then: complete
                )
            } else {
                complete()
            }
        }
    }

    /// Group menu › Move Group to Space: every tab of a group, in its order,
    /// into another space, where it is the same group — its name, folded or
    /// not — after that space's own groups. As Move to Space for one tab: a
    /// space with other sign-ins asks first only when a page has unsaved
    /// form entries, once for the group.
    func move(group id: UUID, toSpace target: UUID) {
        guard showsSpaces, target != spaceID,
              let destination = spaces.first(where: { $0.id == target }),
              tabGroups.contains(where: { $0.id == id })
        else { return }
        let family = folderFamily(id)
        let members = folderTabs(id).filter { !$0.bench && $0.address.flatMap({ Browser.extensionHost(of: $0) }) == nil }
        guard !members.isEmpty else { return }
        let from = spaceID
        let complete: () -> Void = { [weak self] in
            guard let self, self.spaceID == from else { return }
            self.finishGroupMove(family, members.filter { tab in self.tabs.contains { $0.id == tab.id } }, to: destination)
        }
        let store = Spaces.store(for: target)
        guard members.contains(where: { !$0.shy && $0.store !== store }) else { return complete() }
        // Any page with something typed and not sent, asked once.
        var unsaved = false
        let asked = DispatchGroup()
        for tab in members where !tab.shy && tab.store !== store {
            asked.enter()
            tab.unsaved { if $0 { unsaved = true }; asked.leave() }
        }
        asked.notify(queue: .main) {
            guard unsaved else { return complete() }
            Ask.sure(
                "Move group?",
                detail: "A page in this group has unsaved form entries. The group will reopen in “\(destination.name)” with that space's accounts, so the entries may be lost.",
                confirm: "Move",
                then: complete
            )
        }
    }

    private func finishGroupMove(_ family: [TabGroup], _ members: [Tab], to destination: Space) {
        guard !members.isEmpty, var group = family.first else { return }
        group.parent = nil
        // The tab on screen goes with the group: the one after the group
        // comes to the front instead, or the one before it, not each of the
        // group's tabs in turn on the way out.
        if let activeID, members.contains(where: { $0.id == activeID }) {
            let ids = Set(members.map(\.id))
            let at = tabs.firstIndex { $0.id == activeID } ?? 0
            let after = tabs[at...].first { !ids.contains($0.id) && standsInRow($0) }
            let before = tabs[..<at].last { !ids.contains($0.id) && standsInRow($0) }
            if let next = after ?? before { select(next, floatPrevious: false) }
        }
        let moved = [group] + family.dropFirst()
        holdingLoneFolders {
            for tab in members {
                finishMove(tab, toSpace: destination.id, group: moved.first { $0.id == tab.groupID }, quietly: true)
            }
        }
        if var row = parked[destination.id] {
            let have = row.groups ?? []
            row.groups = have + moved.filter { folder in !have.contains { $0.id == folder.id } }
            parked[destination.id] = row
        }
        writeSession(now: true)
        if let row = parked[destination.id] { writeSession(now: true, space: destination.id, row: row) }
        announce("Moved \(group.name) to \(destination.name)")
    }

    @discardableResult
    func finishMove(_ tab: Tab, toSpace id: UUID, group: TabGroup? = nil, quietly: Bool = false) -> Bool {
        guard showsSpaces, id != spaceID,
              let destination = spaces.first(where: { $0.id == id }),
              let index = tabs.firstIndex(where: { $0.id == tab.id })
        else { return false }
        let mark = quietly ? nil : beginStep("Move to Space", carrying: [tab.id], to: id)
        defer { endStep(mark) }
        if let web = tab.built { cancelDisplay(for: web) }
        let partner = split(for: tab).flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        detachSplit(tab)

        if floating == tab.id { land() }
        if editingTab == tab.id { cancelTabEdit() }
        if activeID == tab.id {
            if let next = partner ?? successor(of: tab) {
                select(next, floatPrevious: false)
            } else if tabs.count > 1 {
                select(tabs[index == tabs.count - 1 ? index - 1 : index + 1], floatPrevious: false)
            } else {
                activeID = nil
            }
        }
        tabs.remove(at: index)
        removeEmptyGroup(tab.groupID)
        if tabs.isEmpty { adopt(makeTab()) }

        tab.rehome(in: id)
        if tab.agent, !isPrivate, let task = tab.agentTask { AgentLinks.shared.settle(task, in: id, because: .moved) }
        // Its group stays behind: the space it goes to has groups of its own
        // — unless the whole group is going (Move Group to Space).
        let previousGroup = tab.groupID
        tab.groupID = group?.id
        letGoLive(tab, from: previousGroup)
        if !quietly, !meetingMoved(tab, to: id) { LinkArrivals.moved(tab, to: id, in: self) }
        var row = parked[id] ?? loadRow(id)
        if let group {
            var groups = row.groups ?? readRow(id).groups ?? []
            if !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
            row.groups = groups
        }
        // A pin is that space's pin from now on, in pins.json too: kept only
        // in its row, the next look at the space's pins (another window's
        // change, a change to the shared pins, or a relaunch before the space
        // was opened) found it in no list and closed it.
        if tab.pin != nil, !tab.everywhere, let pin = pinDefs([tab]).first {
            Pins.set(id, Pins.defs(id).filter { $0.id != pin.id } + [pin], from: self)
        }
        let pins = row.tabs.firstIndex { $0.pin == nil } ?? row.tabs.count
        row.tabs.insert(tab, at: tab.pin == nil ? row.tabs.count : pins)
        if row.active == nil { row.active = tab.id }
        parked[id] = row

        guard !quietly else { return true }
        writeSession(now: true)
        writeSession(now: true, space: id, row: row)
        announce("Moved to \(destination.name)")
        return true
    }

    func moveToSpace(_ tab: Tab, id: UUID) -> Bool {
        MeetingSpaceMemory.shared.quiet = true
        defer { MeetingSpaceMemory.shared.quiet = false }
        return finishMove(tab, toSpace: id)
    }

    // MARK: - a tab to another window

    /// The tab's menu: Move to New Window, or to another window. The tab
    /// goes as it is, page and all, into the other window's row after the
    /// tab it's on, in front there; into a space with other sign-ins it
    /// reopens with those, as Move to Space does. Not a pin: pins are
    /// already in every window.
    func moveToWindow(_ tab: Tab, _ target: Browser?, at point: NSPoint? = nil) {
        guard target?.isPopup != true, (target?.isPrivate ?? isPrivate) == isPrivate else { return }
        guard tab.pin == nil, !tab.bench, target !== self, tabs.contains(where: { $0.id == tab.id }),
              target != nil || tabs.count > 1 || !tab.isBlank
        else { return }
        let destination = target ?? Browser(record: WindowRecord(space: spaceID), privateStore: privateStore)
        detach(tab)
        destination.receive(tab)
        if target == nil {
            // Dragged out: the new window where the tab was let go, its row
            // under the hand.
            let frame = point.map { TearOff.newWindow(at: $0, leaving: window) }
            Browsers.open(destination, frame: frame)
        } else {
            destination.window?.makeKeyAndOrderFront(nil)
        }
    }

    func moveToWindow(pairOf tab: Tab, _ target: Browser?, at point: NSPoint? = nil) {
        guard let pair = split(for: tab) else { return moveToWindow(tab, target, at: point) }
        let halves = pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        guard halves.count == pair.tabs.count, target?.isPopup != true, (target?.isPrivate ?? isPrivate) == isPrivate,
              target !== self, halves.allSatisfy({ $0.pin == nil && !$0.bench }), target != nil || tabs.count > halves.count
        else { return }
        let destination = target ?? Browser(record: WindowRecord(space: spaceID), privateStore: privateStore)
        for half in halves { detach(half) }
        destination.receive(pair: pair, halves)
        if target == nil {
            let frame = point.map { TearOff.newWindow(at: $0, leaving: window) }
            Browsers.open(destination, frame: frame)
        } else {
            destination.window?.makeKeyAndOrderFront(nil)
        }
    }

    /// A tab dragged out of the row and let go outside this window: into
    /// the window it was let go over, or a new one there, as in Chrome and
    /// Safari. False when it was let go over this window, where the drag
    /// keeps its meaning, or can't leave (a pin).
    func dragOut(_ tab: Tab, at point: NSPoint = NSEvent.mouseLocation) -> Bool {
        guard tab.pin == nil, !tab.bench, let window,
              !window.frame.insetBy(dx: -12, dy: -12).contains(point)
        else { return false }
        let over = Browsers.all.first { $0 !== self && $0.isOpen && !$0.isPopup && $0.isPrivate == isPrivate && $0.window?.frame.contains(point) == true }
        guard over != nil || tabs.count > 1 else { return false }
        // After the drag has let go, not inside it.
        DispatchQueue.main.async { [weak self] in self?.moveToWindow(tab, over, at: point) }
        return true
    }

    /// Out of this row, not closed: it is on its way to another window.
    private func detach(_ tab: Tab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if let web = tab.built { cancelDisplay(for: web) }
        let partner = split(for: tab).flatMap { pair in tabs.first { $0.id == pair.partner(of: tab.id) } }
        detachSplit(tab)
        if floating == tab.id { land() }
        if editingTab == tab.id { cancelTabEdit() }
        if activeID == tab.id {
            if let next = partner ?? successor(of: tab) {
                select(next, floatPrevious: false)
            } else if tabs.count > 1 {
                select(tabs[index == tabs.count - 1 ? index - 1 : index + 1], floatPrevious: false)
            } else {
                activeID = nil
            }
        }
        tabs.remove(at: index)
        removeEmptyGroup(tab.groupID)
        let previousGroup = tab.groupID
        tab.groupID = nil
        letGoLive(tab, from: previousGroup)
        if tabs.isEmpty { adopt(makeTab()) }
        writeSession(now: true)
    }

    /// A tab from another window, in front here. The empty tab a new window
    /// starts with makes way for it.
    func receive(_ tab: Tab) {
        prepare(tab)
        if !tab.shy { tab.rehome(in: spaceID) }
        let blanks = tabs.filter { $0.isBlank && !$0.bench && split(for: $0) == nil }
        tabs.insert(tab, at: placeForNew())
        select(tab, floatPrevious: false)
        if tabs.count - blanks.count == 1 + pinnedCount {
            for blank in blanks { tabs.removeAll { $0 === blank }; blank.close() }
        }
        if let active, active.id == tab.id, tab.asleep { _ = tab.wake() }
        writeSession(now: true)
    }

    func receive(pair: TabSplit, _ halves: [Tab]) {
        guard let first = halves.first else { return }
        for half in halves { receive(half) }
        var row = tabs.filter { tab in !halves.dropFirst().contains { $0 === tab } }
        guard let at = row.firstIndex(where: { $0 === first }) else { return }
        row.insert(contentsOf: halves.dropFirst(), at: at + 1)
        tabs = row
        putBackSplit(pair)
        if let focused = halves.first(where: { $0.id == pair.focused }) ?? halves.first { focusPane(focused) }
        writeSession(now: true)
    }

    /// A section can be made empty, then filled from a tab's menu.
    @discardableResult
    func addTabGroup(containing tab: Tab, inside parent: UUID? = nil, pinned: Bool? = nil) -> UUID {
        let mark = beginStep("New Folder")
        defer { endStep(mark) }
        let id = UUID()
        var made = TabGroup(id: id, name: "Folder \(tabGroups.count + 1)", collapsed: false, parent: parent)
        made.madeName = made.name
        made.pinned = pinned ?? parent.map { FolderTree.raised($0, in: tabGroups) }
            ?? group(of: tab).map { FolderTree.raised($0, in: tabGroups) } ?? false
        tabGroups.append(made)
        editingGroupID = id
        move(tab, toGroup: id, staying: true)
        // A tab that can't be in a group (a pin, a private one) leaves none behind.
        removeEmptyGroup(id)
        writeSession(now: true)
        FolderEmojis.shared.add(to: id, in: self)
        return id
    }

    func addExtensionGroup(containing tab: Tab) -> UUID {
        let id = addTabGroup(containing: tab)
        editingGroupID = nil
        if let index = tabGroups.firstIndex(where: { $0.id == id }) { tabGroups[index].madeName = nil }
        return id
    }

    func commitFolderName(_ id: UUID, typed: String, opened: String) {
        if typed.trimmingCharacters(in: .whitespacesAndNewlines) != opened.trimmingCharacters(in: .whitespacesAndNewlines) {
            renameTabGroup(id, to: typed)
        }
        editingGroupID = nil
    }

    func renameTabGroup(_ id: UUID, to name: String) {
        let mark = beginStep("Rename Folder")
        defer { endStep(mark) }
        guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabGroups[index].name = trimmed
        tabGroups[index].userNamed = true
        if tabGroups[index].live { LiveFolders.shared.rename(id, to: trimmed) }
        writeSession(now: true)
        FolderEmojis.shared.add(to: id, in: self)
    }

    func toggleTabGroup(_ id: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        KitChange.eased { tabGroups[index].collapsed.toggle() }
        writeSession(now: true)
    }

    /// Fold All Groups / Unfold All Groups, in the space's menu and the View
    /// menu, as in Arc: every group of the space on screen at once, each
    /// keeping its tabs and its place. A folded group still shows the tab in
    /// front if that is one of its own, as one folded by hand does.
    func foldAllGroups(_ fold: Bool) {
        guard tabGroups.contains(where: { $0.collapsed != fold }) else { return }
        KitChange.eased {
            for index in tabGroups.indices where tabGroups[index].collapsed != fold {
                tabGroups[index].collapsed = fold
            }
        }
        writeSession(now: true)
    }

    /// Whether Fold All Groups or Unfold All Groups has anything to do.
    var canFoldAllGroups: Bool { prefs.usesTabGroups && tabGroups.contains { !$0.collapsed } }
    var canUnfoldAllGroups: Bool { prefs.usesTabGroups && tabGroups.contains { $0.collapsed } }

    func removeTabGroup(_ id: UUID) {
        let mark = beginStep("Ungroup")
        defer { endStep(mark) }
        guard let removed = tabGroups.first(where: { $0.id == id }) else { return }
        AIGroups.shared.ungrouped(removed, in: self)
        for tab in tabs where tab.groupID == id { tab.groupID = removed.parent }
        for index in tabGroups.indices where tabGroups[index].parent == id {
            tabGroups[index].parent = removed.parent
            if removed.parent == nil { tabGroups[index].pinned = removed.isPinned }
        }
        tabGroups.removeAll { $0.id == id }
        arrangeGroupedTabs()
        if editingGroupID == id { editingGroupID = nil }
        writeSession(now: true)
    }

    func closeTabGroup(_ id: UUID) {
        guard tabGroups.contains(where: { $0.id == id }) else { return }
        let family = folderFamily(id)
        for folder in family {
            if let at = tabGroups.firstIndex(where: { $0.id == folder.id }) { closedGroups[folder.id] = (folder, at, []) }
        }
        let going = folderTabs(id)
        closingTogether(.group) { _ in
            for tab in going where !visibleTabIDs.contains(tab.id) { close(tab) }
            for tab in going where visibleTabIDs.contains(tab.id) { close(tab) }
        }
        // The group goes with its last tab; an empty one goes here.
        quietly {
            for folder in family.reversed() where tabGroups.contains(where: { $0.id == folder.id }) { removeTabGroup(folder.id) }
        }
        writeSession(now: true)
    }

    private func markFilled(_ id: UUID?) {
        guard undoQuiet == 0, let id, let index = tabGroups.firstIndex(where: { $0.id == id && $0.ai }),
              !tabGroups[index].userFilled else { return }
        tabGroups[index].userFilled = true
    }

    func move(_ tab: Tab, toGroup id: UUID?, staying: Bool = false) {
        let mark = beginStep(id == nil ? "Remove from Folder" : "Move to Folder")
        defer { endStep(mark) }
        guard tabs.contains(where: { $0.id == tab.id }), tab.pin == nil, !tab.shy, !tab.bench,
              id == nil || tabGroups.contains(where: { $0.id == id && !$0.live }) else { return }
        let previousGroup = tab.groupID
        guard previousGroup != id else { return }
        let leading = !staying && id.map { leadsEmpty($0) } == true
        markFilled(id)
        // A pair is one place in the row: moved into a group or out of one,
        // both halves go, and stay a pair. Dragged apart in the row, one
        // half leaves on its own (see dropTabIntoStrip).
        let partner = split(for: tab).flatMap { pair in
            tabs.first { $0.id == (pair.left == tab.id ? pair.right : pair.left) }
        }
        tab.groupID = id
        partner?.groupID = id
        letGoLive(tab, from: previousGroup)
        if let partner { letGoLive(partner, from: previousGroup) }
        placeJoined([tab], leading: leading)
        removeEmptyGroup(previousGroup)
        arrangeGroupedTabs()
        if tab.liveKey != nil { syncLive() }
        if let id, let index = tabGroups.firstIndex(where: { $0.id == id }) {
            tabGroups[index].held = false
            unfoldFolder(id)
        }
        writeSession(now: true)
    }

    func leadsEmpty(_ id: UUID) -> Bool {
        guard FolderTree.leads(id, in: tabGroups) else { return false }
        let family = Set(folderFamily(FolderTree.root(of: id, in: tabGroups)).map(\.id))
        return !tabs.contains { $0.pin == nil && $0.groupID.map(family.contains) == true }
    }

    /// Insert relative to a visible member, after removing the carried item.
    /// Assign the completed row once: tabs' normalization must not see a half move.
    func move(_ tab: Tab, toGroup target: GroupDropTarget, detaching: Bool = false) {
        if reorderLive(tab, to: target) { return }
        let mark = beginStep("Move to Folder")
        defer { endStep(mark) }
        guard tabs.contains(where: { $0 === tab }),
              let groupIndex = tabGroups.firstIndex(where: { $0.id == target.group && !$0.live }) else { return }
        let moving = (detaching ? nil : split(for: tab)).map { pair in
            pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        } ?? [tab]
        guard moving.allSatisfy({ $0.pin == nil && !$0.shy && !$0.bench }) else { return }
        let ids = Set(moving.map(\.id))
        var anchor: Tab?
        if let member = target.member {
            guard let found = tabs.first(where: { $0.id == member }),
                  found.groupID == target.group, found.pin == nil, !found.shy, !found.bench else { return }
            if ids.contains(member) { return }
            let pair = split(for: found).flatMap { pair in
                detaching && pair.contains(tab.id) ? nil : pair
            }
            let anchorID = target.after ? pair?.right : pair?.left
            anchor = anchorID.flatMap { id in tabs.first { $0.id == id } } ?? found
        }
        var row = tabs.filter { !ids.contains($0.id) }
        let insertion: Int
        if let anchor, let index = row.firstIndex(where: { $0 === anchor }) {
            insertion = index + (target.after ? 1 : 0)
        } else {
            insertion = row.lastIndex(where: { $0.groupID == target.group }).map { $0 + 1 }
                ?? row.firstIndex(where: { $0.pin == nil }) ?? row.count
        }
        let previous = Dictionary(moving.map { ($0.id, $0.groupID) }, uniquingKeysWith: { a, _ in a })
        if previous.values.contains(where: { $0 != target.group }) { markFilled(target.group) }
        if detaching { detachSplit(tab) }
        for member in moving {
            member.groupID = target.group
            letGoLive(member, from: previous[member.id] ?? nil)
        }
        row.insert(contentsOf: moving, at: insertion)
        tabGroups[groupIndex].held = false
        unfoldFolder(target.group)
        tabs = row
        for id in Set(previous.values.compactMap { $0 }) where id != target.group { removeEmptyGroup(id) }
        if tab.liveKey != nil { syncLive() }
        writeSession(now: true)
    }

    /// Reorder only among peers in the displayed section. The underlying
    /// tab row remains flat for keyboard shortcuts and the top strip.
    func move(_ tab: Tab, within group: UUID?, to index: Int) {
        let peers = tabs(in: group).filter(standsInRow)
        guard let from = peers.firstIndex(where: { $0.id == tab.id }),
              peers.indices.contains(index), from != index,
              let destination = tabs.firstIndex(where: { $0.id == peers[index].id }) else { return }
        move(tab, to: destination)
    }

    /// The row in the order it is shown: the pins, each group's tabs in the
    /// groups' order, then the tabs in none. The one place that order is
    /// made, run after every change to the row (see `tabs`) and to a group.
    /// Nothing while groups are off: the row stays as you left it.
    func arrangeGroupedTabs(_ on: Bool? = nil) {
        guard on ?? prefs.usesTabGroups else { return }
        AIGroups.shared.membershipChanged(in: self)
        let representatives = displayedTabs
        let pins = representatives.filter { $0.pin != nil }
        let tree = FolderTree.tabOrder(tabGroups)
        let raised = Set(tabGroups.filter { FolderTree.raised($0.id, in: tabGroups) }.map(\.id))
        let grouped = tree.filter { raised.contains($0.id) }.flatMap { group in representatives.filter { self.group(of: $0) == group.id } }
        var list: [Tab] = []
        var gathered = Set<UUID>()
        for tab in representatives where tab.pin == nil {
            guard let id = group(of: tab) else {
                list.append(tab)
                continue
            }
            guard !raised.contains(id) else { continue }
            let root = FolderTree.root(of: id, in: tabGroups)
            guard gathered.insert(root).inserted else { continue }
            let family = Set(folderFamily(root).map(\.id))
            list += tree.filter { family.contains($0.id) }.flatMap { group in representatives.filter { self.group(of: $0) == group.id } }
        }
        let order = (pins + grouped + list).flatMap { tab -> [Tab] in
            guard let pair = split(for: tab), pair.left == tab.id else { return [tab] }
            return pair.tabs.compactMap { id in tabs.first { $0.id == id } }
        }
        // Setting the row runs this again, which then finds nothing to do.
        guard !order.elementsEqual(tabs, by: { $0.id == $1.id }) else { return }
        tabs = order
    }

    func setRow(_ row: [Tab]) {
        tabs = row
    }

    func placeJoined(_ joined: [Tab], leading: Bool = false) {
        guard prefs.usesTabGroups else { return }
        var row = tabs
        for tab in joined {
            guard let id = group(of: tab), !FolderTree.raised(id, in: tabGroups) else { continue }
            let family = Set(folderFamily(FolderTree.root(of: id, in: tabGroups)).map(\.id))
            let moving = split(for: tab).map { pair in pair.tabs.compactMap { id in row.first { $0.id == id } } } ?? [tab]
            let ids = Set(moving.map(\.id))
            let rest = row.filter { !ids.contains($0.id) }
            let last = rest.lastIndex(where: { $0.pin == nil && $0.groupID.map(family.contains) == true }).map { $0 + 1 }
            guard let place = last ?? (leading ? listTop(rest, groups: tabGroups) ?? rest.count : nil) else { continue }
            row = rest
            row.insert(contentsOf: moving, at: place)
        }
        if !row.elementsEqual(tabs, by: { $0.id == $1.id }) { tabs = row }
    }

    func placeLeft(_ left: [Tab], from group: UUID) {
        guard prefs.usesTabGroups, !left.isEmpty else { return }
        let ids = Set(left.map(\.id))
        let moving = tabs.filter { ids.contains($0.id) }
        var row = tabs.filter { !ids.contains($0.id) }
        let family = Set(folderFamily(FolderTree.root(of: group, in: tabGroups)).map(\.id))
        guard let last = row.lastIndex(where: { $0.pin == nil && $0.groupID.map(family.contains) == true }) else { return }
        row.insert(contentsOf: moving, at: last + 1)
        if !row.elementsEqual(tabs, by: { $0.id == $1.id }) { tabs = row }
    }

    enum ListItem: Hashable, Identifiable {
        case tab(Tab.ID)
        case folder(UUID)

        var id: UUID {
            switch self {
            case .tab(let id), .folder(let id): return id
            }
        }

        var isFolder: Bool {
            if case .folder = self { true } else { false }
        }
    }

    func listItems(_ shown: [Tab]) -> [ListItem] {
        guard prefs.usesTabGroups else { return shown.filter { $0.pin == nil }.map { .tab($0.id) } }
        return FolderTree.listed(shown.filter { $0.pin == nil }, group: { self.group(of: $0) }, in: tabGroups) { .tab($0.id) }
    }

    func pinnedFolders() -> [TabGroup] {
        guard prefs.usesTabGroups else { return [] }
        return tabGroups.filter { $0.parent == nil && $0.isPinned }
    }

    /// The group a tab is shown in: none for a pin, or for a group this space
    /// doesn't have, which is shown with the loose tabs rather than lost.
    func group(of tab: Tab) -> UUID? {
        guard tab.pin == nil, let id = tab.groupID, tabGroups.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    func tabs(in group: UUID?) -> [Tab] {
        tabs.filter { $0.pin == nil && self.group(of: $0) == group }
    }

    /// A folded group shows its name alone — and the tab you are on, if it
    /// is in there, so the page on screen always has its place in the row.
    func visibleTabs(in group: TabGroup) -> [Tab] {
        guard !FolderTree.ancestors(of: group.id, in: tabGroups).contains(where: \.collapsed) else { return [] }
        guard group.collapsed else { return Self.unfoldedStacks(tabs(in: group.id).filter(standsInRow), in: group, front: activeSplit?.left ?? activeID) }
        return folderTabs(group.id).filter(standsInRow).filter { $0.id == (activeSplit?.left ?? activeID) }
    }

    func stackTops(in group: TabGroup) -> [Tab.ID: Bool] {
        Self.stackTops(drawnTabs(in: group), in: group)
    }

    static func stackTops(_ drawn: [Tab], in group: TabGroup) -> [Tab.ID: Bool] {
        guard group.live else { return [:] }
        let runs = LiveStackRuns.tops(drawn.map(\.liveItem))
        let folded = foldedRuns(drawn, runs: runs, in: group)
        var out: [Tab.ID: Bool] = [:]
        for (index, top) in runs.enumerated() where top == index { out[drawn[index].id] = folded.contains(index) }
        return out
    }

    func toggleStack(_ top: Tab.ID, in id: UUID) {
        guard let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        guard let kept = Self.toggledStacks(drawnTabs(in: tabGroups[index]), in: tabGroups[index], top: top) else { return }
        KitChange.eased { tabGroups[index].foldedStacks = kept }
        writeSession(now: true)
    }

    func unfoldStack(holding tab: Tab) {
        guard let id = tab.groupID, let index = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        guard let kept = Self.stacksOpened(drawnTabs(in: tabGroups[index]), in: tabGroups[index], for: tab.id) else { return }
        KitChange.eased { tabGroups[index].foldedStacks = kept }
        writeSession(now: true)
    }

    static func stacksOpened(_ drawn: [Tab], in group: TabGroup, for id: Tab.ID) -> [String]? {
        guard group.live, !group.foldedStacks.isEmpty else { return nil }
        let runs = LiveStackRuns.tops(drawn.map(\.liveItem))
        guard let at = drawn.firstIndex(where: { $0.id == id }), let top = runs[at], top != at,
              foldedRuns(drawn, runs: runs, in: group).contains(top) else { return nil }
        return toggledStacks(drawn, in: group, top: drawn[top].id)
    }

    static func toggledStacks(_ drawn: [Tab], in group: TabGroup, top: Tab.ID) -> [String]? {
        let runs = LiveStackRuns.tops(drawn.map(\.liveItem))
        guard let start = drawn.firstIndex(where: { $0.id == top }), runs[start] == start else { return nil }
        let members = Set(drawn.indices.filter { runs[$0] == start }.compactMap { drawn[$0].liveItem?.key })
        let present = Set(drawn.compactMap(\.liveItem?.key))
        var folded = Set(group.foldedStacks).intersection(present)
        if folded.isDisjoint(with: members) { folded.formUnion(members) } else { folded.subtract(members) }
        return drawn.compactMap(\.liveItem?.key).filter(folded.contains)
    }

    private static func foldedRuns(_ tabs: [Tab], runs: [Int?], in group: TabGroup) -> Set<Int> {
        guard !group.foldedStacks.isEmpty else { return [] }
        let folded = Set(group.foldedStacks)
        return Set(tabs.indices.compactMap { index in
            guard let top = runs[index], let key = tabs[index].liveItem?.key, folded.contains(key) else { return nil }
            return top
        })
    }

    static func unfoldedStacks(_ tabs: [Tab], in group: TabGroup, front: Tab.ID?) -> [Tab] {
        guard group.live, !group.foldedStacks.isEmpty else { return tabs }
        let runs = LiveStackRuns.tops(tabs.map(\.liveItem))
        let folded = foldedRuns(tabs, runs: runs, in: group)
        guard !folded.isEmpty else { return tabs }
        return tabs.indices.filter { index in
            guard let top = runs[index], top != index, folded.contains(top) else { return true }
            return tabs[index].id == front
        }.map { tabs[$0] }
    }

    func drawnTabs(in group: TabGroup) -> [Tab] {
        tabs(in: group.id).filter(standsInRow)
    }

    /// A group lasts as long as its tabs: the last one gone, it goes too.
    func removeEmptyGroup(_ id: UUID?) {
        guard let id, let group = tabGroups.first(where: { $0.id == id }) else { return }
        guard !group.held, !tabs.contains(where: { $0.groupID == id }),
              !tabGroups.contains(where: { $0.parent == id }) else { return dissolveLoneFolder(id) }
        tabGroups.removeAll { $0.id == id }
        if editingGroupID == id { editingGroupID = nil }
        removeEmptyGroup(group.parent)
    }

    static func dissolves(_ group: TabGroup) -> Bool {
        group.ai && !group.live && !group.isPinned && !group.held && group.query == nil
            && !group.userNamed && !group.userIcon && !group.userFilled
    }

    func dissolveLoneFolder(_ id: UUID) {
        guard loneHolds == 0, batching == nil else {
            lonesWaiting.insert(id)
            return
        }
        guard prefs.usesTabGroups, editingGroupID != id,
              let at = tabGroups.firstIndex(where: { $0.id == id }), Browser.dissolves(tabGroups[at]),
              !tabGroups.contains(where: { $0.parent == id }) else { return }
        let members = tabs.filter { $0.groupID == id }
        guard members.count == 1, let last = members.first, last.pin == nil else { return }
        let group = tabGroups[at]
        if undoScope == nil, undoQuiet == 0, ghosts.contains(where: { $0.groupID == id }) {
            closedGroups[id] = (group, at, [last.id])
        }
        AIGroups.shared.dissolved(group, in: self)
        last.groupID = group.parent
        tabGroups.remove(at: at)
        arrangeGroupedTabs()
        writeSession(now: true)
    }

    func holdingLoneFolders<T>(_ body: () -> T) -> T {
        loneHolds += 1
        defer {
            loneHolds -= 1
            settleLoneFolders()
        }
        return body()
    }

    func settleLoneFolders() {
        guard loneHolds == 0, batching == nil, !lonesWaiting.isEmpty else { return }
        let waiting = lonesWaiting
        lonesWaiting = []
        for id in waiting { dissolveLoneFolder(id) }
    }

    func dissolveLoneFolders() {
        quietly {
            for group in tabGroups where Browser.dissolves(group) { dissolveLoneFolder(group.id) }
        }
    }

    /// The tabs as they are on screen: with groups on, the ones folded away
    /// in a group are not among them. Tab cycling and selection ranges count
    /// these; number shortcuts also give folded groups a place of their own.
    var shownTabs: [Tab] {
        guard prefs.usesTabGroups else { return displayedTabs }
        return inDisplayOrder(tab: { [$0] }, group: { self.visibleTabs(in: $0) })
    }

    private func inDisplayOrder<Item>(tab: (Tab) -> [Item], group: (TabGroup) -> [Item]) -> [Item] {
        let row = displayedTabs
        let tree = FolderTree.tabOrder(tabGroups)
        var shown = row.filter { $0.pin != nil }.flatMap(tab)
        shown += tree.filter { FolderTree.raised($0.id, in: tabGroups) }.flatMap(group)
        let byID = Dictionary(row.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for item in listItems(row) {
            switch item {
            case .tab(let id):
                if let found = byID[id] { shown += tab(found) }
            case .folder(let root):
                let family = Set(folderFamily(root).map(\.id))
                shown += tree.filter { family.contains($0.id) }.flatMap(group)
            }
        }
        return shown
    }

    /// Number shortcuts count a folded group once, even while its active tab
    /// is shown below its heading. Other tab navigation keeps using shownTabs.
    var tabShortcutTargets: [(id: UUID, tab: Tab)] {
        guard prefs.usesTabGroups else { return displayedTabs.map { ($0.id, $0) } }
        return inDisplayOrder(tab: { [($0.id, $0)] }, group: { group -> [(id: UUID, tab: Tab)] in
            guard !FolderTree.ancestors(of: group.id, in: tabGroups).contains(where: \.collapsed) else { return [] }
            guard group.collapsed else { return tabs(in: group.id).filter(standsInRow).map { ($0.id, $0) } }
            let members = folderTabs(group.id).filter(standsInRow)
            let current = active.flatMap { tab in members.contains { $0.id == tab.id } ? tab : nil }
            guard let tab = current ?? members.max(by: { $0.touched < $1.touched }) else { return [] }
            return [(group.id, tab)]
        })
    }

    /// Only nine hints, worked out once for the window rather than by each tab.
    var tabShortcutNumbers: [UUID: Int] {
        guard prefs.showsTabShortcuts, commandHeld else { return [:] }
        let shown = tabShortcutTargets
        var numbers = Dictionary(uniqueKeysWithValues: shown.prefix(8).enumerated().map { ($0.element.id, $0.offset + 1) })
        if shown.count > 8, let last = shown.last { numbers[last.id] = 9 }
        return numbers
    }

    func clearTabSelection() {
        if !selectedTabIDs.isEmpty { selectedTabIDs.removeAll() }
        selectionAnchor = nil
    }

    func pickAllTabs() {
        let all = Set(pickableTabs.map(\.id))
        guard !all.isEmpty else { return }
        if selectedTabIDs == all { return clearTabSelection() }
        selectedTabIDs = all
        selectionAnchor = activeID.flatMap { all.contains($0) ? $0 : nil }
    }

    /// Command toggles one tab; Shift picks the visible run from the last
    /// clicked tab (or the active tab when a selection begins).
    func extendTabSelection(to tab: Tab, modifiers: NSEvent.ModifierFlags) {
        let shown = selectableTabs.map(\.id)
        guard let end = shown.firstIndex(of: tab.id) else { return }
        if modifiers.contains(.shift) {
            let startID = selectionAnchor ?? activeID ?? tab.id
            let start = shown.firstIndex(of: startID) ?? end
            let range = Set(shown[min(start, end)...max(start, end)])
            selectedTabIDs = modifiers.contains(.command) ? selectedTabIDs.union(range) : range
            selectionAnchor = shown[start]
        } else if modifiers.contains(.command) {
            if selectedTabIDs.isEmpty, let active = activeID,
               shown.contains(active) {
                selectedTabIDs.insert(active)
            }
            if !selectedTabIDs.insert(tab.id).inserted { selectedTabIDs.remove(tab.id) }
            selectionAnchor = tab.id
        }
    }

    var selectableTabs: [Tab] {
        shownTabs.flatMap { tab in
            split(for: tab).map { pair in pair.tabs.compactMap { id in tabs.first { $0.id == id } } } ?? [tab]
        }
    }

    var visibleSelectedTabCount: Int {
        selectableTabs.filter { selectedTabIDs.contains($0.id) }.count
    }

    var selectedTabLinks: [String] {
        selectableTabs.compactMap { tab in
            selectedTabIDs.contains(tab.id) ? tab.address?.absoluteString : nil
        }
    }

    /// ⌃Tab, ⌃⇧Tab: the next tab on screen, round to the first again. It
    /// walks the whole row from the tab you are on, so it finds its way out
    /// even when that tab is one the row doesn't show.
    func step(_ direction: Int) {
        let shown = Set(shownTabs.map(\.id))
        guard let anchor = activeSplit?.left ?? activeID,
              shown.count > 1 || (shown.count == 1 && !shown.contains(anchor)),
              let here = tabs.firstIndex(where: { $0.id == anchor }) else { return }
        for n in 1..<tabs.count {
            let next = tabs[((here + direction * n) % tabs.count + tabs.count) % tabs.count]
            if shown.contains(next.id) { select(entry(next)); return }
        }
    }

    /// Where a key that picks a place in the row lands: a pair's page that
    /// had the keys last, not always its first.
    private func entry(_ tab: Tab) -> Tab {
        guard let pair = split(for: tab), pair.left == tab.id, let id = pair.focused,
              let focused = tabs.first(where: { $0.id == id }) else { return tab }
        return focused
    }

    /// ⌘1–8: a tab or folded group in that place, without unfolding it.
    /// With Settings › Tabs › A pin's number again goes back, the number of
    /// the pin you're on takes you back to the tab you were on before it.
    func select(index: Int) {
        let targets = tabShortcutTargets
        guard targets.indices.contains(index) else { return }
        let tab = entry(targets[index].tab)
        if prefs.pinNumberGoesBack, tab.pin != nil, activeID == tab.id, let back = tabBefore(tab) {
            select(back)
            return
        }
        select(tab, unfoldGroup: false)
    }

    /// The tab last left that is still in the row, other than `tab`.
    func tabBefore(_ tab: Tab) -> Tab? {
        let row = tabs.filter(standsInRow)
        guard let id = tabSwitcher.lastLeft(among: Set(row.map(\.id)), other: tab.id) else { return nil }
        return row.first { $0.id == id }
    }

    func switchTabs(backwards: Bool) {
        guard let activeID else { return }
        tabSwitcher.partners = switcherPartners
        tabSwitcher.step(row: switcherRow, current: activeSplit?.left ?? activeID,
                         backwards: backwards)
    }

    var switcherRow: [Tab.ID] {
        let here = tabs.filter(standsInRow).map(\.id)
        guard showsSpaces else { return here }
        let elsewhere = spaces.filter { $0.id != spaceID }.flatMap { space -> [Tab.ID] in
            guard let row = parked[space.id] else { return [] }
            return row.tabs.filter { tab in
                !tab.isBlank && !tab.everywhere && !row.splits.contains { $0.contains(tab.id) && $0.left != tab.id }
            }.map(\.id)
        }
        return here + elsewhere
    }

    func switcherTab(_ id: Tab.ID) -> Tab? {
        tabs.first { $0.id == id } ?? (showsSpaces ? parkedTabs.first { $0.id == id } : nil)
    }

    func switcherSpace(of id: Tab.ID) -> Space? {
        guard showsSpaces, !tabs.contains(where: { $0.id == id }),
              let held = parked.first(where: { $0.value.tabs.contains { $0.id == id } })?.key else { return nil }
        return spaces.first { $0.id == held }
    }

    private var switcherPartners: [Tab.ID: Tab.ID] {
        guard prefs.splitView else { return [:] }
        let all = splits + (showsSpaces ? parked.filter { $0.key != spaceID }.values.flatMap(\.splits) : [])
        return Dictionary(all.map { ($0.left, $0.right) }, uniquingKeysWith: { first, _ in first })
    }

    func act(_ action: TabSwitcher.Action, onCard id: Tab.ID) {
        let switcher = tabSwitcher
        guard let tab = switcherTab(id) else { return }
        let partner = switcher.partners[id].flatMap(switcherTab)
        if switcherSpace(of: id) != nil {
            switch action {
            case .close:
                switcher.remove(id)
                for page in [tab, partner].compactMap({ $0 }) {
                    if page.pin != nil { page.rest() } else { closeParkedAgentTab(page) }
                }
                writeSession(now: true)
            case .reload:
                tab.reload()
                partner?.reload()
            case .mute:
                tab.toggleMute()
                partner?.toggleMute()
                switcher.redraw()
            }
            return
        }
        switch action {
        case .close:
            // A pin not on screen is put down where it is and keeps its
            // card, as ⌘W puts one down, without taking you anywhere; a tab
            // in a group is put away the same way (closeTab).
            if tab.pin != nil || putsAway(tab), id != activeID, partner == nil {
                tab.rest()
                writeSession(now: true)
                return switcher.redraw()
            }
            switcher.remove(id)
            close(tab)
            if let partner { close(partner) }
        case .reload:
            tab.reload()
            partner?.reload()
        case .mute:
            tab.toggleMute()
            partner?.toggleMute()
            switcher.redraw()
        }
    }

    /// A click while the switcher is up, at a point in the window's own
    /// top-left coordinates: on a card, that card; outside the panel, the
    /// switcher goes. True when the click was the switcher's. Taken before any
    /// view sees it, because ⌃ is held for as long as the switcher is up, and
    /// a ⌃-click is a right-click to AppKit, not a click the card's button
    /// can be counted on to take. From #358, by oddharsh.
    func clickTabSwitcher(at point: CGPoint) -> Bool {
        tabSwitcher.click(at: point) { commitTabSwitch(picking: $0) }
    }

    func commitTabSwitch(picking id: Tab.ID? = nil) {
        guard let target = tabSwitcher.finish(picking: id) else { return }
        if let tab = tabs.first(where: { $0.id == target }) { return select(entry(tab)) }
        guard let space = switcherSpace(of: target), let tab = switcherTab(target) else { return }
        if prefs.stacksSpaces { return stackedSelect(tab, in: space.id) }
        parked[space.id]?.active = target
        goToSpace(space.id)
    }

    /// A link opened from a page lands next to the page it came from, not at
    /// the far end of the row — unless it is one of a batch, which keeps the
    /// order it came in.
    ///
    /// `link`: opened out of a page by a click (⌘-click, the middle button):
    /// after the ones that page already opened (see placeForLink).
    ///
    /// `from`: the tab it was opened out of. A private one's opens private,
    /// in the same store, as a link that asks for a new window already does.
    ///
    /// `mayWait`: opened behind the page by hand, or one of a batch of links
    /// from another app. With Settings › Tabs › Load background tabs when
    /// you go to them, such a tab keeps its address and loads nothing until
    /// it is gone to, as a tab brought back from the last session does. A
    /// tab in front always loads, and so does one an extension opens, which
    /// may be waiting on its page.
    @discardableResult
    func knownTitle(for url: URL) -> String? {
        TitleSource.best(history: history.title(for: url), named: bookmarks.bookmark(for: url)?.title)
    }

    func open(_ url: URL, foreground: Bool, atEnd: Bool = false, from source: Tab? = nil, mayWait: Bool = false,
              link: Bool = false, front: Bool = false, title: String? = nil) -> Tab {
        // One of Search's own pages, from a link, a script or another app:
        // its own tab, one of each (see InternalPages.swift).
        if let own = InternalPage(url: url) { return show(own) }
        // An extension's own page is served only to a view built from that
        // extension's configuration.
        let url = Browser.page(url)
        let page = Browser.extensionConfiguration(for: url)
        // A new tab is in this window's space, with its sign-ins — not the
        // space of whichever window is in front, when this one is behind it.
        let tab = makeTab(configuration: page)
        prepare(tab)
        // A link opened from a grouped tab joins its group, only while groups
        // are on: turned off, they sleep, and nothing new goes into one.
        if prefs.usesTabGroups, let source, !tab.shy, !tab.bench {
            tab.groupID = meetingKeepsLoose(from: source, link: link) ? nil : source.groupID
            tab.bornIn = tab.groupID
        }
        if link, let source { tab.linkedFrom = source.id }
        tabs.insert(tab, at: atEnd ? tabs.count : front ? placeForFront() : link ? placeForLink(from: source) : placeForNew())
        if link, !atEnd, !foreground { noteLink(tab, from: source) }
        if foreground || link { noteReturn(tab, front: foreground, from: source, once: !link) }
        if mayWait, !foreground, prefs.lazyTabs, page == nil {
            tab.restore(url: url, title: TitleSource.best(history: knownTitle(for: url), named: title) ?? "")
        } else {
            tab.go(to: url, known: title)
        }
        if foreground {
            leaving()
            activeID = tab.id
            editing = false
            typed = ""
        } else {
            openedBehind(tab)
        }
        return tab
    }

    /// An extension's page sending its own tab to a website — 1Password's
    /// "Sign in" does, when its Mac app isn't connected. The page's view was
    /// built from the extension's configuration, which WebKit keeps to that
    /// extension's own pages, so the load went nowhere and the button did
    /// nothing. The tab is swapped where it stands for an ordinary one on
    /// the site: to the eye, the page went there. The other way round too:
    /// an extension sending a website's tab to one of its own pages.
    func replace(_ tab: Tab, going url: URL) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // A private tab stays private, and keeps its own sign-ins when it
        // had them; an extension's page it showed was in that extension's
        // store, so going back to the web takes a new private one.
        let page = Browser.extensionConfiguration(for: url)
        let fresh = makeTab(bench: tab.bench, configuration: page)
        // Preserve the sign-in popup's link to the page that opened it —
        // and, since a website can now start the swap, what you made of the
        // tab: a pinned one stays pinned, a named one keeps its name.
        fresh.opener = tab.opener
        fresh.popup = tab.popup
        fresh.pin = tab.pin
        // And it stays the same pin. With no id of its own it would be given
        // a new one, and every other window would close its tab for the old
        // pin and make a sleeping one for the new, losing the page it had
        // there; with no home, the page it was pinned at would become
        // wherever this swap went; and a pin every space shows would be
        // written back as this space's own (see writeSession).
        fresh.pinID = tab.pinID
        fresh.home = tab.home
        fresh.everywhere = tab.everywhere
        fresh.name = tab.name
        prepare(fresh)
        fresh.groupID = tab.groupID
        fresh.bornIn = tab.bornIn
        let wasActive = activeID == tab.id
        replaceSplitMember(tab.id, with: fresh.id)
        carryReturn(from: tab, to: fresh)
        tabs[index] = fresh
        fresh.go(to: url)
        if wasActive { activeID = fresh.id }
        tab.close()
        rememberSession()
    }

    /// An address from before extensions moved to chrome-extension://, as
    /// it is now; any other, as it is.
    static func page(_ url: URL) -> URL {
        return Extensions.current(url)
    }

    /// The extension an address belongs to, or nil for the web.
    static func extensionHost(of url: URL) -> String? {
        let url = Extensions.current(url)
        return url.scheme == Extensions.scheme ? url.host : nil
    }

    /// The configuration for an extension's page, or nil for anything else.
    static func extensionConfiguration(for url: URL) -> WKWebViewConfiguration? {
        let url = Extensions.current(url)
        guard url.scheme == Extensions.scheme else { return nil }
        return Extensions.shared.controller.extensionContext(for: url)?.webViewConfiguration
    }

    @discardableResult
    func benchOpen(_ url: URL) -> Tab {
        let url = Browser.page(url)
        let tab = makeTab(bench: true, configuration: Browser.extensionConfiguration(for: url))
        prepare(tab)
        tabs.append(tab)
        tab.go(to: url)
        return tab
    }

    func benchOpen(_ url: URL, space: UUID) -> Tab {
        let tab = makeTab(space: space, bench: true)
        prepare(tab)
        var row = parked[space] ?? loadRow(space)
        row.tabs.append(tab)
        parked[space] = row
        tab.go(to: Browser.page(url))
        return tab
    }

    /// A link from another app. A blank tab with nothing typed in it takes
    /// the page rather than staying behind as an empty one; otherwise the
    /// page gets a tab of its own, in front.
    func arrive(_ url: URL) {
        if let active, active.isBlank, typed.isEmpty, !active.floating {
            active.go(to: url)
            editing = false
        } else {
            open(url, foreground: true)
        }
    }

    /// A bookmark, or a page from a list of them: into the tab you are on,
    /// the way every bookmarks bar has ever worked — into a new one with ⌘
    /// held, or when the one you are on is busy playing in the float.
    func visit(_ url: URL) {
        let apart = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if let active, !apart, !active.floating {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: true, from: active)
        }
    }

    /// A bookmark, from the bar, the Bookmarks menu or a list of them: in a
    /// tab of its own, never in place of the one you are on (Drice: opened
    /// from a pin, it took the pin's place). An empty new tab is the one
    /// exception, since nothing is lost by using it. With ⌘ it opens behind.
    func openBookmark(_ url: URL) {
        let behind = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        if !behind, let active, active.isBlank || active.page?.kind == .bookmarks, active.pin == nil, !active.floating {
            active.go(to: url)
            editing = false
            typed = ""
        } else {
            open(url, foreground: !behind, from: active, mayWait: behind)
        }
    }

    /// A bookmark picked from the button's list or the full one. Either
    /// goes as the page starts: the list off the button used to stay open
    /// over the page it had just sent you to. A middle-click opens it in a
    /// new tab behind this one and leaves the list open for the next; with
    /// ⇧ it goes to the new tab, and the list closes.
    func pickBookmark(_ url: URL, inNewTab: Bool = false) {
        let foreground = !inNewTab || NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        if foreground {
            // From the Bookmarks tab, the bookmark opens in it, as Chrome's
            // manager does; Back comes back to the list.
            bookmarksOpen = false
        }
        if inNewTab {
            open(url, foreground: foreground, from: active, mayWait: true)
        } else {
            openBookmark(url)
        }
    }

    /// Pages in a window of their own, in this window's space, the first in
    /// front. The empty tab a new window starts with goes once they are in,
    /// as it does for a window an extension opens. Used, for one, by the
    /// bookmarks bar's Open in New Window and Open All in New Window.
    func openInNewWindow(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let fresh = Browser(record: WindowRecord(space: spaceID))
        for (index, url) in urls.enumerated() {
            fresh.open(url, foreground: index == 0, atEnd: true, mayWait: true)
        }
        for blank in fresh.tabs where blank.isBlank && !blank.bench { fresh.close(blank) }
        Browsers.open(fresh, frame: nil)
    }

    /// A page in a new tab, paired with the one on screen as a tab's Open in
    /// Split View pairs it. Used, for one, by the bookmarks bar's Open in
    /// Split View.
    func openInSplit(_ url: URL) {
        guard prefs.splitView else { return }
        openInSplit(open(url, foreground: false, from: active))
    }

    /// Pages in a tab group of their own, under `name`. A group made from a
    /// tab's menu opens with its name ready to be typed; this one is named
    /// already, so it doesn't. Used, for one, by the bookmarks bar's Open All
    /// in Tab Group.
    func openInTabGroup(_ urls: [URL], named name: String) {
        undoQuiet += 1
        defer { undoQuiet -= 1 }
        guard prefs.usesTabGroups, !urls.isEmpty else { return }
        let opened = urls.enumerated().map { index, url in
            open(url, foreground: index == 0, atEnd: true, mayWait: true)
        }
        let id = addTabGroup(containing: opened[0], pinned: true)
        renameTabGroup(id, to: name)
        editingGroupID = nil
        for tab in opened.dropFirst() { move(tab, toGroup: id) }
    }

    private func newPrivateTab() {
        if let blank = tabs.last(where: { $0.isBlank && !$0.bench && split(for: $0) == nil }) {
            placeBlank(blank)
            if activeID != blank.id { leaving() }
            noteReturn(blank, front: true, from: nil, once: true)
            activeID = blank.id
            summoning = false
            typed = ""
            blank.draft = ""
            editing = false
            focusRequest += 1
            return
        }
        let tab = makeTab()
        prepare(tab)
        tabs.insert(tab, at: placeForFront())
        leaving()
        noteReturn(tab, front: true, from: nil, once: true)
        activeID = tab.id
        summoning = false
        typed = ""
        editing = false
        focusRequest += 1
    }

    /// ⌘D. The same page, beside itself.
    func duplicate() {
        guard let url = active?.address else { return }
        open(url, foreground: true, from: active).bornIn = nil
    }

    /// ⌘⇧V, when nothing is being typed. What is in the clipboard, if it is a
    /// place — or a search — in the tab you're on.
    func pasteAndGo() {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = destination(for: text.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            refusals += 1
            return
        }
        (active ?? tabs.first)?.go(to: url)
        editing = false
        typed = ""
    }

    /// File › Export as PDF…. Unlike Print, this keeps the page's screen
    /// layout and takes its whole current length. WebKit splits only a page
    /// taller than a PDF page can be (200 inches).
    func exportPDF() {
        askWhereToSave(active, as: .pdf, ending: "pdf") { [weak self] tab, file in
            self?.exportPDF(tab, to: file)
        }
    }

    /// File › Save Page As…: the page with its pictures and styles in one
    /// web archive, as Safari's Save As makes it. It opens again in Search
    /// or Safari, offline too.
    func savePage() {
        askWhereToSave(active, as: .webArchive, ending: "webarchive") { [weak self] tab, file in
            self?.savePage(tab, to: file)
        }
    }

    /// The save panel for a page, named after its title (or its site), in
    /// Downloads.
    private func askWhereToSave(_ tab: Tab?, as type: UTType, ending: String, then save: @escaping (Tab, URL) -> Void) {
        guard let tab, tab.isWeb, let window = tab.web.window ?? self.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        let title = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stem = (title.isEmpty ? tab.pageAddress?.host() ?? "Page" : title)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = stem.lowercased().hasSuffix(".\(ending)") ? stem : stem + ".\(ending)"
        panel.directoryURL = downloadsFolder
        panel.beginSheetModal(for: window) { answer in
            guard answer == .OK, let file = panel.url else { return }
            save(tab, file)
        }
    }

    /// Keep the tab the save panel was opened for, even if another is active
    /// when it finishes. The bench passes the current tab without a panel.
    func exportPDF(_ tab: Tab, to file: URL, finished: ((Bool) -> Void)? = nil) {
        guard tab.isWeb else {
            finished?(false)
            return
        }
        tab.web.createPDF(configuration: WKPDFConfiguration()) { [weak self] result in
            do {
                let data = try result.get()
                try data.write(to: file, options: .atomic)
                self?.announce("Saved \(file.lastPathComponent)", file: file)
                finished?(true)
            } catch {
                self?.announce("Couldn't export page", kind: .error)
                finished?(false)
            }
        }
    }

    /// As exportPDF(_:to:finished:), for Save Page As….
    func savePage(_ tab: Tab, to file: URL, finished: ((Bool) -> Void)? = nil) {
        guard tab.isWeb else {
            finished?(false)
            return
        }
        tab.web.createWebArchiveData { [weak self] result in
            do {
                let data = try result.get()
                try data.write(to: file, options: .atomic)
                self?.announce("Saved \(file.lastPathComponent)", file: file)
                finished?(true)
            } catch {
                self?.announce("Couldn't save page", kind: .error)
                finished?(false)
            }
        }
    }

    /// ⌘P. The system's print sheet, where a paginated PDF can also be saved.
    func printPage() {
        guard let tab = active, tab.isWeb, let window = NSApp.keyWindow else { return }
        Browser.printing(tab.web).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    /// The print job for a page, or for one frame of it when WebKit names
    /// one: a page's own print() in a frame prints that frame, as in Safari.
    /// The frame's printing is outside the public framework, so it is asked
    /// for first, and a WebKit without it prints the whole page.
    static func printing(_ web: WKWebView, frame: AnyObject? = nil) -> NSPrintOperation {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let forFrame = NSSelectorFromString("_printOperationWithPrintInfo:forFrame:")
        let job: NSPrintOperation
        if let frame, web.responds(to: forFrame) {
            typealias Make = @convention(c) (AnyObject, Selector, NSPrintInfo, AnyObject) -> NSPrintOperation
            job = unsafeBitCast(web.method(for: forFrame), to: Make.self)(web, forFrame, info, frame)
        } else {
            job = web.printOperation(with: info)
        }
        job.view?.frame = web.bounds
        return job
    }

    /// A space's row as its session left it, made without touching the one
    /// on screen: tabs with an address and no page yet, which cost next to
    /// nothing until one is looked at (see Spaces.swift).
    func loadRow(_ space: UUID) -> Parked {
        let saved = readRow(space)
        var restored = restoreRow(saved, space: space, groups: saved.groups ?? [])
        // As restoreSession has it: nothing in front after a fresh start, so
        // the space opens on an empty tab beside its pins (see enter); and a
        // tab whose place no longer reads falls to the first that isn't a pin.
        if saved.active < 0 {
            restored.active = nil
        } else if restored.active == nil {
            restored.active = restored.tabs.first { $0.pin == nil }?.id ?? restored.tabs.first?.id
        }
        restored.groups = saved.groups
        return restored
    }

    private func restoreRow(_ saved: Session.Shape, space: UUID, groups: [TabGroup]) -> Parked {
        var row: [Tab] = []
        var bySavedIndex: [Int: Tab] = [:]
        for (savedIndex, entry) in saved.tabs.enumerated() {
            // An empty page is never written; the first builds of Split View
            // on main wrote one for an empty half.
            guard let saved = URL(string: entry.url), entry.url != "about:blank", !InternalPage.retired(saved) else { continue }
            // A row read from disk is a browser or window opened afresh: with
            // pins going home, a pin comes back at the page it was pinned at,
            // wherever it had been taken since.
            let home = Browser.home(of: entry, at: saved)
            let url = prefs.pinsGoHome ? home ?? saved : saved
            let tab = makeTab(space: space)
            prepare(tab)
            tab.restore(url: url, title: url == saved ? entry.title : url.host ?? "", name: entry.name)
            tab.cameBack = true
            // Never later than now: a clock set wrong once would keep the tab forever.
            if let touched = entry.touched { tab.touch(at: min(touched, Date())) }
            tab.letGo = entry.letGo.map { min($0, Date()) }
            tab.muted = entry.muted
            tab.pin = entry.pin
            tab.pinID = entry.pin == nil ? nil : entry.pinID
            tab.home = home
            tab.groupID = entry.pin == nil && groups.contains(where: { $0.id == entry.groupID })
                ? entry.groupID : nil
            tab.trimWords = tab.groupID == nil ? nil : entry.trim
            tab.liveKey = tab.groupID == nil ? nil : entry.live
            tab.customIcon = entry.icon
            if url == saved { tab.videoSpot = Resume.armed(entry.video, for: url) }
            row.append(tab)
            bySavedIndex[savedIndex] = tab
        }
        let said = bySavedIndex[saved.active]?.id
        row = reconcilePins(row, space: space)
        // Pairs, whether Split View is on or not: off, they wait, as groups
        // do. Each tab in one pair at most, and only a pair that still holds.
        var restoredSplits: [TabSplit] = []
        var taken = Set<Tab.ID>()
        for saved in saved.splits {
            let members = saved.tabs.compactMap { bySavedIndex[$0] }
            guard members.count == saved.tabs.count, !members.contains(where: { taken.contains($0.id) }) else { continue }
            let pair = TabSplit(tabs: members.map(\.id), axis: saved.axis, sizes: saved.sizes,
                                focused: saved.focused.flatMap { bySavedIndex[$0]?.id })
            guard Browser.holds(pair, in: row) else { continue }
            restoredSplits.append(pair)
            taken.formUnion(pair.tabs)
        }
        restoredSplits = pinSplits(row, keeping: restoredSplits, space: space)
        let active = said.flatMap { id in row.contains { $0.id == id } ? id : nil }
        return Parked(tabs: row, active: active, splits: restoredSplits)
    }

    /// Another space's row put on screen in place of this one (see
    /// Spaces.swift) — empty, for one that restores its own.
    /// `blank`: with nothing in front, an empty tab is, rather than the
    /// first of the row (see frontBlank).
    func showRow(_ row: [Tab], active: Tab.ID?, splits restored: [TabSplit] = [], blank: Bool = false) {
        splits = restored
        tabs = row
        if active == nil, blank { return frontBlank() }
        activeID = active ?? row.first?.id
    }

    private func replaceSplitMember(_ old: Tab.ID, with new: Tab.ID) {
        guard let index = splits.firstIndex(where: { $0.contains(old) }) else { return }
        splits[index].replace(old, with: new)
    }

    /// Where a new tab goes: beside the tab you are on — but never among the
    /// pins, which a new tab isn't one of: from a pin, it comes first after
    /// them. A link from another app, with a pin in front, landed between two
    /// (#219).
    func placeForNew() -> Int {
        guard prefs.newTabPlace == .next, let here = tabs.firstIndex(where: { $0.id == activeID }) else { return placeForFront() }
        let after = activeSplit.flatMap { pair in tabs.firstIndex { $0.id == pair.right } } ?? here
        return max(after + 1, pinnedCount)
    }

    /// Where ⌘T's tab goes, a private one, and a page a link opens in front
    /// of you: the end of the row, as always, unless the top was chosen.
    /// After current is for links opened from the tab you are on.
    func placeForFront() -> Int {
        prefs.newTabsAtBottom ? tabs.count : pinnedCount
    }

    /// Where a link opened behind its page goes — ⌘-click, the middle button,
    /// Open Link in New Tab — with After current: right after that page, and
    /// after the links it already opened, so a row of them reads in the order
    /// they were clicked, as in Safari, Chrome and Arc. Each went straight
    /// after the page, the last clicked first. The run ends when you go to
    /// another tab or the page goes somewhere else.
    /// In a group, the run stays in it; a pair is one place.
    func placeForLink(from source: Tab?, beside: Bool = false) -> Int {
        guard let source = source.flatMap({ source in tabs.first { $0.id == source.id } }) ?? active,
              let here = tabs.firstIndex(where: { $0.id == source.id }) else { return placeForNew() }
        let joins = prefs.usesTabGroups && source.groupID != nil && !source.shy
        guard beside || joins || prefs.newTabPlace == .next else { return placeForFront() }
        var anchor = here
        if let run = linkRun, run.opener == source.id,
           let last = tabs.firstIndex(where: { $0.id == run.last }), last > here,
           tabs[last].groupID == source.groupID {
            anchor = last
        }
        let after = split(for: tabs[anchor]).flatMap { pair in tabs.firstIndex { $0.id == pair.right } } ?? anchor
        return max(after + 1, pinnedCount)
    }

    /// A link just opened behind `source`: the next one goes after it.
    private func noteLink(_ tab: Tab, from source: Tab?) {
        guard let source, tabs.contains(where: { $0.id == source.id }) else { return }
        linkRun = LinkRun(opener: source.id, last: tab.id)
    }

    private func placeBlank(_ tab: Tab) {
        guard let from = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let to = placeForFront()
        // Moving an existing tab removes its old slot before inserting it.
        move(tab, to: from < to ? to - 1 : to)
    }

    /// A tab made outside the row — a peek being kept — put in it at `index`.
    func insert(_ tab: Tab, at index: Int) {
        tabs.insert(tab, at: safeInsertionIndex(index))
        rememberSession()
    }

    private func safeInsertionIndex(_ proposed: Int) -> Int {
        let index = min(max(0, proposed), tabs.count)
        guard index < tabs.count, split(for: tabs[index]).map({ $0.left != tabs[index].id }) == true else { return index }
        return index + 1
    }

    func makeTab(space: UUID? = nil, bench: Bool = false, configuration: WKWebViewConfiguration? = nil) -> Tab {
        if let privateStore {
            return Tab(shy: true, bench: bench, configuration: configuration ?? Web.configuration(shy: true, store: privateStore))
        }
        let made = Tab(bench: bench, configuration: configuration ?? Web.configuration(space: space ?? spaceID))
        made.space = space ?? spaceID
        return made
    }

    func spaceOf(_ tab: Tab) -> UUID? {
        guard !tab.shy else { return nil }
        if tabs.contains(where: { $0 === tab }) { return spaceID }
        return parked.first { $0.value.tabs.contains { $0 === tab } }?.key ?? tab.space
    }

    func openSpaceLanguages(_ id: UUID) {
        settingsPage = .general
        settingsLanguages = id
        _ = show(InternalPage(.settings))
    }

    private func adopt(_ tab: Tab) {
        prepare(tab)
        tabs.append(tab)
        if activeID == nil { activeID = tab.id }
    }

    /// Stepping away from a tab. A video you were watching does not stop
    /// existing because you went to look something up.
    func leaving() {
        guard prefs.floatsOnLeave else { return }
        if liftCall(active) || liftCall(otherPane) { return }
        guard floatsOnItsOwn else { return }
        lift(active, quietly: true, otherwise: otherPane)
    }

    var floatsOnItsOwn: Bool { !isPrivate }

    @discardableResult
    func liftCall(_ tab: Tab?) -> Bool {
        guard let tab, !tab.agent, tab.isWeb, !tab.asleep, onCall(tab), tab.web.fullscreenState == .notInFullscreen,
              !CallFloat.shared.showing, !CallFloat.shared.keepsAway(tab) else { return false }
        if floater.showing { land() }
        guard CallFloat.shared.lift(tab, from: self) else { return false }
        floating = tab.id
        tab.floating = true
        return true
    }

    private func landCall(_ tab: Tab) {
        CallFloat.shared.drop()
        floating = nil
        tab.floating = false
        DispatchQueue.main.async { [weak self, weak tab] in
            MainActor.assumeIsolated {
                guard let self, let tab, self.tabs.contains(where: { $0.id == tab.id }),
                      !self.visibleTabIDs.contains(tab.id) else { return }
                self.liftCall(tab)
            }
        }
    }

    /// With a pair on screen, its other page: what floats when the focused
    /// one has nothing playing.
    private var otherPane: Tab? {
        guard let pair = activeSplit, let id = activeID else { return nil }
        return tabs.first { $0.id == pair.partner(of: id) }
    }

    func appLeft() {
        lookAgain(after: 0.3, then: [0.5, 1])
    }

    func appBack() {
        lookAgain(after: 0.1, then: [0.4, 1])
    }

    func sightChanged() {
        lookAgain(after: 0.15, then: [0.4, 1])
    }

    func lookAgain(after delay: Double, then later: [Double] = []) {
        sightLook?.cancel()
        let look = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let was = self.outOfSight
                self.judgeSight()
                if let next = later.first, self.outOfSight == was { self.lookAgain(after: next, then: Array(later.dropFirst())) }
            }
        }
        sightLook = look
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: look)
    }

    func judgeSight() {
        let seen = videoSeen()
        if seen {
            guard outOfSight else { return }
            outOfSight = false
            defer { liftedAway = false }
            if liftedAway, let id = floating, id == activeID { land() }
            if liftedAway, let id = pictured, id == activeID { unpicture() }
            return
        }
        guard prefs.floatsAway, !outOfSight, !shut else { return }
        outOfSight = true
        liftedAway = !floater.showing && pictured == nil
        if liftCall(active) || liftCall(otherPane) { return }
        guard floatsOnItsOwn else {
            liftedAway = false
            return
        }
        lift(active, quietly: true, otherwise: otherPane)
    }

    private func videoSeen() -> Bool {
        if let sightForBench {
            sightJudged = ["bench": sightForBench]
            return sightForBench
        }
        guard let window else {
            sightJudged = ["window": false]
            return false
        }
        let shown = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        let covered = shown ? sightBox(in: window).map { Sight.covered($0, above: window) } : nil
        sightJudged = ["shown": shown, "covered": covered ?? NSNull()]
        return shown && (covered ?? 0) < Sight.most
    }

    private func sightBox(in window: NSWindow) -> NSRect? {
        if let id = floating, tabs.contains(where: { $0.id == id }), let root = window.contentView {
            func stages(in view: NSView) -> [StageView] {
                (view as? StageView).map { [$0] } ?? view.subviews.flatMap(stages)
            }
            guard let stage = stages(in: root).filter({ !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width > 0 })
                .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) else { return nil }
            let box = window.convertToScreen(stage.convert(stage.bounds, to: nil))
            guard let part = floatPicture, part.width > 0, part.height > 0 else { return box }
            return NSRect(
                x: box.minX + part.minX * box.width,
                y: box.maxY - part.maxY * box.height,
                width: part.width * box.width,
                height: part.height * box.height
            ).intersection(box)
        }
        let playing = [active, otherPane].compactMap { $0 }.first { $0.isWeb && ($0.noisy || $0.muted) } ?? active
        guard let web = playing?.web, web.window === window, !web.isHiddenOrHasHiddenAncestor, web.bounds.width > 0 else { return nil }
        return window.convertToScreen(web.convert(web.bounds, to: nil))
    }

    /// ⌘⇧P, for lifting one out by hand.
    func toggleFloat() {
        if floater.showing {
            land()
            return
        }
        if prefs.floatStyle == .system {
            picture(active, quietly: false, toggle: true, otherwise: otherPane)
            return
        }
        lift(active, quietly: false, otherwise: otherPane)
    }

    /// The video playing in `tab` into picture in picture (NativePiP).
    /// `toggle`: ⇧⌘P, which also brings one back.
    private func picture(_ tab: Tab?, quietly: Bool, toggle: Bool = false, otherwise: Tab? = nil) {
        guard let tab, !tab.isBlank, !tab.asleep, tab.web.fullscreenState == .notInFullscreen else {
            if let otherwise { picture(otherwise, quietly: quietly, toggle: toggle) }
            return
        }
        if quietly, !Players.knows(tab.address) || tab.pageAddress?.host().map(Grounded.holds) == true || tab.sound.role == .mini {
            if let otherwise { picture(otherwise, quietly: quietly, toggle: toggle) }
            return
        }
        tab.web.evaluateInSearch(NativePiP.script(toggle: toggle)) { [weak self, weak tab] answer in
            MainActor.assumeIsolated {
                guard let self, let tab else { return }
                switch answer as? String {
                case "in": self.pictured = tab.id
                case "out": if self.pictured == tab.id { self.pictured = nil }
                case "refused": if !quietly { self.announce("This page keeps its video to itself") }
                default:
                    if let otherwise { return self.picture(otherwise, quietly: quietly, toggle: toggle) }
                    if !quietly { self.announce("Nothing is playing here") }
                }
            }
        }
    }

    /// Back into its tab, from macOS's picture in picture.
    func unpicture() {
        guard let id = pictured else { return }
        pictured = nil
        (tabs + parkedTabs).first { $0.id == id }?.web.evaluateInSearch(NativePiP.off)
    }

    /// The button at the top right of macOS's picture in picture, back to the
    /// video. WebKit puts it back into its page only once that page is seen,
    /// and the page is most often a tab behind another one, or behind another
    /// app: until someone shows it, the button did nothing. Its tab comes to
    /// the front, in its window, with Search, and the tab you were on keeps
    /// its own video where it is rather than taking the window's place.
    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        guard let tab = tab(for: webView) ?? parkedTabs.first(where: { $0.built === webView }) else { return }
        if pictured == tab.id { pictured = nil }
        if let space = space(holding: tab.id) { enter(space) }
        select(tab, floatPrevious: false)
        Browsers.show(self)
        NSApp.activate()
    }

    func pictureCame(_ tab: Tab) {
        guard let miss = floatMiss, miss.tab == tab.id, !miss.trying else { return }
        guard miss.fresh() else {
            floatMiss = nil
            return
        }
        floatMiss?.trying = true
        guard prefs.floatStyle != .system, !floater.showing, floating == nil, !CallFloat.shared.showing else { return }
        if miss.quietly {
            guard prefs.floatsOnLeave || prefs.floatsAway, !visibleTabIDs.contains(tab.id) || outOfSight else { return }
        }
        lift(tab, quietly: miss.quietly)
    }

    /// Everything but the video goes out of the way, and the page it lives in
    /// moves house — into a small window that stays above everything.
    /// `otherwise`: the other page of a pair, tried when this one has
    /// nothing playing.
    private func lift(_ tab: Tab?, quietly: Bool, otherwise: Tab? = nil) {
        if quietly, let tab, tab.agent || CallFloat.shared.keepsAway(tab) || tab.sound.role == .mini {
            if let otherwise { lift(otherwise, quietly: quietly) }
            return
        }
        if prefs.floatStyle == .system { return picture(tab, quietly: quietly, otherwise: otherwise) }
        // A tab just put down with ⌘W has no page to lift a video out of, and
        // asking it would only build an empty view to ask.
        guard let tab, tab.isWeb, !tab.asleep, !floater.showing else {
            if let otherwise { lift(otherwise, quietly: quietly) }
            return
        }
        guard !CallFloat.shared.showing else {
            if !quietly { announce("A call is floating") }
            return
        }
        // A video filling the screen stays in its own space, as in Safari.
        // Its page is lent to WebKit's full-screen window, and moving it out
        // into the floating one left that window up, empty and black, to
        // come back to.
        guard tab.web.fullscreenState == .notInFullscreen else { return }
        if quietly, tab.pageAddress?.host().map(Grounded.holds) == true {
            if let otherwise { lift(otherwise, quietly: quietly) }
            return
        }
        let strict = quietly && !Players.knows(tab.address)
        if strict, !tab.noisy, !tab.muted {
            floatMiss = FloatMiss(tab: tab.id, quietly: true, since: floatMiss)
            if let otherwise { lift(otherwise, quietly: quietly) }
            return
        }
        // A picture of the page as it is, asked for in the same breath as the
        // isolation and before it: the page's process answers in the order
        // it is asked, so the picture is of the page before anything moved.
        // Isolating only once the picture is back would be a tenth of a
        // second late, and a muted video, which WebKit stops when nobody can
        // see it, might no longer be playing. The video's frame in the
        // picture covers the little window, and the whole of it the tab when
        // the video lands, each until the page has settled there.
        //
        // At no more than a million and a bit pixels, the size of the page in
        // points or less: WebKit paints a picture of a page on the processor,
        // and one of the whole page at a Retina screen's size took half a
        // second (YouTube, 1412×728 points: 480 ms; 110 ms at one pixel a
        // point). The video's frame is cut from it at about the little
        // window's size anyway, and the tab's picture is up for a moment.
        let shape = tab.web.bounds.size
        let fine = tab.web.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let most = (1_200_000 * shape.width / max(shape.height, 1)).squareRoot()
        let picture = WKSnapshotConfiguration()
        picture.afterScreenUpdates = false
        picture.snapshotWidth = NSNumber(value: Double(min(shape.width, most) / fine))
        var shot: NSImage??
        var found: (answer: Any?, frame: WKFrameInfo?)?
        // Going to another tab, the stage holds on to this page, unseen,
        // until it is in the little window or has nothing to float.
        let stage = tab.web.superview as? StageView
        stage?.keep(tab.web)
        func both() {
            guard let shot, let found else { return }
            lifted(tab, shot: shot, found: found.answer, frame: found.frame, quietly: quietly, otherwise: otherwise)
            stage?.letGo(tab.web)
        }
        tab.web.takeSnapshot(with: picture) { image, _ in
            MainActor.assumeIsolated {
                shot = .some(image)
                both()
            }
        }
        isolate(tab, strict: strict) { answer, frame in
            found = (answer, frame)
            both()
        }
    }

    private func isolate(_ tab: Tab, strict: Bool, then: @escaping (Any?, WKFrameInfo?) -> Void) {
        let web = tab.web
        func floats(_ answer: Any?) -> Bool { (answer as? [String: Any])?["floating"] as? Bool == true }
        var first: Any?
        func frames(_ left: [WKFrameInfo]) {
            guard let frame = left.first else { return then(first, nil) }
            let rest = Array(left.dropFirst())
            web.evaluateJavaScript(FloatFind.look(strict: strict), in: frame, in: Web.world) { seen in
                MainActor.assumeIsolated {
                    guard let path = FloatFind.sizeable(try? seen.get(), in: web, strict: strict) else { return frames(rest) }
                    web.evaluateJavaScript(Isolate.on, in: frame, in: Web.world) { inner in
                        MainActor.assumeIsolated {
                            guard floats(try? inner.get()) else { return frames(rest) }
                            web.evaluateInSearch(FloatFind.carry(path)) { answer in
                                MainActor.assumeIsolated {
                                    guard floats(answer) else {
                                        web.evaluateJavaScript(Isolate.off, in: frame, in: Web.world) { _ in }
                                        return frames(rest)
                                    }
                                    then(answer, frame)
                                }
                            }
                        }
                    }
                }
            }
        }
        let inFrames = Array(tab.mediaFrames.reversed())
        guard strict else {
            web.evaluateInSearch(Isolate.on) { answer in
                MainActor.assumeIsolated {
                    first = answer
                    if floats(answer) || inFrames.isEmpty { return then(answer, nil) }
                    frames(inFrames)
                }
            }
            return
        }
        web.evaluateInSearch(FloatFind.look(strict: true)) { seen in
            MainActor.assumeIsolated {
                guard FloatFind.sizeable(seen, in: web, strict: true) != nil else { return frames(inFrames) }
                web.evaluateInSearch(Isolate.on) { answer in
                    MainActor.assumeIsolated {
                        if floats(answer) || inFrames.isEmpty { return then(answer, nil) }
                        frames(inFrames)
                    }
                }
            }
        }
    }

    /// The page isolated, or not, and pictured as it was before: into the
    /// little window, or on to the other page of a pair.
    private func lifted(_ tab: Tab, shot: NSImage?, found answer: Any?, frame: WKFrameInfo?, quietly: Bool, otherwise: Tab?) {
        guard let found = answer as? [String: Any], found["floating"] as? Bool == true else {
            let loading = answer as? String == "loading" || tab.soundFrames.values.contains { $0.report.undecided }
            if quietly || loading { floatMiss = FloatMiss(tab: tab.id, quietly: quietly, since: floatMiss) }
            if let otherwise { return lift(otherwise, quietly: quietly) }
            if !quietly { announce(loading ? "The video is still loading. It floats once it shows." : "Nothing is playing here") }
            return
        }
        if floatMiss?.tab == tab.id { floatMiss = nil }
        // Out again before it had settled in its tab: the page isn't as it
        // was left yet, and the picture from the first time still is.
        var left = shot
        if landed?.tab == tab.id {
            left = landed?.picture
            landing.end()
        }
        leftAs = left.map { (tab.id, $0) }
        let box = (found["picture"] as? [NSNumber] ?? []).map(\.doubleValue)
        let page = (found["page"] as? [NSNumber] ?? []).map(\.doubleValue)
        floatPicture = box.count == 4 && page.count == 2 && page[0] > 0 && page[1] > 0
            ? CGRect(x: box[0] / page[0], y: box[1] / page[1], width: box[2] / page[0], height: box[3] / page[1])
            : nil
        floating = tab.id
        floatFrame = frame
        tab.floating = true
        ownFloater()
        let still = shot.flatMap { shot in
            Float.still(
                of: shot,
                picture: (found["picture"] as? [NSNumber] ?? []).map(\.doubleValue),
                page: (found["page"] as? [NSNumber] ?? []).map(\.doubleValue)
            )
        }
        floater.lift(tab.web, still: still)
    }

    private func inFloat(_ tab: Tab, _ js: String, search: Bool = false, then: ((Any?) -> Void)? = nil) {
        tab.web.evaluateJavaScript(js, in: floatFrame, in: search ? Web.world : .page) { result in
            MainActor.assumeIsolated { then?(try? result.get()) }
        }
    }

    private func floatHome() -> NSRect? {
        guard let id = landed?.tab, id == activeID,
              let tab = tabs.first(where: { $0.id == id }),
              let window, window.isVisible, window.isOnActiveSpace, !window.isMiniaturized,
              let root = window.contentView
        else { return nil }
        func stages(in view: NSView) -> [StageView] {
            (view as? StageView).map { [$0] } ?? view.subviews.flatMap(stages)
        }
        let place: NSView
        if tab.web.window === window, !tab.web.isHiddenOrHasHiddenAncestor, tab.web.bounds.width > 0 {
            place = tab.web
        } else if let stage = stages(in: root).filter({ !$0.isHiddenOrHasHiddenAncestor })
            .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
            place = stage
        } else {
            return nil
        }
        let box = window.convertToScreen(place.convert(place.bounds, to: nil))
        guard let part = floatPicture, part.width > 0, part.height > 0 else { return box }
        return NSRect(
            x: box.minX + part.minX * box.width,
            y: box.maxY - part.maxY * box.height,
            width: part.width * box.width,
            height: part.height * box.height
        ).intersection(box)
    }

    /// Back into its tab. The stage takes the page again on its next layout,
    /// which is what the self-healing there is for.
    ///
    /// The tab shows the page as it was left until the page is that again
    /// (see Isolate.off). Put back as it comes, it showed the video alone at
    /// the little window's size, then the page around it, then the video
    /// growing into its place. `covering`: false for a tab on its way out,
    /// with nobody to see it land.
    func land(covering: Bool = true) {
        if CallFloat.shared.owner === self, let call = CallFloat.shared.tab {
            landCall(call)
            return
        }
        // Another window's video: that window takes it back.
        if floating == nil, let owner = Browsers.all.first(where: { $0 !== self && $0.floating != nil }) {
            return owner.land(covering: covering)
        }
        // The window closes whatever else is true. Tying that to the bookkeeping
        // is how a little window outlives the thing that opened it.
        if floater.showing { floater.drop() }
        let left = leftAs
        leftAs = nil
        guard let tab = floatingTab else { return }
        let id = tab.id
        floating = nil
        // One landing at a time: one still settling elsewhere is uncovered now.
        landing.end()
        if covering, let left, left.tab == id {
            tab.cover(with: left.picture)
            landed = left
        }
        tab.floating = false
        tab.web.evaluateInSearch(Isolate.off)
        if let frame = floatFrame { tab.web.evaluateJavaScript(Isolate.off, in: frame, in: Web.world) { _ in } }
        floatFrame = nil
        guard landed != nil else { return }
        landing.watch(tab.web, within: 1.5) { [weak self, weak tab] in
            guard let self, let landed = self.landed else { return }
            self.landed = nil
            tab?.uncover(landed.picture)
        }
    }

    func prepare(_ tab: Tab) {
        tab.delegate = self
        wireBack(tab)
        tab.knowsTitle = { [weak self] url in self?.knownTitle(for: url) }
        // With two pages up, the keys going to the other one — Tab walked
        // past the last field of this one — make it the focused page, so the
        // outline, ⌘L and the site card follow what is being typed into.
        tab.onKeys = { [weak self] tab in
            guard let self, let pair = activeSplit, pair.contains(tab.id), activeID != tab.id else { return }
            focusPane(tab)
        }
        tab.onLink = { [weak self] tab, address in
            guard let self, prefs.showsLinks, visibleTabIDs.contains(tab.id) else { return }
            linkStatus.show(address, over: tab.built, space: spaceID, privateTab: tab.shy)
        }
        tab.onPick = { [weak self] tab, selector, label, note in
            guard let self, let host = curtain.host(of: tab.address) else { return }
            // A private tab writes nothing down, hidden.json included: taken
            // off this page only.
            if tab.shy {
                passingVeils[tab.id, default: []].append(selector)
                tab.applyVeils(curtain.css(on: host) + passingCSS(tab.id))
                announce("Hidden on this page. ⌘Z puts it back.")
                return
            }
            curtain.hide(selector, label: label, note: note, on: host)
            let css = curtain.css(on: host)
            tab.arm(hiding: css)
            tab.applyVeils(css)
            announce("Hidden. ⌘Z puts it back.")
        }
        tab.onPickEnd = { [weak self] _ in self?.veiling = false }
        tab.onImageText = { [weak self] tab, url in self?.copyImageText(at: url, in: tab) }
        tab.onImageMenu = { [weak self] tab, url in self?.showImageMenu(for: tab, at: url) }
        tab.onImageItem = { [weak self] tab, url, copy in
            guard let self, let web = tab.built else { return }
            if copy { copyImage(at: url, in: tab) } else { downloadImage(at: url, from: web) }
        }
        tab.searchName = { [weak self] in self.map { $0.prefs.engine.name(custom: $0.prefs.customEngine) } }
        tab.onSearch = { [weak self] tab, text in
            guard let self, let url = self.searchURL(for: text) else { return }
            // From a private tab, the search is private too (see open(_:foreground:atEnd:from:)).
            self.open(url, foreground: true, from: tab)
        }
        tab.onStoreAdd = { [weak self] tab in self?.addFromStore(tab) }
        tab.onPullState = { [weak self] tab, url, state in self?.livePullState(tab, at: url, said: state) }
        tab.onPageActed = { [weak self] tab, url in self?.liveTouch(tab, at: url, .acted) }
        tab.onAddress = { [weak self] tab, url in self?.liveMoved(tab, at: url) }
        // The middle button on a link opens it beside the tab you are on, as
        // it does in every other browser (see MiddleRelay).
        // From a private tab, the new one is private too, as for ⌘-click.
        tab.onMiddleClick = { [weak self] tab, url in self?.openClicked(url, foreground: false, from: tab, view: tab.built) }
        tab.onCross = { [weak self] tab, url in self?.replace(tab, going: url) }
        tab.onFileLink = { [weak self] tab, url, blank in
            if blank { self?.open(url, foreground: true, from: tab) } else { tab.go(to: url) }
        }

        // The caret in a sign-in box: the accounts kept for this site hang
        // from the box, and go when the caret does. Nothing is filled on
        // its own — the way Safari does it, and what a person expects.
        tab.onSnippetFocus = { [weak self, weak tab] in
            guard let self, let tab, self.active?.id == tab.id, self.fieldShowing,
                  self.fieldPlace == .snippets || SnippetStore.shared.isQuery(self.typed) else { return }
            self.retype()
        }
        tab.onField = { [weak self] tab, spot, passwords, name, wide in
            self?.hang(from: tab, spot, passwords: passwords, name: name, wide: wide)
        }

        tab.onFormEvent = { [weak self] tab, event in self?.forms.heard(event, from: tab) }

        tab.onCredentials = { [weak self] tab, host, user, password, clear, port in
            // an extension's own page isn't a site: Bitwarden's unlock pin was offered as its password.
            guard let self, prefs.savesPasswords, !password.isEmpty, !tab.shy,
                  !Vault.isNever(host), tab.address.flatMap(Browser.extensionHost(of:)) == nil
            else { return }
            // A password manager extension that asked Chrome's way to do the
            // saving itself.
            if Extensions.shared.passwordSavingTakenBy != nil { return }
            if strongPasswordSent(tab, host: host, user: user, password: password) { return }
            let sent = SentSignIn(host: host, user: user, password: password, port: port)
            let marks = [tab.appleFill, tab.keptFill]
            let tabID = tab.id
            Task { [weak self] in
                guard let offer = await SavedAlready.offer(for: sent, marks: marks, clear: clear),
                      let self, offering != offer
                else { return }
                offeringTab = tabID
                offering = offer
            }
        }
        tab.onPickTrouble = { [weak self] _, _ in
            self?.announce("Couldn't hide that", kind: .error)
        }

        // The line at the bottom doubles as the zoom read-out: it keeps being
        // rewritten while you pinch and fades a moment after you stop.
        tab.onZoom = { [weak self] _, value in
            guard let self else { return }
            let percent = Int((value * 100).rounded())
            guard percent != zoomShown else { return }
            zoomShown = percent
            announce("\(percent)%")
        }

        // A page's title lands a beat after the page itself, and a history
        // entry that only ever holds an address is half a memory.
        // Anywhere a tab lands is worth remembering for next launch.
        kitObserve(initial: false, { [weak tab] in tab?.address }) { [weak self] _ in self?.rememberSession() }
            .store(in: &bag)

        kitObserve(initial: false, { [weak tab] in tab?.muted }) { [weak self] _ in self?.rememberSession() }
            .store(in: &bag)

        kitObserve(initial: false, { [weak tab] in tab?.address }) { [weak self, weak tab] _ in
            if let tab { self?.noteMeetingPage(tab) }
        }
        .store(in: &bag)

        kitObserve(initial: false, { [weak tab] in tab?.title ?? "" }) { [weak self, weak tab] title in
                if let tab { self?.noteMeetingPage(tab) }
                // A translated title is the page's in your words, not its own:
                // history keeps the page's (Translate.swift).
                guard let tab, !tab.shy, !tab.agent, tab.translator == nil, let url = tab.address else { return }
                self?.history.retitle(url, title)
            }
            .store(in: &bag)
    }

    /// Put the cursor back in the field, from wherever asked.
    func askFocus() { focusRequest += 1 }

    /// A key typed between ⌘T and the field taking the keys, kept for it.
    ///
    /// The field comes a turn or two of the run loop after it is asked for —
    /// later still with Split View, where it waits for the stage to say where
    /// the page is — and a hand already typing got there first: the first
    /// letter or two went to the page being left, or nowhere. Held for half
    /// a second at most, and only typing: a key with ⌘ or ⌃ is a shortcut.
    func holdKey(_ event: NSEvent) -> Bool {
        guard let asked = focusAsked, CACurrentMediaTime() - asked < 0.5,
              fieldShowing, editingTab == nil,
              event.modifierFlags.intersection([.command, .control]).isEmpty
        else { return false }
        if heldKeys.isEmpty {
            // The field never came: what was typed goes where it would have.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.heldKeys.isEmpty else { return }
                self.focusAsked = nil
                self.letGo(in: event.window)
            }
        }
        heldKeys.append(event)
        return true
    }

    /// The field has the keys: what was held goes to it, in order.
    func fieldFocused(in window: NSWindow) {
        if fieldTimes.focused == nil { fieldTimes.focused = CACurrentMediaTime() }
        focusAsked = nil
        letGo(in: window)
    }

    private func letGo(in window: NSWindow?) {
        let held = heldKeys
        heldKeys = []
        // Straight to the window, which hands a key to whatever has the
        // keys: not back through the app, whose monitor would hold it again.
        for event in held { window?.sendEvent(event) }
    }

    // MARK: - guessing

    /// ⌘K again, with ⌘ still down: one step further down the list.
    func stepSummon() {
        cycling = true
        walk(1)
    }

    /// ⌘ let go of: take whatever the walk landed on.
    func landSummon() {
        guard cycling else { return }
        cycling = false
        guard picked != nil else { return }
        submit()
    }

    /// ⌘K. Only what is open, nothing else.
    func summon() {
        reviewing = false
        cancelTabEdit()
        launching = false
        fieldPlace = nil
        summoning = true
        typed = ""
        editing = true
        focusRequest += 1
    }

    func retype() { guess() }

    private func guess() {
        guessedAt = CACurrentMediaTime()
        snippetField.reset()
        pointer.rest()
        pointed = nil
        pageQuestion?.cancel()
        var offeredPlace: FieldPlace?
        defer { if placeOffer != offeredPlace { placeOffer = offeredPlace } }
        // Only a plain field asks the engine (see askEngine, at the end).
        if summoning || siteChip != nil || fieldPlace != nil || typed.trimmingCharacters(in: .whitespaces).isEmpty {
            suggester.stop()
            engineWords = ("", [])
        }
        fieldSections = []
        guard !summoning else {
            offers = openPages(matching: typed)
            ending = nil
            // The most recent page is already chosen, so ⌘K then Return is the
            // whole gesture.
            picked = offers.isEmpty ? nil : 0
            return
        }

        // A site in the field: only its search, for what is typed after it.
        if let site = siteChip {
            siteOffer = nil
            ending = nil
            picked = nil
            let words = typed.trimmingCharacters(in: .whitespaces)
            offers = words.isEmpty ? [] : site.url(for: words).map {
                [Suggestion(key: words, title: site.name, url: $0, kind: .search)]
            } ?? []
            return
        }

        if let place = fieldPlace {
            siteOffer = nil
            ending = nil
            if place == .snippets {
                addSnippetPlaceRows()
                return
            }
            offers = placeRows(place, matching: typed)
            picked = offers.isEmpty ? nil : 0
            return
        }

        guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
            (offers, fieldSections) = homeOffers()
            ending = nil
            picked = nil
            siteOffer = nil
            return
        }
        offeredPlace = FieldPlace.offered(for: typed)
        // "red": Reddit's search, a Tab away.
        let site = offeredPlace == nil && prefs.searchesSites && !summoning
            ? SiteSearch.match(typed) { [history] in history.visits(to: $0.map(\.host)) }
            : nil
        if siteOffer != site { siteOffer = site }

        if typed == active?.shownURL?.absoluteString {
            (offers, fieldSections) = pageActionRows()
            ending = nil
            picked = nil
            return
        }

        (offers, ending) = placeOffers(for: typed)
        // A row that was picked stops being the right row the moment the
        // question changes.
        picked = nil
        addFieldRows()
        addAnswerRow()
        addSnippetRows()
        askPages()
        askEngine()
    }

    // MARK: - the engine's suggestions

    /// The question this field may ask the engine, or nil when it may not:
    /// the switch off, a private tab, ⌘K, a site or a shortcut in charge,
    /// or words that look like anything but a search.
    func engineQuestion(for typed: String) -> URL? {
        guard prefs.engineSuggests, !summoning, siteChip == nil, fieldPlace == nil, active?.shy != true,
              FieldAnswers.answer(for: typed) == nil,
              !FieldCurrency.isQuery(typed),
              !SnippetStore.shared.isQuery(typed),
              issueRef(for: typed) == nil,
              EngineSuggest.sendable(typed),
              Keyword.match(typed, in: prefs.keywords) == nil
        else { return nil }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return EngineSuggest.url(for: words, engine: prefs.engine, test: EngineSuggest.testEndpoint)
    }

    private func askEngine() {
        guard let question = engineQuestion(for: typed) else {
            suggester.stop()
            engineWords = ("", [])
            return
        }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // Until the answer: last time's words that still begin with these.
        let lower = words.lowercased()
        let places = Set(offers.map { $0.key.lowercased() })
        let still = engineWords.words.filter {
            $0.lowercased().hasPrefix(lower) && $0.lowercased() != lower && !places.contains($0.lowercased())
        }
        if !still.isEmpty { offers += engineOffers(still) }
        suggester.ask(question, words: words) { [weak self] answer in
            guard let self else { return }
            // Typed on since, or the field gone: nothing to answer.
            guard self.typed.trimmingCharacters(in: .whitespacesAndNewlines) == words,
                  self.fieldShowing, self.engineQuestion(for: self.typed) != nil
            else { return }
            let mine = self.offers.filter { $0.kind != .suggested }
            // A row of the engine's that the arrow keys are on stays put.
            if let picked = self.picked, picked >= mine.count { return }
            self.engineWords = (words, answer)
            let places = Set(mine.map { $0.key.lowercased() })
            self.offers = mine + self.engineOffers(answer.filter { !places.contains($0.lowercased()) })
        }
    }

    private func engineOffers(_ words: [String]) -> [Suggestion] {
        words.prefix(EngineSuggest.most).compactMap { word in
            searchURL(for: word).map { Suggestion(key: word, title: "", url: $0, kind: .suggested) }
        }
    }

    /// What an address field offers for what is typed in it, and the rest of
    /// the address it would complete to: ⌘L's field and the one in the tab
    /// ask the same question (#534).
    func placeOffers(for typed: String) -> (offers: [Suggestion], ending: String?) {
        // Three places and, if it can't be a place, a search. No open pages:
        // ⌘K exists for those, and mixing them in here made the list long
        // enough that reading it cost more than typing the address would have.
        //
        // Your bookmarks first, by name or address, then where you have been
        // (idea 417): a bookmark is a place you chose to keep. One place of
        // history stays if it has one, the front door the field completes
        // towards, and a page that is both is one row, the bookmark's.
        let visited = history.suggestions(for: typed, limit: 3)
        var list: [Suggestion] = []
        var seen = Set<String>()
        func add(_ place: Suggestion) {
            if list.count < 3, seen.insert(History.identity(for: place.url)).inserted { list.append(place) }
        }
        let front = visited.first.map { History.identity(for: $0.url) }
        for kept in bookmarks.places(for: typed, limit: 3) {
            if list.count == 2, let front, !seen.contains(front), History.identity(for: kept.url) != front { break }
            add(kept)
        }
        visited.forEach(add)
        // Last in the list, and only when what was typed cannot be a place.
        if !typed.isEmpty, Address.url(from: typed) == nil {
            if let (keyword, rest) = Keyword.match(typed, in: prefs.keywords),
               let asked = Engine.url(for: rest, template: keyword.template) {
                list.append(Suggestion(key: typed, title: keyword.name, url: asked, kind: .search))
            } else if let asked = searchURL(for: typed) {
                list.append(
                    Suggestion(key: typed, title: prefs.engine.name(custom: prefs.customEngine), url: asked, kind: .search)
                )
            }
        }
        // First, not last: typing "settings" to reach Settings is the whole
        // point, and it would otherwise sit under a search for the word.
        let command = prefs.commandBar ? AddressCommand.matching(typed, in: self) : nil
        if let command { list.insert(.command(command), at: 0) }
        if command == nil, Address.url(from: typed) == nil, let ref = issueRef(for: typed) {
            list.insert(Suggestion(key: typed, title: "Open \(ref.said)", url: ref.url, kind: .known), at: 0)
        }
        // Neither a page already open nor a command has an address to
        // complete towards. And with a command on top, Return runs it: a
        // grey ending in the field ("history" finishing as history.com)
        // would promise a place Return doesn't go to.
        // Towards where you have been first, as before bookmarks were here,
        // then towards a bookmark.
        let places = list.filter { $0.kind != .open && !$0.kind.isCommand }
        let ending = command != nil ? nil
            : history.completion(for: typed, among: places.filter { $0.kind != .bookmark } + places.filter { $0.kind == .bookmark })
        return (list, ending)
    }

    /// What is open, most recently looked at first, filtered by what has been
    /// typed. On an empty field this is the whole point of the summon: it is
    /// the tab strip, except you read it only when you ask for it.
    private func openPages(matching typed: String) -> [Suggestion] {
        let needle = typed.trimmingCharacters(in: .whitespaces).lowercased()
        return tabs
            .filter { $0.id != activeID && !$0.isBlank }
            .filter { tab in
                guard !needle.isEmpty else { return true }
                let address = tab.address.map { Address.pretty($0) } ?? ""
                return tab.label.lowercased().contains(needle) || address.contains(needle)
            }
            .sorted { $0.touched > $1.touched }
            .prefix(needle.isEmpty ? 6 : 3)
            .compactMap { tab in
                guard let url = tab.address else { return nil }
                return Suggestion(
                    key: tab.label,
                    title: Address.pretty(url),
                    url: url,
                    kind: .open,
                    tab: tab.id
                )
            }
    }

    /// A row clicked in the list, taken directly rather than through the
    /// keyboard's selection. The pointer and the arrow keys are answering the
    /// same question but must not share an answer: a list that appears under a
    /// resting cursor would otherwise rewrite the field before you had moved.
    func take(_ offer: Suggestion) {
        summoning = false
        if let item = offer.placed {
            openPlaced(item)
            return
        }
        if case .snippet(let snippet) = offer.kind {
            chooseSnippet(snippet)
            return
        }
        if case .answer(let answer) = offer.kind {
            copyAnswer(answer, whole: false)
            return
        }
        if case .action(let id) = offer.kind {
            runFieldAction(id)
            return
        }
        if case .command(let command) = offer.kind {
            command.run(on: self)
        } else if let id = offer.tab, let tab = tabs.first(where: { $0.id == id }) {
            if !switchFromNewTab(to: tab) { select(tab) }
        } else if launching {
            open(offer.url, foreground: true, from: active)
        } else {
            (active ?? tabs.first)?.go(to: offer.url)
        }
        editing = false
        typed = ""
        picked = nil
    }

    /// A backspace means the ending was not wanted. Recomputing it on the very
    /// next keystroke is right; putting it back on this one is what makes a
    /// field impossible to shorten.
    func stopCompleting() { ending = nil }

    /// Tab with a site offered: the site goes into the field as a chip, and
    /// what was typed to name it is let go. True when it did.
    func lockSiteOffer() -> Bool {
        if let place = placeOffer {
            enterPlace(place)
            return true
        }
        guard prefs.searchesSites, siteChip == nil, let site = siteOffer else { return false }
        siteOffer = nil
        typed = ""
        siteChip = site
        return true
    }

    func lockSiteOnSpace() -> Bool {
        guard prefs.searchesSites, siteChip == nil, fieldPlace == nil, !summoning,
              !prefs.keywords.contains(where: { $0.keyword.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(typed) == .orderedSame }),
              let site = SiteSearch.exact(typed) else { return false }
        siteOffer = nil
        typed = ""
        siteChip = site
        return true
    }

    func enterPlace(_ place: FieldPlace) {
        if !fieldShowing { edit() }
        fieldMenu.close()
        summoning = false
        siteChip = nil
        holdingOffers = true
        typed = ""
        holdingOffers = false
        fieldPlace = place
        focusRequest += 1
    }

    func leavePlace() {
        guard fieldPlace != nil else { return }
        holdingOffers = true
        typed = ""
        holdingOffers = false
        fieldPlace = nil
        picked = nil
    }

    /// The arrow keys walk the list, and walking off the top lets go of it.
    func walk(_ step: Int) {
        if fieldMenu.showing {
            fieldMenu.walk(step)
            return
        }
        pointerTaken()
        guard !offers.isEmpty else { return }
        if !fieldSections.isEmpty, let here = picked {
            picked = (here + step + offers.count) % offers.count
            return
        }
        switch picked {
        case nil:
            picked = step > 0 ? 0 : offers.count - 1
        case let here?:
            let next = here + step
            picked = (next < 0 || next >= offers.count) ? nil : next
        }
    }

    // MARK: - the address field

    /// ⌘L. The current address comes up selected, so typing over it replaces it
    /// and Escape puts it back.
    func edit() {
        summoning = false
        launching = false
        // Never a name and password written into the address: they would be
        // on screen, and in whatever you copy from here.
        typed = active?.shownURL.map { url -> String in
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.user != nil || parts.password != nil
            else { return url.absoluteString }
            parts.user = nil
            parts.password = nil
            return parts.string ?? ""
        } ?? ""
        editing = true
        focusRequest += 1
    }

    var returnIsIdle: Bool {
        if fieldPlace == .snippets { return !fieldMenu.showing && pickedOffer == nil && !SnippetStore.shared.snippets.isEmpty }
        if fieldPlace != nil { return !fieldMenu.showing && pickedOffer?.placed == nil }
        return !fieldMenu.showing && fieldRow == nil && siteChip == nil && pointed != Self.siteRow
            && typed.trimmingCharacters(in: .whitespaces).isEmpty && offers.first?.leads != true
    }

    func letGoOfRow() -> Bool {
        guard picked != nil, !launching, !(active?.isBlank == true && prefs.floatingNewTab) else { return false }
        picked = nil
        return true
    }

    func quitField() {
        fieldMenu.close()
        summoning = false
        cycling = false
        launching = false
        siteChip = nil
        fieldPlace = nil
        editing = false
        typed = ""
        picked = nil
    }

    func dismiss() {
        fieldMenu.close()
        summoning = false
        cycling = false
        // The floating new tab was never a tab: nothing is left behind.
        if launching {
            launching = false
            siteChip = nil
            editing = false
            holdingOffers = true
            ending = nil
            typed = ""
            holdingOffers = false
            return
        }
        // Esc with a site in the field: the site goes, the field stays.
        if siteChip != nil {
            siteChip = nil
            return
        }
        // Esc on the empty page of a pair: the page isn't wanted after all.
        if let tab = active, tab.isBlank, split(for: tab) != nil {
            editing = false
            typed = ""
            close(tab)
            return
        }
        // A blank tab has nothing behind the field to go back to.
        guard active?.isBlank == false else { return }
        editing = false
        typed = ""
    }

    /// Return. A row picked from the list wins; otherwise what the field was
    /// finishing for you wins; otherwise what you actually typed. If none of
    /// those is a place, nothing happens and the field says so.
    ///
    /// `aside`: ⌘Return, as in Safari. The place opens in a new tab and the
    /// tab you were on is left as it was, behind it unless `front` (⇧⌘Return)
    /// asks to go there.
    func submit(aside: Bool = false, front: Bool = false, split beside: Bool = false) {
        if fieldMenu.showing {
            fieldMenu.runPicked()
            return
        }
        if pointed == Self.siteRow {
            pointed = nil
            if lockSiteOffer() { return }
        }
        if returnIsIdle, !summoning { return }
        pointerTaken()
        if fieldPlace == .snippets {
            submitSnippetPlace()
            return
        }
        if fieldPlace != nil {
            if let item = pickedOffer?.placed {
                if beside, splitsFromField(.placed(item)) { openPlacedInSplit(item) } else { openPlaced(item, aside: aside, front: front) }
            }
            return
        }
        if waitForSnippet(aside: aside, front: front) { return }
        // A page already open is switched to, not opened again.
        if let picked, offers.indices.contains(picked),
           let id = offers[picked].tab,
           let tab = tabs.first(where: { $0.id == id }) {
            summoning = false
            // From the empty page of a pair: that tab comes into the pair.
            if let blank = active, blank.isBlank, split(for: blank) != nil, !aside,
               tab.shy == blank.shy, split(for: tab)?.contains(blank.id) != true {
                fill(blank, with: tab)
                return
            }
            if !aside, switchFromNewTab(to: tab) { return }
            select(tab)
            editing = false
            typed = ""
            return
        }

        // The switcher proposes nothing but pages you have open. It still has
        // to accept an address typed into it, though — the two fields look
        // alike, and a Return that quietly does nothing is the worst answer
        // either of them could give.
        if summoning {
            summoning = false
            guard !typed.trimmingCharacters(in: .whitespaces).isEmpty else {
                editing = false
                return
            }
        }

        // The row the arrow keys chose, or else the top one: a command is
        // only ever on top, and there it is what Return does. Walked past,
        // Return goes where it always went.
        let chosen = (picked.flatMap { offers.indices.contains($0) ? offers[$0] : nil }) ?? offers.first
        if case .snippet(let snippet) = chosen?.kind, picked != nil || chosen?.leads == true {
            useSnippet(snippet)
            return
        }
        if case .answer(let answer) = chosen?.kind, picked != nil || chosen?.leads == true {
            copyAnswer(answer, whole: aside)
            return
        }
        if case .action(let id) = chosen?.kind, picked != nil || chosen?.leads == true {
            runFieldAction(id)
            return
        }
        if case .command(let command) = chosen?.kind {
            command.run(on: self)
            editing = false
            typed = ""
            picked = nil
            return
        }

        let target: URL?
        if let picked, offers.indices.contains(picked) {
            target = offers[picked].url
        } else if ending != nil {
            target = Address.url(from: completed)
        } else {
            target = destination(for: typed)
        }

        guard let asked = target else {
            refusals += 1
            return
        }
        let url = typedAddress(asked, picked: picked, typed: ending != nil ? completed : typed)
        hints.typed(url)
        if let page = InternalPage(url: url) {
            show(page)
            picked = nil
            return
        }
        let known = knownTitle(picked: chosen, going: url)
        if beside, splitsFromField(picked.flatMap { offers.indices.contains($0) ? offers[$0].kind : nil }) {
            openInSplit(url)
        } else if launching, !aside {
            // The floating new tab: what was typed gets a tab of its own, and
            // the page the field was raised over stays as it was.
            open(url, foreground: true, from: active, title: known)
        } else if aside {
            // Opened behind the page by hand, as a ⌘-clicked link is: it may
            // wait to load (Settings › Tabs › Load background tabs…).
            open(url, foreground: front, from: active, mayWait: true, title: known)
        } else {
            (active ?? tabs.first)?.go(to: url, known: known)
        }
        editing = false
        typed = ""
    }

    private func knownTitle(picked chosen: Suggestion?, going url: URL) -> String? {
        if let chosen, chosen.url == url {
            switch chosen.kind {
            case .search, .suggested: return chosen.key
            case .visited, .bookmark, .known: return chosen.title
            default: return nil
            }
        }
        let words = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty, Address.url(from: words) == nil, url == searchURL(for: words) else { return nil }
        return words
    }

    // MARK: - the page

    func zoom(by factor: CGFloat) { active?.magnify(by: factor) }
    func resetZoom() { active?.resetZoom() }

    /// ⌘⇧R. The article, and nothing that was arranged around it.
    // MARK: - dark pages

    /// Whether ⇧⌘D has anything to do: on, not paused, and the frame dark,
    /// since a light frame darkens nothing.
    var canDusk: Bool { canDusk(active) }

    /// The same for a given tab: the site card's, which in Split View can be
    /// the page beside the one with the keys.
    func canDusk(_ tab: Tab?) -> Bool {
        prefs.darkensPages && !Dusk.shared.paused && Dusk.frameIsDark
            && Dusk.host(of: tab?.pageAddress) != nil
    }

    /// ⇧⌘D: the site you're on, darkened or left as it is, the other way
    /// from now. Kept for the site; in a private tab, for this page alone.
    func toggleDusk() {
        guard canDusk, let tab = active else { return }
        dusk(!tab.dusked, tab)
    }

    func dusk(_ on: Bool, _ tab: Tab) {
        guard let host = Dusk.host(of: tab.pageAddress) else { return }
        if tab.shy {
            tab.built?.evaluateInSearch(Dusk.shared.forced(for: host, on))
        } else {
            Dusk.shared.choose(on, for: host, native: tab.duskNative)
        }
    }

    /// ⌥⇧⌘D: every page as its site made it, until pressed again or Search
    /// quits. For showing someone a site the way they see it.
    func pauseDusk() {
        guard prefs.darkensPages else { return }
        Dusk.shared.pause(!Dusk.shared.paused)
        announce(Dusk.shared.paused ? "Pages as their sites made them, until ⌥⇧⌘D" : "Light pages darkened again")
    }

    /// The darkening as it now stands, into every tab's next page and the
    /// page each is showing: taken over, let go, or, for a site not known
    /// yet, looked at.
    private func redusk() {
        for tab in tabs + parkedTabs {
            tab.arm(hiding: curtain.css(on: curtain.host(of: tab.address)))
            guard let web = tab.built else { continue }
            let host = Dusk.host(of: tab.pageAddress)
            if Dusk.shared.unsure(host) { duskLook(tab) } else { web.evaluateInSearch(Dusk.shared.update(for: host)) }
        }
    }

    /// A page on a site not known to be light, looked at from outside as it
    /// is drawn (see Dusk.look). Light, and it is darkened now, and every
    /// page of the site after it from its first frame; dark, and it is left
    /// with nothing in it.
    func duskLook(_ tab: Tab) {
        guard let web = tab.built, let url = web.url, let host = Dusk.host(of: url),
              Dusk.shared.unsure(host), !tab.dusked else { return }
        Dusk.look(at: web) { [weak self, weak tab] dark in
            MainActor.assumeIsolated {
                guard let self, let tab, let dark, tab.built === web, web.url == url, Dusk.shared.unsure(host) else { return }
                tab.duskNative = dark
                // A private tab remembers nothing, not even this.
                if !tab.shy { Dusk.shared.saw(host, dark: dark) }
                guard !dark, let script = Dusk.shared.script(for: host, light: true) else { return }
                web.evaluateInSearch(script)
                tab.arm(hiding: self.curtain.css(on: self.curtain.host(of: tab.address)))
            }
        }
    }

    func reload(fromOrigin: Bool = false) {
        Shield.shared.reloaded(hereHost)
        active?.reload(fromOrigin: fromOrigin)
    }

    func reloadPage() {
        let picked = pickedTabs
        guard picked.count > 1 else { return reload() }
        for tab in picked where !tab.asleep { tab.reload() }
    }
    func back() {
        if let tab = active, leaveBack(tab) { return }
        active?.back()
    }
    func forward() { active?.forward() }
}

// MARK: - WebKit

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// Every navigation is decided in `decide` below; this form of the
    /// question also hands over the page's preferences, the only place a
    /// site allowed to play sound by itself can say so (see Autoplay). Only
    /// a page that is allowed to load, in the tab's own frame, is touched.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        decide(webView, action) { [weak self] policy in
            // Revoke before WebKit can run the old document's unload handlers.
            // A nil target is a new window, not this tab leaving its document.
            if policy == .allow, action.targetFrame?.isMainFrame == true {
                self?.popupTab(for: webView)?.popupGesture.clear()
            }
            if policy == .allow, action.targetFrame?.isMainFrame ?? true, let url = action.request.url {
                let shy = self?.tab(for: webView)?.shy == true || !webView.configuration.websiteDataStore.isPersistent
                Autoplay.apply(to: preferences, for: url, shy: shy, agent: self?.anyTab(for: webView)?.agent == true,
                               made: webView.configuration.mediaTypesRequiringUserActionForPlayback)
                PrivacySignal.apply(to: preferences, shy: shy)
            }
            SignInKeeper.shared.ready(webView.configuration.websiteDataStore) { decisionHandler(policy, preferences) }
        }
    }

    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    private func decide(
        _ webView: WKWebView,
        _ action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        noteFileAction(action, in: webView)
        // "Download Image" from the page's own context menu and a link with
        // the `download` attribute arrive as an ordinary-looking action with
        // this one flag set. ("Download Linked File" doesn't come this way:
        // see contextMenuDidCreateDownload below.) Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page — nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the `WKDownload` that `didBecome download:` below already knows
        // what to do with.
        guard !action.shouldPerformDownload else {
            DownloadTrace.note("action-download", ["url": action.request.url?.absoluteString ?? ""], private: tracesPrivately(webView))
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }
        if action.targetFrame?.isMainFrame == true, let opener = popupTab(for: webView) {
            let redirect = action.responds(to: NSSelectorFromString("_isRedirect"))
                && (action.value(forKey: "_isRedirect") as? Bool) == true
            let held = redirect ? opener.heldTabUnder : nil
            opener.heldTabUnder = nil
            if !redirect { opener.undoneBy = nil }
            let fresh = opener.popupGesture.tabUnder().flatMap { spawn in
                (spawn.tab.map(popupStands) ?? true)
                    && PopupGuard.tabUnder(spawn, navigation: action.navigationType, to: url, page: opener.committed ?? webView.url)
                    ? spawn : nil
            }
            if let spawn = held?.spawn ?? fresh {
                let hold = HeldTabUnder(spawn: spawn, url: held?.url ?? url, navigation: held?.navigation ?? action.navigationType)
                if case .go = localNetworkStep(action, to: url, in: webView) {
                    opener.heldTabUnder = hold
                    DownloadTrace.note("window", ["verdict": "tab-under-held", "url": url.absoluteString], private: tracesPrivately(webView))
                    decisionHandler(.allow)
                } else {
                    decisionHandler(.cancel)
                    refuseTabUnder(hold, opener: opener)
                }
                return
            }
        }
        if action.targetFrame?.isMainFrame == true, let tab = tab(for: webView) {
            tab.heads(action, in: webView)
        }

        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView)
            || ExtensionAuth.handOver(url, mainFrame: action.targetFrame?.isMainFrame == true, browser: self, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // 0.0.0.0, as a dev server prints it: this Mac, as localhost (see
        // Address.reachable). Only the page itself; a frame goes nowhere.
        if action.targetFrame?.isMainFrame == true, let local = Address.reachable(url) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: local))
            return
        }

        // An extension's rule sending a site to one of its pages (Norma's
        // block page): that page needs another view too.
        if routeRuleRedirect(action, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // A website returning to a public extension page needs another view.
        if routeExtensionReturn(action, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // An extension's page sending its own tab to a website (see
        // replace(_:going:)).
        if ["http", "https"].contains(scheme),
           action.targetFrame?.isMainFrame ?? true,
           webView.url?.scheme == Extensions.scheme,
           let tab = tab(for: webView) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.replace(tab, going: url) }
            return
        }

        // ⌘-click opens beside this tab and leaves you where you are; ⌘⇧-click
        // takes you with it.
        //
        // The middle button is not judged here. WebKit hands the browser a
        // navigation action for a ⌘-click and none at all for a middle one,
        // and where it does report a button it answers with a mask — 1 left,
        // 2 right, 4 middle — so a check for 2 here would have meant the right
        // button, not the middle (see MiddleRelay, which is where the middle
        // button is answered).
        //
        // Should a WebKit ever hand one over for the middle button after all,
        // it is cancelled: MiddleRelay has already opened the link in a tab of
        // its own, and letting this one through would take the page there too.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 {
            decisionHandler(.cancel)
            return
        }
        // The chosen modified click: a peek at the link, over this
        // page (see Peek.swift). Only from a tab in the row — within a peek,
        // a link just goes.
        if prefs.peeksLinks, action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.intersection([.shift, .command, .option, .control]) == prefs.peekClick.flags,
           let from = tab(for: webView), peekTab == nil {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.peek(url, from: from) }
            return
        }
        // A plain click in a pin, on a link to another site: a peek too, when
        // Settings says so (see peeksFromPin). Links into the page's frames
        // are the page's own business. A link the site sends out by way of
        // itself, as Google's results go by google.com/goto, is asked about
        // again at the redirect, still as a click — by then webView.url is
        // already where it is going, so the page it was on is the one in the
        // history.
        if action.navigationType == .linkActivated, action.targetFrame?.isMainFrame == true,
           action.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let from = tab(for: webView), peeksFromPin(url, in: from, on: webView.backForwardList.currentItem?.url) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.peek(url, from: from) }
            return
        }
        if action.navigationType == .other, action.targetFrame?.isMainFrame == true,
           let from = tab(for: webView), followsPeek(url, in: from) {
            decisionHandler(.cancel)
            return
        }
        if action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) {
            let source = tab(for: webView)
            let opened = openClicked(url, foreground: action.modifierFlags.contains(.shift), from: source, view: webView)
            if let opened { fileSearchResult(opened, from: source) }
            decisionHandler(.cancel)
            return
        }

        if action.targetFrame?.isMainFrame == true, let tab = popupTab(for: webView) {
            switch localNetworkStep(action, to: url, in: webView) {
            case .go:
                break
            case .stop:
                decisionHandler(.cancel)
                return
            case .ask:
                askLocalNetwork(from: webView, tab: tab, page: LocalNetwork.origin(action.sourceFrame.securityOrigin), target: url) { [weak self, weak webView] allowed in
                    guard allowed, let self, let webView else { return decisionHandler(.cancel) }
                    self.letThrough(action, to: url, scheme: scheme, in: webView, decisionHandler: decisionHandler)
                }
                return
            }
        }
        letThrough(action, to: url, scheme: scheme, in: webView, decisionHandler: decisionHandler)
    }

    private func letThrough(_ action: WKNavigationAction, to url: URL, scheme: String, in webView: WKWebView,
                            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        if action.targetFrame?.isMainFrame ?? true, let tab = anyTab(for: webView) {
            let host = curtain.host(of: url)
            if let space = spaceOf(tab) { tab.space = space }
            tab.arm(hiding: curtain.css(on: host), to: url)
            // And the blocker, on or off for where it is going.
            Shield.shared.tune(webView.configuration.userContentController, for: host)
            LocalNetworkGuard.shared.tune(webView.configuration.userContentController, for: url, tab: tab.id,
                                          shy: tab.shy || !webView.configuration.websiteDataStore.isPersistent)
            // The frames that were told about the last page's darkening go
            // with it.
            tab.duskFrames.removeAll()
            // And the frames that played, and the count to the media keys.
            tab.leaving()
        }

        // chrome-extension: an extension's own pages — options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            handOff(url, scheme: scheme, action: action, from: webView)
        }
    }

    /// Unlike tabs.update(), a website's navigation must be checked against
    /// web_accessible_resources before using an extension view.
    private func routeExtensionReturn(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard let tab = tab(for: webView) else { return false }
        let source = tab.extensionReturn.source(for: action)
        guard let requested = action.request.url else { return false }
        let target = Extensions.current(requested)
        guard target.scheme == Extensions.scheme, let source else { return false }
        return handOverExtensionReturn(target, source: source, from: webView, tab: tab)
    }

    /// WebKit marks the navigation it starts for a content rule's redirect
    /// (`_isContentExtensionRedirect`); a page can't. What a page could reach
    /// is still all it gets: the file must be one the extension exposes to
    /// the site the tab was going to, as Chrome requires of a redirect to an
    /// extension's file.
    private func routeRuleRedirect(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard action.targetFrame?.isMainFrame == true,
              action.responds(to: NSSelectorFromString("_isContentExtensionRedirect")),
              (action.value(forKey: "_isContentExtensionRedirect") as? Bool) == true,
              let tab = tab(for: webView), let requested = action.request.url
        else { return false }
        let source = tab.extensionReturn.ruleSource(for: action)
        let target = Extensions.current(ExtensionRedirectPolicy.ruleTarget(requested))
        guard target.scheme == Extensions.scheme, let source else { return false }
        return handOverExtensionReturn(target, source: source, from: webView, tab: tab, fromRule: true)
    }

    private func handOverExtensionReturn(_ target: URL, source: URL, from webView: WKWebView, tab: Tab, fromRule: Bool = false) -> Bool {
        guard !tab.shy,
              let context = Extensions.shared.controller.extensionContext(for: target),
              context.isLoaded, context.webViewConfiguration != nil,
              ExtensionRedirectPolicy.allows(target: target, sourceOrigin: source, manifest: context.webExtension.manifest, fromRule: fromRule)
        else { return false }
        let revision = tab.extensionReturn.revision
        DispatchQueue.main.async { [weak self, weak tab, weak webView] in
            guard let self, let tab, let webView,
                  self.tab(for: webView)?.id == tab.id,
                  tab.extensionReturn.revision == revision else { return }
            self.replace(tab, going: target)
        }
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let choosingPage = anyTab(for: webView) ?? (peekTab?.built === webView ? peekTab : nil)
        if let tab = choosingPage, fileChoice?.tabID == tab.id { fileChoice?.cancel() }
        cancelDisplay(for: webView)
        guard let navigation else { return }
        tab(for: webView)?.began(asked: navigation === (webView as? PageView)?.started)
        tab(for: webView)?.extensionReturn.started(navigation, at: webView.url)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let tab = tab(for: webView) else { return }
        tab.redirected()
        let redirect = tab.extensionReturn.redirected(navigation, to: webView.url)
        guard let redirect,
              handOverExtensionReturn(Extensions.current(redirect.target), source: redirect.source, from: webView, tab: tab)
        else { return }
        webView.stopLoading()
    }

    /// An address for another app — mail, a call, a meeting. The page itself
    /// may ask, or a frame of the page's own site — Zoom's, Teams' and
    /// Slack's "open the app" pages load it into a frame of their own from a
    /// script — or a click inside any frame. A frame from another site that
    /// asks on its own (an advertisement, say) is ignored. And the other app
    /// opens only once you have said so, as in Safari — except a mail or
    /// phone link you just clicked on, which is exactly what it says.
    private func handOff(_ url: URL, scheme: String, action: WKNavigationAction, from webView: WKWebView) {
        let clicked = action.navigationType == .linkActivated
        let source: WKFrameInfo? = action.sourceFrame
        let top = webView.url?.host()?.lowercased() ?? ""
        let asker = source?.securityOrigin.host.lowercased() ?? ""
        let ownSite = source?.isMainFrame == true
            || (!top.isEmpty && !asker.isEmpty && Vault.registrable(asker) == Vault.registrable(top))
        // No target frame is a new window asked for: the frame asking is
        // judged, as for any other frame.
        guard action.targetFrame?.isMainFrame ?? false || clicked || ownSite else {
            if Store.testing { Browser.handedOff.append("\(scheme): ignored") }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if Store.testing { Browser.handedOff.append("\(scheme): no app") }
            return
        }
        // A test run can't show the question (see Dialogs): it says it would.
        if Store.testing {
            Browser.handedOff.append("\(scheme): asked")
            return
        }
        if clicked, ["mailto", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        // Over its own tab only, as a page's own questions are (see ask).
        ask(from: webView, show: {
            let alert = NSAlert()
            alert.messageText = "Open \u{201C}\(name)\u{201D}?"
            alert.informativeText = "\(webView.url?.host() ?? "This page") wants to open \(name)"
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            Dialogs.show(alert, over: webView) { answer in
                guard answer == .alertFirstButtonReturn else { return }
                NSWorkspace.shared.open(url)
            }
        }, drop: {})
    }

    /// A link that asks for a new window gets a new tab. The configuration
    /// WebKit hands over has to be the one the new view is built with, or the
    /// opener and the opened can't talk to each other.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let opener = popupTab(for: webView) else { return nil }
        let popup = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.toolbarsVisibility?.boolValue == false
        let clicked = opener.popupGesture.take(origin: PopupGesture.origin(action.sourceFrame), mainFrame: action.sourceFrame.isMainFrame,
                                               patient: SignInWindows.listed(action.request.url))
        if !clicked {
            // A second window for a click that already had its one: the
            // duplicate one click must not make, said nowhere.
            if opener.popupGesture.spent() {
                tracePopup(opener, action, "spent", clicked: false, sized: popup)
                let now = ProcessInfo.processInfo.systemUptime
                let same = opener.lastWindow.map { $0.url == action.request.url && now - $0.at < 5 } ?? false
                if !same { speculate(action, from: webView, opener: opener, verdict: "spent") }
                return nil
            }
            // No click just before: refused, and the tab says so (see
            // BlockedPopups.swift), unless you allowed pop-ups from this site
            // and it is the site's own page or frame asking.
            guard popupsAllowed(opener, from: action.sourceFrame, top: opener.committed ?? webView.url) else {
                tracePopup(opener, action, "no-click", clicked: false, sized: popup)
                opener.noteBlocked(action.request.url)
                if FileAnswer.namesFile(action.request.url) { speculate(action, from: webView, opener: opener, verdict: "no-click") }
                return nil
            }
        }
        let from = opener.id
        // The link menu's Open Link in New Tab, asked for in the last second.
        // Read once: reading it takes it.
        let behind = (webView as? PageView)?.takeBehind() == true
        // Its Open Link in Split View, the same way.
        let beside = (webView as? PageView)?.takeBeside() == true
        let page = opener.committed ?? webView.url
        if clicked, !behind, !beside, !action.modifierFlags.contains(.command),
           !popupsAllowed(opener, top: page),
           let refusal = PopupGuard.refusal(opener.popupGesture.hits, url: action.request.url, page: page,
                                            sized: popup, wary: PopupGuard.wary(page)) {
            tracePopup(opener, action, refusal.rawValue, clicked: true, sized: popup)
            opener.noteBlocked(action.request.url, reason: refusal)
            opener.popupGesture.refused(sized: popup, reason: refusal)
            PopupGuard.strike(page, for: refusal, to: action.request.url)
            if refusal == .unseen {
                webView.evaluateJavaScript("globalThis.broadwayPopupPass && globalThis.broadwayPopupPass()",
                                           in: action.sourceFrame, in: Web.world) { _ in }
            }
            if [.astray, .wary].contains(refusal) { speculate(action, from: webView, opener: opener, verdict: refusal.rawValue) }
            return nil
        }
        // WebKit's copy of the opener's configuration still holds the
        // opener's user content controller — its scripts and its message
        // handlers. Shared, the new tab claimed the opener's handlers as its
        // own, and closing or sleeping it took them off the opener's page:
        // right-click on a picture on X, after following a link out of it,
        // did nothing at all. Each tab gets a controller of its own.
        configuration.userContentController = WKUserContentController()
        // The opener's copy is what its view was made with, maybe before
        // Settings › Videos wait for a click last moved.
        configuration.mediaTypesRequiringUserActionForPlayback = Web.playback
        if opener.agent {
            guard let tab = agentPopup(configuration, opener: opener, url: action.request.url, sized: popup) else { return nil }
            if !parkAgentPopup(tab, beside: opener) { tabs.append(tab) }
            return settleAgentPopup(tab, from: opener, url: action.request.url)
        }
        // A new window a pin's page asked for on a click — a target="_blank"
        // link, or window.open from the click, as Gmail's links and many
        // sites' do, often by way of a redirect on their own site — opens in
        // the peek rather than the row (see peekWindow). Only on a click:
        // a window the page opens by itself, even from a site allowed
        // pop-ups, takes the tab path as before. A window sized by the page,
        // "Sign in with…", is left alone, as is a modified click, and so is
        // anything that isn't a web page (about:blank, data:, blob:).
        if clicked, !behind, !beside, !popup, let url = action.request.url, joinsMeeting(url, from: opener) {
            tracePopup(opener, action, "meeting", clicked: clicked, sized: popup)
            return nil
        }
        if clicked, !behind, !beside, !popup, prefs.pinsPeek, peekTab == nil, opener.pin != nil,
           [.linkActivated, .other].contains(action.navigationType),
           action.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let url = action.request.url, Browser.peekable(url) {
            let peek = peekWindow(configuration, from: opener, going: url)
            tracePopup(opener, action, "peek", clicked: clicked, sized: popup)
            opener.popupGesture.opened(peek.id, sized: popup)
            return peek.web
        }
        if !isPrivate, Browser.routesNewWindow(clicked: clicked, navigation: action.navigationType, popup: popup, beside: beside,
                                               shy: opener.shy, url: action.request.url, page: opener.committed ?? webView.url, menu: behind),
           let url = action.request.url, case .yes = routeClicked(url, foreground: !behind, from: opener) {
            tracePopup(opener, action, "routed", clicked: clicked, sized: popup)
            return nil
        }
        tracePopup(opener, action, "opened", clicked: clicked, sized: popup)
        let tab = Tab(shy: opener.shy, configuration: configuration)
        tab.popup = popup
        tab.opener = from
        tab.openedByClick = clicked
        tab.linkedFrom = from
        if clicked { opener.popupGesture.opened(tab.id, sized: popup) }
        opener.lastWindow = (action.request.url, ProcessInfo.processInfo.systemUptime)
        // The link menu's Open Link in New Tab: behind this tab, where a
        // ⌘-click's goes (see open(_:foreground:)).
        prepare(tab)
        if behind || beside {
            if prefs.usesTabGroups, !tab.shy, !tab.bench {
                tab.groupID = opener.groupID
                tab.bornIn = tab.groupID
            }
            tabs.insert(tab, at: placeForLink(from: opener, beside: beside))
            noteLink(tab, from: opener)
            noteReturn(tab, front: false, from: opener)
            if beside { pair(tab, with: opener, onLeft: false) }
        } else {
            if prefs.usesTabGroups, !tab.shy, !tab.bench {
                tab.groupID = opener.groupID
                tab.bornIn = tab.groupID
            }
            tabs.insert(tab, at: placeForLink(from: opener))
            if clicked, let run = linkRun { runBeforeScript = (tab.id, run) }
            noteReturn(tab, front: true, from: opener)
            activeID = tab.id
            editing = false
        }
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url, link: opener.linkWords(for: url)) }
        return tab.web
    }

    private func tracePopup(_ opener: Tab, _ action: WKNavigationAction, _ verdict: String, clicked: Bool, sized: Bool) {
        guard Store.testing else { return }
        let frame = action.sourceFrame
        DownloadTrace.note("window", ["verdict": verdict, "url": action.request.url?.absoluteString ?? "", "clicked": String(clicked)], private: tracesPrivately(opener))
        let hits = opener.popupGesture.hits.map { hit in
            "fade \(hit.fade) hidden \(hit.hidden) over \(hit.over) cover \(hit.cover) active \(hit.active) masked \(hit.masked) "
                + "link \(hit.link?.absoluteString ?? "")"
        }
        opener.popupTrace = Array((opener.popupTrace + [[
            "verdict": verdict,
            "url": action.request.url?.absoluteString ?? "",
            "frame": PopupGesture.origin(frame) ?? "",
            "main": String(frame.isMainFrame),
            "clicked": String(clicked),
            "sized": String(sized),
            "navigation": String(action.navigationType.rawValue),
            "hits": hits.joined(separator: " | "),
        ]]).suffix(20))
    }

    private func popupStands(_ id: UUID) -> Bool {
        peekTab?.id == id || Browsers.all.contains { $0.tabs.contains { $0.id == id } }
    }

    private func refuseTabUnder(_ hold: HeldTabUnder, opener: Tab) {
        DownloadTrace.note("window", ["verdict": "tab-under", "url": hold.url.absoluteString], private: tracesPrivately(opener))
        if Store.testing {
            opener.popupTrace = Array((opener.popupTrace + [[
                "verdict": "tab-under", "url": hold.url.absoluteString, "refused": String(hold.spawn.refused),
                "navigation": String(hold.navigation.rawValue),
            ]]).suffix(20))
        }
        if opener.popupGesture.spawn?.serial == hold.spawn.serial { opener.popupGesture.dropSpawn() }
        undoTabUnder(hold.spawn, opener: opener)
    }

    private func undoTabUnder(_ spawn: PopupSpawn, opener: Tab) {
        guard let id = spawn.tab, let made = tabs.first(where: { $0.id == id }) else { return }
        guard BlockedPopups.site(of: made.pageAddress) != BlockedPopups.site(of: opener.pageAddress) else { return }
        if made.committed == nil, made.built?.isLoading == true {
            made.undoneBy = opener.id
            return
        }
        closeUndone(made, opener: opener)
    }

    private func closeUndone(_ made: Tab, opener: Tab?) {
        if let opener {
            opener.noteBlocked(made.pageAddress, reason: .tabUnder)
            PopupGuard.strike(opener.pageAddress, for: .tabUnder)
        }
        let shown = made.id == activeID
        close(made)
        if shown, let opener, tabs.contains(where: { $0.id == opener.id }) { select(opener) }
    }

    private func speculate(_ action: WKNavigationAction, from webView: WKWebView, opener: Tab, verdict: String) {
        guard let url = BlockedPopups.openable(action.request.url), FetchEntry.replayable(action.request) else { return }
        var request = URLRequest(url: url)
        if let page = opener.committed ?? webView.url { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
        let id = opener.id
        DownloadTrace.note("window", ["verdict": verdict + "-fetched", "url": url.absoluteString], private: tracesPrivately(webView))
        webView.startDownload(using: request) { [weak self] download in
            MainActor.assumeIsolated {
                guard let self else { return download.cancel { _ in } }
                self.speculating[ObjectIdentifier(download)] = Speculation(download: download, opener: id, url: url)
                download.delegate = self
            }
        }
    }

    /// A link clicked open in a tab by Search itself (⌘-click, the middle
    /// button): one click, one tab. When the page's own script already
    /// opened a window for that click, it is the tab — put where the click
    /// asked, behind unless ⇧ was held — and no second one opens. Otherwise
    /// the click is spent, and a window.open after it gets nothing.
    @discardableResult
    private func openClicked(_ url: URL, foreground: Bool, from source: Tab?, view: WKWebView?) -> Tab? {
        let opener = view.flatMap { popupTab(for: $0) }
        if let made = opener?.popupGesture.claim(),
           let tab = Browsers.all.lazy.flatMap(\.tabs).first(where: { $0.id == made }) {
            let run = runBeforeScript?.tab == made ? runBeforeScript?.run : nil
            runBeforeScript = nil
            if !foreground, activeID == tab.id, let source, tabs.contains(where: { $0.id == source.id }) {
                activeID = source.id
            }
            // The script's tab went where a page opened in front goes; it is
            // the ⌘-click's, so it goes where the ⌘-click's would have.
            if let source, tabs.contains(where: { $0.id == source.id }), source.id != tab.id,
               split(for: tab) == nil, let at = tabs.firstIndex(where: { $0.id == tab.id }) {
                if !foreground, run?.opener == source.id { linkRun = run }
                tabs.remove(at: at)
                if prefs.usesTabGroups, !tab.shy, !tab.bench {
                    tab.groupID = source.groupID
                    tab.bornIn = tab.groupID
                }
                tab.linkedFrom = source.id
                tabs.insert(tab, at: placeForLink(from: source))
                if !foreground {
                    noteLink(tab, from: source)
                    noteReturn(tab, front: false, from: source)
                }
            }
            if !foreground { openedBehind(tab) }
            return tab
        }
        if case .yes(let routed) = routeClicked(url, foreground: foreground, from: source) { return routed }
        return open(url, foreground: foreground, from: source, mayWait: true, link: true, title: source?.linkWords(for: url))
    }

    /// Anything the window can't show is something to keep instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A redirect (3xx) has nowhere to be shown and carries no content of
        // its own, but must be followed rather than downloaded — even if its
        // headers say `application/binary` or `application/octet-stream`, as
        // youtube.com and some servers do on their redirects.
        if let http = response.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        if response.isForMainFrame, let tab = popupTab(for: webView), tab.heldTabUnder != nil || tab.undoneBy != nil {
            let file = FileAnswer.navigationIsFile(response.response, canShow: response.canShowMIMEType)
            let url = response.response.url?.absoluteString ?? ""
            if let hold = tab.heldTabUnder {
                tab.heldTabUnder = nil
                DownloadTrace.note("window", ["verdict": file ? "tab-under-file" : "tab-under-page", "url": url], private: tracesPrivately(webView))
                if file { return decisionHandler(.download) }
                decisionHandler(.cancel)
                refuseTabUnder(hold, opener: tab)
                return
            }
            let by = tab.undoneBy
            tab.undoneBy = nil
            DownloadTrace.note("window", ["verdict": file ? "undone-file" : "undone-page", "url": url], private: tracesPrivately(webView))
            if file { return decisionHandler(.download) }
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab, self.tabs.contains(where: { $0.id == tab.id }) else { return }
                self.closeUndone(tab, opener: (self.tabs + self.parkedTabs).first { $0.id == by })
            }
            return
        }
        // A server that says "attachment" means a file to keep, even one
        // WebKit could show. Gmail's download button loads the attachment
        // into a hidden frame and counts on exactly that: a PDF shown there
        // instead was the button doing nothing at all.
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            DownloadTrace.note("response-attachment", ["url": response.response.url?.absoluteString ?? ""], private: tracesPrivately(webView))
            decisionHandler(.download)
            return
        }
        // A text file already on this Mac that WebKit has no type for — a
        // hosts file, a .yaml, a Dockerfile — is shown as text, as in Safari
        // and Chrome, rather than copied into Downloads (#525). And one it
        // does show as text is read as UTF-8: WebKit took a file's text for
        // Windows-1252, and every accent in it came out as two letters.
        // Read off the main thread, a file on a slow share included; the
        // decision waits for it, and the window doesn't.
        let plain = response.response.mimeType?.lowercased() == "text/plain"
        if !response.canShowMIMEType || plain, response.isForMainFrame,
           let url = response.response.url, url.isFileURL {
            let showable = response.canShowMIMEType
            Task.detached(priority: .userInitiated) {
                let text = LocalText.contents(of: url)
                await MainActor.run {
                    guard let text else {
                        decisionHandler(showable ? .allow : .download)
                        return
                    }
                    decisionHandler(.cancel)
                    webView.load(text, mimeType: "text/plain", characterEncodingName: "utf-8", baseURL: url)
                }
            }
            return
        }
        DownloadTrace.note(response.canShowMIMEType ? "response-show" : "response-download", [
            "url": response.response.url?.absoluteString ?? "", "type": response.response.mimeType ?? "",
            "main": String(response.isForMainFrame),
        ], private: tracesPrivately(webView))
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        noteFileBegan(download, from: webView, start: .page)
        keep(download, from: webView)
        dropEmpty(webView)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        noteFileBegan(download, from: webView, start: .page)
        keep(download, from: webView)
        dropEmpty(webView)
    }

    /// Download Linked File in the right-click menu. WebKit starts the
    /// download and hands it to a delegate that answers this name, outside
    /// the public framework; unanswered, the file was fetched and went nowhere.
    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        keep(download, from: webView)
    }

    /// A tab that has shown nothing, and whose first page turned out to be a
    /// file: a download link that opens in a new tab, as a course site's
    /// attachments do. The file goes on arriving without it. Kept, the tab
    /// held the file's address, came back with the session, and downloaded
    /// the file again each time it was opened. It forgets the address; and
    /// when a page's link opened it, it closes, as in Safari and Chrome, and
    /// you are back on that page. A tab you opened yourself stays, as a new
    /// tab, and so does a window's only tab: closing it would close the
    /// window.
    private func dropEmpty(_ webView: WKWebView) {
        guard let tab = tab(for: webView), tab.committed == nil, tab.pin == nil else { return }
        // Without its address, it is not offered back by ⇧⌘T either.
        tab.forget()
        guard let opener = tab.opener, tabs.count > 1 else { return }
        if tab.id == activeID, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        close(tab)
    }

    /// Every download this window has going, heard from until it ends — and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(
        _ download: WKDownload,
        from suppliedWebView: WKWebView? = nil,
        continuing entry: FetchEntry? = nil,
        operationID: UUID? = nil,
        helper: WKWebView? = nil
    ) {
        let webView = suppliedWebView ?? download.webView
        DownloadTrace.note("became", ["url": download.originalRequest?.url?.absoluteString ?? "", "view": String(webView != nil)], private: isPrivate || (entry == nil && tracesPrivately(webView)))
        // Find privacy before publishing the entry. A private transfer is
        // still tracked internally so its delegate and Finder progress clean
        // up correctly, but it never enters the shared Downloads panel.
        let isPrivate = entry == nil && webView.map {
            !$0.configuration.websiteDataStore.isPersistent || anyTab(for: $0)?.shy == true
        } == true
        download.delegate = self
        if !downloading.contains(where: { $0 === download }) { downloading.append(download) }
        if isPrivate { unlisted.insert(ObjectIdentifier(download)) }
        else { unlisted.remove(ObjectIdentifier(download)) }
        guard fetches.start(
            download,
            owner: self,
            webView: webView,
            listed: !isPrivate,
            entry: entry,
            operationID: operationID,
            helper: helper
        ) else {
            relinquish(download)
            download.cancel { _ in }
            return
        }
        // A true resume may continue the preserved target without asking its
        // delegate for a destination again. Publish Finder progress as soon
        // as the resumed WKDownload is attached; `going` coalesces a later
        // destination callback for the same URL.
        if entry != nil, let destination = entry?.destination {
            fetches.going(download, to: destination, cancel: finderCancellation(for: download))
        }
    }

    /// Pause an active download. WebKit's cancellation callback is the
    /// authoritative source of resume data and also owns cleanup if no
    /// delegate failure callback arrives.
    func pauseDownload(_ entry: FetchEntry) {
        guard entry.canPause, let operation = fetches.beginStop(entry, action: .pause) else { return }
        stopDownload(operation)
    }

    func resumeDownload(_ entry: FetchEntry) {
        guard let operation = fetches.beginResume(entry), let data = operation.resumeData else { return }
        operation.webView.resumeDownload(fromResumeData: data) { download in
            self.continueDownload(download, operation)
        }
    }

    /// From the start, to the folder it went to, under the name it was asked
    /// for: numbered afresh, " 2" and on, past whatever is there now, the
    /// last attempt's half-written file let go first.
    func retryDownload(_ entry: FetchEntry) {
        let folder = entry.destination?.deletingLastPathComponent() ?? downloadsFolder
        guard let operation = fetches.beginRetry(entry, destination: { Self.free(entry.retryName, in: folder) }),
              let request = operation.request else { return }
        operation.webView.startDownload(using: request) { download in
            self.continueDownload(download, operation)
        }
    }

    private func continueDownload(_ download: WKDownload, _ operation: Fetches.StartOperation) {
        guard fetches.accepts(operation) else {
            download.cancel { _ in }
            return
        }
        keep(
            download, from: operation.webView, continuing: operation.entry, operationID: operation.operationID,
            helper: operation.helper ? operation.webView : nil
        )
    }

    /// Active rows stop; paused and failed rows are removed and release their
    /// in-memory resume data and the store they were asked with.
    func cancelDownload(_ entry: FetchEntry) {
        switch entry.state {
        case .downloading:
            guard let operation = fetches.beginStop(entry, action: .cancel) else { return }
            stopDownload(operation)
        case .pausing:
            _ = fetches.upgradeStopToCancel(entry)
        case .resuming:
            fetches.removeStarting(entry)
        case .paused, .failed:
            fetches.removeStopped(entry)
        }
    }

    /// A space deleted: its downloads go with it, whatever they were doing,
    /// as Cancel or Remove would take them, and with them the store they
    /// kept and any view made to ask with it. Its cookies can then be
    /// erased, and nothing is asked with them again.
    func forgetDownloads(of store: WKWebsiteDataStore) {
        for entry in fetches.entries where entry.store === store { cancelDownload(entry) }
    }

    private func stopDownload(_ operation: Fetches.StopOperation) {
        let fetches = self.fetches
        operation.download.cancel { resumeData in
            DispatchQueue.main.async {
                guard let ended = fetches.stopped(operation, resumeData: resumeData) else { return }
                ended.owner.relinquish(operation.download)
            }
        }
    }

    /// Called for both delegate completion and WKDownload.cancel completion;
    /// idempotence handles WebKit choosing either callback order.
    func relinquish(_ download: WKDownload) {
        SaveAsk.shared.downloadEnded(download)
        SiteFileAsk.shared.downloadEnded(download)
        downloading.removeAll { $0 === download }
        unlisted.remove(ObjectIdentifier(download))
    }

    private func finderCancelled(_ download: WKDownload) {
        guard let operation = fetches.beginFinderStop(download) else { return }
        stopDownload(operation)
    }

    private func finderCancellation(for download: WKDownload) -> @Sendable () -> Void {
        { [weak self, weak download] in
            DispatchQueue.main.async {
                guard let self, let download else { return }
                self.finderCancelled(download)
            }
        }
    }

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        askedForCapture(webView, origin: origin, frame: frame, type: type, decisionHandler: decisionHandler)
    }

    /// The camera or microphone, for a tab's page or an extension's popup.
    ///
    /// Remembered for the origin that asked — http://site and https://site,
    /// or another port, are other sites — and never for a private tab, which
    /// leaves nothing behind. An extension's page asking — its popup, or a
    /// frame of its own inside a website (a recorder's camera bubble) — is
    /// named as the extension and remembered for it, never for the site it
    /// sits in: allowing the bubble must not give the site the camera.
    func askedForCapture(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo, type: WKMediaCaptureType,
                         decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // An extension capturing, however it went about it: the pill says so.
        ExtensionCapture.shared.watchCapture(webView, frame: frame)
        let asker = frame.securityOrigin
        let host: String
        let site: String
        if Browser.extensionScheme(asker.protocol) {
            host = Browser.extensionName(asker.host)
            site = "\(asker.protocol.lowercased())://\(asker.host.lowercased())"
        } else {
            host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
            site = origin.host.isEmpty ? host : "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
        }
        let key = "\(site)|\(type.rawValue)"
        let shy = tab(for: webView).map { $0.shy || !webView.configuration.websiteDataStore.isPersistent } ?? false

        if !shy, let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        HookAsk.permission(site: site, wants: HookAsk.wants(type), tab: tab(for: webView), in: self, asker: asker.protocol) { [weak self, weak webView] hooked in
            if let hooked { return decisionHandler(hooked ? .grant : .deny) }
            guard let self, let webView else { return decisionHandler(.deny) }
            ask(from: webView, show: { [weak self] in
                guard let self else { return decisionHandler(.deny) }
                guard !permissionBusy else { return decisionHandler(.deny) }
                decide = decisionHandler
                askedAbout = shy ? "" : key
                asking = CaptureAsk(host: host, wants: Browser.name(for: type))
            }, drop: { decisionHandler(.deny) })
        }
    }

    /// WebKit's private delegate lets Search ask before opening the system picker.
    /// Extension pages use separate delegates.
    @objc(_webView:requestDisplayCapturePermissionForOrigin:initiatedByFrame:withSystemAudio:decisionHandler:)
    func askedToShareScreen(_ webView: WKWebView, origin: WKSecurityOrigin, frame: WKFrameInfo,
                            systemAudio: Bool, decisionHandler: @escaping (Int) -> Void) {
        guard !permissionBusy, let tab = (tabs + parkedTabs).first(where: { $0.built === webView })
        else { return decisionHandler(0) }
        let request = UUID()
        displayRequest = request
        displayTab = tab
        decideDisplay = decisionHandler
        let asker = frame.securityOrigin
        let host = origin.host.isEmpty ? (tab.address?.host() ?? "This page") : origin.host
        let named = Browser.extensionScheme(asker.protocol) ? Browser.extensionName(asker.host) : host
        // Recheck ownership when a background tab's question is shown.
        displayHeld = ask(from: webView, show: { [weak self, weak webView] in
            guard let self, displayRequest == request else { return }
            guard let webView, activeID == tab.id, tab.built === webView else { return cancelDisplay() }
            asking = CaptureAsk(host: named, wants: "screen", screen: true, sound: systemAudio)
        }, drop: { [weak self] in
            guard let self, displayRequest == request else { return }
            cancelDisplay()
        })
    }

    /// An extension's own scheme, today's or the one it had before.
    static func extensionScheme(_ scheme: String) -> Bool {
        ["chrome-extension", "webkit-extension"].contains(scheme.lowercased())
    }

    /// An extension by the name it shows, for a question it asks.
    static func extensionName(_ id: String) -> String {
        if let found = Extensions.shared.installed.first(where: { $0.id.lowercased() == id.lowercased() }) {
            return found.name
        }
        return "An extension"
    }

    /// A page asking where you are. WebKit asks this through a delegate
    /// method that isn't public on the Mac; unanswered, every page is refused.
    ///
    /// Only the page on screen, and only for itself: the tab in front, and
    /// the page's own origin or a frame of that same origin. WebKit already
    /// keeps frames from elsewhere out unless the page lets them in
    /// (allow="geolocation"); here they don't get to borrow the page's
    /// answer at all. Remembered per origin, as the camera is, and never for
    /// a private tab.
    @objc(_webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:)
    func askedForLocation(
        _ webView: WKWebView,
        origin: WKSecurityOrigin,
        frame: WKFrameInfo,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let give: (WKPermissionDecision) -> Void = { decision in
            guard Store.testing else { return decisionHandler(decision) }
            Browser.locationAnswered = decision == .grant ? "granted" : "denied"
            decisionHandler(.deny)
        }
        // WebKit names the page's origin for a frame it let in, whoever the
        // frame is: the frame's own is what counts.
        let site = Browser.origin(origin.protocol, origin.host, origin.port)
        let asker = frame.securityOrigin
        guard let tab = tab(for: webView), tab.id == activeID, !origin.host.isEmpty,
              let page = webView.url, let scheme = page.scheme, let host = page.host(),
              site == Browser.origin(scheme, host, page.port ?? 0),
              Browser.origin(asker.protocol, asker.host, asker.port) == site
        else { return give(.deny) }
        let key = "\(site)|location"
        if !tab.shy, let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            return give(remembered ? .grant : .deny)
        }
        HookAsk.permission(site: site, wants: ["location"], tab: tab, in: self, asker: origin.protocol) { [weak self] hooked in
            if let hooked { return give(hooked ? .grant : .deny) }
            guard let self, tab.id == activeID else { return give(.deny) }
            guard !permissionBusy else { return give(.deny) }
            decide = give
            askedAbout = tab.shy ? "" : key
            let named = Browser.extensionScheme(origin.protocol) ? Browser.extensionName(origin.host) : origin.host
            asking = CaptureAsk(host: named, wants: "location", once: true, keeps: !tab.shy)
        }
    }

    /// A page asking to send notifications. Asked over its own page, as the
    /// camera is, and only for the page's own origin; kept per origin under
    /// the same "capture." keys, so Forget choices takes it back. A private
    /// tab, or Settings › Privacy's switch off, is refused without a card.
    @objc(_webView:requestNotificationPermissionForSecurityOrigin:decisionHandler:)
    func askedForNotifications(_ webView: WKWebView, origin: WKSecurityOrigin, decisionHandler: @escaping (Bool) -> Void) {
        let site = Browser.origin(origin.protocol, origin.host, origin.port)
        guard prefs.siteNotifications, let tab = tab(for: webView), !tab.shy, webView.configuration.websiteDataStore.isPersistent,
              !origin.host.isEmpty,
              let page = webView.url, let scheme = page.scheme, let host = page.host(),
              Browser.origin(scheme, host, page.port ?? 0) == site
        else { return decisionHandler(false) }
        if let remembered = SiteNotifications.choices[site] { return decisionHandler(remembered) }
        HookAsk.permission(site: site, wants: ["notifications"], tab: tab, in: self, asker: origin.protocol) { [weak self, weak webView] hooked in
            if let hooked {
                if hooked { SiteNotifications.shared.authorize() }
                return decisionHandler(hooked)
            }
            guard let self, let webView else { return decisionHandler(false) }
            ask(from: webView, show: { [weak self] in
                guard let self else { return decisionHandler(false) }
                guard !permissionBusy else { return decisionHandler(false) }
                decide = { decision in
                    if decision == .grant { SiteNotifications.shared.authorize() }
                    decisionHandler(decision == .grant)
                    SiteNotifications.shared.changed()
                }
                askedAbout = "\(site)|notifications"
                asking = CaptureAsk(host: origin.host, wants: "notifications")
            }, drop: { decisionHandler(false) })
        }
    }

    func localNetworkStep(_ action: WKNavigationAction, to url: URL, in webView: WKWebView) -> LocalNetwork.Step {
        let source: WKFrameInfo? = action.sourceFrame
        guard let source, let page = LocalNetwork.origin(source.securityOrigin) else { return .go }
        let tab = popupTab(for: webView)
        let shy = tab?.shy == true || !webView.configuration.websiteDataStore.isPersistent
        let answer = LocalNetwork.origin(page).flatMap { LocalNetworkGuard.shared.answer(for: $0, tab: tab?.id, shy: shy) }
        let flag: (String) -> Bool = { key in
            action.responds(to: NSSelectorFromString(key)) && (action.value(forKey: key) as? Bool) == true
        }
        let own = (webView as? PageView)?.started.map { started in
            action.responds(to: NSSelectorFromString("_mainFrameNavigation")) && (action.value(forKey: "_mainFrameNavigation") as AnyObject?) === started
        } ?? false
        return LocalNetwork.step(source: page, target: url, userInitiated: own || flag("_isUserInitiated"), redirect: flag("_isRedirect"),
                                 type: action.navigationType, on: prefs.asksLocalNetwork, answer: answer,
                                 developer: Developer.shared.isOn(page))
    }

    @objc(_webView:contentRuleListWithIdentifier:performedAction:forURL:)
    func ruleListActed(_ webView: WKWebView, identifier: String, action: NSObject, url: URL) {
        if action.responds(to: NSSelectorFromString("blockedLoad")), (action.value(forKey: "blockedLoad") as? Bool) == true {
            DownloadTrace.note("blocked", ["list": identifier, "url": url.absoluteString], private: tracesPrivately(webView))
        }
        guard identifier == LocalNetwork.identifier,
              action.responds(to: NSSelectorFromString("blockedLoad")),
              (action.value(forKey: "blockedLoad") as? Bool) == true,
              let tab = popupTab(for: webView),
              let site = LocalNetworkGuard.shared.guardedOrigin(webView.configuration.userContentController),
              let page = URL(string: site)
        else { return }
        let shy = tab.shy || !webView.configuration.websiteDataStore.isPersistent
        if Store.testing { LocalNetworkGuard.shared.blocked.append(url.absoluteString) }
        guard LocalNetworkGuard.shared.answer(for: site, tab: tab.id, shy: shy) == nil,
              LocalNetworkGuard.shared.firstAsk(tab: tab.id, origin: site) else { return }
        askLocalNetwork(from: webView, tab: tab, page: page, target: url) { [weak tab] allowed in
            guard allowed, let tab else { return }
            tab.reload()
        }
    }

    func askLocalNetwork(from webView: WKWebView, tab: Tab, page: URL?, target: URL, then: @escaping (Bool) -> Void) {
        guard let page, let site = LocalNetwork.origin(page) else { return then(false) }
        let shy = tab.shy || !webView.configuration.websiteDataStore.isPersistent
        let id = tab.id
        ask(from: webView, show: { [weak self] in
            guard let self, !permissionBusy else { return then(false) }
            decide = { decision in
                let allowed = decision == .grant
                if shy {
                    LocalNetworkGuard.shared.remember(allowed, origin: site, tab: id, shy: true)
                } else {
                    LocalNetworkGuard.shared.refitAll()
                    SiteNotifications.shared.changed()
                }
                then(allowed)
            }
            askedAbout = shy ? "" : "\(site)|\(LocalNetwork.kind)"
            asking = CaptureAsk(host: page.host(percentEncoded: false) ?? site, wants: LocalNetwork.kind,
                                reach: LocalNetwork.shown(target), mac: LocalNetwork.reach(target) == .loopback)
        }, drop: { then(false) })
    }

    /// "scheme://host[:port]", the way an origin is kept for its answers.
    static func origin(_ scheme: String, _ host: String, _ port: Int) -> String {
        let scheme = scheme.lowercased(), host = host.lowercased()
        let standard = (scheme == "https" && port == 443) || (scheme == "http" && port == 80)
        return "\(scheme)://\(host)" + (port == 0 || standard ? "" : ":\(port)")
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "camera and microphone"
        @unknown default: return "camera and microphone"
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
        loadFailedBeforeCommit(webView, error)
    }

    /// A page asking to close itself.
    ///
    /// Signing in with Google — or with anything using OAuth — happens in a
    /// window the page opens, and that window calls close() when it is done.
    /// With nobody listening for it, what is left behind is a tab holding the
    /// blank page the flow ended on: nothing to look at, and nothing for
    /// reload to fetch, because there is no longer an address to fetch.
    func webViewDidClose(_ webView: WKWebView) {
        if leaveHeardClose(webView) { return }
        guard let tab = tab(for: webView) else { return }
        // A popup window is the one page it opened: when that
        // page closes itself (a sign-in, once done), the
        // window goes too, as in Chrome, instead of staying on a blank tab.
        if isPopup, tabs.count == 1 {
            window?.close()
            return
        }
        if tab.id == activeID, let opener = tab.opener, let home = tabs.first(where: { $0.id == opener }), !home.agent {
            select(home)
        }
        tab.pin = nil
        close(tab)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        popupTab(for: webView)?.popupGesture.clear()
        popupTab(for: webView)?.didCommit()
        guard let tab = anyTab(for: webView) else {
            // A peek or a small window opens at the size the site has, or
            // the one in Settings, as a tab does: neither is in the row,
            // and both opened at 100% (#691).
            if let page = peekTab, page.built === webView {
                page.applyRememberedZoom()
            }
            return
        }
        // A page that went somewhere else starts a new run of links.
        if linkRun?.opener == tab.id { linkRun = nil }
        tab.extensionReturn.finished(navigation)
        if tab.id == activeID {
            invalidateFindPage(retryOnActiveTab: false)
            linkStatus.dismiss()
        }
        tab.failure = nil
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
        // A tab waking from sleep: the new document is in, and a moment
        // after it is on screen the picture of the old one can go.
        tab.uncover(after: 0.45)
    }

    /// The page has drawn something: a view kept out of sight until now, so
    /// as not to show the white it starts as, comes in. WebKit calls this only
    /// on a view asked to — see `PageView.holdForFirstFrame()`.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        (webView as? PageView)?.showUnlessBlank()
        // Dark pages: a page's first frame is what it looks like.
        if let tab = tab(for: webView) { duskLook(tab) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame. Done is
        // done, and it is shown.
        (webView as? PageView)?.showUnlessBlank()
        guard let tab = anyTab(for: webView), let url = tab.address else { return }
        tab.uncover()
        if tab.id == activeID { Developer.shared.arrived(tab, offers: prefs.offersDeveloperMode) }
        // And again once it has all come in, for a page that drew its look
        // late, or never had a first frame to say so.
        duskLook(tab)
        // The find bar still open over a page that has just come in: look
        // for the same words on it.
        if tab.id == activeID, finding, findSpec == nil,
           !needle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            look(forward: true)
        }
        tellStore(tab)
        liveTabLanded(tab, at: url)
        AIGroups.shared.landed(tab, in: self)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // A page in a language you always translate, or one that slept
        // translated (Translate.swift). Nothing at all while it's off.
        tab.translateIfWanted()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        guard !tab.shy, !tab.bench, !tab.agentSteeredLately else { return }
        history.record(url, title: tab.titleSettled ? tab.title : "", from: tab.takeOrigin(), space: spaceOf(tab))
        rememberText(of: tab, at: url)
        // A site's home page that says where its search is (OpenSearch):
        // with Search a site on, it joins the list (see SiteSearch.learn).
        if prefs.searchesSites, url.scheme == "https", url.path.isEmpty || url.path == "/" {
            webView.evaluateInSearch(SiteSearch.lookup) { value in
                guard let text = value as? String, let description = URL(string: text) else { return }
                MainActor.assumeIsolated { SiteSearch.learn(from: url, description: description) }
            }
        }
    }

    private func fail(_ webView: WKWebView, _ error: Error) {
        let tab = anyTab(for: webView)
        if tab?.memoryStopped == true { return }
        DownloadTrace.error("page-failed", error, ["url": webView.url?.absoluteString ?? ""], private: tracesPrivately(webView))
        tab?.uncover()
        let nsError = error as NSError
        let code = nsError.code
        // Cancelled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else { return }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked — clicked again,
        // it downloaded again.
        guard !(nsError.domain == "WebKitErrorDomain" && code == 102) else { return }
        // Nor is a video or sound file opened as a page: WebKit's own player
        // takes it over and ends the load with "plug-in handled load" (204),
        // as in Safari, while the video plays. Answered as a failure, it
        // covered the playing video with "The page didn't load".
        guard !(nsError.domain == "WebKitErrorDomain" && code == 204) else { return }
        TroubleKind.lastSeen = "\(nsError.domain) \(code)"
        tab?.failure = TroubleKind(error: nsError).message
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.built === webView }
    }

    func popupTab(for webView: WKWebView) -> Tab? {
        guard webView.navigationDelegate === self else { return nil }
        return anyTab(for: webView)
            ?? (peekTab?.built === webView ? peekTab : nil)
    }

    /// The tab a page belongs to, in the space on screen or another: a page
    /// still loading when you went to another space finishes there, and
    /// still goes into History with its icon.
    func anyTab(for webView: WKWebView) -> Tab? {
        tab(for: webView) ?? parkedTabs.first { $0.built === webView }
    }
}

// MARK: - keeping files

extension Browser: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        DownloadTrace.note("asked-destination", ["url": response.url?.absoluteString ?? "", "suggested": suggestedFilename,
                                                 "type": response.mimeType ?? ""], private: tracesPrivately(download))
        if let guess = speculating.removeValue(forKey: ObjectIdentifier(download)) {
            guard FileAnswer.fetchedIsFile(response) else {
                DownloadTrace.note("refused-page", ["url": guess.url.absoluteString], private: tracesPrivately(download))
                return completionHandler(nil)
            }
            DownloadTrace.note("refused-file", ["url": guess.url.absoluteString], private: tracesPrivately(download))
            (tabs + parkedTabs).first { $0.id == guess.opener }?.blockedPopups.removeAll { $0.url == guess.url }
            keep(download, from: download.webView)
        }
        if fetches.destination(for: download) == nil,
           gateSiteFile(download, response: response,
                        name: Browser.fileName(response.url.flatMap { namedDownloads[$0] } ?? suggestedFilename),
                        agent: AgentDownloadWatch.watches(download),
                        then: { [weak self] in
                            guard let self else { return completionHandler(nil) }
                            self.download(download, decideDestinationUsing: response, suggestedFilename: suggestedFilename,
                                          completionHandler: completionHandler)
                        },
                        drop: { [weak self] in
                            self?.dropSiteFile(download)
                            completionHandler(nil)
                        }) {
            return
        }
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let chosen = fetches.destination(for: download)
        let name = Browser.fileName(asked ?? suggestedFilename)
        let agent = AgentDownloadWatch.folder(for: download, in: self, type: response.mimeType)
        if chosen == nil, agent == nil, !AgentDownloadWatch.watches(download), prefs.asksWhereToSave {
            SaveAsk.shared.ask(name, from: download.webView, in: self, download: download,
                               quiet: unlisted.contains(ObjectIdentifier(download))) { [weak self] file in
                guard let self else { return completionHandler(nil) }
                self.place(download, at: file, chosen: nil, name: name, held: false, asked: true, completionHandler)
            }
            return
        }
        let folder = chosen?.deletingLastPathComponent() ?? agent ?? downloadsFolder
        let wanted = chosen?.lastPathComponent ?? name
        Task { @MainActor [weak self] in
            let found = await DownloadPlace.find(wanted, in: folder, numbered: chosen == nil, seconds: DownloadPlace.patience)
            guard let self else { return completionHandler(nil) }
            self.place(download, at: found.file, chosen: chosen, name: name, held: found.held, completionHandler)
        }
    }

    private func place(_ download: WKDownload, at file: URL?, chosen: URL?, name: String, held: Bool, asked: Bool = false, _ completionHandler: @escaping (URL?) -> Void) {
        DownloadTrace.note("placed", ["file": file?.path ?? "", "held": String(held)], private: tracesPrivately(download))
        guard let file else {
            if let ended = fetches.destinationCancelled(download) {
                ended.owner.relinquish(download)
            } else {
                relinquish(download)
            }
            AgentDownloadWatch.failed(download, "No place was chosen for it")
            completionHandler(nil)
            return
        }
        fetches.going(download, to: file, cancel: finderCancellation(for: download))
        if chosen == nil { fetches.entry(for: download)?.retryName = asked ? file.lastPathComponent : name }
        AgentDownloadWatch.placed(download, at: file)
        completionHandler(file)
        announce(held ? "macOS hasn't let Broadway into that folder yet, so \(file.lastPathComponent) went to Broadway's own folder" : "Downloading \(file.lastPathComponent)")
    }

    func downloadDidFinish(_ download: WKDownload) {
        let entry = fetches.entry(for: download)
        let source = download.originalRequest?.url ?? entry?.request?.url
        let file = download.progress.fileURL ?? entry?.destination
        let listed = !unlisted.contains(ObjectIdentifier(download))
        DownloadTrace.note("finished", ["file": file?.path ?? "", "listed": String(listed)], private: tracesPrivately(download))
        AgentDownloadWatch.finished(download, at: file)
        let ended = fetches.finish(download, file: file)
        (ended?.owner ?? self).relinquish(download)
        guard ended != nil else { return }
        guard let file else {
            announce("Download finished")
            return
        }
        guard listed else {
            let owner = ended?.owner ?? self
            if !owner.shut {
                owner.privateFileDownloads.removeAll { $0.path == file.path }
                owner.privateFileDownloads.insert(Keep(name: file.lastPathComponent, from: source?.host() ?? "", path: file.path, date: Date()), at: 0)
                if owner.privateFileDownloads.count > 500 { owner.privateFileDownloads.removeLast() }
            }
            announce("Saved \(file.lastPathComponent)")
            return
        }
        if let asked = source,
           let id = ExtensionShims.askedDownloads.removeValue(forKey: asked) {
            ExtensionShims.ownDownloads[id, default: []].insert(file.path)
        }
        saved(file, from: source)
        HookDownloads.finished(download, file: file, source: source, in: self)
    }

    /// The download button in the bar WebKit draws over a PDF. WebKit has the
    /// file already and hands it over whole — to a delegate that answers
    /// this name, outside the public framework, and to nobody otherwise: the
    /// button did nothing at all.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data?,
        suggestedFilename: String?,
        mimeType: String?,
        originatingURL: URL?
    ) {
        guard let data else { return }
        let name = Browser.fileName(suggestedFilename ?? "")
        if prefs.asksWhereToSave, anyTab(for: webView).map({ $0.agentHere && !$0.driving }) != true {
            SaveAsk.shared.ask(name, from: webView, in: self) { [weak self, weak webView] file in
                guard let self, let webView, let file else { return }
                self.keepData(data, at: file, webView: webView, originatingURL: originatingURL)
            }
            return
        }
        let folder = downloadsFolder
        Task { @MainActor [weak self, weak webView] in
            let found = await DownloadPlace.find(name, in: folder, numbered: true, seconds: DownloadPlace.patience)
            guard let self, let webView else { return }
            self.keepData(data, at: found.file, webView: webView, originatingURL: originatingURL)
        }
    }

    private func keepData(_ data: Data, at file: URL, webView: WKWebView, originatingURL: URL?) {
        Task { @MainActor [weak self, weak webView] in
            let wrote = await DownloadPlace.write(data, to: file, seconds: DownloadPlace.patience)
            guard let self, let webView else { return }
            self.keptData(wrote, at: file, webView: webView, originatingURL: originatingURL)
        }
    }

    private func keptData(_ wrote: Bool, at file: URL, webView: WKWebView, originatingURL: URL?) {
        do {
            guard wrote else { throw CocoaError(.fileWriteUnknown) }
            if anyTab(for: webView)?.shy == true || !webView.configuration.websiteDataStore.isPersistent {
                if !shut {
                    privateFileDownloads.removeAll { $0.path == file.path }
                    privateFileDownloads.insert(Keep(name: file.lastPathComponent, from: originatingURL?.host() ?? "", path: file.path, date: Date()), at: 0)
                }
                announce("Saved \(file.lastPathComponent)")
            } else {
                saved(file, from: originatingURL)
            }
        } catch {
            announce("That download didn't finish", kind: .error)
        }
    }

    /// A page's own print(): the Print… item in a page's own menu, or ⌘P in
    /// an editor that keeps the key for itself (the page has it first, see
    /// `pageFirst`). WebKit hands it to a delegate that answers this name,
    /// outside the public framework, and to nobody otherwise: the button did
    /// nothing at all, and neither did ⌘P.
    ///
    /// The page waits while the sheet is up, as it does in Safari: WebKit
    /// holds its script until `done`, and draws the pages meanwhile. Only the
    /// tab in front of the window you are in may ask, one sheet at a time: a
    /// tab behind, or another window's, is answered with nothing, as Safari
    /// does. And a site that asks again each time the sheet is cancelled
    /// asks no more after the second cancel within ten seconds, until the
    /// tab goes to another site (see PrintSheet).
    @objc(_webView:printFrame:pdfFirstPageSize:completionHandler:)
    func webView(
        _ webView: WKWebView,
        printFrame frame: NSObject,
        pdfFirstPageSize: CGSize,
        completionHandler done: @escaping () -> Void
    ) {
        guard let window = webView.window, window.isKeyWindow, window.attachedSheet == nil,
              let tab = anyTab(for: webView), tab.id == activeID, !tab.isBlank,
              PrintSheet.allows(tab)
        else { done(); return }
        let sheet = PrintSheet(tab) { done() }
        Browser.printing(webView, frame: frame).runModal(
            for: window, delegate: sheet,
            didRun: #selector(PrintSheet.printOperationDidRun(_:success:contextInfo:)),
            contextInfo: Unmanaged.passRetained(sheet).toOpaque()
        )
    }

    private static func fileName(_ name: String) -> String {
        let last = (name as NSString).lastPathComponent
        return ["", ".", "..", "/"].contains(last) ? "download" : last
    }

    private func saved(_ file: URL, from source: URL?) {
        loot.add(Keep(name: file.lastPathComponent, from: source?.host() ?? "", path: file.path, date: Date()))
        announce("Saved \(file.lastPathComponent)", file: file)
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        DownloadTrace.error("failed", error, ["url": download.originalRequest?.url?.absoluteString ?? ""], private: tracesPrivately(download))
        if speculating.removeValue(forKey: ObjectIdentifier(download)) != nil { return }
        AgentDownloadWatch.failed(download, error.localizedDescription)
        guard let ended = fetches.fail(download, error: error, resumeData: resumeData) else { return }
        ended.owner.relinquish(download)
        if ended.announceFailure { announce("That download didn't finish", kind: .error) }
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    private static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}

/// What a page's print() is waiting on: told when the sheet has gone,
/// printed or cancelled, so WebKit can let the page's script go on. The
/// sheet's context keeps it alive until then.
@MainActor
final class PrintSheet: NSObject {
    private let done: () -> Void
    private let tab: Tab.ID
    private let site: String?

    init(_ tab: Tab, _ done: @escaping () -> Void) {
        self.tab = tab.id
        self.site = PrintSheet.site(of: tab)
        self.done = done
    }

    /// The sheets a page's print() had cancelled, by tab, on the site it
    /// was on: its origin, not its address, which the page itself can
    /// change with history.pushState between two print()s. Two cancels
    /// within ten seconds and the site asks no more, until the tab goes to
    /// another site or closes.
    private struct Cancels {
        var site: String?
        var when: [Date] = []
        var blocked = false
    }
    private static var cancelled: [Tab.ID: Cancels] = [:]

    private static func site(of tab: Tab) -> String? {
        guard let page = tab.committed else { return nil }
        return "\(page.scheme ?? "")://\(page.host() ?? ""):\(page.port.map(String.init) ?? "")"
    }

    /// Whether this tab's site may bring the sheet up again.
    static func allows(_ tab: Tab) -> Bool {
        guard let seen = cancelled[tab.id], seen.site == site(of: tab) else {
            cancelled[tab.id] = nil
            return true
        }
        return !seen.blocked
    }

    @objc func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if let contextInfo { Unmanaged<PrintSheet>.fromOpaque(contextInfo).release() }
        if !success {
            var seen = PrintSheet.cancelled[tab].flatMap { $0.site == site ? $0 : nil } ?? Cancels(site: site)
            let now = Date()
            seen.when = seen.when.filter { now.timeIntervalSince($0) < 10 } + [now]
            if seen.when.count >= 2 { seen.blocked = true }
            PrintSheet.cancelled[tab] = seen
        }
        done()
    }
}

// MARK: - Search's own pages, in tabs (see InternalPages.swift)

extension Browser {
    /// The tab in this window's row showing that kind of page, if any.
    func pageTab(_ kind: InternalPage.Kind) -> Tab? {
        tabs.first { $0.page?.kind == kind }
    }

    /// ⌘, ⌘Y ⇧⌘J and the menus: the page's tab, brought forward if it is
    /// open, made otherwise. An empty tab in front becomes the page rather
    /// than being left behind it; a private one doesn't — these pages are
    /// never private, as Chrome's settings never open in an incognito
    /// window — and the page opens beside it.
    @discardableResult
    func show(_ page: InternalPage) -> Tab {
        if page.kind == .settings, let detail = page.detail, let section = SettingsPage.named( detail) {
            settingsPage = section
        }
        if page.kind == .settings, SettingsWindow.stands, let here = active ?? tabs.first {
            SettingsWindow.shared.open(self, section: page.detail)
            return here
        }
        if page.kind == .passwords { relist() }
        if page.kind == .history, pageTab(.history) == nil { recallMode = .history }
        let tab: Tab
        if let open = pageTab(page.kind) {
            tab = open
            // Asked for another section, or another browser to bring
            // things from: the open tab moves there, without a step back.
            if page.detail != nil, open.page != page {
                open.show(page, stepping: false)
                revision &+= 1
            }
        } else {
            if let blank = active, blank.isBlank, !blank.shy, !blank.bench, blank.pin == nil,
               blank.draft.isEmpty, typed.isEmpty {
                tab = blank
            } else {
                tab = makeTab()
                prepare(tab)
                tabs.insert(tab, at: placeForNew())
            }
            tab.show(page)
        }
        if launching { dismiss() }
        summoning = false
        editing = false
        typed = ""
        if activeID != tab.id { select(tab) }
        writeSessionSoon()
        return tab
    }

    /// From one of these pages to another — Settings' "Passwords…", Bring
    /// Things Over's "Show bookmarks": the same tab goes there, and Back
    /// comes back, as a link would. Unless that page is already open in a
    /// tab of its own, which is then the one shown.
    func lead(to page: InternalPage) {
        guard let here = active, here.page != nil, pageTab(page.kind) == nil else {
            show(page)
            return
        }
        if page.kind == .settings, let detail = page.detail, let section = SettingsPage.named( detail) {
            settingsPage = section
        }
        // As show(_:) does: the list read before the page is drawn.
        if page.kind == .passwords { relist() }
        here.show(page)
        writeSessionSoon()
    }

    /// The page's tab closed, as ⌘W would close it. For the bench, and the
    /// last few callers that put a panel away.
    func putAway(_ kind: InternalPage.Kind) {
        guard let tab = pageTab(kind) else { return }
        close(tab)
    }

    /// Settings moved to another of its sections: the tab's address says
    /// so, and comes back there after a relaunch.
    func settingsMoved(to section: SettingsPage) {
        guard let tab = pageTab(.settings), tab.page?.detail != section.rawValue else { return }
        tab.show(InternalPage(.settings, section.rawValue), stepping: false)
        writeSessionSoon()
    }
}
