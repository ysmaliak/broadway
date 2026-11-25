import AppKit
import Foundation

struct PersonRefusal: Error {
    var code: String
    var message: String
    var hint: String?

    init(_ code: String, _ message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    static func usage(_ message: String, hint: String? = nil) -> PersonRefusal { PersonRefusal("usage", message, hint: hint) }
    static func missing(_ what: String, _ named: String) -> PersonRefusal {
        PersonRefusal("not_found", "No such \(what): \(named)", hint: looks[what] ?? "Run broadway help for the list")
    }
    static func ambiguous(_ what: String, _ named: String, _ count: Int) -> PersonRefusal {
        PersonRefusal("ambiguous", "\(named) matches \(count) of them", hint: "Give more of the \(what)")
    }

    static let looks: [String: String] = [
        "setting": "Look for it with broadway settings find WORDS",
        "command": "Look for it with broadway shortcuts list WORDS",
        "space": "broadway spaces list names them",
        "folder": "broadway folders list names them",
        "bookmark": "broadway bookmarks list gives their ids",
        "bookmark folder": "broadway bookmarks list gives their ids",
        "download": "broadway downloads list gives their ids",
        "download under way": "broadway downloads list gives their ids",
        "Live Folder": "broadway live list gives their ids",
        "skill": "broadway skills list names them",
        "watch": "broadway replies list gives their ids",
        "row": "broadway now list gives their ids",
        "hidden element": "broadway site hidden lists them",
        "extension": "broadway extensions list gives their ids",
        "permission": "broadway permissions list names them",
        "agent session": "broadway agents list gives their ids",
        "link rule": "broadway links list gives their ids",
        "site shortcut": "broadway keywords list names them",
        "Quick Action": "broadway actions list gives their ids",
        "snippet": "broadway snippets list names them",
    ]
    static func person(_ message: String, where place: String) -> PersonRefusal {
        PersonRefusal("person_only", message, hint: "The person can do this in Broadway: \(place)")
    }
}

enum PersonClass: Equatable {
    case tool
    case look
    case arrange
    case erase
    case person(AgentAct)
    case open
}

@MainActor
struct PersonCall {
    var noun: String
    var verb: String
    var arguments: [String: Any]
    var browser: Browser
    var box: BrowserToolbox
    var tab: (tab: Tab, browser: Browser)?
    var askedAt: URL?
    var link: AgentLink?
    var hook = false
    var request: [String: Any] = [:]
    var channel: PersonChannel?

    func string(_ key: String) -> String? {
        guard let text = arguments[key] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func need(_ key: String) throws -> String {
        guard let found = string(key) else { throw PersonRefusal.usage("\(noun) \(verb) needs \(key)") }
        return found
    }

    func flag(_ key: String) -> Bool { arguments[key] as? Bool == true }

    func strings(_ key: String) -> [String] { arguments[key] as? [String] ?? [] }

    func number(_ key: String) -> Double? { arguments[key] as? Double ?? (arguments[key] as? Int).map(Double.init) }

    var page: (tab: Tab, browser: Browser) {
        get throws {
            guard let tab else { throw PersonRefusal("no_tab", "No tab to work in") }
            return tab
        }
    }

    var line: String {
        var words = ["broadway", noun, verb]
        for key in arguments.keys.sorted() where key != "tab" {
            switch arguments[key] {
            case let text as String: words.append(text)
            case let list as [Any]: words += list.map { "\($0)" }
            case let on as Bool where on: words.append("--\(key)")
            case let number as NSNumber: words.append("--\(key) \(number)")
            default: break
            }
        }
        return words.joined(separator: " ")
    }
}

typealias PersonHandler = @MainActor (PersonCall) async throws -> [String: Any]

struct PersonVerb {
    var noun: String
    var verb: String
    var kind: PersonClass
    var tabbed = false
    var softer: (@MainActor (PersonCall) -> PersonClass?)?
    var first: (@MainActor (PersonCall) async throws -> Void)?
    var run: PersonHandler

    init(_ noun: String, _ verb: String, _ kind: PersonClass, tabbed: Bool = false, softer: (@MainActor (PersonCall) -> PersonClass?)? = nil,
         first: (@MainActor (PersonCall) async throws -> Void)? = nil, run: @escaping PersonHandler) {
        self.noun = noun
        self.verb = verb
        self.kind = kind
        self.tabbed = tabbed
        self.softer = softer
        self.first = first
        self.run = run
    }

    var name: String { "\(noun) \(verb)" }
}

@MainActor
enum PersonCommands {
    static let table: [PersonVerb] = PersonTabs.verbs + PersonFolders.verbs + PersonGroups.verbs + PersonStuff.verbs + PersonPages.verbs + PersonSettings.verbs + PersonConfig.verbs + PersonKnowledge.verbs + PersonAgents.verbs + completionVerbs

    private static let completionVerbs = [
        PersonVerb("complete", "values", .look) { call in
            var rows: [[String: Any]] = []
            switch call.string("of") {
            case "space": rows = call.browser.spaces.map { ["value": $0.name, "about": "space"] }
            case "tab": rows = PersonTabs.everyTab(call).map { ["value": short($0.tab.id), "about": $0.tab.title] }
            case "setting": rows = SettingsIndex.items.map { ["value": $0.id, "about": $0.title] }
            case "shortcut": rows = PersonSettings.commands.map { ["value": $0.id, "about": $0.title] }
            case "folder": rows = call.browser.tabGroups.map { ["value": $0.name, "about": "folder"] }
            default: break
            }
            return ["values": rows]
        },
    ]

    static var names: [String] { table.filter { $0.noun != "complete" }.map(\.name).sorted() }

    static func find(_ noun: String, _ verb: String) -> PersonVerb? {
        table.first { $0.noun == noun && $0.verb == verb }
    }

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)).lowercased() }

    static func stamp(_ date: Date?) -> String { date.map(ISO8601DateFormatter().string(from:)) ?? "" }

    static func pick<Item>(_ items: [Item], id: (Item) -> UUID, named: String, what: String) throws -> Item {
        let wanted = named.lowercased()
        let found = items.filter { id($0).uuidString.lowercased().hasPrefix(wanted) }
        if found.count > 1 { throw PersonRefusal.ambiguous("id", named, found.count) }
        guard let only = found.first else { throw PersonRefusal.missing(what, named) }
        return only
    }

    static func tool(_ call: PersonCall, _ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let outcome = await call.box.call(name, arguments, task: call.link?.id)
        if outcome.failed {
            let text = outcome.text ?? "That didn't work"
            throw PersonRefusal(outcome.code ?? ToolFailure.code(text), text, hint: outcome.hint)
        }
        return ToolReply.data(outcome)
    }

    static func handle(_ asked: [String: Any], browser: Browser, socket: AgentSocket, on connection: LineConnection) {
        let request = PersonGive.stamp(asked, peer: connection.peer)
        let noun = request["noun"] as? String ?? ""
        let verb = request["verb"] as? String ?? ""
        let channel = PersonChannel { [weak connection] event in connection?.send(event) }
        let gone = connection.onClose
        connection.onClose = {
            gone?()
            MainActor.assumeIsolated { channel.leave() }
        }
        Task { @MainActor in
            let arguments = request["arguments"] as? [String: Any] ?? [:]
            let connecting = noun == "agents" && verb == "connect"
            let named = connecting ? (arguments["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } : nil
            let reply = await perform(request, browser: browser, socket: socket, channel: channel) {
                socket.link(for: request, create: connecting || PersonGive.creates(request, on: browser.prefs.agentsGivePasswords), rejoin: noun != "agents" && request["hook"] as? Bool != true, name: named)
            }
            if request["hook"] as? Bool != true { AgentTally.shared.count(find(noun, verb)?.name ?? AgentTally.other, reply: reply) }
            connection.send(reply)
            connection.close()
        }
    }

    static func perform(_ request: [String: Any], browser: Browser, socket: AgentSocket, channel: PersonChannel,
                        link: () -> AgentLink?) async -> [String: Any] {
        let box = socket.box
        box.browser = browser
        let noun = request["noun"] as? String ?? ""
        let verb = request["verb"] as? String ?? ""
        guard let entry = find(noun, verb) else {
            return failure(PersonRefusal.usage("Broadway has no \(noun) \(verb)", hint: "This broadway and this Broadway may be different versions"))
        }
        guard entry.kind == .open || box.open else { return ToolFailure.error("agents_off", "Agents are off in Broadway") }
        do {
            var call = PersonCall(noun: noun, verb: verb, arguments: request["arguments"] as? [String: Any] ?? [:], browser: browser, box: box)
            call.link = link()
            call.hook = request["hook"] as? Bool == true
            call.request = request
            call.channel = channel
            if entry.tabbed {
                let named = call.arguments["tab"] as? String
                switch await socket.target(named, browser: browser, link: call.link?.id) {
                case .failure(let refused): throw PersonRefusal(refused.code, refused.message, hint: refused.hint)
                case .success(let id):
                    call.tab = box.find(["tab": id])
                    if named != nil { socket.remember(id, link: call.link?.id) }
                }
            }
            let caller = request["hook"] as? Bool == true ? nil : call.link?.id
            AgentLinks.shared.calling(caller)
            defer { AgentLinks.shared.called(caller) }
            try await entry.first?(call)
            call.askedAt = call.tab?.tab.pageAddress
            try await gate(entry, call, request: request, channel: channel)
            let data = try await entry.run(call)
            return ["ok": true, "data": entry.name == PersonGive.name ? data : AgentSecrets.scrub(data, sealed: AgentSeals.all)]
        } catch let refused as PersonRefusal {
            return failure(refused)
        } catch {
            return ToolFailure.error("failed", "That didn't work")
        }
    }

    static func failure(_ refused: PersonRefusal) -> [String: Any] {
        var reply = ToolFailure.error(refused.code, AgentSecrets.scrub(refused.message, sealed: AgentSeals.all))
        var error = reply["error"] as? [String: Any] ?? [:]
        error["retry_safe"] = true
        if let hint = refused.hint { error["hint"] = AgentSecrets.scrub(hint, sealed: AgentSeals.all) }
        reply["error"] = error
        return reply
    }

    private static func gate(_ entry: PersonVerb, _ call: PersonCall, request: [String: Any], channel: PersonChannel) async throws {
        let kind = entry.softer?(call) ?? entry.kind
        if kind == .open || kind == .tool { return }
        if let tab = call.tab?.tab, tab.driving || tab.handedBack {
            guard await AgentDriving.settled(tab, patience: .zero) else {
                throw PersonRefusal("driving", "The person is driving that tab. Nothing was done. Work elsewhere, or try later.")
            }
            tab.handedBack = false
            if kind != .look {
                throw PersonRefusal("handed_back", "The person drove that tab and handed it back. Nothing was done. Look at it again before you go on.")
            }
        }
        if entry.noun == "fill" { return }
        let site = call.tab.flatMap { AgentSites.site(of: $0.tab.pageAddress) }
        try await approve(kind, call, site: site, request: request, channel: channel)
    }

    static func approve(_ kind: PersonClass, _ call: PersonCall, site: String?, request: [String: Any], channel: PersonChannel,
                        title: String? = nil) async throws {
        switch decide(kind, mode: call.browser.prefs.agentMode, rule: AgentSites.shared.rule(for: site)) {
        case .go:
            return
        case .refuse:
            throw PersonRefusal("never_here", "The person never lets agents act on \(site ?? "this site"). Leave it.")
        case .needsTask:
            guard let link = call.link else {
                throw PersonRefusal("needs_task", "This needs the person's yes, and only a connected agent can ask for it. Nothing was done.")
            }
            if AgentDesk.shared.isGranted(.tab, task: link.id, site: site) { return }
            try await PersonAsk.yes(.tab, call: call, site: site, request: request, channel: channel, title: title)
            AgentDesk.shared.grant(.tab, task: link.id, site: site)
        case .person(let act):
            try await PersonAsk.yes(act, call: call, site: site, request: request, channel: channel, title: title)
        }
    }

    static func decide(_ kind: PersonClass, mode: AgentMode, rule: SiteRule?) -> PersonGate {
        let act: AgentAct
        switch kind {
        case .open, .tool: return .go
        case .erase: act = .delete
        case .person(let wanted): act = wanted
        case .look, .arrange: act = .tab
        }
        let verdict = AgentPolicy.verdict(act, mode: mode, rule: rule)
        if verdict == .refuse { return .refuse }
        if case .person = kind { return .person(act) }
        guard verdict == .ask else { return .go }
        return kind == .look ? .needsTask : .person(act)
    }
}

enum PersonGate: Equatable {
    case go
    case refuse
    case needsTask
    case person(AgentAct)
}

@MainActor
enum PersonAsk {
    static func reachable(wait: Double, request: [String: Any]) -> Bool {
        wait > 0 && request["person"] as? String != "none" && !AgentSocket.shared.nobodyHome && (Store.testing || !NSApp.isHidden)
    }

    static let generic = "Run this broadway command?"

    static let titles: [String: String] = [
        "fill login": "Sign in on SITE?",
        "fill details": "Fill your name, address and phone on SITE?",
        "fill card": "Fill your saved card on SITE?",
        "tabs new": "Open a new tab?",
        "tabs select": "Switch to another tab?",
        "tabs close": "Close tabs?",
        "tabs reopen": "Reopen a closed tab?",
        "tabs move": "Move a tab?",
        "tabs keep": "Keep an agent's tab as yours?",
        "windows new": "Open a new window?",
        "page reload": "Reload this page?",
        "page back": "Go back on this page?",
        "page forward": "Go forward on this page?",
        "page translate": "Translate this page?",
        "page original": "Show this page untranslated?",
        "bookmarks add": "Add a bookmark?",
        "bookmarks delete": "Delete a bookmark?",
        "bookmarks open": "Open a bookmark?",
        "history delete": "Delete pages from your history?",
        "history clear": "Clear your history?",
        "downloads cancel": "Cancel a download?",
        "downloads forget": "Take a download off the list?",
        "downloads clear": "Clear the downloads list?",
        "spaces new": "Make a new space?",
        "spaces switch": "Switch spaces?",
        "spaces delete": "Delete a space?",
        "settings set": "Change a setting?",
        "shortcuts set": "Change a keyboard shortcut?",
        "links add": "Add a link rule?",
        "links move": "Move a link rule?",
        "links delete": "Delete a link rule?",
        "keywords add": "Add a site shortcut?",
        "keywords delete": "Delete a site shortcut?",
        "actions add": "Add a Quick Action?",
        "actions rename": "Rename a Quick Action?",
        "actions move": "Move a Quick Action?",
        "actions delete": "Delete a Quick Action?",
        "snippets add": "Add a snippet?",
        "snippets rename": "Rename a snippet?",
        "snippets delete": "Delete a snippet?",
        "spaces colour": "Change a space's colour?",
        "shortcuts clear": "Clear a keyboard shortcut?",
        "shortcuts reset": "Reset keyboard shortcuts?",
        "extensions install": "Install an extension?",
        "extensions enable": "Turn on an extension?",
        "extensions disable": "Turn off an extension?",
        "extensions remove": "Remove an extension?",
        "permissions reset": "Reset a site's permissions?",
        "skills delete": "Delete a skill?",
        "live delete": "Delete a Live Folder?",
        "folders delete": "Delete a folder?",
        "folders close": "Close a folder's tabs?",
    ]

    static func title(for call: PersonCall, site: String?) -> String {
        let more = call.strings("values").count / 2
        if call.noun == "settings", call.verb == "set", more > 0 { return "Change \(more + 1) settings?" }
        return title(noun: call.noun, verb: call.verb, site: site)
    }

    static func title(noun: String, verb: String, site: String?) -> String {
        guard let words = titles["\(noun) \(verb)"] else { return generic }
        return words.replacingOccurrences(of: "SITE", with: site ?? "this page")
    }

    static func yes(_ act: AgentAct, call: PersonCall, site: String?, request: [String: Any], channel: PersonChannel, title asked: String? = nil) async throws {
        var wait = request["wait"] as? Double ?? (request["wait"] as? Int).map(Double.init) ?? 0
        if let link = call.link, wait == 0 { wait = AgentLinks.shared.patience(link.id) }
        guard reachable(wait: wait, request: request) else {
            throw PersonRefusal("needs_you", "This needs the person's yes in Broadway. Nothing was done.",
                                hint: "Tell the person, or run it with --wait-person MIN while they are at Broadway")
        }
        if channel.gone { throw PersonRefusal("needs_you", "Nobody answered in Broadway. Nothing was done.") }
        let pass = "person|\(act.rawValue)|\(site ?? "")|\(call.line)"
        if let link = call.link, AgentLinks.shared.takePass(link.id, pass) { return }
        var question = AgentQuestion(kind: .approval(act), title: asked ?? title(for: call, site: site))
        question.tab = call.tab?.tab.id
        question.site = site
        question.quote = AgentQuestion.clean(call.line)
        question.quoteLabel = call.link.map { "From \($0.title)" } ?? "From a terminal"
        question.task = call.link?.id
        channel.send(["event": "asking", "message": "Waiting for your yes in Broadway"])
        let kept = call.link.flatMap { AgentHeld.shared.entry($0.id, pass) }
        let id = kept?.question ?? question.id
        let asking = kept?.asking ?? Task { @MainActor in await AgentDesk.shared.ask(question) }
        let unseen = kept == nil ? AgentLooking.unseen(for: call.link?.id) : nil
        channel.left = { AgentDesk.shared.take(id, .dropped) }
        let early = AgentPatience.Early()
        let heard = await AgentPatience.race(asking, seconds: wait, unseen: unseen, early: early)
        channel.left = nil
        if heard == nil, early.hit, let link = call.link {
            let held = AgentHeld.shared.hold(link.id, pass, kind: .person, question: id, tab: question.tab, asking: asking)
            Task { @MainActor in
                let said = await asking.value
                guard !held.taken else { return }
                if said == .yes || said == .always { AgentLinks.shared.givePass(link.id, pass) }
                if said == .always, let site { AgentSites.shared.set(.always, for: site) }
                if said == .never, let site { AgentSites.shared.set(.never, for: site) }
                AgentHeld.shared.release(held)
            }
            throw PersonRefusal("needs_you", "Broadway is asking the person: \"\(AgentQuestion.clean(question.title))\". Nothing happens until they answer there. \(ToolReply.awayLine)",
                                hint: ToolReply.awayHint)
        }
        AgentDesk.shared.take(id, .dropped)
        if let kept, let link = call.link {
            kept.taken = true
            _ = AgentLinks.shared.takePass(link.id, pass)
            AgentHeld.shared.release(kept)
        }
        let answer = heard ?? .dropped
        switch answer {
        case .yes:
            return
        case .always:
            if let site { AgentSites.shared.set(.always, for: site) }
        case .never:
            if let site { AgentSites.shared.set(.never, for: site) }
            throw PersonRefusal("never_here", "The person said never here. Leave \(site ?? "this site").")
        case .no, .picked:
            throw PersonRefusal("said_no", "The person said not now. Nothing was done.")
        case .dropped:
            throw PersonRefusal("needs_you", "Nobody answered in Broadway. Nothing was done.")
        }
    }
}

@MainActor
final class PersonChannel {
    let send: ([String: Any]) -> Void
    var left: (() -> Void)?
    private(set) var gone = false

    init(send: @escaping ([String: Any]) -> Void) {
        self.send = send
    }

    func leave() {
        gone = true
        left?()
    }
}
