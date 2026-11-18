import AppKit
import Foundation
import WebKit

enum AgentAddress {
    static let tracking: Set<String> = ["fbclid", "gclid", "dclid", "msclkid", "igshid", "mc_cid", "mc_eid", "ref_src"]

    static func key(_ url: URL?) -> String? {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), !host.isEmpty else { return nil }
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let scheme = parts.scheme?.lowercased() ?? ""
        let port = parts.port.flatMap { ($0 == 443 && scheme == "https") || ($0 == 80 && scheme == "http") ? nil : $0 }
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = (parts.percentEncodedQueryItems ?? [])
            .filter { item in
                let name = item.name.lowercased()
                return !name.hasPrefix("utm_") && !tracking.contains(name)
            }
            .map { "\($0.name)=\($0.value ?? "")" }
            .sorted()
        return bare + (port.map { ":\($0)" } ?? "") + path + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
    }

    static func same(_ one: URL?, _ other: URL?) -> Bool {
        guard let first = key(one), let second = key(other) else { return false }
        return first == second
    }
}

@MainActor
enum AgentAwake {
    private static var held: NSObjectProtocol?

    static var holding: Bool { held != nil }

    static func atWork(_ link: AgentLink) -> Bool {
        guard link.live else { return false }
        guard link.rest == nil || AgentDesk.shared.pending.contains(where: { $0.task == link.id }) else { return false }
        return !AgentBoard.allTabs(of: link.id).isEmpty
    }

    static var anyAtWork: Bool {
        AgentLinks.shared.links.contains(where: atWork)
    }

    static func refresh() {
        if anyAtWork {
            guard held == nil else { return }
            held = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "An agent is at work in its pages")
        } else if let made = held {
            ProcessInfo.processInfo.endActivity(made)
            held = nil
        }
    }
}

@MainActor
enum AgentWorkTabs {
    struct Popups {
        var opened: [UUID] = []
        var blocked: [String] = []
    }

    private static var popups: [UUID: Popups] = [:]
    static var loadCap: Double = 5

    static let readsWithoutTab: Set<String> = ["snapshot", "text", "read", "screenshot", "shot", "locate", "find", "console", "network", "pdf", "wait"]

    static let specs: [ToolSpec] = [
        ToolSpec(name: "tab", description: "Say which tab is your current one, or make one of your own tabs current with id. Every tool without a tab works there.",
                 properties: ["id": ["type": "string"]]),
    ]

    static func widen(_ spec: ToolSpec) -> ToolSpec {
        var wide = spec
        switch spec.name {
        case "close":
            wide.properties["others"] = ["type": "boolean"]
            wide.properties["all"] = ["type": "boolean"]
            wide.required = []
        case "open":
            wide.properties["urls"] = ["type": "array", "items": ["type": "string"]]
            wide.required = []
        case "tabs":
            wide.properties["all"] = ["type": "boolean"]
        default:
            break
        }
        return wide
    }

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    static func note(_ opener: Tab, opened tab: Tab) {
        popups[opener.id, default: Popups()].opened.append(tab.id)
    }

    static func note(_ opener: Tab, blocked site: String) {
        popups[opener.id, default: Popups()].blocked.append(site)
    }

    static func takePopups(from opener: UUID) -> Popups {
        popups.removeValue(forKey: opener) ?? Popups()
    }

    static func forget() {
        popups = [:]
    }

    static func takeBack(_ session: UUID, from ended: [UUID]) {
        let links = AgentLinks.shared
        var current: String?
        for old in ended {
            let found = AgentBoard.allTabs(of: old)
            guard !found.isEmpty else { continue }
            for each in found {
                each.tab.agentTask = session
                each.tab.agentFinished = nil
                if each.tab.agentMood != .waving { each.tab.agentMood = nil }
                each.tab.agentActing = nil
            }
            let ids = found.map { short($0.tab.id) }
            current = links.lastTab(old).flatMap { ids.contains($0) ? $0 : nil } ?? ids.last
        }
        if let current { links.setCurrentTab(session, current) }
        AgentAwake.refresh()
    }

    static func tabs(of session: UUID?, in box: BrowserToolbox) -> [(tab: Tab, browser: Browser)] {
        guard let session else { return [] }
        return box.visible.filter { $0.tab.agent && $0.tab.agentTask == session }
    }

    static func page(_ tab: Tab) -> AgentChange.Page {
        AgentChange.Page(url: AgentSecrets.shown(tab.page?.url ?? tab.pageAddress), title: title(tab), navigated: true,
                         loaded: tab.built?.isLoading != true)
    }

    static func title(_ tab: Tab) -> String {
        let seen = tab.built?.title ?? ""
        return seen.isEmpty ? tab.title : seen
    }

    static func loaded(_ tab: Tab, cap given: Double? = nil) async -> Bool {
        let cap = given ?? loadCap
        let end = Date().addingTimeInterval(cap)
        try? await Task.sleep(for: .milliseconds(min(100, Int(cap * 1000))))
        while Date() < end {
            if tab.built?.isLoading != true, tab.committed != nil || tab.failure != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return tab.built?.isLoading != true
    }

    static func row(_ tab: Tab, current: String?) -> [String: Any] {
        let id = short(tab.id)
        return ["id": id, "title": title(tab), "url": AgentSecrets.shown(tab.page?.url ?? tab.pageAddress),
                "working": id == current, "agent": tab.agent, "loading": tab.loading,
                "front": Browsers.all.contains { $0.active === tab }]
    }

    static func listing(_ link: UUID?, box: BrowserToolbox, current here: String?) -> ToolOutcome {
        let mine = tabs(of: link, in: box)
        let others = box.visible.filter { !$0.tab.agent }.count
        let rows = mine.map { row($0.tab, current: here) }
        var lines = rows.map { row in
            let id = row["id"] as? String ?? ""
            return "\(id == here ? "*" : " ") \(id)  \(AgentChange.cell(row["title"] as? String ?? ""))  \(AgentChange.short(row["url"] as? String ?? ""))"
        }
        if rows.isEmpty { lines.append("You have no tabs. Open one with broadway open URL.") }
        let theirs = "\(others) tab\(others == 1 ? "" : "s") of the person's: broadway tabs --all"
        lines.append("And " + theirs)
        let shown = here.flatMap { id in rows.contains { $0["id"] as? String == id } ? id : nil }
        let message = (shown.map { "Your current tab is \($0). And " } ?? (rows.isEmpty ? "You have no tabs. And " : "And ")) + theirs + (shown != nil || rows.isEmpty ? "." : "")
        return ToolOutcome(text: lines.joined(separator: "\n"),
                           data: ["tabs": rows, "others": others, "current": shown ?? NSNull(), "message": message])
    }

    static func unseen(_ tab: Tab, in browser: Browser) -> Bool {
        !tab.agentSeen && browser.active !== tab && !browser.visibleTabIDs.contains(tab.id)
    }

    static func busy(_ tab: Tab, among all: [Tab]) async -> String? {
        if tab.noisy { return "it is playing sound" }
        if let record = AgentDownloadWatch.latest(tab.id, since: Date().addingTimeInterval(-600)), !record.done, record.failed == nil {
            return "a download there is not finished"
        }
        if all.contains(where: { $0.opener == tab.id && $0.popup && $0.id != tab.id }) { return "a window it opened is still open" }
        if tab.popup, let opener = tab.opener, all.contains(where: { $0.id == opener }) { return "a page is waiting on this window" }
        let unsaved = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in tab.unsaved { done.resume(returning: $0) } }
        return unsaved ? "a form there is not sent" : nil
    }

    struct Tidied {
        var closed: [String] = []
        var kept: [(id: String, why: String)] = []

        var lines: [String] { kept.map { "Kept \($0.id): \($0.why)" } }

        var object: [String: Any] {
            ["closed": closed, "kept": kept.map { ["id": $0.id, "why": $0.why] }]
        }
    }

    static func tidy(_ found: [(tab: Tab, browser: Browser)], everyTab: [Tab]) async -> Tidied {
        var said = Tidied()
        for (tab, browser) in found {
            if let why = await busy(tab, among: everyTab) {
                said.kept.append((short(tab.id), why))
                continue
            }
            browser.closeAgentTab(tab)
            said.closed.append(short(tab.id))
        }
        return said
    }
}

@MainActor
final class AgentSessionBox: AgentToolbox {
    let socket: AgentSocket
    weak var browser: Browser?

    init(socket: AgentSocket, browser: Browser) {
        self.socket = socket
        self.browser = browser
    }

    var open: Bool { socket.box.open }
    var tools: [ToolSpec] { socket.box.tools }

    func call(_ name: String, _ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        guard let browser = browser ?? Browsers.front else { return .failure("Broadway has no window open", code: .noWindow) }
        let said = await socket.session(name, arguments, task: task, browser: browser)
        var outcome = said.outcome
        if let used = said.used, outcome.data?["tab"] == nil, outcome.data != nil { outcome.data?["tab"] = used }
        return outcome
    }
}

extension AgentSocket {
    func session(_ name: String, _ given: [String: Any], task: UUID?, browser: Browser, preferred: String? = nil) async -> (outcome: ToolOutcome, used: String?) {
        let link = task
        var arguments = given
        let outside = TaskLedger.shared.entry(link) != nil
        switch name {
        case "tab":
            return (pick(arguments["id"] as? String, link: link), current(link))
        case "tabs" where outside && arguments["all"] as? Bool != true:
            return (listing(link), nil)
        case "open" where arguments["urls"] is [Any]:
            return (await openMany(arguments, task: task, link: link), current(link))
        case "close" where arguments["others"] as? Bool == true || arguments["all"] as? Bool == true:
            if arguments["tab"] != nil { return (.failure("close takes a tab, --others or --all, one of them", code: .usage), nil) }
            return (await closeMany(all: arguments["all"] as? Bool == true, task: task, link: link), current(link))
        default:
            break
        }
        var used: String?
        var notice: String?
        if box.tools.first(where: { $0.name == name })?.properties["tab"] != nil {
            let given = arguments["tab"] as? String
            let named = given ?? preferred.flatMap { $0.isEmpty ? nil : $0 }
            switch await target(named, browser: browser, link: link, reads: AgentWorkTabs.readsWithoutTab.contains(name)) {
            case .failure(let refused):
                guard name == "ask", named == nil else { return (.failure(refused.message, code: refused.code), nil) }
            case .success(let id):
                arguments["tab"] = id
                used = id
                if given != nil, owns(id, link: link) { remember(id, link: link) }
                if named == nil, !owns(id, link: link), id != current(link) {
                    notice = "Reading the person's tab \(id). Your own: broadway open URL."
                }
            }
        }
        let started = Date()
        var outcome = ToolReply.asking(await box.call(name, arguments, task: task), task: link)
        guard !outcome.failed else { return (outcome, used) }
        switch name {
        case "open":
            outcome = await opened(outcome, link: link, started: started)
            used = current(link)
        case "navigate":
            outcome = await went(outcome, tab: used, link: link, started: started)
        case "close":
            outcome = closed(outcome, tab: used, link: link)
        default:
            break
        }
        if let used { outcome = popped(outcome, from: used, link: link) }
        if let notice { outcome = noted(outcome, notice) }
        return (outcome, used)
    }

    func owns(_ id: String, link: UUID?) -> Bool {
        guard let tab = box.find(["tab": id])?.tab, tab.agent else { return false }
        return tab.agentTask == link
    }

    private func pick(_ wanted: String?, link: UUID?) -> ToolOutcome {
        let mine = AgentWorkTabs.tabs(of: link, in: box)
        guard let wanted = wanted?.trimmingCharacters(in: .whitespaces).lowercased(), !wanted.isEmpty else {
            guard let id = current(link), let found = box.find(["tab": id]) else {
                return .failure("You have no tab. Open one with broadway open URL.", code: .noTab)
            }
            var row = AgentWorkTabs.row(found.tab, current: id)
            row["tabs"] = mine.count
            row["message"] = "\(id)  \(AgentChange.cell(found.tab.title))  \(AgentChange.short(row["url"] as? String ?? ""))"
            return ToolOutcome(text: row["message"] as? String, data: row)
        }
        let matches = mine.filter { AgentWorkTabs.short($0.tab.id).hasPrefix(String(wanted.prefix(8))) }
        if matches.count > 1 {
            return .failure("\(wanted) fits \(matches.count) of your tabs: give more of its id", code: .ambiguousTab)
        }
        guard let only = matches.first else {
            let anywhere = box.tabIDs.contains { $0.hasPrefix(String(wanted.prefix(8))) }
            return anywhere
                ? .failure("Tab \(wanted) isn't one of yours", code: .notYours)
                : .failure("No such tab: \(wanted)", code: .noTab)
        }
        let id = AgentWorkTabs.short(only.tab.id)
        remember(id, link: link)
        var row = AgentWorkTabs.row(only.tab, current: id)
        row["tabs"] = mine.count
        row["message"] = "\(id)  \(AgentChange.cell(only.tab.title))  \(AgentChange.short(row["url"] as? String ?? ""))"
        return ToolOutcome(text: "Your current tab is now \(id)", data: row)
    }

    func listing(_ link: UUID?) -> ToolOutcome {
        AgentWorkTabs.listing(link, box: box, current: current(link))
    }

    private func closeMany(all: Bool, task: UUID?, link: UUID?) async -> ToolOutcome {
        let here = current(link)
        let mine = AgentWorkTabs.tabs(of: link, in: box)
        let going = mine.filter { all || AgentWorkTabs.short($0.tab.id) != here }
        let every = box.browsers.flatMap { $0.tabs + $0.parkedAgentTabs }
        let said = await AgentWorkTabs.tidy(going, everyTab: every)
        if all, let here, said.closed.contains(here) { remember(nil, link: link) }
        let left = AgentWorkTabs.tabs(of: link, in: box)
        if current(link).map({ id in !left.contains { AgentWorkTabs.short($0.tab.id) == id } }) ?? true {
            remember(left.last.map { AgentWorkTabs.short($0.tab.id) }, link: link)
        }
        let first = said.closed.isEmpty ? "Closed nothing" : "Closed \(said.closed.count) tab\(said.closed.count == 1 ? "" : "s")"
        let now = current(link).map { "Your current tab is \($0)" } ?? "You have no tabs left"
        let lines = [first] + said.lines + [now]
        var data: [String: Any] = ["closed": said.closed, "tidy": said.object]
        data["current"] = current(link) ?? NSNull()
        data["tabs"] = left.count
        data["message"] = lines.joined(separator: "\n")
        return ToolOutcome(text: lines.joined(separator: "\n"), data: data)
    }

    private func openMany(_ arguments: [String: Any], task: UUID?, link: UUID?) async -> ToolOutcome {
        let listed = (arguments["urls"] as? [Any] ?? []).compactMap { $0 as? String }
        let urls = listed.isEmpty ? (arguments["url"] as? String).map { [$0] } ?? [] : listed
        guard !urls.isEmpty else { return .failure("open needs an address", code: .usage) }
        guard urls.count <= 20 else { return .failure("open takes 20 addresses at most, and this was \(urls.count)", code: .usage) }
        var made: [Tab] = []
        var lines: [String] = []
        var refused: [[String: Any]] = []
        for url in urls {
            let said = await box.call("open", ["url": url], task: task)
            if said.failed {
                let text = said.text ?? "That didn't work"
                refused.append(["url": url, "code": said.code ?? ToolFailure.code(text), "message": text])
                lines.append("Not opened: \(AgentChange.short(url)). \(text)")
                break
            }
            guard let id = ToolReply.data(said)["id"] as? String, let tab = box.find(["tab": id])?.tab else { continue }
            remember(id, link: link)
            made.append(tab)
        }
        let deadline = Date().addingTimeInterval(min(20, AgentWorkTabs.loadCap * 4))
        try? await Task.sleep(for: .milliseconds(100))
        while Date() < deadline, made.contains(where: { $0.built?.isLoading == true || ($0.committed == nil && $0.failure == nil) }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let rows: [[String: Any]] = made.map { tab in
            ["id": AgentWorkTabs.short(tab.id), "title": AgentWorkTabs.title(tab),
             "url": AgentSecrets.shown(tab.pageAddress ?? tab.address), "loading": tab.built?.isLoading == true]
        }
        let opened = rows.map { row in
            "\(row["id"] as? String ?? "")  \(AgentChange.cell(row["title"] as? String ?? ""))  \(AgentChange.short(row["url"] as? String ?? ""))"
                + (row["loading"] as? Bool == true ? "  still loading" : "")
        }
        let skipped = urls.count - made.count - refused.count
        if skipped > 0 { lines.append("Stopped there, so \(skipped) more address\(skipped == 1 ? " was" : "es were") not tried") }
        let count = AgentWorkTabs.tabs(of: link, in: box).count
        var data: [String: Any] = ["opened": rows, "tabs": count, "current": current(link) ?? NSNull(), "website": true]
        if !refused.isEmpty { data["refused"] = refused }
        data["message"] = (opened + lines).joined(separator: "\n")
        guard !made.isEmpty else {
            return .failure(lines.joined(separator: "\n"), code: refused.first?["code"] as? String ?? "failed", data: data)
        }
        return ToolOutcome(text: (opened + lines + ["Your current tab is \(current(link) ?? "")"]).joined(separator: "\n"), data: data)
    }

    private func opened(_ outcome: ToolOutcome, link: UUID?, started: Date) async -> ToolOutcome {
        let said = ToolReply.data(outcome)
        guard let id = said["id"] as? String, let found = box.find(["tab": id]) else { return outcome }
        remember(id, link: link)
        let tab = found.tab
        let done = await AgentWorkTabs.loaded(tab)
        let mine = AgentWorkTabs.tabs(of: link, in: box)
        let same = mine.filter { $0.tab.id != tab.id && AgentAddress.same($0.tab.pageAddress, tab.pageAddress ?? tab.address) }
            .map { AgentWorkTabs.short($0.tab.id) }
        var kept = said
        kept["loading"] = tab.loading
        kept["title"] = AgentWorkTabs.title(tab)
        let change = AgentChange(tab: id, did: "open", same: same, settled: done ? .quiet : .capped,
                                 ms: Int(Date().timeIntervalSince(started) * 1000), page: AgentWorkTabs.page(tab),
                                 tabs: AgentChange.Tabs(working: id, count: mine.count), kept: kept)
        var object = change.object()
        object["tabs"] = mine.count
        object["session"] = change.tabs.object()
        return ToolOutcome(text: change.lines().joined(separator: "\n"), data: object)
    }

    private func went(_ outcome: ToolOutcome, tab id: String?, link: UUID?, started: Date) async -> ToolOutcome {
        let said = ToolReply.data(outcome)
        guard said["did"] == nil, let id, let tab = box.find(["tab": id])?.tab else { return outcome }
        let done = await AgentWorkTabs.loaded(tab)
        var kept = said
        kept["loading"] = tab.loading
        kept["title"] = AgentWorkTabs.title(tab)
        let change = AgentChange(tab: id, did: "go", settled: done ? .quiet : .capped, ms: Int(Date().timeIntervalSince(started) * 1000),
                                 page: AgentWorkTabs.page(tab), tabs: AgentChange.Tabs(working: current(link)), kept: kept)
        return ToolOutcome(text: change.lines().joined(separator: "\n"), data: change.object())
    }

    private func closed(_ outcome: ToolOutcome, tab id: String?, link: UUID?) -> ToolOutcome {
        let left = AgentWorkTabs.tabs(of: link, in: box)
        if let id, id == current(link) || current(link) == nil {
            remember(left.last.map { AgentWorkTabs.short($0.tab.id) }, link: link)
        }
        let now = current(link)
        var data = ToolReply.data(outcome)
        data["closed"] = id ?? NSNull()
        data["current"] = now ?? NSNull()
        data["tabs"] = left.count
        let text = (outcome.plain ?? outcome.text ?? "Closed") + "\n" + (now.map { "Your current tab is \($0)" } ?? "You have no tabs left")
        data["message"] = text
        var said = outcome
        said.text = text
        said.plain = nil
        said.data = data
        return said
    }

    private func popped(_ outcome: ToolOutcome, from id: String, link: UUID?) -> ToolOutcome {
        guard let opener = box.find(["tab": id])?.tab else { return outcome }
        let popups = AgentWorkTabs.takePopups(from: opener.id)
        guard !popups.opened.isEmpty || !popups.blocked.isEmpty else { return outcome }
        let opened = popups.opened.compactMap { made in box.visible.first { $0.tab.id == made }?.tab }.map { tab in
            AgentChange.OpenedTab(id: AgentWorkTabs.short(tab.id), title: tab.title,
                                  url: AgentSecrets.shown(tab.pageAddress ?? tab.address), popup: true)
        }
        var data = ToolReply.data(outcome)
        let key = data["tabs"] == nil || data["tabs"] is [String: Any] ? "tabs" : "session"
        var tabs = data[key] as? [String: Any] ?? ["closed": [String](), "working": current(link) ?? NSNull()]
        tabs["opened"] = (tabs["opened"] as? [[String: Any]] ?? []) + opened.map { $0.object() }
        if !popups.blocked.isEmpty { tabs["blocked"] = (tabs["blocked"] as? [String] ?? []) + popups.blocked }
        data[key] = tabs
        let lines = AgentChange(tab: id, did: "popup", settled: .skipped, page: AgentChange.Page(url: "", title: ""),
                                tabs: AgentChange.Tabs(opened: opened, working: current(link), blocked: popups.blocked)).lines().dropFirst()
        var said = outcome
        let first = said.plain ?? said.text ?? ""
        said.text = ([first].filter { !$0.isEmpty } + lines).joined(separator: "\n")
        said.plain = nil
        said.data = data
        return said
    }

    private func noted(_ outcome: ToolOutcome, _ notice: String) -> ToolOutcome {
        var said = outcome
        var data = ToolReply.data(outcome)
        data["notice"] = notice
        said.data = data
        said.text = notice + "\n" + (said.text ?? "")
        return said
    }
}

extension Browser {
    func agentPopup(_ configuration: WKWebViewConfiguration, opener: Tab, url: URL?, sized: Bool) -> Tab? {
        let site = AgentSites.site(of: url)
        let task = opener.agentTask
        let rule = AgentSites.shared.rule(for: site)
        let refused = AgentPolicy.verdict(.tab, mode: prefs.agentMode, rule: rule) == .refuse
        if refused {
            AgentWorkTabs.note(opener, blocked: site ?? url?.host() ?? "that site")
            return nil
        }
        let tab = Tab(shy: opener.shy, bench: true, configuration: configuration)
        tab.space = opener.space
        tab.popup = sized
        tab.opener = opener.id
        tab.linkedFrom = opener.id
        tab.agent = true
        tab.agentTask = task
        prepare(tab)
        return tab
    }

    func parkAgentPopup(_ tab: Tab, beside opener: Tab) -> Bool {
        guard let space = parked.first(where: { $0.value.tabs.contains { $0 === opener } })?.key, var row = parked[space] else { return false }
        row.tabs.append(tab)
        parked[space] = row
        return true
    }

    func settleAgentPopup(_ tab: Tab, from opener: Tab, url: URL?) -> WKWebView {
        if let url { tab.setAddressOptimistically(url) }
        Bench.shared.house(tab)
        AgentWorkTabs.note(opener, opened: tab)
        return tab.web
    }
}
