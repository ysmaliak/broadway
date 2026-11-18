import AppKit
import WebKit

struct LinkLanding {
    let browser: Browser
    var tab: Tab?
    var forward: Bool
}

@MainActor
final class LinkNotice {
    let id = UUID()
    let text: String
    let choices: [OfferBarView.Choice]

    init(_ text: String, choices: [OfferBarView.Choice]) {
        self.text = text
        self.choices = choices
    }
}

@MainActor
enum LinkArrivals {
    struct Arrival {
        var site: String
        var when: Date
    }

    static var arrived: [UUID: Arrival] = [:]
    static var offered: Set<String> = []
    static var quiet = false

    static func note(_ tab: Tab?, url: URL) {
        guard let tab, !tab.shy, let site = LinkRouter.site(of: url) else { return }
        let now = Date()
        arrived = arrived.filter { now.timeIntervalSince($0.value.when) < 60 }
        arrived[tab.id] = Arrival(site: site, when: now)
    }

    static func moved(_ tab: Tab, to space: UUID, in browser: Browser, now: Date = Date()) {
        guard !quiet, !browser.isPrivate, let arrival = arrived.removeValue(forKey: tab.id),
              now.timeIntervalSince(arrival.when) < 60, !offered.contains(arrival.site),
              let name = browser.spaces.first(where: { $0.id == space })?.name,
              LinkRules.shared.target(of: arrival.site) != .space(space, folder: nil) else { return }
        offered.insert(arrival.site)
        let site = arrival.site
        browser.showLinkNotice(LinkNotice("Always open \(site) in \(name)?", choices: [
            .init("Not Now", id: "link.notice.notNow") { [weak browser] in browser?.showLinkNotice(nil) },
            .init("Always", .primary, id: "link.notice.always") { [weak browser] in
                LinkRules.shared.always(site, to: .space(space, folder: nil))
                browser?.showLinkNotice(nil)
                browser?.announce("\(site) opens in \(name) from now on")
            },
        ]), for: 6)
    }
}

extension Browser {
    func showLinkNotice(_ notice: LinkNotice?, for seconds: Double = 4) {
        linkNoticeHush?.cancel()
        linkNotice = notice
        guard let notice else { return }
        let work = DispatchWorkItem { [weak self] in
            guard self?.linkNotice?.id == notice.id else { return }
            self?.linkNotice = nil
        }
        linkNoticeHush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    func openAway(_ url: URL, space: UUID, folder: UUID? = nil) -> Tab {
        let tab = makeTab(space: space)
        prepare(tab)
        var row = parked[space] ?? loadRow(space)
        if let folder, (row.groups ?? readRow(space).groups ?? []).contains(where: { $0.id == folder }) { tab.groupID = folder }
        row.tabs.append(tab)
        if row.active == nil { row.active = tab.id }
        parked[space] = row
        if prefs.lazyTabs {
            tab.restore(url: url, title: knownTitle(for: url) ?? "")
        } else {
            tab.go(to: Browser.page(url))
        }
        writeSession(now: true, space: space, row: row)
        return tab
    }

    @discardableResult
    func land(_ url: URL, background: Bool) -> Tab? {
        if background { return open(url, foreground: false, atEnd: true, mayWait: true) }
        if let active, active.isBlank, typed.isEmpty, !active.floating {
            active.go(to: url)
            editing = false
            return active
        }
        return open(url, foreground: true)
    }

    func folders(of space: UUID) -> [TabGroup] {
        let groups = space == spaceID ? tabGroups : parked[space]?.groups ?? readRow(space).groups ?? []
        return groups.filter { !$0.live }
    }

    func put(_ tab: Tab, inFolder folder: UUID?) {
        guard let folder, tabGroups.contains(where: { $0.id == folder && !$0.live }), tabs.contains(where: { $0.id == tab.id }) else { return }
        move(tab, toGroup: folder)
    }
}

extension Browsers {
    static var linkTargets: [Browser] { all.filter { $0.isOpen && !$0.keepsNothing } }

    static func linkWorld(from browser: Browser, rules: [LinkRule]? = nil) -> LinkWorld {
        let rules = rules ?? LinkRules.shared.rules
        var world = LinkWorld()
        world.usesSpaces = browser.prefs.usesSpaces
        world.front = browser.isPrivate ? nil : browser.spaceID
        world.broadway = Bundle.main.bundleIdentifier ?? "com.officecommun.search"
        let windows = linkTargets
        world.windows = windows.map(\.record.id)
        world.spaces = browser.spaces.map { space in
            LinkWorld.Space(id: space.id, name: space.name,
                            folders: browser.folders(of: space.id).map { LinkWorld.Folder(id: $0.id, name: $0.name) })
        }
        var seen: [(site: String, space: UUID, when: Date)] = []
        var loaded: Set<UUID> = []
        for window in windows {
            var rows: [(UUID, [Tab])] = [(window.spaceID, window.tabs)]
            rows += window.parked.map { ($0.key, $0.value.tabs) }
            for (space, tabs) in rows {
                loaded.insert(space)
                for tab in tabs where !tab.shy && !tab.bench {
                    guard let url = tab.address else { continue }
                    if let site = LinkRouter.site(of: url) { seen.append((site, space, tab.touched)) }
                    let key = LinkRouter.key(of: url)
                    if world.tabs[space]?[key] == nil { world.tabs[space, default: [:]][key] = tab.id }
                }
            }
        }
        if rules.contains(where: { $0.on && $0.target == .whereOpen }) {
            for space in browser.spaces where !loaded.contains(space.id) {
                for saved in Session.read(space: space.id).tabs {
                    if let site = LinkRouter.site(of: URL(string: saved.url)) { seen.append((site, space.id, .distantPast)) }
                }
            }
        }
        for item in seen.sorted(by: { $0.when > $1.when }) where !(world.open[item.site]?.contains(item.space) ?? false) {
            world.open[item.site, default: []].append(item.space)
        }
        for rule in rules {
            if case .app(let bundle, _) = rule.target, NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil {
                world.apps.insert(bundle)
            }
        }
        if browser.prefs.liveFolders, browser.prefs.usesTabGroups {
            let shown = Set(windows.map(\.spaceID) + (browser.isPrivate ? [] : [browser.spaceID]))
            for space in world.spaces where world.usesSpaces || shown.contains(space.id) {
                for folder in LiveFolders.shared.folders where folder.space == space.id {
                    world.rows += folder.items.map {
                        LinkWorld.Row(folder: folder.id, name: folder.name, space: space.id, kind: folder.source.kind, key: $0.key)
                    }
                }
            }
        }
        return world
    }

    static func decide(_ link: IncomingLink, from browser: Browser) -> (LinkDecision, LinkWorld) {
        let store = LinkRules.shared
        let world = linkWorld(from: browser, rules: store.rules)
        return (LinkRouter.decide(link, rules: store.rules, settings: store.settings, world: world), world)
    }

    @discardableResult
    static func place(_ link: IncomingLink, from browser: Browser) -> LinkLanding {
        guard Browser.peekable(link.url) else {
            browser.arrive(link.url)
            return LinkLanding(browser: browser, tab: browser.active, forward: true)
        }
        let (decided, world) = decide(link, from: browser)
        let decision = link.hooked.map { HookLinks.decision($0, over: decided, world: world) } ?? decided
        return apply(decision, link: link, from: browser, world: world)
    }

    static func placeBehind(_ link: IncomingLink, from browser: Browser) {
        guard Browser.peekable(link.url) else {
            browser.open(link.url, foreground: false, atEnd: true, mayWait: true)
            return
        }
        let (decided, world) = decide(link, from: browser)
        var decision = decided
        if decision.place == .here, decision.rule == nil {
            browser.open(decision.url, foreground: false, atEnd: true, mayWait: true)
            return
        }
        if case .row = decision.place { decision.background = true }
        apply(decision, link: link, from: browser, world: world)
    }

    @discardableResult
    static func place(_ url: URL, from browser: Browser) -> Browser {
        place(IncomingLink(url: url, source: .unknownApp), from: browser).browser
    }

    @discardableResult
    static func apply(_ decision: LinkDecision, link: IncomingLink, from browser: Browser, world: LinkWorld, chosen: Bool = false) -> LinkLanding {
        let url = decision.url
        let background = decision.background
        let fromSpace = browser.spaceID
        func plain() -> LinkLanding {
            LinkLanding(browser: browser, tab: browser.land(url, background: background), forward: !background)
        }
        var landing: LinkLanding
        switch decision.place {
        case .here:
            landing = plain()
        case .space(let id, let folder):
            guard browser.prefs.usesSpaces, !browser.isPrivate, browser.spaces.contains(where: { $0.id == id }) else {
                landing = plain()
                break
            }
            if let there = linkTargets.first(where: { $0.spaceID == id }) {
                let tab = there.land(url, background: background)
                if let tab { there.put(tab, inFolder: folder) }
                landing = LinkLanding(browser: there, tab: tab, forward: !background)
            } else if background {
                landing = LinkLanding(browser: browser, tab: browser.openAway(url, space: id, folder: folder), forward: false)
            } else {
                browser.switchSpace(to: id)
                let tab = browser.land(url, background: false)
                if let tab { browser.put(tab, inFolder: folder) }
                landing = LinkLanding(browser: browser, tab: tab, forward: true)
            }
        case .window(let id):
            let there = id.flatMap { id in linkTargets.first { $0.record.id == id } } ?? newWindow()
            landing = LinkLanding(browser: there, tab: there.land(url, background: background), forward: !background)
        case .peek:
            guard let active = browser.active, !active.isBlank, !active.shy, browser.peekTab == nil, Browser.peekable(url) else {
                landing = plain()
                break
            }
            browser.peek(url, from: active)
            landing = LinkLanding(browser: browser, tab: browser.peekTab, forward: true)
        case .app(let bundle, _):
            if !Store.testing, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = !background
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
            }
            landing = LinkLanding(browser: browser, tab: nil, forward: false)
        case .ask:
            LinkChooser.ask(link, url: url, in: browser, world: world)
            return LinkLanding(browser: browser, tab: nil, forward: true)
        case .tab(let id, let space):
            if let there = linkTargets.first(where: { $0.tabs.contains { $0.id == id } }),
               let tab = there.tabs.first(where: { $0.id == id }) {
                there.select(tab)
                landing = LinkLanding(browser: there, tab: tab, forward: !background)
            } else if browser.prefs.usesSpaces, !browser.isPrivate, browser.parked[space]?.tabs.contains(where: { $0.id == id }) == true {
                browser.switchSpace(to: space)
                if let tab = browser.tabs.first(where: { $0.id == id }) { browser.select(tab) }
                landing = LinkLanding(browser: browser, tab: browser.tabs.first { $0.id == id }, forward: !background)
            } else {
                landing = plain()
            }
        case .row(let key, let folder, let space):
            guard let shown = show(row: key, folder: folder, space: space, at: url, background: background, from: browser) else {
                let opened = plain()
                LinkArrivals.note(opened.tab, url: url)
                return opened
            }
            record(decision, link: link, landing: shown, world: world, chosen: chosen)
            tellRow(decision, landing: shown, from: browser, space: fromSpace, world: world)
            return shown
        }
        LinkArrivals.note(landing.tab, url: url)
        record(decision, link: link, landing: landing, world: world, chosen: chosen)
        if decision.rule != nil || chosen {
            tell(decision, landing: landing, from: browser, space: fromSpace, world: world, chosen: chosen)
        }
        return landing
    }

    static func show(row key: String, folder: UUID, space: UUID, at url: URL, background: Bool, from browser: Browser) -> LinkLanding? {
        func row(_ tabs: [Tab]) -> Tab? { tabs.first { $0.groupID == folder && $0.liveKey.map { LiveIdentity.same($0, key) } == true } }
        func point(_ tab: Tab) {
            if !LiveLinks.shows(tab.address, url) { tab.go(to: url) }
        }
        let front = !browser.isPrivate && browser.spaceID == space ? browser : nil
        if let there = front ?? linkTargets.first(where: { $0.spaceID == space }) {
            if row(there.tabs) == nil { there.syncLive() }
            guard let tab = row(there.tabs) else { return nil }
            point(tab)
            if !background { there.select(tab) }
            return LinkLanding(browser: there, tab: tab, forward: !background)
        }
        guard browser.showsSpaces, !browser.isPrivate, browser.spaces.contains(where: { $0.id == space }) else { return nil }
        if background {
            let kept = browser.parked[space] ?? browser.loadRow(space)
            guard let tab = row(kept.tabs) else { return nil }
            browser.parked[space] = kept
            point(tab)
            browser.writeSession(now: true, space: space, row: kept)
            return LinkLanding(browser: browser, tab: tab, forward: false)
        }
        if browser.stacked { browser.stackedJump(to: space) } else { browser.switchSpace(to: space) }
        guard browser.spaceID == space else { return nil }
        if row(browser.tabs) == nil { browser.syncLive() }
        guard let tab = row(browser.tabs) else { return nil }
        point(tab)
        browser.select(tab)
        return LinkLanding(browser: browser, tab: tab, forward: true)
    }

    static func tellRow(_ decision: LinkDecision, landing: LinkLanding, from browser: Browser, space: UUID, world: LinkWorld,
                        source: Tab? = nil) {
        let behind = !landing.forward
        guard behind ? source != nil : landing.browser !== browser || browser.spaceID != space else {
            for window in [browser, landing.browser] where window.linkNotice?.choices.contains(where: { $0.id == "link.notice.newTab" }) == true {
                window.showLinkNotice(nil)
            }
            return
        }
        let url = decision.url
        let shown = behind ? browser : landing.browser
        let text = behind ? LinkRouter.pointed(decision.place, here: space, world: world) : LinkRouter.words(decision.place, world: world)
        shown.showLinkNotice(LinkNotice(text, choices: [
            .init("Open in New Tab", id: "link.notice.newTab") { [weak browser, weak shown, weak source] in
                guard let browser else { return }
                shown?.showLinkNotice(nil)
                if browser.spaceID != space, browser.showsSpaces { browser.switchSpace(to: space) }
                if let source, browser.tabs.contains(where: { $0.id == source.id }) {
                    browser.open(url, foreground: !behind, from: source, mayWait: true, link: true, title: source.linkWords(for: url))
                } else {
                    browser.land(url, background: behind)
                }
                if !behind { browser.window?.makeKeyAndOrderFront(nil) }
            },
        ]))
    }

    static func record(_ decision: LinkDecision, link: IncomingLink, landing: LinkLanding, world: LinkWorld, chosen: Bool) {
        var live: String?
        if case .row(_, let folder, _) = decision.place { live = world.rows.first { $0.folder == folder }?.name ?? "a live folder" }
        guard decision.rule != nil || chosen || live != nil else { return }
        let from: String = switch link.source {
        case .app(_, let name): name
        case .unknownApp: "Another app"
        case .page(_, let site): site.map { "A page on \($0)" } ?? "A page in Broadway"
        }
        let site = LinkRouter.site(of: decision.url) ?? decision.url.host() ?? decision.url.absoluteString
        let went = LinkRouter.words(decision.place, world: world, outside: link.source.outside)
        let shown = decision.background ? "Its row goes there in the background" : "Shown there"
        LinkRules.shared.note(LinkRecent(site: site, from: from, rule: chosen ? nil : decision.rule, went: live == nil ? went : shown, live: live))
    }

    private static func tell(_ decision: LinkDecision, landing: LinkLanding, from browser: Browser, space: UUID, world: LinkWorld, chosen: Bool) {
        let rule = decision.rule
        let by = chosen ? "as you chose" : "by a rule"
        var choices: [OfferBarView.Choice] = []
        let text: String
        switch decision.place {
        case .space(let id, _):
            let away = landing.tab.map { tab in !browser.tabs.contains { $0.id == tab.id } } ?? false
            guard landing.browser !== browser || browser.spaceID != space || away else { return }
            text = "Opened in \(world.name(of: id)) \(by)"
        case .window:
            guard landing.browser !== browser else { return }
            text = "Opened in another window \(by)"
        case .peek:
            guard landing.browser.peekTab != nil else { return }
            text = "Opened in a peek \(by)"
        case .app(_, let name):
            text = "Sent to \(name) \(by)"
        case .here, .ask, .tab, .row:
            return
        }
        if let tab = landing.tab {
            let there = landing.browser
            choices.append(.init("Undo", id: "link.notice.undo") { [weak browser, weak there, weak tab] in
                guard let browser, let there, let tab else { return }
                there.showLinkNotice(nil)
                undo(tab, in: there, back: browser, space: space, url: decision.url)
            })
        }
        if let rule {
            choices.append(.init("Edit Rule", id: "link.notice.edit") { [weak browser] in
                browser?.showLinkNotice(nil)
                landing.browser.showLinkNotice(nil)
                SettingsWindow.showLinkRule(rule)
            })
        }
        let shown = landing.forward || decision.place == .peek ? landing.browser : browser
        shown.showLinkNotice(LinkNotice(text, choices: choices))
    }

    static func undo(_ tab: Tab, in there: Browser, back browser: Browser, space: UUID, url: URL) {
        LinkArrivals.arrived[tab.id] = nil
        LinkArrivals.quiet = true
        defer { LinkArrivals.quiet = false }
        if there.peekTab?.id == tab.id {
            there.closePeek()
            browser.land(url, background: false)
            return
        }
        if there !== browser {
            if there.tabs.contains(where: { $0.id == tab.id }) {
                there.moveToWindow(tab, browser)
            } else {
                browser.land(url, background: false)
            }
            if browser.spaceID != space, browser.prefs.usesSpaces { browser.switchSpace(to: space) }
            if let moved = browser.tabs.first(where: { $0.id == tab.id }) { browser.select(moved) }
            browser.window?.makeKeyAndOrderFront(nil)
            return
        }
        if let parkedIn = browser.space(holding: tab.id), parkedIn != space {
            browser.parked[parkedIn]?.tabs.removeAll { $0.id == tab.id }
            if browser.parked[parkedIn]?.active == tab.id { browser.parked[parkedIn]?.active = browser.parked[parkedIn]?.tabs.first?.id }
            tab.close()
            if browser.spaceID != space { browser.switchSpace(to: space) }
            browser.land(url, background: false)
            return
        }
        if browser.spaceID != space, browser.tabs.contains(where: { $0.id == tab.id }) {
            _ = browser.finishMove(tab, toSpace: space, quietly: true)
            browser.switchSpace(to: space)
            if let moved = browser.tabs.first(where: { $0.id == tab.id }) { browser.select(moved) }
        }
    }
}

enum LinkRouted {
    case no
    case yes(Tab?)
}

extension Browser {
    static func routesNewWindow(clicked: Bool, navigation: WKNavigationType, popup: Bool, beside: Bool, shy: Bool, url: URL?,
                                page: URL?, menu: Bool = false) -> Bool {
        guard !popup, !beside, !shy, let url, let site = LinkRouter.site(of: url) else { return false }
        if menu { return true }
        guard clicked, navigation == .linkActivated else { return false }
        return site != LinkRouter.site(of: page)
    }

    func rowsTake(_ source: Tab) -> Bool {
        LinkRules.shared.settings.goesToLiveRow && prefs.liveFolders && prefs.usesTabGroups && !source.agent
            && tabs.contains { $0.id == source.id } && LiveFolders.shared.folders.contains { !$0.items.isEmpty }
    }

    func seats(of source: Tab) -> [IncomingLink.Seat] {
        let beside = split(for: source)?.tabs ?? [source.id]
        return tabs.filter { beside.contains($0.id) }.compactMap { tab in
            guard let key = tab.liveKey, let kind = LiveFolders.shared.folders.first(where: { $0.id == tab.groupID })?.source.kind else { return nil }
            return IncomingLink.Seat(kind: kind, key: key)
        }
    }

    func routeClicked(_ url: URL, foreground: Bool, from source: Tab?) -> LinkRouted {
        guard !isPrivate, let source, !source.shy, !source.bench, Browser.peekable(url) else { return .no }
        let store = LinkRules.shared
        let ruled = store.rules.contains { rule in
            rule.on && LinkRouter.accepts(rule.from, .page(space: spaceID, site: nil))
        }
        let rows = rowsTake(source)
        guard ruled || rows else { return .no }
        var settings = store.settings
        if !rows { settings.goesToLiveRow = false }
        let link = IncomingLink(url: url, source: .page(space: spaceID, site: LinkRouter.site(of: source.address)),
                                behind: !foreground, seats: rows ? seats(of: source) : [])
        let world = Browsers.linkWorld(from: self, rules: store.rules)
        var decision = LinkRouter.decide(link, rules: store.rules, settings: settings, world: world)
        if case .row(let key, let folder, let space) = decision.place {
            let from = spaceID
            if let shown = Browsers.show(row: key, folder: folder, space: space, at: decision.url, background: decision.background, from: self) {
                Browsers.record(decision, link: link, landing: shown, world: world, chosen: false)
                Browsers.tellRow(decision, landing: shown, from: self, space: from, world: world, source: source)
                if shown.forward, shown.browser !== self { shown.browser.window?.makeKeyAndOrderFront(nil) }
                return .yes(nil)
            }
            settings.goesToLiveRow = false
            decision = LinkRouter.decide(link, rules: store.rules, settings: settings, world: world)
        }
        guard decision.rule != nil, decision.place != .here else { return .no }
        let landing = Browsers.apply(decision, link: link, from: self, world: world)
        if landing.forward, landing.browser !== self { landing.browser.window?.makeKeyAndOrderFront(nil) }
        return .yes(landing.tab)
    }
}
