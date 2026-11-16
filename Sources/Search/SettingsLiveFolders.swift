import AppKit

struct LiveSuggestion: Equatable, Identifiable {
    var id: String
    var title: String
    var name: String
    var source: LiveSource
    var visits: Int
    var details: [String]

    var line: String {
        ([visits == 1 ? "1 visit" : "\(visits) visits"] + details).joined(separator: " · ")
    }
}

struct LivePreset: Equatable, Identifiable {
    let id: String
    let title: String
    let name: String
    let detail: String
    let source: LiveSource

    static let all: [LivePreset] = [
        LivePreset(id: "github.pulls", title: "GitHub Pull Requests", name: LiveSource.pullRequestsName,
                   detail: "Review requests first, then yours", source: .pullRequests),
        LivePreset(id: "github.assigned", title: "GitHub Assigned Issues", name: "Assigned Issues",
                   detail: "Open issues assigned to you", source: .assignedIssues),
        LivePreset(id: "github.notifications", title: "GitHub Notifications", name: "Notifications",
                   detail: "The threads on your notifications page", source: .gitHubNotifications),
        LivePreset(id: "linear.assigned", title: "Linear My Issues", name: "My Issues",
                   detail: "Assigned to you and not done", source: .linear(.assigned)),
        LivePreset(id: "linear.mentions", title: "Linear Mentions", name: "Mentions",
                   detail: "Unread mentions of you", source: .linear(.mentions)),
        LivePreset(id: "linear.inbox", title: "Linear Inbox", name: "Inbox",
                   detail: "Every unread notification", source: .linear(.inbox)),
        LivePreset(id: "linear.created", title: "Linear Created by Me", name: "Created by Me",
                   detail: "Open issues you made", source: .linear(.created)),
        LivePreset(id: "youtube", title: "YouTube Subscriptions", name: "Subscriptions",
                   detail: "New videos from the channels you follow", source: .subscriptions),
    ]

    static func same(_ one: LiveSource, _ other: LiveSource) -> Bool {
        guard one.kind == other.kind, one.service == other.service else { return false }
        switch one.kind {
        case .linear: return LinearAPI.List(address: one.address) == LinearAPI.List(address: other.address)
        case .issues, .repository, .feed, .page: return one.address == other.address
        case .pullRequests, .notifications, .subscriptions: return true
        }
    }
}

enum LiveAdd: Equatable, Identifiable {
    case suggested(LiveSuggestion)
    case preset(LivePreset)

    var id: String {
        switch self {
        case .suggested(let suggestion): return suggestion.id
        case .preset(let preset): return preset.id
        }
    }

    var row: String {
        switch self {
        case .suggested(let suggestion): return "live.suggest." + suggestion.id
        case .preset(let preset): return "live.add." + preset.id
        }
    }

    var title: String {
        switch self {
        case .suggested(let suggestion): return suggestion.title
        case .preset(let preset): return preset.title
        }
    }

    var name: String {
        switch self {
        case .suggested(let suggestion): return suggestion.name
        case .preset(let preset): return preset.name
        }
    }

    var line: String {
        switch self {
        case .suggested(let suggestion): return suggestion.line
        case .preset(let preset): return preset.detail
        }
    }

    var source: LiveSource {
        switch self {
        case .suggested(let suggestion): return suggestion.source
        case .preset(let preset): return preset.source
        }
    }

    static func list(suggestions: [LiveSuggestion], folders: [LiveFolder]) -> [LiveAdd] {
        let presets = LivePreset.all.filter { preset in
            !folders.contains { LivePreset.same($0.source, preset.source) }
                && !suggestions.contains { LivePreset.same($0.source, preset.source) }
        }
        return suggestions.map(LiveAdd.suggested) + presets.map(LiveAdd.preset)
    }

    @MainActor static func now(for browser: Browser, space: UUID) -> [LiveAdd] {
        list(suggestions: LiveSuggestions.now(for: browser, space: space),
             folders: LiveFolders.shared.folders.filter { $0.space == space })
    }
}

@MainActor
enum LiveSuggestions {
    static let days = 30
    static let most = 5

    struct Spot {
        let id: String
        let title: String
        let name: String
        let source: LiveSource
        let detail: String?
    }

    private struct Tally {
        let spot: Spot
        var visits = 0
        var details: [String: Int] = [:]
    }

    private static let gitHubWords: Set<String> = [
        "about", "account", "apps", "codespaces", "collections", "contact", "copilot", "dashboard", "enterprise", "explore",
        "features", "issues", "join", "login", "logout", "marketplace", "new", "notifications", "organizations", "orgs",
        "pricing", "pulls", "search", "security", "sessions", "settings", "signup", "site", "sponsors", "stars", "topics",
        "trending", "users", "watching",
    ]

    static func from(_ traces: [History.Trace], folders: [LiveFolder], now: Date = Date()) -> [LiveSuggestion] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var tallies: [String: Tally] = [:]
        for trace in traces where trace.last >= since {
            guard let spot = spot(trace.url) else { continue }
            var tally = tallies[spot.id] ?? Tally(spot: spot)
            tally.visits = min(History.mostVisits, tally.visits + max(1, trace.count))
            if let detail = spot.detail { tally.details[detail, default: 0] += max(1, trace.count) }
            tallies[spot.id] = tally
        }
        return tallies.values
            .filter { !covered($0.spot.source, by: folders) }
            .sorted { $0.visits != $1.visits ? $0.visits > $1.visits : $0.spot.title < $1.spot.title }
            .prefix(most)
            .map { tally in
                let details = tally.details.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(2).map(\.key)
                return LiveSuggestion(id: tally.spot.id, title: tally.spot.title, name: tally.spot.name, source: tally.spot.source,
                                      visits: tally.visits, details: Array(details))
            }
    }

    static func covered(_ source: LiveSource, by folders: [LiveFolder]) -> Bool {
        folders.contains { folder in
            if source.kind == .feed {
                return folder.source.address == source.address || folder.source.kind == .feed && folder.source.host == source.host
            }
            return folder.source.kind == source.kind && folder.source.service == source.service
        }
    }

    static let aliasKey = "live.suggest.hosts"

    static func alias(_ url: URL, settings: UserDefaults = Store.settings, testing: Bool = Store.testing) -> String? {
        guard testing, let host = url.host()?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host),
              let port = url.port, let text = settings.string(forKey: aliasKey) else { return nil }
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: "=").map(String.init)
            if parts.count == 2, parts[0] == String(port) { return parts[1] }
        }
        return nil
    }

    static func visits(_ id: String, in traces: [History.Trace], now: Date = Date()) -> Int {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var total = 0
        for trace in traces where trace.last >= since && spot(trace.url)?.id == id {
            total = min(History.mostVisits, total + max(1, trace.count))
        }
        return total
    }

    static func spot(_ url: URL) -> Spot? {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host()?.lowercased() else { return nil }
        let site = alias(url) ?? Address.withoutWWW(host)
        let path = url.path().split(separator: "/").map(String.init)
        switch site {
        case "github.com":
            let repository = path.count >= 2 && !gitHubWords.contains(path[0].lowercased()) ? "\(path[0])/\(path[1])" : nil
            return Spot(id: "github", title: "GitHub Pull Requests", name: LiveSource.pullRequestsName, source: .pullRequests,
                        detail: repository)
        case "linear.app":
            let workspace = path.count >= 2 ? path[0] : nil
            return Spot(id: "linear", title: "Linear My Issues", name: "My Issues", source: .linear(.assigned), detail: workspace)
        case "youtube.com", "m.youtube.com":
            let channel = path.first.flatMap { $0.hasPrefix("@") ? $0 : nil }
            return Spot(id: "youtube", title: "YouTube Subscriptions", name: "Subscriptions", source: .subscriptions, detail: channel)
        default:
            guard feedLike(path) else { return nil }
            let address = url.absoluteString
            return Spot(id: "feed:" + History.identity(for: url), title: site, name: site, source: LiveSource(kind: .feed, address: address),
                        detail: "/" + path.joined(separator: "/"))
        }
    }

    static let offered: Set<String> = ["github", "linear", "youtube"]

    static func title(_ id: String) -> String {
        switch id {
        case "github": return "GitHub Pull Requests"
        case "linear": return "Linear My Issues"
        case "youtube": return "YouTube Subscriptions"
        default: return id
        }
    }

    static func feedLike(_ path: [String]) -> Bool {
        guard let last = path.last?.lowercased() else { return false }
        if ["feed", "feeds", "rss", "atom"].contains(last) { return true }
        let ext = (last as NSString).pathExtension
        let stem = (last as NSString).deletingPathExtension
        if ext == "rss" || ext == "atom" { return true }
        guard ext == "xml" else { return false }
        return stem == "index" || ["feed", "rss", "atom"].contains { stem.contains($0) }
    }

    static func symbol(_ source: LiveSource) -> String {
        switch source.kind {
        case .pullRequests, .repository: return "arrow.triangle.pull"
        case .issues, .linear: return "smallcircle.filled.circle"
        case .notifications: return "bell"
        case .subscriptions: return "play.rectangle"
        case .feed, .page: return "dot.radiowaves.up.forward"
        }
    }

    private static var memo: (key: String, made: [LiveSuggestion])?

    static func now(for browser: Browser, space: UUID? = nil) -> [LiveSuggestion] {
        let space = space ?? browser.spaceID
        let folders = LiveFolders.shared.folders.filter { $0.space == space }
        let day = Int(Date().timeIntervalSince1970 / 3600)
        let key = "\(browser.history.revision)|\(space)|\(day)|" + folders.map { $0.source.address }.joined(separator: "|")
        if let memo, memo.key == key { return memo.made }
        let made = from(browser.history.everything(in: space), folders: folders)
        memo = (key, made)
        return made
    }
}

@MainActor
enum LiveFolderRows {
    static func folders(_ all: [LiveFolder], space: UUID, order: [UUID]) -> [LiveFolder] {
        let mine = all.enumerated().filter { $0.element.space == space }
        return mine.sorted {
            let a = order.firstIndex(of: $0.element.id) ?? order.count
            let b = order.firstIndex(of: $1.element.id) ?? order.count
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
    }

    static func folders(of browser: Browser, space: UUID? = nil) -> [LiveFolder] {
        let space = space ?? browser.spaceID
        let groups = space == browser.spaceID ? browser.tabGroups : browser.parked[space]?.groups ?? []
        return folders(LiveFolders.shared.folders, space: space, order: groups.filter(\.live).map(\.id))
    }

    static func tabs(_ count: Int?) -> String? {
        count.map { $0 == 1 ? "1 tab" : "\($0) tabs" }
    }

    static func tabs(_ id: UUID, in browser: Browser, space: UUID? = nil) -> String? {
        let space = space ?? browser.spaceID
        let row = space == browser.spaceID ? browser.tabs : browser.parked[space]?.tabs
        return tabs(row?.filter { $0.groupID == id }.count)
    }

    static func none(in space: Space?, offered: Bool) -> String {
        guard offered, let space else { return "No live folders yet" }
        return "No live folders in \(space.name) yet"
    }

    static func opened(in space: Space?, offered: Bool) -> String {
        guard offered, let space else {
            return "The sites you opened most in the last \(LiveSuggestions.days) days come first, counted on this Mac. A folder reads its site with your sign-in."
        }
        return "The sites you opened most in \(space.name) in the last \(LiveSuggestions.days) days come first, counted on this Mac. A folder reads its site with your sign-in in the space it is in."
    }

    static func allAdded(in space: Space?, offered: Bool) -> String {
        guard offered, let space else { return "Everything is added" }
        return "Everything is added in \(space.name)"
    }

    static func read(_ folder: LiveFolder, reading: Bool, now: Date = Date()) -> String {
        if reading { return "Reading now…" }
        guard let read = folder.read else { return folder.paused ? "Not yet, and paused" : "Not yet" }
        let ago = ago(read, now: now)
        return ago.prefix(1).uppercased() + ago.dropFirst()
    }

    static func statusesFooter(_ list: LinearAPI.List) -> String {
        list.isCycle
            ? "Done and canceled issues in the cycle show too. Every team's own statuses fall under these four, so In Review counts as In Progress."
            : "Done and canceled issues never show. Every team's own statuses fall under these four, so In Review counts as In Progress."
    }

    static func ago(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 90 { return "a moment ago" }
        if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return minutes == 1 ? "a minute ago" : "\(minutes) minutes ago"
        }
        if seconds < 3 * 3600 {
            let hours = Int(seconds / 3600)
            return hours == 1 ? "an hour ago" : "\(spelled(hours)) hours ago"
        }
        if calendar.isDate(date, inSameDayAs: now) {
            return calendar.component(.hour, from: date) < 12 ? "this morning" : "earlier today"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 1 { return calendar.component(.hour, from: date) >= 17 ? "yesterday evening" : "yesterday" }
        return "\(spelled(days)) days ago"
    }

    private static func spelled(_ number: Int) -> String {
        let format = NumberFormatter()
        format.locale = Locale(identifier: "en")
        format.numberStyle = .spellOut
        return number <= 10 ? (format.string(from: NSNumber(value: number)) ?? "\(number)") : "\(number)"
    }

    static func badge(_ row: SettingsRowView, address: String) {
        guard let icon = row.icon, let image = Favicons.shared.cached(for: URL(string: address)) else { return }
        let view = NSImageView(image: image)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setAccessibilityElement(false)
        row.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            view.widthAnchor.constraint(equalToConstant: 16),
            view.heightAnchor.constraint(equalToConstant: 16),
        ])
        icon.alphaValue = 0
    }
}

extension SettingsShell {
    func openLiveFolder(_ id: UUID) {
        query = ""
        walk { $0.open(.liveFolder, folder: id) }
    }
}

extension SettingsPageView {
    func liveFolders() {
        let browser = browser
        let live = LiveFolders.shared
        let space = spacePicker("Each space keeps its own live folders")
        shape { LiveFolderRows.folders(of: browser, space: space).map(\.id) }
        let folders = LiveFolderRows.folders(of: browser, space: space)
        let home = browser.spaces.first { $0.id == space }
        section("Your live folders") {
            if folders.isEmpty {
                let none = SettingsRowView(id: "live.folders", symbol: nil,
                                           title: LiveFolderRows.none(in: home, offered: offersSpaces))
                none.title.textColor = .secondaryLabelColor
                put(none)
            }
            for folder in folders {
                let id = folder.id
                let made = SettingsDrillRow(id: "live.folder." + id.uuidString, symbol: LiveSuggestions.symbol(folder.source),
                                            title: folder.name) { [weak self] in self?.shell.openLiveFolder(id) }
                LiveFolderRows.badge(made, address: folder.source.address)
                update { [weak made] in
                    guard let made, let now = live.folder(id) else { return }
                    made.rename(now.name)
                    made.setAccessibilityLabel(now.name)
                    made.tell(now.status)
                    made.mark.show(count: nil, value: LiveFolderRows.tabs(id, in: browser, space: space))
                }
                put(made)
            }
        }
        shape { LiveAdd.now(for: browser, space: space).map(\.id) }
        let adds = LiveAdd.now(for: browser, space: space)
        section("Add a live folder", footer: LiveFolderRows.opened(in: home, offered: offersSpaces)) {
            if adds.isEmpty {
                note(LiveFolderRows.allAdded(in: home, offered: offersSpaces))
            }
            for adding in adds {
                let add = button("Add") { browser.addLivePreset(adding.name, adding.source, space: space) }
                add.kitAccess(id: "settings.live.add." + adding.id, label: "Add \(adding.title)")
                let made = SettingsRowView(id: adding.row, symbol: LiveSuggestions.symbol(adding.source),
                                           title: adding.title, detail: adding.line, control: add,
                                           pad: SettingsMetrics.rowPad - 2, centered: true, tiled: true)
                LiveFolderRows.badge(made, address: adding.source.address)
                if case .suggested(let suggestion) = adding {
                    update { [weak made] in
                        guard let made, let now = LiveSuggestions.now(for: browser, space: space).first(where: { $0.id == suggestion.id }) else { return }
                        made.say(now.line)
                    }
                }
                put(made)
            }
        }
        let offers = LiveOffers.shared
        shape { offers.turnedDown(in: space).map(\.id) }
        let down = offers.turnedDown(in: space)
        section("While you browse") {
            settingRow("live.offers")
            if !down.isEmpty {
                let again = button(LiveOfferWords.again) { offers.suggestAgain(in: space) }
                row("live.offers.again", control: again) {
                    offers.turnedDown(in: space).map { LiveSuggestions.title($0.id) }.joined(separator: ", ")
                }
                again.kitAccess(id: "settings.live.offers.again", label: LiveOfferWords.again)
            }
        }
    }

    func liveFolder() {
        let browser = browser
        let live = LiveFolders.shared
        let shell = shell
        guard let id = shell.trail.folder ?? LiveFolderRows.folders(of: browser, space: spaceID).first?.id else { return }
        shape { live.folder(id) != nil }
        shape { (live.folder(id)?.hiddenInFeed ?? 0) > 0 }
        guard let folder = live.folder(id) else { return }
        section {
            labeled("Name", field("Name", text: { live.folder(id)?.name ?? "" }, prompt: folder.source.siteName) { typed in
                let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                live.rename(id, to: name)
            })
            let source = line("Reads from", folder.source.address, id: "live.source",
                              control: button("Open") { browser.openLiveSource(id) })
            source.detail.isSelectable = true
            shape { SettingsSpaceChoice.key(browser.spaces) }
            if offersSpaces, let home = browser.spaces.first(where: { $0.id == folder.space }) {
                line("Space", nil, id: "live.space", control: SettingsSpaceChip(home))
            }
        }
        shape { live.folder(id)?.source.linearStatuses != nil }
        if let list = LinearAPI.List(address: folder.source.address), folder.source.linearStatuses != nil {
            section("Statuses", footer: LiveFolderRows.statusesFooter(list)) {
                let shown = { live.folder(id)?.source.linearStatuses ?? [] }
                for status in LinearStatus.allCases {
                    let row = "live.status." + status.rawValue
                    let made = toggle(row, get: { shown().contains(status) }, set: { on in
                        live.setStatuses(id, on ? shown() + [status] : shown().filter { $0 != status })
                    })
                    line(status.title, status.detail, id: row, control: made)
                    update { [weak made] in made?.isEnabled = shown() != [status] }
                }
            }
        }
        section("Updates") {
            let keeps = toggle("live.updating", get: { live.folder(id)?.paused == false }, set: { live.pause(id, !$0) })
            let updating = line("Keep up to date", nil, id: "live.updating", control: keeps)
            update { [weak updating] in
                updating?.say(live.folder(id)?.paused == true ? "Paused. Turn on to read it again."
                    : "Reads every \(Int(LiveFolders.every / 60)) minutes while you use Broadway, less often while you are away, and when you open one of its pages")
            }
            let now = button("Update Now") { live.update(id) }
            let reading = line("Last read", nil, id: "live.update", control: now)
            update { [weak reading, weak now] in
                guard let folder = live.folder(id) else { return }
                reading?.say(LiveFolderRows.read(folder, reading: live.reading.contains(id)))
                now?.isEnabled = !live.reading.contains(id)
            }
            if folder.hiddenInFeed > 0 {
                let hidden = line("Hidden items", nil, id: "live.hidden", control: button("Show Hidden") { live.showHidden(id) })
                update { [weak hidden] in
                    let count = live.folder(id)?.hiddenInFeed ?? 0
                    hidden?.say(count == 1 ? "1 item you removed from this folder" : "\(count) items you removed from this folder")
                }
            }
        }
        section {
            let remove = SettingsDangerRow(id: "live.remove", symbol: MenuSymbol.close, title: "Remove Folder…",
                                           detail: "Its tabs close, and it stops reading \(folder.source.siteName)") { [weak self] in
                let name = live.folder(id)?.name ?? folder.name
                SettingsQuestion.liveFolder(name, site: folder.source.siteName).ask(over: self?.window) {
                    live.remove(id)
                    _ = shell.up()
                }
            }
            put(remove)
        }
    }
}
