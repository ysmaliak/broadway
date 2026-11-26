import Foundation
import Observation
import Combine

@MainActor
@Observable
final class AIGroups {
    static let shared = AIGroups()

    nonisolated static let onKey = "ai.groups"
    nonisolated static let emojiKey = "ai.groups.emoji"

    private let store = Store.settings

    private var stored: Bool?
    var emoji: Bool { didSet { store.set(emoji, forKey: Self.emojiKey) } }
    private(set) var note: String?
    private(set) var veiled: Set<UUID> = []

    @ObservationIgnored var quiet: Double = 1.5
    @ObservationIgnored var gap: Double = 4
    @ObservationIgnored var timeout: Double = 25
    @ObservationIgnored var stop: Double = 8
    @ObservationIgnored private var stops: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var standIn: (any AIGroupDecider & AIGroupNamer)?
    @ObservationIgnored var namerStandIn: (any AIGroupNamer)?
    @ObservationIgnored var macAvailable: () -> Bool = { MacGroupEngine.available }
    @ObservationIgnored var macDecider: () -> any AIGroupDecider = { MacGroupEngine() }
    @ObservationIgnored var macNamer: () -> any AIGroupNamer = { MacGroupEngine() }
    @ObservationIgnored var remoteNamer: (String) -> any AIGroupNamer = { OpenRouterNamer(key: $0) }
    @ObservationIgnored var remoteDecider: ((String, String) -> any AIGroupDecider)? = { OpenRouterDecider(key: $0, model: $1) }
    @ObservationIgnored var openRouter = OpenRouterKey.shared
    @ObservationIgnored private var groupers: [ObjectIdentifier: AIGrouper] = [:]

    init() {
        stored = store.object(forKey: Self.onKey) as? Bool
        emoji = store.object(forKey: Self.emojiKey) as? Bool ?? true
    }

    var on: Bool {
        get { stored ?? (deciding != nil) }
        set {
            stored = newValue
            store.set(newValue, forKey: Self.onKey)
            if newValue, !emoji { emoji = true }
        }
    }

    func available(_ kind: AIGroupEngineKind) -> Bool {
        switch kind {
        case .auto: return true
        case .thisMac: return standIn != nil || macAvailable()
        case .openRouter: return openRouter.present
        }
    }

    var remoteDecides: Bool { remoteDecider != nil }

    var deciding: AIGroupEngineKind? {
        if standIn != nil { return .thisMac }
        if available(.openRouter), remoteDecides { return .openRouter }
        return available(.thisMac) ? .thisMac : nil
    }

    var naming: AIGroupEngineKind? {
        if standIn != nil || namerStandIn != nil { return .thisMac }
        if available(.openRouter) { return .openRouter }
        return available(.thisMac) ? .thisMac : nil
    }

    func decider() -> (any AIGroupDecider)? {
        if let standIn { return standIn }
        let mac = available(.thisMac) ? macDecider() : nil
        if let key = openRouter.key, let remote = remoteDecider?(key, OpenRouterModels.grouping) {
            let keys = openRouter
            return AIGroupDeciderChain(remote: remote, mac: mac, report: { await keys.note($0) })
        }
        return mac
    }

    func namers() -> [any AIGroupNamer] {
        if let namerStandIn { return [namerStandIn] }
        if let standIn { return [standIn] }
        var out: [any AIGroupNamer] = []
        if let key = openRouter.key { out.append(remoteNamer(key)) }
        if available(.thisMac) { out.append(macNamer()) }
        return out
    }

    func namerEngine() -> (any AIGroupNamer)? {
        let all = namers()
        guard all.count > 1 else { return all.first }
        return AIGroupNamerChain(all)
    }

    var sends: String {
        AIGroupWords.line(mac: available(.thisMac), key: openRouter.present && remoteDecides)
    }

    func active(_ browser: Browser) -> Bool {
        on
    }

    func grouper(for browser: Browser) -> AIGrouper {
        let id = ObjectIdentifier(browser)
        if let found = groupers[id], found.browser === browser { return found }
        let made = AIGrouper(browser: browser)
        groupers[id] = made
        groupers = groupers.filter { $0.value.browser != nil }
        return made
    }

    func landed(_ tab: Tab, in browser: Browser) {
        guard active(browser) else {
            tab.bornIn = nil
            return
        }
        grouper(for: browser).landed(tab)
    }

    func membershipChanged(in browser: Browser) {
        guard browser.tabGroups.contains(where: AIGrouper.named), active(browser) else { return }
        grouper(for: browser).membershipChanged()
    }

    func ungrouped(_ group: TabGroup, in browser: Browser) {
        guard group.ai else { return }
        grouper(for: browser).ungrouped(group)
    }

    func dissolved(_ group: TabGroup, in browser: Browser) {
        guard group.ai else { return }
        grouper(for: browser).dissolved(group)
    }

    func told(_ text: String?) {
        note = text
    }

    func forget(_ browser: Browser) {
        groupers[ObjectIdentifier(browser)] = nil
    }

    func veil(_ id: UUID, held: Bool = false) {
        stops[id]?.cancel()
        stops[id] = nil
        if !veiled.contains(id) { veiled.insert(id) }
        guard !held else { return }
        let wait = stop
        stops[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, wait)))
            guard !Task.isCancelled else { return }
            self?.unveil(id)
        }
    }

    func unveil(_ id: UUID) {
        stops[id]?.cancel()
        stops[id] = nil
        if veiled.contains(id) { veiled.remove(id) }
    }

    func veils(_ group: TabGroup, in browser: Browser) -> Bool {
        Self.veils(group, veiled: veiled, editing: browser.editingGroupID)
    }

    nonisolated static func veils(_ group: TabGroup, veiled: Set<UUID>, editing: UUID?) -> Bool {
        veiled.contains(group.id) && !group.live && !group.userNamed && group.query == nil && editing != group.id
            && (group.ai || (group.madeName != nil && group.name == group.madeName))
    }
}

@MainActor
final class AIGrouper {
    enum Cached: Equatable {
        case group(UUID)
        case loose(String)
    }

    struct Outcome: Equatable {
        var joined = 0
        var formed = 0
        var renamed = 0
    }

    weak var browser: Browser?
    private(set) var pending: [UUID: [Tab.ID: Int]] = [:]
    private(set) var decided: Set<Tab.ID> = []
    private(set) var passes = 0
    private(set) var dismissed: [UUID: [Set<String>]] = [:]
    private(set) var cache: [String: Cached] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]
    private var running: Set<UUID> = []
    private var again: Set<UUID> = []
    private var lastPass: [UUID: Date] = [:]
    private var members: [UUID: [UUID: Set<Tab.ID>]] = [:]
    private var namedWith: [UUID: Set<Tab.ID>] = [:]
    private var nameTimer: Task<Void, Never>?
    private var naming = false
    private var nameAgain = false
    private(set) var nameAsks = 0
    private(set) var how: [UUID: String] = [:]
    private(set) var provisional: Set<UUID> = []
    private(set) var away: [Tab.ID: Set<UUID>] = [:]
    private(set) var heard: [String: Set<UUID>] = [:]
    private var fits: [String: AIGroupFit] = [:]
    private var watched: Set<Tab.ID> = []
    private var bumped: Set<Tab.ID> = []
    private var settings: AIGroups { AIGroups.shared }

    static let batch = 8
    static let context = 15

    init(browser: Browser) {
        self.browser = browser
    }

    var busy: Bool { !running.isEmpty || !timers.isEmpty || nameTimer != nil || naming }

    static func usable(_ tab: Tab, in browser: Browser) -> Bool {
        !tab.shy && !tab.bench && !tab.agent && !tab.popup && tab.pin == nil && browser.split(for: tab) == nil
            && browser.tabs.contains { $0 === tab }
    }

    static func shown(_ tab: Tab) -> AIGroupTab? {
        AIGroupTab(id: tab.id, title: tab.title, url: tab.pageAddress, by: tab.by)
    }

    func landed(_ tab: Tab) {
        membershipChanged()
        guard let browser, let scheme = tab.pageAddress?.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
        guard !tab.cameBack, !decided.contains(tab.id), Self.usable(tab, in: browser) else {
            tab.bornIn = nil
            return
        }
        let space = browser.spaceID
        if pending[space]?[tab.id] == nil { pending[space, default: [:]][tab.id] = 0 }
        schedule(space)
    }

    func schedule(_ space: UUID, after wait: Double? = nil) {
        if running.contains(space) {
            again.insert(space)
            return
        }
        timers[space]?.cancel()
        let since = lastPass[space].map { Date().timeIntervalSince($0) } ?? .infinity
        let delay = wait ?? max(settings.quiet, settings.gap - since)
        timers[space] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled, let self else { return }
            self.timers[space] = nil
            await self.pass(space)
        }
    }

    static func members(_ id: UUID, in browser: Browser) -> Set<Tab.ID> {
        Set(browser.tabs.filter { $0.groupID == id && $0.bornIn == nil && shown($0) != nil }.map(\.id))
    }

    static func automatic(_ group: TabGroup) -> Bool {
        group.ai && !group.live && group.query == nil
    }

    static func born(_ tab: Tab, in browser: Browser) -> TabGroup? {
        guard let id = tab.bornIn, browser.group(of: tab) == id,
              let group = browser.tabGroups.first(where: { $0.id == id }), automatic(group) else { return nil }
        return group
    }

    func info(_ group: TabGroup, in browser: Browser) -> AIGroupInfo {
        var refused = Set(group.aiRefused)
        for tab in browser.tabs where away[tab.id]?.contains(group.id) == true {
            if let key = Self.shown(tab)?.key { refused.insert(key) }
        }
        return AIGroupInfo(id: group.id, name: group.name, members: browser.tabs(in: group.id).compactMap(Self.shown),
                           refused: refused, settled: !provisional.contains(group.id))
    }

    static func named(_ group: TabGroup) -> Bool {
        (group.ai || group.madeName != nil) && !group.live && !group.userNamed
    }

    static func handMade(_ group: TabGroup) -> Bool {
        !group.ai && group.madeName != nil
    }

    static func unnamed(_ group: TabGroup) -> Bool {
        handMade(group) && group.name == group.madeName
    }

    func membershipChanged() {
        guard let browser, settings.active(browser) else { return }
        var stale = false
        for group in browser.tabGroups where Self.named(group) {
            let now = Self.members(group.id, in: browser)
            if namedWith[group.id] == nil, Self.unnamed(group) {
                namedWith[group.id] = []
                if now.count >= 2 { stale = true }
                continue
            }
            guard let before = namedWith[group.id] else {
                namedWith[group.id] = now
                continue
            }
            if before != now { stale = true }
        }
        if stale { scheduleNaming() }
    }

    func nameSoon(_ id: UUID) {
        namedWith[id] = []
        provisional.insert(id)
        scheduleNaming()
    }

    func scheduleNaming() {
        if naming {
            nameAgain = true
            return
        }
        nameTimer?.cancel()
        let wait = settings.quiet
        nameTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, wait)))
            guard !Task.isCancelled, let self else { return }
            self.nameTimer = nil
            await self.renameChanged()
        }
    }

    func query(of ids: Set<Tab.ID>) -> String? {
        guard let browser else { return nil }
        return browser.tabs.lazy.filter { ids.contains($0.id) }.compactMap { browser.searchQuery(of: $0) }.first
    }

    @discardableResult
    func renameChanged() async -> Int {
        guard let browser, settings.active(browser), !naming else { return 0 }
        naming = true
        defer {
            naming = false
            if nameAgain {
                nameAgain = false
                scheduleNaming()
            }
        }
        let namer = settings.namerEngine()
        let wantsEmoji = settings.emoji
        var renamed = 0
        for group in browser.tabGroups where Self.named(group) {
            let handMade = Self.handMade(group)
            if handMade, namer == nil || browser.editingGroupID == group.id { continue }
            let now = Self.members(group.id, in: browser)
            guard let before = namedWith[group.id], before != now else { continue }
            namedWith[group.id] = now
            if handMade, now.count < 2 { continue }
            let tabs = browser.tabs.filter { now.contains($0.id) }.compactMap(Self.shown)
            guard !tabs.isEmpty else { continue }
            let query = group.query ?? query(of: now)
            let guessed = provisional.contains(group.id) || Self.unnamed(group)
            let ask = AIGroupNameAsk(tabs: tabs, current: guessed ? nil : group.name, currentEmoji: group.aiEmoji,
                                     emoji: wantsEmoji && !handMade, query: query)
            if !before.isEmpty, ask.current != nil, Self.stillFits(ask) {
                how[group.id] = "kept: still fits"
                continue
            }
            let veils = handMade && Self.unnamed(group)
            if veils { settings.veil(group.id) }
            defer { if veils { settings.unveil(group.id) } }
            let said = await resolve(namer, ask)
            how[group.id] = said.how
            if browser.editingGroupID == group.id {
                namedWith[group.id] = before
                continue
            }
            if said.how.hasPrefix("model") { provisional.remove(group.id) }
            if handMade, !said.how.hasPrefix("model"), !said.how.hasPrefix("fallback: rejected twice") { continue }
            guard let name = said.name, let index = browser.tabGroups.firstIndex(where: { $0.id == group.id }),
                  Self.named(browser.tabGroups[index]),
                  name.name != browser.tabGroups[index].name || (name.emoji != nil && name.emoji != browser.tabGroups[index].aiEmoji)
            else { continue }
            var changed = browser.tabGroups[index]
            changed.name = name.name
            if !changed.userIcon, !handMade {
                if wantsEmoji, let mark = name.emoji {
                    changed.icon = TabIcon(emoji: mark)
                    changed.aiEmoji = mark
                } else if !wantsEmoji, changed.icon?.emoji == changed.aiEmoji {
                    changed.icon = nil
                    changed.aiEmoji = nil
                }
            }
            browser.tabGroups[index] = changed
            renamed += 1
        }
        if renamed > 0 { browser.writeSession(now: true) }
        return renamed
    }

    static func stillFits(_ ask: AIGroupNameAsk) -> Bool {
        guard let current = ask.current else { return false }
        return AIGroupNames.problem(current, tabs: ask.tabs, query: ask.query) == nil && AIGroupPrompt.fits(current, ask.tabs)
    }

    func renamed(_ namer: (any AIGroupNamer)?, _ ask: AIGroupNameAsk) async -> (name: AIGroupName?, how: String) {
        if ask.current != nil, Self.stillFits(ask) { return (nil, "kept: still fits") }
        return await resolve(namer, ask)
    }

    func resolve(_ namer: (any AIGroupNamer)?, _ ask: AIGroupNameAsk) async -> (name: AIGroupName?, how: String) {
        var mark: String?
        func fallback(_ why: String) -> (name: AIGroupName?, how: String) {
            if let current = ask.current, AIGroupNames.problem(current, tabs: ask.tabs, query: ask.query) == nil {
                return (nil, "kept: \(why)")
            }
            let name = AIGroupNames.fallback(ask.tabs, query: ask.query)
            if name == ask.current { return (nil, "kept: \(why)") }
            return (AIGroupName(name: name, emoji: ask.emoji ? mark : nil), "fallback: \(why)")
        }
        let namers = (namer as? AIGroupNamerChain)?.namers ?? namer.map { [$0] } ?? []
        guard !namers.isEmpty else { return fallback("no namer") }
        var why = ""
        for namer in namers {
            let who = namers.count > 1 || namer is OpenRouterNamer ? (namer.local ? " on this Mac" : " on OpenRouter") : ""
            var question = ask
            var last = ""
            var failed = false
            for attempt in 0..<2 {
                nameAsks += 1
                let said: AIGroupName
                do {
                    let asking = namer.local ? question : namer is OpenRouterNamer ? question.bare : question.sent
                    said = try await Self.within(settings.timeout) { try await namer.name(asking) }
                } catch {
                    AIGroupTrace.note("name", ["tabs": ask.tabs.map(\.title), "failed": error.localizedDescription])
                    why = "the namer\(who) failed: \(error.localizedDescription)"
                    failed = true
                    break
                }
                let problem = AIGroupNames.problem(said.name, tabs: ask.tabs, query: ask.query)
                AIGroupTrace.note("name", ["tabs": ask.tabs.map(\.title), "said": said.name, "emoji": said.emoji ?? "", "keep": said.keep,
                                           "current": ask.current ?? "", "problem": problem ?? "", "namer": namer.local ? "this Mac" : "OpenRouter"])
                let source = (attempt == 0 ? "model" : "model on a second ask") + who
                if mark == nil { mark = said.emoji }
                if let current = ask.current, said.keep || AIGroupNames.fold(said.name) == AIGroupNames.fold(current) {
                    let outgrown = namer.local && !AIGroupNames.describes(current, ask.tabs) ? "it no longer says what most of the tabs share" : nil
                    guard let problem = outgrown ?? AIGroupNames.problem(current, tabs: ask.tabs, query: ask.query) else {
                        return (nil, "kept by the \(source)")
                    }
                    last = "“\(current)” \(problem)"
                    question.rejected.append("“\(current)”, because \(problem)")
                    continue
                }
                if let problem {
                    last = "“\(said.name)” \(problem)"
                    question.rejected.append("“\(said.name)”, because \(problem)")
                    continue
                }
                if let current = ask.current, AIGroupNames.sameSubject(said.name, current),
                   AIGroupNames.problem(current, tabs: ask.tabs, query: ask.query) == nil {
                    return (nil, "kept: the \(source) said the same subject")
                }
                var named = said
                named.name = AIGroupNames.spelled(AIGroupNames.cased(said.name), like: ask.tabs)
                named.keep = false
                if !ask.emoji { named.emoji = nil }
                return (named, source)
            }
            if !failed { why = "rejected twice, last \(last)" }
        }
        return fallback(why)
    }

    func ungrouped(_ group: TabGroup) {
        guard let browser else { return }
        let keys = Set(browser.tabs.filter { $0.groupID == group.id }.compactMap { Self.shown($0)?.key })
        guard keys.count >= 2 else { return }
        dismissed[browser.spaceID, default: []].append(keys)
        if dismissed[browser.spaceID, default: []].count > 40 { dismissed[browser.spaceID]?.removeFirst() }
        for key in keys where cache[key] == .group(group.id) { cache[key] = nil }
    }

    func dissolved(_ group: TabGroup) {
        guard let browser else { return }
        let space = browser.spaceID
        let seen = (members[space]?[group.id] ?? []).union(browser.tabs.filter { $0.groupID == group.id }.map(\.id))
        let keys = Set(browser.tabs.filter { seen.contains($0.id) }.compactMap { Self.shown($0)?.key })
        if keys.count >= 2 {
            dismissed[space, default: []].append(keys)
            if dismissed[space, default: []].count > 40 { dismissed[space]?.removeFirst() }
        }
        for (key, cached) in cache where cached == .group(group.id) { cache[key] = nil }
        members[space]?[group.id] = nil
        namedWith[group.id] = nil
        provisional.remove(group.id)
    }

    func observe() {
        guard let browser else { return }
        let space = browser.spaceID
        let open = Dictionary(browser.tabs.map { ($0.id, $0) }, uniquingKeysWith: { one, _ in one })
        var now: [UUID: Set<Tab.ID>] = [:]
        for group in browser.tabGroups where group.ai {
            now[group.id] = Set(browser.tabs.filter { $0.groupID == group.id }.map(\.id))
        }
        for (id, before) in members[space] ?? [:] {
            guard let index = browser.tabGroups.firstIndex(where: { $0.id == id }) else { continue }
            for left in before.subtracting(now[id] ?? []) {
                guard let tab = open[left], tab.groupID != id, let key = Self.shown(tab)?.key else { continue }
                if !browser.tabGroups[index].aiRefused.contains(key) { browser.tabGroups[index].aiRefused.append(key) }
                if cache[key] == .group(id) { cache[key] = nil }
            }
        }
        members[space] = now
        away = away.filter { open[$0.key] != nil }
    }

    func regroup() async -> Outcome {
        guard let browser else { return Outcome() }
        let space = browser.spaceID
        for tab in browser.tabs(in: nil) where Self.usable(tab, in: browser) && Self.shown(tab) != nil {
            decided.remove(tab.id)
            pending[space, default: [:]][tab.id] = 0
        }
        timers[space]?.cancel()
        timers[space] = nil
        while running.contains(space) { try? await Task.sleep(for: .milliseconds(50)) }
        var outcome = Outcome()
        var rounds = 0
        while !(pending[space] ?? [:]).isEmpty, rounds < 12 {
            let before = pending[space]?.count ?? 0
            let found = await pass(space, everything: true)
            timers[space]?.cancel()
            timers[space] = nil
            outcome.joined += found.joined
            outcome.formed += found.formed
            rounds += 1
            if (pending[space]?.count ?? 0) >= before { break }
        }
        if !(pending[space] ?? [:]).isEmpty { schedule(space) }
        nameTimer?.cancel()
        nameTimer = nil
        membershipChanged()
        nameTimer?.cancel()
        nameTimer = nil
        outcome.renamed = await renameChanged()
        return outcome
    }

    struct Step {
        var outcome = Outcome()
        var made: [UUID] = []
        var touched: Set<UUID> = []
        var asked: Set<Tab.ID> = []
        var went = false
        var failed = false
    }

    static let rounds = 12

    @discardableResult
    func pass(_ space: UUID, everything: Bool = false) async -> Outcome {
        guard let browser, !running.contains(space) else { return Outcome() }
        guard browser.spaceID == space, settings.active(browser) else { return Outcome() }
        running.insert(space)
        lastPass[space] = Date()
        passes += 1
        var outcome = Outcome()
        defer {
            running.remove(space)
            if again.remove(space) != nil || !(pending[space] ?? [:]).isEmpty { schedule(space) }
        }
        let decider = settings.decider()
        let namer = settings.namerEngine()
        bumped = []
        var made: [UUID] = []
        var touched: Set<UUID> = []
        var asked: Set<Tab.ID> = []
        var named = false
        var steps = 0
        for _ in 0..<Self.rounds {
            steps += 1
            guard browser.spaceID == space, settings.active(browser) else { break }
            let step = await step(space, everything: everything, decider: decider, leftovers: asked)
            outcome.joined += step.outcome.joined
            outcome.formed += step.outcome.formed
            made += step.made
            touched.formUnion(step.touched)
            asked.formUnion(step.asked)
            let naming = step.made.map { id in Task { await self.name(id, namer: namer) } }
            for task in naming {
                if await task.value { named = true }
            }
            guard step.went, !step.failed else { break }
            let waiting = (pending[space] ?? [:]).keys
            guard waiting.contains(where: { id in browser.tabs.first { $0.id == id }.flatMap(Self.shown) != nil }) else { break }
        }
        if steps > 1, let decider, !touched.isEmpty, browser.spaceID == space, settings.active(browser) {
            let joined = await gather(into: touched, space: space, decider: decider, leftovers: asked)
            outcome.joined += joined
        }
        if named { browser.writeSession(now: true) }
        if browser.spaceID == space, settings.active(browser) {
            outcome.joined += await joinTwins(fresh: touched, space: space, decider: decider)
        }
        return outcome
    }

    func name(_ id: UUID, namer: (any AIGroupNamer)?) async -> Bool {
        guard let browser else { return false }
        let wantsEmoji = settings.emoji
        let members = browser.tabs.filter { $0.groupID == id }
        let shown = members.compactMap(Self.shown)
        guard shown.count >= 2 else { return false }
        namedWith[id] = Set(members.filter { Self.shown($0) != nil }.map(\.id))
        let ask = AIGroupNameAsk(tabs: shown, current: nil, currentEmoji: nil, emoji: wantsEmoji, query: query(of: Set(members.map(\.id))))
        let said = await resolve(namer, ask)
        defer { settings.unveil(id) }
        how[id] = said.how
        if browser.editingGroupID == id {
            namedWith[id] = []
            return false
        }
        if said.how.hasPrefix("model") { provisional.remove(id) }
        guard let name = said.name,
              let index = browser.tabGroups.firstIndex(where: { $0.id == id }), Self.named(browser.tabGroups[index])
        else { return false }
        var changed = browser.tabGroups[index]
        changed.name = name.name
        if wantsEmoji, settings.emoji, !changed.userIcon, let mark = name.emoji {
            changed.icon = TabIcon(emoji: mark)
            changed.aiEmoji = mark
        }
        guard changed != browser.tabGroups[index] else { return false }
        browser.tabGroups[index] = changed
        return true
    }

    static let compared = 3

    func fit(_ tab: AIGroupTab, in folder: AIGroupInfo, decider: any AIGroupDecider) async -> AIGroupFit {
        let key = ([tab.key, folder.name] + folder.members.prefix(6).map(\.key)).joined(separator: "|")
        if let known = fits[key] { return known }
        let asked = decider.local ? (tab, folder) : (tab.sent, folder.sent)
        guard let said = try? await Self.within(settings.timeout, { try await decider.fits(asked.0, in: asked.1) }) else { return .unsure }
        if fits.count > 2000 { fits = [:] }
        fits[key] = said
        return said
    }

    func belongs(_ tabs: [AIGroupTab], in folder: AIGroupInfo, decider: any AIGroupDecider) async -> Bool {
        let asked = Array(tabs.prefix(Self.compared))
        guard !asked.isEmpty, !folder.members.isEmpty else { return false }
        var said: [AIGroupFit] = []
        await withTaskGroup(of: AIGroupFit.self) { group in
            for tab in asked { group.addTask { @MainActor in await self.fit(tab, in: folder, decider: decider) } }
            for await fit in group { said.append(fit) }
        }
        return said.contains(.yes) && !said.contains(.no)
    }

    static func splits(_ keys: [String], _ dismissed: [Set<String>]) -> Bool {
        dismissed.contains { set in keys.filter(set.contains).count >= 2 }
    }

    func together(_ formed: [[UUID]], everyone: [UUID: AIGroupTab], decider: any AIGroupDecider, dismissed: [Set<String>] = []) async -> [[UUID]] {
        var kept: [[UUID]] = []
        for component in formed {
            let tabs = component.compactMap { everyone[$0] }
            var home: Int?
            for (index, earlier) in kept.enumerated() {
                let members = earlier.compactMap { everyone[$0] }
                guard !Self.splits((members + tabs).map(\.key), dismissed) else { continue }
                let folder = AIGroupInfo(id: UUID(), name: AIGroupNames.fallback(members, query: query(of: Set(earlier))), members: members)
                if await belongs(tabs, in: folder, decider: decider) {
                    home = index
                    break
                }
            }
            AIGroupTrace.note("together", ["component": tabs.map(\.title), "joined": home.map { kept[$0].compactMap { everyone[$0]?.title } } ?? []])
            if let home {
                kept[home] += component
            } else {
                kept.append(component)
            }
        }
        return kept
    }

    static func untouched(_ group: TabGroup, in browser: Browser) -> Bool {
        automatic(group) && !group.userNamed && !group.userIcon && group.aiRefused.isEmpty && group.parent == nil
            && browser.editingGroupID != group.id && !browser.tabGroups.contains { $0.parent == group.id }
    }

    func joinTwins(fresh: Set<UUID>, space: UUID, decider: (any AIGroupDecider)?) async -> Int {
        guard let browser, !fresh.isEmpty else { return 0 }
        var joined = 0
        var apart: Set<String> = []
        for _ in 0..<Self.rounds {
            guard browser.spaceID == space, settings.active(browser) else { break }
            let folders = browser.tabGroups.filter { Self.untouched($0, in: browser) }
            let sized = folders.map { (group: $0, tabs: browser.tabs(in: $0.id)) }.filter { $0.tabs.count >= 1 }
            var found: (small: TabGroup, large: TabGroup)?
            var maybe: [(small: TabGroup, large: TabGroup)] = []
            for (index, one) in sized.enumerated() {
                for two in sized.dropFirst(index + 1) where fresh.contains(one.group.id) || fresh.contains(two.group.id) {
                    let (small, large) = one.tabs.count < two.tabs.count ? (one.group, two.group) : (two.group, one.group)
                    guard mayJoin(small.id, into: large.id, space: space) else { continue }
                    let named = !provisional.contains(one.group.id) && !provisional.contains(two.group.id)
                        && how[one.group.id]?.hasPrefix("fallback") != true && how[two.group.id]?.hasPrefix("fallback") != true
                    if named, AIGroupNames.twins(one.group.name, two.group.name) {
                        found = (small, large)
                        break
                    }
                    if AIGroupNames.twins(one.group.name, two.group.name)
                        || AIGroupNames.sameSubject(one.group.name, two.group.name) || AIGroupNames.sameSubject(two.group.name, one.group.name) {
                        maybe.append((small, large))
                    }
                }
                if found != nil { break }
            }
            if found == nil, let decider {
                for pair in maybe {
                    let key = "\(pair.small.id)|\(pair.large.id)|\(browser.tabs(in: pair.small.id).count)|\(browser.tabs(in: pair.large.id).count)"
                    guard !apart.contains(key) else { continue }
                    let tabs = browser.tabs(in: pair.small.id).compactMap(Self.shown)
                    if await belongs(tabs, in: info(pair.large, in: browser), decider: decider) {
                        found = pair
                        break
                    }
                    apart.insert(key)
                }
            }
            guard let found else { break }
            joined += join(found.small.id, into: found.large.id, space: space)
        }
        return joined
    }

    func mayJoin(_ small: UUID, into large: UUID, space: UUID) -> Bool {
        guard let browser else { return false }
        let moving = browser.tabs(in: small)
        guard !moving.contains(where: { away[$0.id]?.contains(large) == true }) else { return false }
        let keys = (moving + browser.tabs(in: large)).compactMap { Self.shown($0)?.key }
        return !Self.splits(keys, dismissed[space] ?? [])
    }

    func join(_ small: UUID, into large: UUID, space: UUID) -> Int {
        guard let browser, browser.tabGroups.contains(where: { $0.id == large }) else { return 0 }
        let moving = browser.tabs.filter { $0.groupID == small }
        AIGroupTrace.note("twins", ["from": browser.tabGroups.first { $0.id == small }?.name ?? "?",
                                    "into": browser.tabGroups.first { $0.id == large }?.name ?? "?", "tabs": moving.map(\.title)])
        for tab in moving { tab.groupID = large }
        browser.tabGroups.removeAll { $0.id == small }
        members[space]?[small] = nil
        namedWith[small] = nil
        provisional.remove(small)
        how[small] = nil
        settings.unveil(small)
        for (key, cached) in cache where cached == .group(small) { cache[key] = .group(large) }
        namedWith[large] = Self.members(large, in: browser)
        browser.placeJoined(moving)
        browser.arrangeGroupedTabs()
        browser.writeSession(now: true)
        observe()
        return moving.count
    }

    func watch(_ tab: Tab) {
        guard !watched.contains(tab.id) else { return }
        watched.insert(tab.id)
        withObservationTracking {
            _ = tab.title
        } onChange: { [weak self, weak tab] in
            Task { @MainActor in
                guard let self, let tab else { return }
                self.watched.remove(tab.id)
                guard Self.shown(tab) != nil else {
                    self.watch(tab)
                    return
                }
                self.landed(tab)
            }
        }
    }

    private func step(_ space: UUID, everything: Bool, decider: (any AIGroupDecider)?, leftovers: Set<Tab.ID>) async -> Step {
        var step = Step()
        guard let browser else { return step }
        observe()
        let room = min(everything ? 24 : Self.batch, decider?.batch ?? Self.batch)
        let places = Dictionary(browser.tabs.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { one, _ in one })
        let waiting = (pending[space] ?? [:]).sorted {
            ($0.value, places[$0.key] ?? .max, $0.key.uuidString) < ($1.value, places[$1.key] ?? .max, $1.key.uuidString)
        }
        var chosen: [Tab] = []
        var born: [Tab] = []
        let tried = Dictionary(waiting.map { ($0.key, $0.value) }, uniquingKeysWith: { one, _ in one })
        for (id, tries) in waiting {
            guard let tab = browser.tabs.first(where: { $0.id == id }), Self.usable(tab, in: browser) else {
                pending[space]?[id] = nil
                decided.insert(id)
                continue
            }
            if browser.group(of: tab) != nil {
                guard Self.born(tab, in: browser) != nil, Self.shown(tab) != nil || tries < 2 else {
                    tab.bornIn = nil
                    pending[space]?[id] = nil
                    decided.insert(id)
                    continue
                }
                guard Self.shown(tab) != nil else {
                    if bumped.insert(id).inserted { pending[space]?[id] = tries + 1 }
                    watch(tab)
                    continue
                }
                guard born.count < Self.batch else { continue }
                born.append(tab)
                pending[space]?[id] = nil
                continue
            }
            guard Self.shown(tab) != nil else {
                if bumped.insert(id).inserted {
                    if tries >= 2 { pending[space]?[id] = nil } else { pending[space]?[id] = tries + 1 }
                }
                watch(tab)
                continue
            }
            guard chosen.count < room else { continue }
            chosen.append(tab)
            pending[space]?[id] = nil
        }
        for tab in await judge(born, space: space, decider: decider) {
            if chosen.count < room {
                chosen.append(tab)
            } else {
                pending[space, default: [:]][tab.id] = 0
            }
        }
        if decider?.local == true {
            for tab in chosen { await tab.readBy() }
        }
        let fresh = chosen.compactMap(Self.shown)
        step.went = !fresh.isEmpty || !born.isEmpty
        guard !fresh.isEmpty else { return step }
        decided.formUnion(fresh.map(\.id))
        step.asked = Set(fresh.map(\.id))
        let freshIDs = Set(fresh.map(\.id))
        var loose = Array(browser.tabs(in: nil).filter { !freshIDs.contains($0.id) && Self.usable($0, in: browser) }
            .compactMap(Self.shown).suffix(Self.context))
        var openers: [UUID: UUID] = [:]
        for shown in fresh {
            guard let tab = browser.tabs.first(where: { $0.id == shown.id }), let from = tab.linkedFrom ?? tab.opener,
                  let source = browser.tabs.first(where: { $0.id == from }), browser.group(of: source) == nil,
                  Self.usable(source, in: browser), browser.searchQuery(of: source) != nil,
                  let seen = Self.shown(source) else { continue }
            openers[shown.id] = source.id
            if !freshIDs.contains(source.id), !loose.contains(where: { $0.id == source.id }) { loose.append(seen) }
        }
        let groups = browser.tabGroups.filter(Self.automatic).map { info($0, in: browser) }
        let ask = AIGroupAsk(groups: groups, loose: loose, fresh: fresh)
        var picks: [UUID: AIGroupPick] = [:]
        var unknown: [AIGroupTab] = []
        for tab in fresh {
            switch cache[tab.key] {
            case .group(let id)? where groups.contains(where: { $0.id == id && !$0.refused.contains(tab.key) }):
                picks[tab.id] = .group(id)
            case .loose(let signature)? where signature == ask.signature:
                picks[tab.id] = AIGroupPick.none
            default:
                unknown.append(tab)
            }
        }
        if !unknown.isEmpty {
            guard let decider else {
                settings.told("Nothing is set up to group tabs")
                step.failed = true
                return step
            }
            let whole = AIGroupAsk(groups: groups, loose: loose, fresh: unknown)
            let question = decider.local ? whole : whole.sent
            do {
                let said = try await Self.within(settings.timeout) { try await decider.decide(question) }
                for tab in unknown { picks[tab.id] = said[tab.id] ?? AIGroupPick.none }
                let offered = Set(groups.map(\.id) + groups.flatMap { $0.members.map(\.id) } + fresh.map(\.id))
                if heard.count > 2000 { heard = [:] }
                for tab in unknown { heard[tab.key, default: []].formUnion(offered) }
            } catch {
                settings.told("Couldn't group tabs: \(error.localizedDescription)")
                AIGroupTrace.note("failed", ["why": error.localizedDescription, "fresh": unknown.map(\.title)])
                if decider.local {
                    for tab in unknown where tried[tab.id] == 0 {
                        pending[space, default: [:]][tab.id] = 1
                        decided.remove(tab.id)
                    }
                }
                step.failed = true
                return step
            }
        }
        var plan = AIGroupRules.plan(ask, picks: picks, dismissed: dismissed[space] ?? [], openers: openers)
        let everyone = Dictionary((fresh + loose + groups.flatMap(\.members)).map { ($0.id, $0) }, uniquingKeysWith: { one, _ in one })
        if plan.formed.count > 1, let decider {
            plan.formed = await together(plan.formed, everyone: everyone, decider: decider, dismissed: dismissed[space] ?? [])
        }
        AIGroupTrace.note("pass", [
            "asked": AIGroupPrompt.deciding(AIGroupAsk(groups: groups, loose: loose, fresh: unknown)),
            "cached": fresh.filter { tab in !unknown.contains { $0.id == tab.id } }.map(\.title),
            "picks": fresh.map { "\($0.title) -> \(AIGroupTrace.said(picks[$0.id] ?? AIGroupPick.none, in: ask))" },
            "joins": plan.joins.map { tab, group in "\(fresh.first { $0.id == tab }?.title ?? loose.first { $0.id == tab }?.title ?? "?") -> \(groups.first { $0.id == group }?.name ?? "?")" },
            "formed": plan.formed.map { $0.map { id in (fresh + loose).first { $0.id == id }?.title ?? "?" } },
        ])
        for tab in fresh {
            if let group = plan.joins[tab.id] {
                cache[tab.key] = .group(group)
            } else if !plan.formed.contains(where: { $0.contains(tab.id) }) {
                cache[tab.key] = .loose(ask.signature)
            }
        }
        if cache.count > 500 { cache = cache.filter { if case .group = $0.value { return true } else { return false } } }
        guard !plan.isEmpty else {
            settings.told(nil)
            return step
        }
        guard browser.spaceID == space, settings.active(browser) else { return step }
        let stillLoose = { (id: UUID) -> Tab? in
            guard let tab = browser.tabs.first(where: { $0.id == id }), Self.usable(tab, in: browser),
                  browser.group(of: tab) == nil else { return nil }
            return tab
        }
        var formedKeys: [String: UUID] = [:]
        var made: [UUID] = []
        var touched: Set<UUID> = []
        var kept = browser.tabGroups
        var outcome = Outcome()
        for (tab, id) in plan.joins {
            guard kept.contains(where: { $0.id == id }), let found = stillLoose(tab), away[found.id]?.contains(id) != true else { continue }
            found.groupID = id
            touched.insert(id)
            outcome.joined += 1
        }
        for component in plan.formed {
            let tabs = component.compactMap(stillLoose)
            guard tabs.count >= 2 else { continue }
            let shown = component.compactMap { everyone[$0] }
            var group = TabGroup(id: UUID(), name: AIGroupNames.fallback(shown, query: query(of: Set(component))), collapsed: false)
            group.ai = true
            group.pinned = false
            kept.append(group)
            namedWith[group.id] = Set(tabs.filter { Self.shown($0) != nil }.map(\.id))
            provisional.insert(group.id)
            settings.veil(group.id)
            made.append(group.id)
            touched.insert(group.id)
            for tab in tabs {
                tab.groupID = group.id
                if let key = Self.shown(tab)?.key { formedKeys[key] = group.id }
            }
            outcome.formed += 1
        }
        browser.tabGroups = kept
        browser.placeJoined(plan.joins.compactMap { tab, id in browser.tabs.first { $0.id == tab && $0.groupID == id } })
        browser.arrangeGroupedTabs()
        for (key, id) in formedKeys { cache[key] = .group(id) }
        browser.writeSession(now: true)
        observe()
        settings.told(nil)
        if let decider { outcome.joined += await gather(into: touched, space: space, decider: decider, leftovers: leftovers.union(step.asked)) }
        step.outcome = outcome
        step.made = made
        step.touched = touched
        return step
    }


    func judge(_ tabs: [Tab], space: UUID, decider: (any AIGroupDecider)?) async -> [Tab] {
        guard let browser, !tabs.isEmpty else { return [] }
        if decider?.local == true {
            for tab in tabs { await tab.readBy() }
        }
        let waiting = Set(browser.tabs.filter { $0.bornIn != nil }.map(\.id))
        var leaving: [(tab: Tab, group: UUID)] = []
        var failed: String?
        for tab in tabs {
            guard let group = Self.born(tab, in: browser), let shown = Self.shown(tab) else {
                tab.bornIn = nil
                decided.insert(tab.id)
                continue
            }
            let members = browser.tabs(in: group.id).filter { !waiting.contains($0.id) }.compactMap(Self.shown)
            let folder = AIGroupInfo(id: group.id, name: group.name, members: members, settled: !provisional.contains(group.id))
            var fit = AIGroupFit.unsure
            var why = ""
            if !folder.settled {
                why = "the folder is not settled yet"
            } else if members.count < 2 {
                why = "the folder has fewer than two other tabs"
            } else if let failed {
                why = "an earlier judgment in this pass failed: \(failed)"
            } else if let decider {
                let asked = decider.local ? (shown, folder) : (shown.sent, folder.sent)
                do {
                    fit = try await Self.within(settings.timeout) { try await decider.fits(asked.0, in: asked.1) }
                } catch {
                    why = error.localizedDescription
                    failed = why
                }
            } else {
                why = "nothing is set up to judge"
            }
            AIGroupTrace.note("born", ["tab": shown.title, "folder": group.name, "members": members.map(\.title), "fit": fit.rawValue, "why": why])
            guard Self.born(tab, in: browser)?.id == group.id else { continue }
            tab.bornIn = nil
            decided.insert(tab.id)
            if fit == .no { leaving.append((tab, group.id)) }
        }
        membershipChanged()
        guard !leaving.isEmpty, browser.spaceID == space, settings.active(browser) else { return [] }
        var left: [Tab] = []
        for (tab, id) in leaving {
            guard tab.groupID == id, browser.group(of: tab) == id, Self.usable(tab, in: browser),
                  browser.tabs(in: id).count >= 3 else { continue }
            members[space]?[id]?.remove(tab.id)
            tab.groupID = nil
            away[tab.id, default: []].insert(id)
            decided.remove(tab.id)
            if let key = Self.shown(tab)?.key, cache[key] == .group(id) { cache[key] = nil }
            left.append(tab)
        }
        guard !left.isEmpty else { return [] }
        for id in Set(leaving.map(\.group)) {
            browser.placeLeft(left.filter { tab in leaving.contains { $0.tab === tab && $0.group == id } }, from: id)
        }
        browser.arrangeGroupedTabs()
        browser.writeSession(now: true)
        observe()
        return left
    }

    static let gathered = 8

    static func unheard(_ tab: AIGroupTab, _ group: AIGroupInfo, heard: Set<UUID>) -> Bool {
        !heard.contains(group.id) && group.members.contains { !heard.contains($0.id) }
    }

    func gather(into ids: Set<UUID>, space: UUID, decider: any AIGroupDecider, leftovers: Set<Tab.ID> = []) async -> Int {
        guard let browser, !ids.isEmpty else { return 0 }
        var joined = 0
        var asked: Set<String> = []
        for _ in 0..<4 {
            guard browser.spaceID == space, settings.active(browser) else { break }
            let groups = browser.tabGroups.filter { ids.contains($0.id) && Self.automatic($0) }.map { info($0, in: browser) }
            guard !groups.isEmpty else { break }
            let waiting = pending[space] ?? [:]
            let near = browser.tabs(in: nil).filter { Self.usable($0, in: browser) && waiting[$0.id] == nil }.compactMap(Self.shown)
                .filter { tab in
                    !asked.contains(tab.key) && groups.contains { group in
                        !group.refused.contains(tab.key)
                            && ((leftovers.contains(tab.id) && Self.unheard(tab, group, heard: heard[tab.key] ?? [])) || group.members.contains {
                                AIGroupEvidence.channel(tab, $0) || !AIGroupEvidence.shared(tab, $0).isEmpty || AIGroupSubjects.near(tab, $0)
                            })
                    }
                }.prefix(Self.gathered)
            guard !near.isEmpty else { break }
            asked.formUnion(near.map(\.key))
            if heard.count > 2000 { heard = [:] }
            let offered = Set(groups.map(\.id) + groups.flatMap { $0.members.map(\.id) })
            for tab in near { heard[tab.key, default: []].formUnion(offered) }
            let whole = AIGroupAsk(groups: groups, loose: [], fresh: Array(near))
            let question = decider.local ? whole : whole.sent
            guard let said = try? await Self.within(settings.timeout, { try await decider.decide(question) }) else { break }
            let picks = said.filter { if case .group = $0.value { return true } else { return false } }
            let plan = AIGroupRules.plan(whole, picks: picks, dismissed: dismissed[space] ?? [])
            AIGroupTrace.note("gather", [
                "offered": near.map(\.title),
                "joins": plan.joins.map { tab, group in "\(near.first { $0.id == tab }?.title ?? "?") -> \(groups.first { $0.id == group }?.name ?? "?")" },
            ])
            var moved: [Tab] = []
            for (id, group) in plan.joins {
                guard browser.tabGroups.contains(where: { $0.id == group }),
                      let tab = browser.tabs.first(where: { $0.id == id }), Self.usable(tab, in: browser),
                      browser.group(of: tab) == nil, away[id]?.contains(group) != true else { continue }
                tab.groupID = group
                decided.insert(id)
                if let key = Self.shown(tab)?.key { cache[key] = .group(group) }
                moved.append(tab)
            }
            guard !moved.isEmpty else { break }
            joined += moved.count
            browser.placeJoined(moved)
            browser.arrangeGroupedTabs()
            browser.writeSession(now: true)
            observe()
        }
        return joined
    }

    static func within<Value: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ProviderError.failed("It took too long")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ProviderError.cancelled }
            return first
        }
    }
}
