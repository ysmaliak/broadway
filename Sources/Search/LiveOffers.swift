import AppKit
import Observation

struct LiveOffer: Equatable, Identifiable {
    var id: String
    var space: UUID
    var title: String
    var name: String
    var source: LiveSource
    var items: [LiveItem] = []

    var key: String { "\(space.uuidString)|\(id)" }
    var gives: String { LiveOfferWords.gives(source) }
}

enum LiveOfferWords {
    static let add = "Add Folder"
    static let addShort = "Add"
    static let decline = "No Thanks"
    static let undo = "Add Live Folder"
    static let again = "Suggest Again"

    static func gives(_ source: LiveSource) -> String {
        switch source.kind {
        case .pullRequests, .repository: return "Your open pull requests on \(source.siteName), kept up to date"
        case .issues: return "Your open issues on \(source.siteName), kept up to date"
        case .linear: return "Issues assigned to you in \(source.siteName), kept up to date"
        case .notifications: return "Your \(source.siteName) notifications, kept up to date"
        case .subscriptions: return "New videos from your \(source.siteName) subscriptions"
        case .feed, .page:
            if LiveDrive.reads(source) { return "Files you opened lately on \(source.siteName), kept up to date" }
            return "What is new on \(source.siteName), kept up to date"
        }
    }

    static func spoken(_ offer: LiveOffer) -> String {
        "Suggested folder in the sidebar: \(offer.name). \(offer.gives)."
    }

    static func turnedDown(_ titles: [String]) -> String {
        titles.count == 1 ? "You turned down \(titles[0])" : "You turned down \(titles.count) suggestions"
    }
}

struct LiveOfferPast: Codable, Equatable {
    var space: UUID
    var id: String
    var turnedDown: Date? = nil
    var byTimer: Bool? = nil
    var seen: TimeInterval? = nil
    var tried: Date? = nil
    var empty: Bool? = nil
}

struct LiveVisit: Equatable {
    var url: URL?
    var space: UUID
    var quiet: String? = nil
}

@MainActor
enum LiveOfferRule {
    static func spot(_ url: URL?) -> LiveSuggestions.Spot? {
        guard let url, let spot = LiveSuggestions.spot(url), spot.source.kind != .feed else { return nil }
        return spot
    }

    static func refusal(_ visit: LiveVisit, folders: [LiveFolder], past: [LiveOfferPast]) -> String? {
        if let quiet = visit.quiet { return quiet }
        guard let url = visit.url, let spot = spot(url) else { return "site" }
        if LiveSignOn.step(url) { return "signing in" }
        if LiveSuggestions.covered(spot.source, by: folders.filter { $0.space == visit.space }) { return "covered" }
        if past.contains(where: { $0.space == visit.space && $0.id == spot.id && $0.turnedDown != nil }) { return "turned down" }
        return nil
    }

    static func left(seen: TimeInterval, lasts: TimeInterval, lastLook: TimeInterval) -> TimeInterval {
        max(0, min(max(lasts - seen, min(lastLook, lasts)), lasts + lastLook - seen))
    }

    static func tries(_ past: LiveOfferPast?, now: Date, emptyRetry: TimeInterval = LiveOffers.emptyRetry,
                      shutRetry: TimeInterval = LiveOffers.shutRetry) -> Bool {
        guard let tried = past?.tried else { return true }
        return now.timeIntervalSince(tried) >= (past?.empty == true ? emptyRetry : shutRetry)
    }
}

@MainActor
@Observable
final class LiveOffers {
    static let shared = LiveOffers(file: Store.file("live-offers.json"))

    nonisolated static let lasts: TimeInterval = 45
    nonisolated static let lastLook: TimeInterval = 10
    nonisolated static let settles: TimeInterval = 3
    nonisolated static let visits = 3
    nonisolated static let fresh: TimeInterval = 600
    nonisolated static let emptyRetry: TimeInterval = 3_600
    nonisolated static let shutRetry: TimeInterval = 86_400
    nonisolated static let beat: TimeInterval = 0.25

    struct Showing: Equatable {
        var offer: LiveOffer
        var left: TimeInterval
        var anchor: Date
        var running = false
        var before: TimeInterval
        var given: TimeInterval
        var lasts: TimeInterval
        var holds: [String] = []

        func remaining(at now: Date) -> TimeInterval {
            running ? max(0, left - now.timeIntervalSince(anchor)) : left
        }

        func share(at now: Date) -> Double {
            lasts > 0 ? min(1, max(0, remaining(at: now) / lasts)) : 0
        }
    }

    struct Eyes {
        var seen = false
        var held = false
    }

    private final class Window {
        weak var browser: Browser?
        init(_ browser: Browser) { self.browser = browser }
    }

    private final class Eye {
        weak var view: LiveGhostView?
        init(_ view: LiveGhostView) { self.view = view }
    }

    private(set) var showing: [ObjectIdentifier: Showing] = [:]
    private(set) var past: [LiveOfferPast] = []

    @ObservationIgnored var lasts = LiveOffers.lasts
    @ObservationIgnored var lastLook = LiveOffers.lastLook
    @ObservationIgnored var settles = LiveOffers.settles
    @ObservationIgnored var visits = LiveOffers.visits
    @ObservationIgnored var now: @MainActor () -> Date = { Date() }
    @ObservationIgnored var later: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = { wait, run in
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { MainActor.assumeIsolated { run() } }
    }
    @ObservationIgnored var reader: @MainActor (LiveFolder) async -> LiveReader.Answer = { await LiveFolders.shared.reader($0) }
    @ObservationIgnored var frontmost: @MainActor () -> Bool = { NSApp?.isActive ?? false }
    @ObservationIgnored var sight: @MainActor (Browser) -> Bool = { $0.windowSeen }
    @ObservationIgnored var visited: @MainActor (Browser, UUID, String) -> Int = { browser, space, id in
        LiveSuggestions.visits(id, in: browser.history.everything(in: space))
    }
    @ObservationIgnored var folders: @MainActor () -> [LiveFolder] = { LiveFolders.shared.folders }
    @ObservationIgnored var visit: @MainActor (Browser) -> LiveVisit = { $0.liveVisit }
    @ObservationIgnored var watching: (@MainActor (Browser) -> Eyes)?
    @ObservationIgnored var adds: @MainActor (Browser, LiveOffer) -> LiveFolder? = { browser, offer in
        LiveOffers.add(offer, in: browser)
    }
    @ObservationIgnored private(set) var spoken: [String] = []
    @ObservationIgnored private(set) var accepted: [ObjectIdentifier: UUID] = [:]
    @ObservationIgnored private var windows: [ObjectIdentifier: Window] = [:]
    @ObservationIgnored private var eyes: [ObjectIdentifier: [Eye]] = [:]
    @ObservationIgnored private var waiting: [ObjectIdentifier: (key: String, token: UUID)] = [:]
    @ObservationIgnored private var found: [String: (items: [LiveItem], at: Date)] = [:]
    @ObservationIgnored private var trying: Set<String> = []
    @ObservationIgnored private var said: Set<String> = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let file: URL?

    init(file: URL? = nil) {
        self.file = file
        guard let file, let data = try? Data(contentsOf: file) else { return }
        guard let saved = try? JSONDecoder().decode([LiveOfferPast].self, from: data) else {
            Store.quarantine(file)
            return
        }
        past = saved.filter { LiveSuggestions.offered.contains($0.id) }
    }

    nonisolated static func key(_ space: UUID, _ id: String) -> String { "\(space.uuidString)|\(id)" }

    private func save() {
        guard let file else { return }
        let past = past
        Disk.write(file) { try? JSONEncoder().encode(past) }
    }

    func record(_ space: UUID, _ id: String) -> LiveOfferPast? {
        past.first { $0.space == space && $0.id == id }
    }

    private func change(_ space: UUID, _ id: String, _ edit: (inout LiveOfferPast) -> Void) {
        let blank = LiveOfferPast(space: space, id: id)
        var entry = record(space, id) ?? blank
        edit(&entry)
        if entry.seen == 0 { entry.seen = nil }
        if let index = past.firstIndex(where: { $0.space == space && $0.id == id }) {
            guard past[index] != entry else { return }
            past[index] = entry
        } else {
            guard entry != blank else { return }
            past.append(entry)
        }
        save()
    }

    func offer(for browser: Browser) -> LiveOffer? { showing[ObjectIdentifier(browser)]?.offer }

    func clock(for browser: Browser) -> Showing? { showing[ObjectIdentifier(browser)] }

    func filled(in browser: Browser) -> UUID? { accepted[ObjectIdentifier(browser)] }

    func turnedDown(in space: UUID) -> [LiveOfferPast] {
        past.filter { $0.space == space && $0.turnedDown != nil }
    }

    func suggestAgain(in space: UUID) {
        let before = past
        past.removeAll { $0.space == space && $0.turnedDown != nil }
        guard past != before else { return }
        for key in said where key.hasPrefix(space.uuidString) { said.remove(key) }
        save()
        reconsider()
    }

    func forget(space: UUID) {
        let before = past
        past.removeAll { $0.space == space }
        if past != before { save() }
    }

    func reconsider() {
        for window in windows.values { if let browser = window.browser { consider(browser) } }
    }

    func watch(_ view: LiveGhostView, in browser: Browser) {
        let id = ObjectIdentifier(browser)
        var kept = (eyes[id] ?? []).filter { $0.view != nil && $0.view !== view }
        kept.append(Eye(view))
        eyes[id] = kept
    }

    func unwatch(_ view: LiveGhostView, in browser: Browser) {
        let id = ObjectIdentifier(browser)
        eyes[id] = (eyes[id] ?? []).filter { $0.view != nil && $0.view !== view }
    }

    func views(in browser: Browser) -> [LiveGhostView] {
        (eyes[ObjectIdentifier(browser)] ?? []).compactMap(\.view)
    }

    private func looks(_ browser: Browser) -> Eyes {
        if let watching { return watching(browser) }
        let views = views(in: browser)
        return Eyes(seen: views.contains(where: \.inSight), held: views.contains(where: \.held))
    }

    func holds(_ browser: Browser) -> [String] {
        var out: [String] = []
        if !frontmost() { out.append("away") }
        if !sight(browser) { out.append("unseen") }
        if browser.liveOfferBusy { out.append("busy") }
        let eyes = looks(browser)
        if !eyes.seen || browser.folded && !browser.peeking { out.append("hidden") }
        if eyes.held { out.append("held") }
        return out
    }

    private func blocks(_ browser: Browser) -> [String] {
        var out: [String] = []
        if !frontmost() { out.append("away") }
        if !sight(browser) { out.append("unseen") }
        if browser.liveOfferBusy { out.append("busy") }
        return out
    }

    func consider(_ browser: Browser) {
        let id = ObjectIdentifier(browser)
        windows[id] = windows[id] ?? Window(browser)
        guard !browser.liveOfferMoving else { return }
        let visit = self.visit(browser)
        let spot = LiveOfferRule.spot(visit.url)
        let refusal = LiveOfferRule.refusal(visit, folders: folders(), past: past)
        if refusal == "signing in", let spot { change(visit.space, spot.id) { $0.tried = nil; $0.empty = nil } }
        if let shown = showing[id] {
            if refusal == nil, let spot, shown.offer.id == spot.id, shown.offer.space == visit.space {
                hold(browser)
                return
            }
            withdraw(browser)
        }
        guard refusal == nil, let spot else {
            waiting[id] = nil
            return
        }
        let key = Self.key(visit.space, spot.id)
        guard waiting[id]?.key != key else { return }
        let token = UUID()
        waiting[id] = (key, token)
        later(settles) { [weak self, weak browser] in
            guard let self, let browser else { return }
            self.arrive(browser, key: key, token: token)
        }
    }

    private func standing(_ browser: Browser, key: String) -> LiveOffer? {
        let visit = self.visit(browser)
        guard showing[ObjectIdentifier(browser)] == nil, !browser.liveOfferMoving,
              LiveOfferRule.refusal(visit, folders: folders(), past: past) == nil,
              let spot = LiveOfferRule.spot(visit.url), Self.key(visit.space, spot.id) == key, blocks(browser).isEmpty else { return nil }
        return LiveOffer(id: spot.id, space: visit.space, title: spot.title, name: spot.name, source: spot.source)
    }

    private func arrive(_ browser: Browser, key: String, token: UUID) {
        let id = ObjectIdentifier(browser)
        guard waiting[id]?.token == token else { return }
        waiting[id] = nil
        guard var offer = standing(browser, key: key), visited(browser, offer.space, offer.id) >= visits else { return }
        if let known = found[key], now().timeIntervalSince(known.at) < Self.fresh {
            offer.items = known.items
            show(browser, offer)
            return
        }
        guard !trying.contains(key), LiveOfferRule.tries(record(offer.space, offer.id), now: now()) else { return }
        trying.insert(key)
        let asked = LiveFolder(space: offer.space, name: offer.name, source: offer.source)
        Task { @MainActor [weak self, weak browser] in
            guard let self else { return }
            let answer = await self.reader(asked)
            self.trying.remove(key)
            self.read(answer, for: offer)
            guard let browser, var offer = self.standing(browser, key: key), let known = self.found[key] else { return }
            offer.items = known.items
            self.show(browser, offer)
        }
    }

    func read(_ answer: LiveReader.Answer, for offer: LiveOffer) {
        if let items = answer.found, !items.isEmpty {
            found[offer.key] = (items, now())
            change(offer.space, offer.id) { $0.tried = nil; $0.empty = nil }
            return
        }
        found[offer.key] = nil
        var empty = false
        if answer.found != nil { empty = true }
        let at = now()
        change(offer.space, offer.id) { $0.tried = at; $0.empty = empty ? true : nil }
    }

    private func show(_ browser: Browser, _ offer: LiveOffer) {
        let id = ObjectIdentifier(browser)
        let seen = record(offer.space, offer.id)?.seen ?? 0
        let left = LiveOfferRule.left(seen: seen, lasts: lasts, lastLook: lastLook)
        guard left > 0 else {
            let at = now()
            change(offer.space, offer.id) { $0.turnedDown = at; $0.byTimer = true }
            return
        }
        accepted[id] = nil
        showing[id] = Showing(offer: offer, left: left, anchor: now(), before: seen, given: left, lasts: lasts)
        run()
        later(0) { [weak self, weak browser] in
            guard let self, let browser else { return }
            self.hold(browser)
        }
        guard said.insert(offer.key).inserted else { return }
        let words = LiveOfferWords.spoken(offer)
        spoken.append(words)
        guard let window = browser.window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: words, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    @discardableResult
    func hold(_ browser: Browser, at time: Date? = nil) -> [String] {
        let id = ObjectIdentifier(browser)
        guard var shown = showing[id] else { return [] }
        let now = time ?? self.now()
        let holds = holds(browser)
        if holds.isEmpty != shown.running {
            shown.left = shown.remaining(at: now)
            shown.anchor = now
            shown.running = holds.isEmpty
        }
        shown.holds = holds
        if shown != showing[id] { showing[id] = shown }
        return holds
    }

    func tick(at time: Date? = nil) {
        let now = time ?? self.now()
        for id in Array(showing.keys) {
            guard let browser = windows[id]?.browser else {
                showing[id] = nil
                continue
            }
            hold(browser, at: now)
            guard let current = showing[id], current.running, current.remaining(at: now) <= 0 else { continue }
            turnDown(browser, byTimer: true)
        }
        if showing.isEmpty { stop() }
    }

    private func spent(_ shown: Showing, at now: Date) -> TimeInterval {
        shown.before + max(0, shown.given - shown.remaining(at: now))
    }

    func withdraw(_ browser: Browser) {
        let id = ObjectIdentifier(browser)
        guard let shown = showing.removeValue(forKey: id) else { return }
        let at = now()
        let seen = spent(shown, at: at)
        let out = LiveOfferRule.left(seen: seen, lasts: lasts, lastLook: lastLook) <= 0
        change(shown.offer.space, shown.offer.id) { entry in
            entry.seen = seen
            if out {
                entry.turnedDown = at
                entry.byTimer = true
            }
        }
        if showing.isEmpty { stop() }
    }

    func turnDown(_ browser: Browser, byTimer: Bool = false) {
        let id = ObjectIdentifier(browser)
        guard let shown = showing[id] else { return }
        let at = now()
        let seen = spent(shown, at: at)
        for (other, entry) in showing where entry.offer.key == shown.offer.key { showing[other] = nil }
        change(shown.offer.space, shown.offer.id) { entry in
            entry.turnedDown = at
            entry.byTimer = byTimer ? true : nil
            entry.seen = seen
        }
        if showing.isEmpty { stop() }
    }

    @discardableResult
    func accept(_ browser: Browser) -> LiveFolder? {
        let id = ObjectIdentifier(browser)
        guard let shown = showing[id] else { return nil }
        let seen = spent(shown, at: now())
        for (other, entry) in showing where entry.offer.key == shown.offer.key { showing[other] = nil }
        change(shown.offer.space, shown.offer.id) { $0.seen = seen }
        if showing.isEmpty { stop() }
        guard let made = adds(browser, shown.offer) else { return nil }
        accepted[id] = made.id
        return made
    }

    static func add(_ offer: LiveOffer, in browser: Browser) -> LiveFolder? {
        let live = LiveFolders.shared
        if !browser.prefs.liveFolders { browser.prefs.liveFolders = true }
        let made = live.add(name: offer.name, source: offer.source, space: offer.space)
        if !offer.items.isEmpty { live.apply(.items(offer.items, nil), to: made.id) }
        LiveOffers.shared.accepted[ObjectIdentifier(browser)] = made.id
        browser.syncLive()
        browser.unfoldFolder(made.id)
        let id = made.id
        browser.offerStep(LiveOfferWords.undo) { _ in LiveFolders.shared.remove(id) }
        return live.folder(made.id)
    }

    private func run() {
        guard timer == nil, !Store.unitTests else { return }
        let made = Timer(timeInterval: Self.beat, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(made, forMode: .common)
        timer = made
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    func reason(_ browser: Browser) -> String? {
        LiveOfferRule.refusal(visit(browser), folders: folders(), past: past) ?? blocks(browser).first
    }

    func waits(_ browser: Browser) -> Bool { waiting[ObjectIdentifier(browser)] != nil }

    func reads(_ browser: Browser) -> Bool {
        let visit = self.visit(browser)
        guard let spot = LiveOfferRule.spot(visit.url) else { return false }
        return trying.contains(Self.key(visit.space, spot.id))
    }

    func resetForTests() {
        showing = [:]
        past = []
        accepted = [:]
        windows = [:]
        eyes = [:]
        waiting = [:]
        found = [:]
        trying = []
        said = []
        spoken = []
        stop()
    }
}

extension Browser {
    var liveVisit: LiveVisit {
        LiveVisit(url: active?.address, space: spaceID, quiet: liveVisitQuiet)
    }

    var liveVisitQuiet: String? {
        if isPrivate { return "private" }
        if isPopup { return "popup" }
        if !prefs.liveFolders || !prefs.usesTabGroups { return "off" }
        if !prefs.suggestsLiveFolders { return "suggestions off" }
        if Onboarding.shared.showing { return "onboarding" }
        guard let tab = active else { return "no tab" }
        if tab.shy { return "private" }
        if tab.popup { return "popup" }
        if tab.bench { return "bench" }
        if tab.agent || tab.agentSteeredLately { return "agent" }
        return nil
    }

    var liveOfferMoving: Bool { spaceNext != nil || makingSpace }

    var liveOfferBusy: Bool { liveOfferBehind != nil }

    var liveOfferBehind: String? {
        if peekTab != nil { return "peek" }
        if linkNotice != nil { return "link notice" }
        if asking != nil { return "question" }
        if offering != nil { return "offer" }
        let tab = active?.id
        if StoreOfferRules.offered(active, Extensions.shared) != nil { return "store" }
        if let up = forms.preview, up.tab == tab { return "fill" }
        if let up = forms.offer, up.tab == tab { return "save" }
        if let host = Shield.shared.offer, host == hereHost { return "shield" }
        if let key = Developer.shared.offer, key == LocalServer.key(active?.pageAddress) { return "developer" }
        if let up = drafts.preview, up.tab == tab { return "draft" }
        return nil
    }

    func considerLiveOffer() {
        guard !isPopup else { return }
        LiveOffers.shared.consider(self)
    }

    func watchLiveOffers() -> AnyObject {
        let prefs = prefs
        let offers = LiveOffers.shared
        let live = LiveFolders.shared
        return kitObserve(initial: true, { [weak self] in
            guard let self else { return 0 }
            _ = (self.activeID, self.spaceID, self.active?.address, self.spaceNext, self.makingSpace, self.peekTab == nil)
            _ = (prefs.liveFolders, prefs.suggestsLiveFolders, prefs.usesTabGroups, self.linkNotice == nil)
            _ = live.folders.map(\.id)
            _ = offers.past.count
            return 0
        }) { [weak self] _ in self?.considerLiveOffer() }
    }
}

extension LiveOffers {
    private func shownView(in browser: Browser) -> LiveGhostView? {
        let all = views(in: browser).filter { $0.window != nil && $0.interactive && !$0.filling }
        return all.first { !$0.isHiddenOrHasHiddenAncestor } ?? all.first
    }

    private func box(_ view: NSView) -> [Double] {
        guard let content = view.window?.contentView else { return [] }
        let rect = view.convert(view.bounds, to: content)
        let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
        return [rect.minX, top, rect.width, rect.height].map { Double($0) }
    }

    func benchState(_ browser: Browser) -> [String: Any] {
        let at = now()
        var out: [String: Any] = [
            "on": browser.prefs.suggestsLiveFolders,
            "reason": reason(browser) ?? "",
            "behind": browser.liveOfferBehind ?? "",
            "waiting": waits(browser),
            "reading": reads(browser),
            "spoken": spoken,
            "pace": ["lasts": lasts, "settles": settles, "lastLook": lastLook, "visits": visits],
            "past": past.map { entry in
                ["space": browser.spaces.first { $0.id == entry.space }?.name ?? entry.space.uuidString, "id": entry.id,
                 "turnedDown": entry.turnedDown != nil, "byTimer": entry.byTimer == true, "seen": entry.seen ?? 0,
                 "tried": entry.tried != nil, "empty": entry.empty == true] as [String: Any]
            },
            "visits": LiveOfferRule.spot(visit(browser).url).map { visited(browser, visit(browser).space, $0.id) } ?? 0,
            "canUndo": browser.window?.undoManager?.canUndo ?? false,
            "undoName": browser.window?.undoManager?.undoActionName ?? "",
            "canRedo": browser.window?.undoManager?.canRedo ?? false,
            "moving": browser.liveOfferMoving,
        ]
        if let shown = clock(for: browser) {
            out["shown"] = ["id": shown.offer.id, "name": shown.offer.name, "title": shown.offer.title, "gives": shown.offer.gives,
                            "space": browser.spaces.first { $0.id == shown.offer.space }?.name ?? "", "items": shown.offer.items.count,
                            "left": shown.remaining(at: at), "share": shown.share(at: at), "running": shown.running,
                            "holds": shown.holds] as [String: Any]
        }
        let ghosts = views(in: browser).filter { $0.window != nil }
        out["ghosts"] = ghosts.count
        out["drawn"] = ghosts.map { view in
            ["frame": box(view), "hidden": view.isHiddenOrHasHiddenAncestor, "live": view.interactive, "filling": view.filling,
             "clipped": Double(view.visibleRect.height)] as [String: Any]
        }
        if let view = shownView(in: browser) {
            out["view"] = ["frame": box(view), "add": view.add.title, "decline": view.decline.title, "addFrame": box(view.add),
                           "declineFrame": box(view.decline), "nameWidth": Double(view.nameFrame.width), "folded": view.decline.folded, "crossWidth": Double(view.decline.shownFrame.width), "inSight": view.inSight, "held": view.held, "time": view.timeShare,
                           "label": view.accessibilityLabel() ?? "", "help": view.accessibilityHelp() ?? "",
                           "addLabel": view.add.accessibilityLabel() ?? "", "declineLabel": view.decline.accessibilityLabel() ?? "",
                           "focusable": [view.add.acceptsFirstResponder, view.decline.acceptsFirstResponder],
                           "dark": view.ground.dark] as [String: Any]
        }
        return out
    }

    func bench(_ args: [String], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "live offer only works on a test run"]); return }
        func flag(_ word: String?) -> Bool? { word == "on" ? true : word == "off" ? false : nil }
        switch args.first {
        case nil:
            break
        case "pace":
            let numbers = args.dropFirst().compactMap(Double.init)
            guard numbers.count >= 2 else { answer(["error": "live offer pace LASTS SETTLES [LASTLOOK] [VISITS]"]); return }
            lasts = numbers[0]
            settles = numbers[1]
            if numbers.count > 2 { lastLook = numbers[2] }
            if numbers.count > 3 { visits = Int(numbers[3]) }
        case "front":
            if let on = flag(args.dropFirst().first) { frontmost = { on } } else { frontmost = { NSApp?.isActive ?? false } }
            consider(browser)
        case "sight":
            browser.sightForBench = flag(args.dropFirst().first)
            consider(browser)
        case "hover":
            guard let view = shownView(in: browser), let on = flag(args.dropFirst().first) else { answer(["error": "no ghost to hover"]); return }
            view.benchPillHover(on)
        case "press":
            guard let view = shownView(in: browser) else { answer(["error": "no ghost on screen"]); return }
            let button = args.dropFirst().first == "add" ? view.add : view.decline
            guard button.accessibilityPerformPress() else { answer(["error": "the button didn't press"]); return }
        case "focus":
            guard let view = shownView(in: browser), let window = view.window else { answer(["error": "no ghost on screen"]); return }
            switch args.dropFirst().first {
            case "add": window.makeFirstResponder(view.add)
            case "decline": window.makeFirstResponder(view.decline)
            default: window.makeFirstResponder(nil)
            }
        case "keys":
            if let on = flag(args.dropFirst().first) { KitFocus.keyboardAccess = { on } } else { KitFocus.keyboardAccess = { NSApp.isFullKeyboardAccessEnabled } }
        case "key":
            guard let window = browser.window, let view = window.firstResponder as? NSView, let name = args.dropFirst().first,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, characters: name == "space" ? " " : "\r",
                                               charactersIgnoringModifiers: name == "space" ? " " : "\r", isARepeat: false,
                                               keyCode: name == "space" ? 49 : 36) else { answer(["error": "live offer key space|return, with a control focused"]); return }
            view.keyDown(with: event)
        case "again":
            suggestAgain(in: browser.spaceID)
        case "undo":
            browser.window?.undoManager?.undo()
        case "consider":
            consider(browser)
        default:
            answer(["error": "live offer [pace|front|sight|hover|press|focus|keys|key|again|undo|consider]"])
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated { answer(self?.benchState(browser) ?? [:]) }
        }
    }
}
