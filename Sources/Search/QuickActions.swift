import AppKit
import Observation
import Combine

struct QuickAction: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var aliases: [String]
    var address: String

    var url: URL? {
        URL(string: address.contains("://") ? address : "https://" + address)
    }

    var shown: String {
        Address.withoutWWW(url?.host() ?? address)
    }

    var target: String {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count))
        }
        if text.lowercased().hasPrefix("www.") { text = String(text.dropFirst(4)) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    var short: String { aliases.first ?? "" }

    static func alias(_ typed: String) -> String {
        typed.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

struct QuickSuggestion: Equatable {
    let action: QuickAction
    let reason: String
}

enum QuickCatalog {
    struct Choice {
        let address: String
        let site: String
    }

    struct Slot {
        let id: String
        let name: String
        let aliases: [String]
        let choices: [Choice]
    }

    struct Offer {
        let action: QuickAction
        let host: String
        let paths: [String]
        let noun: String
    }

    static let slots: [Slot] = [
        Slot(id: "doc", name: "New document",
             aliases: ["doc", "docs", "document", "new doc", "new document", "документ", "новый документ"],
             choices: [Choice(address: "docs.new", site: "docs.google.com"), Choice(address: "notion.new", site: "notion.so")]),
        Slot(id: "meet", name: "New meeting",
             aliases: ["meet", "meeting", "new meet", "new meeting", "встреча", "новая встреча"],
             choices: [Choice(address: "meet.new", site: "meet.google.com"), Choice(address: "zoom.new", site: "zoom.us")]),
    ]

    static let offers: [Offer] = [
        Offer(action: QuickAction(id: "sheet", name: "New sheet",
                                  aliases: ["sheet", "sheets", "spreadsheet", "new sheet", "таблица", "новая таблица"],
                                  address: "sheets.new"),
              host: "docs.google.com", paths: ["/spreadsheets/d/"], noun: "sheets"),
        Offer(action: QuickAction(id: "slides", name: "New presentation",
                                  aliases: ["slides", "presentation", "new slides", "new presentation", "презентация", "новая презентация"],
                                  address: "slides.new"),
              host: "docs.google.com", paths: ["/presentation/d/"], noun: "presentations"),
        Offer(action: QuickAction(id: "notion", name: "New Notion page",
                                  aliases: ["notion", "new notion", "new notion page"], address: "notion.new"),
              host: "notion.so", paths: ["/"], noun: "Notion pages"),
        Offer(action: QuickAction(id: "zoom", name: "New Zoom meeting",
                                  aliases: ["zoom", "new zoom"], address: "zoom.new"),
              host: "zoom.us", paths: ["/j/"], noun: "Zoom meetings"),
        Offer(action: QuickAction(id: "figma", name: "New Figma file",
                                  aliases: ["figma", "new figma"], address: "figma.new"),
              host: "figma.com", paths: ["/design/", "/file/", "/board/"], noun: "Figma files"),
        Offer(action: QuickAction(id: "linear", name: "New Linear issue",
                                  aliases: ["linear", "issue", "new issue", "new linear"], address: "linear.new"),
              host: "linear.app", paths: ["/issue/"], noun: "Linear issues"),
        Offer(action: QuickAction(id: "repo", name: "New repository",
                                  aliases: ["repo", "repository", "new repo", "new repository"], address: "repo.new"),
              host: "github.com", paths: ["/new"], noun: "new repositories"),
        Offer(action: QuickAction(id: "gist", name: "New gist",
                                  aliases: ["gist", "new gist"], address: "gist.new"),
              host: "gist.github.com", paths: ["/"], noun: "gists"),
        Offer(action: QuickAction(id: "cal", name: "New calendar event",
                                  aliases: ["cal", "event", "new event", "new calendar event"], address: "cal.new"),
              host: "calendar.google.com", paths: ["eventedit"], noun: "calendar events"),
    ]

    static func evidence(for offer: Offer, among pages: [URL]) -> Int {
        pages.filter { page in
            guard let host = page.host()?.lowercased() else { return false }
            let bare = PageIndex.bare(host)
            guard bare == offer.host || bare.hasSuffix("." + offer.host) else { return false }
            let path = page.path()
            if offer.paths == ["/"] { return path.count > 1 }
            return offer.paths.contains { path.contains($0) }
        }
        .count
    }
}

@MainActor
@Observable
final class QuickActions {
    static let shared = QuickActions(file: Store.file("quickactions.json"))

    struct Saved: Codable, Equatable {
        var custom: [QuickAction] = []
        var kept: [String] = []
        var dismissed: [String] = []
        var hidden: [String] = []
        var order: [String] = []
        var changed: [QuickAction] = []

        init() {}

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            custom = try values.decodeIfPresent([QuickAction].self, forKey: .custom) ?? []
            kept = try values.decodeIfPresent([String].self, forKey: .kept) ?? []
            dismissed = try values.decodeIfPresent([String].self, forKey: .dismissed) ?? []
            hidden = try values.decodeIfPresent([String].self, forKey: .hidden) ?? []
            order = try values.decodeIfPresent([String].self, forKey: .order) ?? []
            changed = try values.decodeIfPresent([QuickAction].self, forKey: .changed) ?? []
        }
    }

    static let enough = 3
    static let lately: TimeInterval = 30 * 86_400

    private(set) var saved = Saved()

    private let file: URL

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file) {
            if let read = try? JSONDecoder().decode(Saved.self, from: data) { saved = read } else { Store.quarantine(file) }
        }
    }

    private func save() {
        let snapshot = saved
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }

    static func problem(alias: String, address: String, among taken: [String]) -> String? {
        let word = QuickAction.alias(alias)
        if word.isEmpty { return "Add a short name you type to reach it" }
        if taken.contains(word) { return "\(word) is already a Quick Action" }
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: text.contains("://") ? text : "https://" + text)
        guard !text.isEmpty, let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host() != nil else {
            return "Add a web address to open"
        }
        return nil
    }

    var takenAliases: [String] { takenAliases(except: nil) }

    func takenAliases(except id: String?) -> [String] {
        let slots = QuickCatalog.slots.filter { $0.id != id && !saved.hidden.contains($0.id) }
            .flatMap { slot in changedAction(slot.id)?.aliases ?? slot.aliases }
        let offers = QuickCatalog.offers.filter { $0.action.id != id }
            .flatMap { offer in changedAction(offer.action.id)?.aliases ?? offer.action.aliases }
        return (saved.custom.filter { $0.id != id }.flatMap(\.aliases) + slots + offers).map(QuickAction.alias)
    }

    func problem(editing id: String?, alias: String, address: String) -> String? {
        Self.problem(alias: alias, address: address, among: takenAliases(except: id))
    }

    private func changedAction(_ id: String) -> QuickAction? {
        saved.changed.first { $0.id == id }
    }

    private var customAliases: Set<String> {
        Set(saved.custom.flatMap(\.aliases).map(QuickAction.alias))
    }

    @discardableResult
    func add(name: String, alias: String, address: String) -> QuickAction? {
        guard Self.problem(alias: alias, address: address, among: takenAliases) == nil else { return nil }
        let word = QuickAction.alias(alias)
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let action = QuickAction(id: "custom-" + UUID().uuidString, name: title.isEmpty ? word : title, aliases: [word],
                                 address: address.trimmingCharacters(in: .whitespacesAndNewlines))
        saved.custom.append(action)
        save()
        return action
    }

    func remove(_ id: String) {
        _ = delete(id, history: Shared.history)
    }

    func isBuiltIn(_ id: String) -> Bool { QuickCatalog.slots.contains { $0.id == id } }

    func canDelete(_ id: String) -> Bool {
        isCustom(id) || saved.kept.contains(id) || (isBuiltIn(id) && !saved.hidden.contains(id))
    }

    @discardableResult
    func edit(_ id: String, name: String, alias: String, address: String, history: History) -> Bool {
        guard let current = shown(history: history).first(where: { $0.id == id }),
              problem(editing: id, alias: alias, address: address) == nil
        else { return false }
        let word = QuickAction.alias(alias)
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = current
        next.name = title.isEmpty ? word : title
        next.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if word != current.short {
            next.aliases = [word] + current.aliases.dropFirst().filter { QuickAction.alias($0) != word }
        }
        guard next != current else { return true }
        if let index = saved.custom.firstIndex(where: { $0.id == id }) {
            saved.custom[index] = next
        } else {
            saved.changed.removeAll { $0.id == id }
            saved.changed.append(next)
        }
        save()
        return true
    }

    @discardableResult
    func delete(_ id: String, history: History) -> Bool {
        guard canDelete(id), shown(history: history).contains(where: { $0.id == id }) else { return false }
        ShortcutStore.shared.clear("quick:" + id)
        Favorites.shared.remove("quick:" + id)
        saved.custom.removeAll { $0.id == id }
        saved.kept.removeAll { $0 == id }
        if isBuiltIn(id) { saved.hidden.append(id) } else { saved.changed.removeAll { $0.id == id } }
        save()
        return true
    }

    @discardableResult
    func move(_ id: String, by step: Int, history: History) -> Bool {
        var ids = shown(history: history).map(\.id)
        guard let here = ids.firstIndex(of: id), ids.indices.contains(here + step) else { return false }
        ids.swapAt(here, here + step)
        arrange(ids)
        return true
    }

    func move(from offsets: IndexSet, to place: Int, history: History) {
        var ids = shown(history: history).map(\.id)
        ids.move(fromOffsets: offsets, toOffset: place)
        arrange(ids)
    }

    private func arrange(_ ids: [String]) {
        saved.order = ids + saved.order.filter { !ids.contains($0) && saved.hidden.contains($0) }
        save()
    }

    var builtInsChanged: Bool {
        QuickCatalog.slots.contains { slot in saved.hidden.contains(slot.id) || changedAction(slot.id) != nil }
    }

    var builtInsEdited: Bool {
        QuickCatalog.slots.contains { changedAction($0.id) != nil }
    }

    func restoreBuiltIns() {
        let ids = QuickCatalog.slots.map(\.id)
        saved.hidden.removeAll { ids.contains($0) }
        saved.changed.removeAll { ids.contains($0.id) }
        if !saved.order.isEmpty {
            saved.order = ids + saved.order.filter { !ids.contains($0) }
        }
        save()
    }

    static func preview(_ actions: [QuickAction]) -> String? {
        let words = actions.map(\.short).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        if words.count == 1 { return words[0] }
        if words.count <= 3 { return words.dropLast().joined(separator: ", ") + " and " + words[words.count - 1] }
        return words.prefix(3).joined(separator: ", ") + " and \(words.count - 3) more"
    }

    func keep(_ id: String) {
        guard !saved.kept.contains(id) else { return }
        saved.kept.append(id)
        saved.dismissed.removeAll { $0 == id }
        save()
    }

    func dismiss(_ id: String) {
        guard !saved.dismissed.contains(id) else { return }
        saved.dismissed.append(id)
        save()
    }

    func builtIn(_ slot: QuickCatalog.Slot, history: History) -> QuickAction {
        let taken = customAliases
        if let changed = changedAction(slot.id) {
            var action = changed
            action.aliases = changed.aliases.filter { !taken.contains(QuickAction.alias($0)) }
            return action
        }
        let counts = history.visits(to: slot.choices.map(\.site))
        let best = slot.choices.enumerated().max { one, other in
            let (a, b) = (counts[one.element.site] ?? 0, counts[other.element.site] ?? 0)
            return a == b ? one.offset > other.offset : a < b
        }?.element ?? slot.choices[0]
        return QuickAction(id: slot.id, name: slot.name, aliases: slot.aliases.filter { !taken.contains(QuickAction.alias($0)) },
                           address: best.address)
    }

    private var keptOffers: [QuickAction] {
        saved.kept.compactMap { id in
            changedAction(id) ?? QuickCatalog.offers.first { $0.action.id == id }?.action
        }
    }

    func shown(history: History) -> [QuickAction] {
        let slots = QuickCatalog.slots.filter { !saved.hidden.contains($0.id) }.map { builtIn($0, history: history) }
        let all = slots + keptOffers + saved.custom
        guard !saved.order.isEmpty else { return all }
        var rank: [String: Int] = [:]
        for (place, id) in saved.order.enumerated() where rank[id] == nil { rank[id] = place }
        return all.enumerated()
            .sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }
            .map(\.element)
    }

    func reachable(history: History) -> [QuickAction] {
        let shown = shown(history: history)
        let known = Set(shown.map(\.id))
        return shown + QuickCatalog.offers.map { changedAction($0.action.id) ?? $0.action }.filter { !known.contains($0.id) }
    }

    func site(of action: QuickAction) -> String? {
        if let slot = QuickCatalog.slots.first(where: { $0.id == action.id }),
           let choice = slot.choices.first(where: { $0.address == action.address }) {
            return choice.site
        }
        if let offer = QuickCatalog.offers.first(where: { $0.action.id == action.id }), action.address == offer.action.address {
            return offer.host
        }
        if let slot = QuickCatalog.slots.first(where: { slot in slot.choices.contains { $0.address == action.target } }) {
            return slot.choices.first { $0.address == action.target }?.site
        }
        return action.url?.host()
    }

    func action(_ id: String, history: History) -> QuickAction? {
        reachable(history: history).first { $0.id == id }
    }

    func isSuggestion(_ id: String) -> Bool {
        QuickCatalog.offers.contains { $0.action.id == id } && !saved.kept.contains(id)
    }

    func isCustom(_ id: String) -> Bool { saved.custom.contains { $0.id == id } }

    func suggestions(history: History, now: Date = Date()) -> [QuickSuggestion] {
        let pages = history.everything().filter { now.timeIntervalSince($0.last) < Self.lately }.map(\.url)
        return QuickCatalog.offers.compactMap { offer in
            let id = offer.action.id
            guard !saved.kept.contains(id), !saved.dismissed.contains(id) else { return nil }
            let count = QuickCatalog.evidence(for: offer, among: pages)
            guard count >= Self.enough else { return nil }
            return QuickSuggestion(action: offer.action, reason: "You opened \(count) \(offer.noun) this month")
        }
        .sorted { $0.reason.count < $1.reason.count }
        .prefix(2)
        .map { $0 }
    }

    func matches(_ typed: String, history: History) -> (lead: QuickAction?, others: [QuickAction]) {
        let word = QuickAction.alias(typed)
        guard word.count >= 2 else { return (nil, []) }
        let leading = shown(history: history)
        let lead = leading.first { $0.aliases.contains(word) }
        let others = reachable(history: history).filter { action in
            action.id != lead?.id && FieldName.score(word, title: action.name, aliases: action.aliases) != nil
        }
        return (lead, Array(others.prefix(2)))
    }
}

extension Browser {
    func quickRow(_ action: QuickAction, reason: String = "", leads: Bool = false) -> Suggestion? {
        guard let url = action.url else { return nil }
        var row = Suggestion(key: action.name, title: reason.isEmpty ? action.shown : reason, url: url,
                             kind: .action("quick:" + action.id))
        row.leads = leads
        row.keys = ShortcutStore.shared.key(for: "quick:" + action.id)?.display ?? ""
        return row
    }

    func quickHomeRows() -> [Suggestion] {
        let store = QuickActions.shared
        return store.shown(history: history).compactMap { quickRow($0) }
            + store.suggestions(history: history).compactMap { quickRow($0.action, reason: $0.reason) }
    }

    func runQuick(_ id: String) {
        guard let url = QuickActions.shared.action(id, history: history)?.url else { return }
        if let tab = active, tab.isBlank {
            tab.go(to: url)
        } else {
            open(url, foreground: true, from: active)
        }
    }

    func commandKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
              let combo = KeyCombo(event: event)
        else { return false }
        for action in QuickActions.shared.saved.custom
        where ShortcutStore.shared.key(for: "quick:" + action.id) == combo {
            runQuick(action.id)
            return true
        }
        guard prefs.nextMeeting else { return false }
        for id in Command.meeting where ShortcutStore.shared.key(for: id) == combo {
            Command.named(id)?.run(self)
            return true
        }
        return false
    }

    func pageActionRows() -> ([Suggestion], [FieldSection]) {
        func row(_ id: String, _ title: String, _ symbol: String, _ keys: String = "") -> Suggestion {
            var row = Suggestion(key: title, title: "", url: FieldAction.nowhere, kind: .action("page:" + id))
            row.symbol = symbol
            row.keys = keys
            return row
        }
        let rows = [
            row("copy", LinkCopy.title(.address, count: 1), "link"),
            row("markdown", LinkCopy.title(.markdown, count: 1), "text.badge.checkmark"),
            row("rich", LinkCopy.title(.rich, count: 1), "link.badge.plus"),
            row("pageMarkdown", "Copy Page as Markdown", "doc.plaintext",
                ShortcutStore.shared.key(for: "edit.copyPageMarkdown")?.display ?? ""),
            row("duplicate", "Duplicate Tab", "plus.square.on.square",
                ShortcutStore.shared.key(for: "tabs.duplicate")?.display ?? ""),
        ]
        return (rows, [FieldSection(title: "This Page", range: 0..<rows.count)])
    }

    func runPageAction(_ id: String) {
        switch id {
        case "copy": copyPage(.address)
        case "markdown": copyPage(.markdown)
        case "rich": copyPage(.rich)
        case "pageMarkdown": copyPageAsMarkdown()
        case "duplicate": duplicate()
        default: break
        }
    }
}
