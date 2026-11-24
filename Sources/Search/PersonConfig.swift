import AppKit
import Foundation

@MainActor
enum PersonConfig {
    private static func short(_ id: UUID) -> String { PersonCommands.short(id) }

    static let rulesPlace = "Settings › Links › Rules"
    static let keywordsPlace = "Settings › Field › Site shortcuts"

    private static func rule(_ call: PersonCall) throws -> LinkRule {
        try PersonCommands.pick(LinkRules.shared.rules, id: \.id, named: try call.need("id"), what: "link rule")
    }

    static func kind(_ call: PersonCall, typed: String) throws -> LinkRule.Match.Kind {
        guard let named = call.string("kind") else { return LinkRuleEditor.reading(typed) }
        guard let kind = LinkRule.Match.Kind(rawValue: named.lowercased()) else {
            throw PersonRefusal.usage("--kind is one of \(LinkRule.Match.Kind.allCases.map(\.rawValue).joined(separator: ", ")), not \(named)")
        }
        return kind
    }

    static func planned(_ call: PersonCall) throws -> (rule: LinkRule, space: Space) {
        let typed = try call.need("match")
        if call.string("app") != nil {
            throw PersonRefusal.person("A rule that hands links to another app or browser is the person's to make", where: rulesPlace)
        }
        guard let named = call.string("space") else {
            throw PersonRefusal.usage("Say which space the links open in: --space NAME", hint: "broadway spaces list names them")
        }
        let space = try PersonTabs.space(call, named)
        let rule = LinkRule(match: .make(try kind(call, typed: typed), typed), target: .space(space.id, folder: nil))
        if let broken = LinkRouter.broken(rule) { throw PersonRefusal.usage(broken) }
        if let same = LinkRules.shared.rules.first(where: { $0.match == rule.match }) {
            throw PersonRefusal("refused", "There's already a rule for \(LinkRouter.words(rule.match)), \(short(same.id))",
                                hint: "broadway links delete \(short(same.id)) first, to send these links somewhere else")
        }
        return (rule, space)
    }

    private static func ruleRow(_ rule: LinkRule, at index: Int, world: LinkWorld) -> [String: Any] {
        var space = ""
        if case .space(let id, _) = rule.target { space = world.space(id)?.name ?? "" }
        return ["id": short(rule.id), "position": index + 1, "kind": rule.match.kind.rawValue, "match": LinkRouter.words(rule.match),
                "text": rule.match.text, "opens": LinkRouter.words(rule.target, world: world), "space": space, "on": rule.on]
    }

    private static func keyword(_ call: PersonCall) throws -> Keyword {
        let word = try call.need("keyword")
        guard let found = call.browser.prefs.keywords.first(where: { $0.keyword.caseInsensitiveCompare(word) == .orderedSame }) else {
            throw PersonRefusal.missing("site shortcut", word)
        }
        return found
    }

    static func newKeyword(_ call: PersonCall) throws -> Keyword {
        let word = try call.need("keyword")
        let address = try call.need("address")
        let keywords = call.browser.prefs.keywords
        if let taken = keywords.first(where: { $0.keyword.caseInsensitiveCompare(word) == .orderedSame }) {
            if taken.template == address { throw PersonRefusal("refused", "\(taken.keyword) already goes there") }
            throw PersonRefusal.person("\(taken.keyword) already goes to \(taken.name). What the person types after it would go somewhere they never chose, so only they can change it.",
                                       where: keywordsPlace)
        }
        if let problem = Keyword.problem(word: word, template: address, among: keywords) { throw PersonRefusal.usage(problem) }
        return Keyword(keyword: word, template: address)
    }

    private static func actionID(_ action: QuickAction) -> String {
        action.id.hasPrefix("custom-") ? String(action.id.dropFirst(7).prefix(8)).lowercased() : action.id
    }

    static func action(_ call: PersonCall) throws -> QuickAction {
        let named = try call.need("action")
        let wanted = named.lowercased()
        let shown = QuickActions.shared.shown(history: call.browser.history)
        if let exact = shown.first(where: { $0.id == named || actionID($0) == wanted || $0.short == QuickAction.alias(named) }) { return exact }
        let found = shown.filter { actionID($0).hasPrefix(wanted) }
        if found.count > 1 { throw PersonRefusal.ambiguous("id", named, found.count) }
        guard let only = found.first else { throw PersonRefusal.missing("Quick Action", named) }
        return only
    }

    static func newAction(_ call: PersonCall) throws -> (alias: String, address: String) {
        let alias = try call.need("short")
        let address = try call.need("address")
        let store = QuickActions.shared
        let word = QuickAction.alias(alias)
        if store.takenAliases.contains(word) {
            let current = store.reachable(history: call.browser.history).first { $0.aliases.map(QuickAction.alias).contains(word) }
            if let current, current.target == QuickAction(id: "", name: "", aliases: [], address: address).target {
                throw PersonRefusal("refused", "\(word) already opens \(current.shown)")
            }
            throw PersonRefusal.person("\(word) already opens \(current?.shown ?? "something"). Only the person can send it somewhere else.",
                                       where: "Settings › Field › Quick Actions")
        }
        if let problem = QuickActions.problem(alias: alias, address: address, among: store.takenAliases) { throw PersonRefusal.usage(problem) }
        return (alias, address)
    }

    private static func actionRow(_ action: QuickAction) -> [String: Any] {
        ["id": actionID(action), "name": action.name, "short": action.short, "aliases": action.aliases, "address": action.address,
         "builtIn": QuickActions.shared.isBuiltIn(action.id)]
    }

    static func snippet(_ call: PersonCall) throws -> Snippet {
        let word = SnippetStore.normalized(try call.need("keyword"))
        let bare = word.hasPrefix(";") ? String(word.dropFirst()) : word
        guard let found = SnippetStore.shared.snippets.first(where: { SnippetStore.normalized($0.keyword) == bare }) else {
            throw PersonRefusal.missing("snippet", bare)
        }
        return found
    }

    static func newSnippet(_ call: PersonCall) throws -> Snippet {
        let typed = try call.need("keyword")
        let keyword = typed.hasPrefix(";") ? String(typed.dropFirst()) : typed
        let made = Snippet(title: call.string("title") ?? keyword, keyword: keyword, text: try call.need("text"))
        if let problem = SnippetStore.shared.problem(made) { throw PersonRefusal.usage(problem) }
        return made
    }

    private static func snippetRow(_ snippet: Snippet) -> [String: Any] {
        let first = snippet.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let line = first.count > 60 ? String(first.prefix(60)) + "…" : first
        return ["keyword": snippet.keyword, "title": snippet.title, "line": line, "text": snippet.text]
    }

    static func colour(_ named: String) throws -> String {
        let wanted = named.lowercased()
        guard let preset = SpaceLook.presets.first(where: { $0.id == wanted || $0.name.lowercased() == wanted }) else {
            throw PersonRefusal.usage("\(named) isn't a space colour", hint: "Colours: \(SpaceLook.presets.map(\.id).joined(separator: ", "))")
        }
        return preset.id
    }

    static func colour(of space: Space) -> String {
        let look = space.look ?? SpaceLook()
        return SpaceLook.presets.contains { $0.id == look.colour } ? look.colour : "custom"
    }

    static let verbs: [PersonVerb] = [
        PersonVerb("links", "list", .look) { call in
            let world = Browsers.linkWorld(from: call.browser)
            return ["rules": LinkRules.shared.rules.enumerated().map { ruleRow($0.element, at: $0.offset, world: world) }]
        },
        PersonVerb("links", "add", .arrange, first: { _ = try planned($0) }) { call in
            let (rule, space) = try planned(call)
            var at: Int?
            if case .site(let text) = rule.match { at = LinkRules.place(forSite: LinkRouter.plainSite(text), in: LinkRules.shared.rules) }
            let made = LinkRules.shared.add(rule, at: at)
            let position = (LinkRules.shared.index(of: made.id) ?? 0) + 1
            return ["id": short(made.id), "position": position, "space": space.name,
                    "message": "\(LinkRouter.words(made.match)) opens in \(space.name)"]
        },
        PersonVerb("links", "move", .arrange, first: { _ = try rule($0) }) { call in
            let found = try rule(call)
            let count = LinkRules.shared.rules.count
            guard let position = Int(try call.need("position")), (1...count).contains(position) else {
                throw PersonRefusal.usage("Position is 1 to \(count)")
            }
            LinkRules.shared.move(found.id, to: position - 1)
            return ["id": short(found.id), "position": position, "message": "Moved"]
        },
        PersonVerb("links", "delete", .erase, first: { _ = try rule($0) }) { call in
            let found = try rule(call)
            LinkRules.shared.remove(found.id)
            return ["id": short(found.id), "message": "Deleted"]
        },
        PersonVerb("keywords", "list", .look) { call in
            ["keywords": call.browser.prefs.keywords.map { ["keyword": $0.keyword, "site": $0.name, "address": $0.template] as [String: Any] }]
        },
        PersonVerb("keywords", "add", .arrange, first: { _ = try newKeyword($0) }) { call in
            let made = try newKeyword(call)
            call.browser.prefs.keywords.append(made)
            return ["keyword": made.keyword, "site": made.name, "message": "\(made.keyword) searches \(made.name)"]
        },
        PersonVerb("keywords", "delete", .erase, first: { _ = try keyword($0) }) { call in
            let found = try keyword(call)
            call.browser.prefs.keywords.removeAll { $0.id == found.id }
            return ["keyword": found.keyword, "message": "Deleted"]
        },
        PersonVerb("actions", "list", .look) { call in
            ["actions": QuickActions.shared.shown(history: call.browser.history).map(actionRow)]
        },
        PersonVerb("actions", "add", .arrange, first: { _ = try newAction($0) }) { call in
            let (alias, address) = try newAction(call)
            guard let made = QuickActions.shared.add(name: call.string("name") ?? "", alias: alias, address: address) else {
                throw PersonRefusal("failed", "No Quick Action was made")
            }
            return ["id": actionID(made), "short": made.short, "message": "\(made.short) opens \(made.shown)"]
        },
        PersonVerb("actions", "rename", .arrange, first: { _ = try action($0) }) { call in
            let found = try action(call)
            let name = try call.need("name")
            guard QuickActions.shared.edit(found.id, name: name, alias: found.short, address: found.address, history: call.browser.history) else {
                throw PersonRefusal("refused", "\(found.name) can't be renamed")
            }
            return ["id": actionID(found), "name": name, "message": "Renamed"]
        },
        PersonVerb("actions", "move", .arrange, first: { _ = try action($0) }) { call in
            let found = try action(call)
            let shown = QuickActions.shared.shown(history: call.browser.history)
            guard let position = Int(try call.need("position")), (1...shown.count).contains(position),
                  let from = shown.firstIndex(where: { $0.id == found.id }) else {
                throw PersonRefusal.usage("Position is 1 to \(shown.count)")
            }
            let place = position - 1 > from ? position : position - 1
            QuickActions.shared.move(from: IndexSet(integer: from), to: place, history: call.browser.history)
            return ["id": actionID(found), "position": position, "message": "Moved"]
        },
        PersonVerb("actions", "delete", .erase, first: { call in
            guard QuickActions.shared.canDelete(try action(call).id) else { throw PersonRefusal("refused", "That Quick Action can't be deleted") }
        }) { call in
            let found = try action(call)
            guard QuickActions.shared.delete(found.id, history: call.browser.history) else {
                throw PersonRefusal("refused", "That Quick Action can't be deleted")
            }
            return ["id": actionID(found), "message": QuickActions.shared.isBuiltIn(found.id) ? "Deleted. Settings › Field › Quick Actions can bring it back." : "Deleted"]
        },
        PersonVerb("snippets", "list", .look) { _ in
            ["snippets": SnippetStore.shared.snippets.map(snippetRow)]
        },
        PersonVerb("snippets", "add", .arrange, first: { _ = try newSnippet($0) }) { call in
            let made = try newSnippet(call)
            if let trouble = SnippetStore.shared.save(made) { throw PersonRefusal("failed", trouble) }
            return ["keyword": SnippetStore.normalized(made.keyword), "message": "Type ;\(SnippetStore.normalized(made.keyword)) in a field for it"]
        },
        PersonVerb("snippets", "rename", .arrange, first: { _ = try snippet($0) }) { call in
            var found = try snippet(call)
            found.title = try call.need("title")
            if let problem = SnippetStore.shared.save(found) { throw PersonRefusal.usage(problem) }
            return ["keyword": found.keyword, "title": found.title, "message": "Renamed"]
        },
        PersonVerb("snippets", "delete", .erase, first: { _ = try snippet($0) }) { call in
            let found = try snippet(call)
            if let trouble = SnippetStore.shared.delete(found.id) { throw PersonRefusal("failed", trouble) }
            return ["keyword": found.keyword, "message": "Deleted"]
        },
        PersonVerb("spaces", "colour", .arrange, first: { call in
            _ = try PersonTabs.space(call, try call.need("space"))
            _ = try colour(try call.need("colour"))
        }) { call in
            let space = try PersonTabs.space(call, try call.need("space"))
            let id = try colour(try call.need("colour"))
            guard let look = SpaceLook.named(id, over: space.look ?? SpaceLook()) else { throw PersonRefusal("failed", "That colour didn't take") }
            call.browser.setSpaceLook(space.id, to: look)
            return ["space": space.name, "colour": id, "message": "Changed"]
        },
    ]
}
