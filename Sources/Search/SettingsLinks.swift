import AppKit
import UniformTypeIdentifiers

@MainActor
final class SettingsLinkDraft {
    var tried = ""
    var ruleTried: [UUID: String] = [:]
    var habits: [(site: String, space: UUID)]?
    var kind: [UUID: LinkRule.Match.Kind] = [:]
    var more: [UUID: Bool] = [:]
}

final class SettingsFoldRow: SettingsRowView {
    init(id: String, title: String, detail: String, open: Bool, control: NSView, flip: @escaping () -> Void) {
        super.init(id: id, symbol: nil, title: title, detail: detail, control: control, centered: true)
        press = flip
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityExpanded(open)
        control.setAccessibilityElement(false)
        (control as? NSControl)?.cell?.setAccessibilityElement(false)
    }

    override func accessibilityPerformPress() -> Bool {
        press?()
        return press != nil
    }
}

enum LinkMenuEntry<Value> {
    case value(String, Value, NSImage?)
    case run(String, () -> Void)
    case line
}

@MainActor
enum LinkRuleWords {
    static let field = "Site or address"
    static let blank = "Choose where links come from, or type a site"

    static let kinds: [(LinkRule.Match.Kind, String)] = [
        (.site, "A Site and Its Subdomains"),
        (.host, "Exactly This Host"),
        (.starts, "The Start of an Address"),
        (.contains, "Any Part of an Address"),
        (.pattern, "A Pattern with *"),
        (.regex, "A Regular Expression"),
    ]

    static func example(_ kind: LinkRule.Match.Kind) -> String {
        switch kind {
        case .site: "github.com"
        case .host: "docs.google.com"
        case .starts: "github.com/apple"
        case .contains: "/pull/"
        case .pattern: "github.com/*/pull/*"
        case .regex: "^https://.*\\.zoom\\.us/j/"
        }
    }

    static func prompt(_ rule: LinkRule, chosen: LinkRule.Match.Kind?) -> String {
        let kind = LinkRuleEditor.kind(rule, chosen: chosen)
        if kind != .site { return example(kind) }
        return LinkRuleEditor.isAny(rule.match) ? "Any site" : example(.site)
    }

    static func subject(_ from: LinkRule.From, any: Bool) -> String {
        let links = any ? "Every link" : "Links"
        return switch from {
        case .anywhere: links
        case .otherApps: links + " from other apps"
        case .app(_, let name): links + " from \(name)"
        case .insideBroadway: links + " from pages in Broadway"
        }
    }

    static func sentence(_ rule: LinkRule, world: LinkWorld) -> String {
        let target = LinkRouter.words(rule.target, world: world)
        if LinkRuleEditor.isEmpty(rule.match) { return "A new rule → \(target)" }
        if LinkRuleEditor.isAny(rule.match) { return "\(subject(rule.from, any: rule.from == .anywhere)) → \(target)" }
        return "\(LinkRouter.words(rule.match)) → \(target)"
    }

    static func named(_ rule: LinkRule) -> String {
        if LinkRuleEditor.isEmpty(rule.match) { return "" }
        guard LinkRuleEditor.isAny(rule.match) else { return LinkRouter.words(rule.match) }
        let said = subject(rule.from, any: true)
        return said.prefix(1).lowercased() + said.dropFirst()
    }

    static func line(_ rule: LinkRule, world: LinkWorld) -> String {
        if let problem = LinkRouter.problem(rule, world: world) { return "⚠︎ " + problem }
        let any = LinkRuleEditor.isAny(rule.match)
        var parts: [String] = []
        if rule.from != .anywhere, !any { parts.append(LinkRouter.words(rule.from)) }
        if rule.background { parts.append("in the background") }
        if rule.rewrite != nil { parts.append("changes the address") }
        if !rule.note.isEmpty { parts.append(rule.note) }
        if parts.isEmpty { parts.append(any && rule.from != .anywhere ? "Any site" : "From anywhere") }
        return parts.joined(separator: " · ")
    }

    static func needs(_ rule: LinkRule, world: LinkWorld) -> String? {
        if LinkRuleEditor.isEmpty(rule.match) { return rule.from == .anywhere ? blank : "Type a site to finish this rule" }
        return LinkRouter.problem(rule, world: world).map { $0 + "." }
    }

    static func says(_ rule: LinkRule, world: LinkWorld) -> String {
        let any = LinkRuleEditor.isAny(rule.match)
        var words = subject(rule.from, any: any)
        switch rule.match {
        case .pattern where any: break
        case .site(let text): words += " to " + LinkRouter.plainSite(text)
        case .host(let text): words += " to exactly " + LinkRouter.plainSite(text, keepsWWW: true)
        case .starts(let text): words += " that start with " + LinkRouter.anchored(text)
        case .contains(let text): words += " with “\(text.trimmingCharacters(in: .whitespacesAndNewlines))” in the address"
        case .pattern(let text): words += " like " + LinkRouter.anchored(text)
        case .regex(let text): words += " that fit /\(text)/"
        }
        let open = any ? "opens" : "open"
        switch rule.target {
        case .frontSpace: words += " \(open) in the space in front"
        case .whereOpen: words += " \(open) where the site is already open"
        case .ask: words += any ? " asks where to open" : " ask where to open"
        case .window, .peek: words += " \(open) in " + LinkRouter.words(rule.target, world: world).lowercasedFirst
        case .space, .app: words += " \(open) in " + LinkRouter.words(rule.target, world: world)
        }
        if rule.background { words += ", in the background" }
        if let rewrite = rule.rewrite, !rewrite.find.isEmpty { words += ", with the address changed" }
        return words + "."
    }
}

extension SettingsShell {
    func openLinkRule(_ id: UUID) {
        query = ""
        walk { $0.open(.linkRule, folder: id) }
    }
}

extension SettingsWindow {
    static func showLinkRule(_ id: UUID) {
        guard let browser = Browsers.front ?? Browsers.all.first else { return }
        browser.openSettings(.links)
        DispatchQueue.main.async { browser.settingsRule = id }
    }
}

extension SettingsPageView {
    @discardableResult
    func linkRow(_ id: String) -> Bool {
        let store = LinkRules.shared
        let switches: [String: WritableKeyPath<LinkSettings, Bool>] = [
            "links.choose": \.chooseKey, "links.tracking": \.cleansLinks, "links.unwrap": \.unwrapsLinks,
            "links.openTab": \.goesToOpenTab, "links.liveRow": \.goesToLiveRow,
        ]
        if let path = switches[id] {
            row(id, control: toggle(id, get: { store.settings[keyPath: path] }, set: { on in store.set { $0[keyPath: path] = on } }))
            return true
        }
        guard id == "links.open" else { return false }
        let spaces = browser.prefs.usesSpaces ? browser.spaces : []
        var choices: [LinkSettings.Outside] = [.front]
        choices += spaces.map { .space($0.id) }
        choices.append(.ask)
        let titles = choices.map { choice -> String in
            switch choice {
            case .front: "The Space in Front"
            case .space(let id): spaces.first { $0.id == id }?.name ?? "A Space That's Gone"
            case .ask: "Ask Every Time"
            }
        }
        let outside = popUp(id, titles: titles, picked: { choices.firstIndex(of: store.settings.outsideDefault) ?? 0 },
                            set: { at in store.set { $0.outsideDefault = choices[at] } })
        for (at, choice) in choices.enumerated() {
            guard case .space(let space) = choice else { continue }
            outside.button.item(at: at)?.image = spaces.first { $0.id == space }?.settingsBadge
        }
        row(id, control: outside)
        return true
    }

    func links() {
        let browser = browser
        let store = LinkRules.shared
        let draft = linkDraft
        let shell = shell
        let world = { Browsers.linkWorld(from: browser) }
        if draft.habits == nil { draft.habits = store.suggestions(for: browser) }

        let spaces = browser.prefs.usesSpaces ? browser.spaces : []
        shape { spaces.map(\.id) }
        section("From other apps") {
            linkRow("links.open")
            linkRow("links.choose")
        }

        store.rules.filter(LinkRuleEditor.isBlank).forEach { store.remove($0.id) }
        shape { store.rules.map(\.id) }
        section("Rules", footer: store.rules.count > 1 ? "The first rule that matches a link decides. Rules made from a tab's menu or the chooser go above broader ones." : nil) {
            if store.rules.isEmpty {
                note("No rules yet. Add one here, or use Move › Always Open in a tab's menu.")
            }
            for (index, rule) in store.rules.enumerated() {
                let id = rule.id
                let on = toggle("link.rule.on.\(index)", get: { store.rule(id)?.on ?? false }, set: { value in store.change(id) { $0.on = value } })
                let mark = SettingsDrillMark()
                let controls = NSStackView(views: [on, mark])
                controls.orientation = .horizontal
                controls.spacing = 12
                let made = SettingsRowView(id: "link.rule.\(index)", symbol: nil, title: LinkRuleWords.sentence(rule, world: world()),
                                           detail: LinkRuleWords.line(rule, world: world()), control: controls)
                made.press = { [weak shell] in shell?.openLinkRule(id) }
                made.setAccessibilityElement(true)
                made.setAccessibilityRole(.button)
                made.setAccessibilityLabel(LinkRuleWords.sentence(rule, world: world()))
                update { [weak made] in
                    guard let made, let now = store.rule(id) else { return }
                    let here = world()
                    made.rename(LinkRuleWords.sentence(now, world: here))
                    made.say(LinkRuleWords.line(now, world: here))
                    made.detail.textColor = LinkRouter.problem(now, world: here) == nil ? .secondaryLabelColor : .systemOrange
                    made.alphaValue = now.on ? 1 : 0.55
                }
                put(made)
            }
            let add = button("Add Rule") { [weak shell] in
                let target: LinkRule.Target = browser.prefs.usesSpaces ? .space(browser.spaceID, folder: nil) : .window(nil)
                let made = store.add(LinkRule(match: .site(""), target: target))
                shell?.openLinkRule(made.id)
            }
            add.kitAccess(id: "settings.links.add", label: "Add Rule")
            put(SettingsRowView(id: "links.add", symbol: nil, title: "", control: add))
        }

        let habits = (draft.habits ?? []).filter { store.target(of: $0.site) == nil }
        shape { habits.map(\.site) }
        if !habits.isEmpty {
            section("Suggestions", footer: "Sites you keep in one space. Adding one makes a rule for links from anywhere.") {
                for habit in habits {
                    let name = browser.spaces.first { $0.id == habit.space }?.name ?? ""
                    let add = button("Add") { store.always(habit.site, to: .space(habit.space, folder: nil)) }
                    add.kitAccess(id: "settings.links.suggest." + habit.site, label: "Add \(habit.site)")
                    let made = SettingsRowView(id: "link.habit." + habit.site, symbol: nil, title: "\(habit.site) → \(name)",
                                               detail: "You keep this site in that space", control: add)
                    put(made)
                }
            }
        }

        section("Clean-up", footer: "Links from other apps only, but the last switch also takes links you open in a new tab. On this Mac, before rules read them. Short links aren't expanded, because that would need the network.") {
            linkRow("links.tracking")
            linkRow("links.unwrap")
            linkRow("links.openTab")
            linkRow("links.liveRow")
        }

        section("Try a link", footer: "As if it came from another app. Nothing opens.") {
            let typed = field("Address", text: { draft.tried }, prompt: "https://github.com/apple/swift/pull/1", width: nil) { [weak self] in
                draft.tried = $0
                self?.refresh()
            }
            fitted(typed, name: "links.try")
            let result = SettingsRowView(id: "links.try.result", symbol: nil, title: "Type an address to see where it goes")
            result.title.textColor = .secondaryLabelColor
            update { [weak result] in
                guard let result else { return }
                let text = draft.tried.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let url = Address.url(from: text) ?? URL(string: text) else {
                    result.rename("Type an address to see where it goes")
                    result.title.textColor = .secondaryLabelColor
                    result.say("")
                    return
                }
                let decision = LinkRouter.decide(IncomingLink(url: url, source: .unknownApp), rules: store.rules,
                                                 settings: store.settings, world: world())
                result.title.textColor = .labelColor
                result.rename(decision.steps.last ?? "")
                result.say(decision.steps.dropLast().joined(separator: "\n"))
            }
            put(result)
        }

        shape { store.recent.map(\.id) }
        section("Recent", footer: "The last \(LinkRules.recentLimit) links a rule, a live folder or you placed. Kept until Broadway quits.") {
            if store.recent.isEmpty {
                note("Nothing yet")
            }
            for entry in store.recent {
                let rule = entry.rule.flatMap { store.index(of: $0) }
                let by = rule.map { "rule \($0 + 1)" } ?? entry.live.map { "already in \($0)" } ?? "you chose"
                let made = SettingsRowView(id: "link.recent." + entry.id.uuidString, symbol: nil, title: entry.site,
                                           detail: "\(entry.from) · \(by) · \(entry.went)")
                if let id = entry.rule, rule != nil { made.press = { [weak shell] in shell?.openLinkRule(id) } }
                put(made)
            }
            if !store.recent.isEmpty {
                let clear = button("Clear…") { [weak self] in SettingsQuestion.recentLinks.ask(over: self?.window) { store.clearRecent() } }
                clear.kitAccess(id: "settings.links.clearRecent", label: "Clear Recent")
                put(SettingsRowView(id: "links.recent.clear", symbol: nil, title: "", control: clear))
            }
        }
    }

    func linkMenu<Value: Equatable>(_ id: String, _ entries: [LinkMenuEntry<Value>], picked: @escaping () -> Value?,
                                    set: @escaping (Value) -> Void) -> SettingsPopUp {
        let holder = SettingsPopUp()
        let made = holder.button
        for entry in entries {
            switch entry {
            case .line:
                made.menu?.addItem(.separator())
            case .value(let title, _, let image):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = image
                made.menu?.addItem(item)
            case .run(let title, _):
                made.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            }
        }
        made.kitOnChange { control in
            guard let at = (control as? NSPopUpButton)?.indexOfSelectedItem, entries.indices.contains(at) else { return }
            switch entries[at] {
            case .value(_, let value, _): set(value)
            case .run(_, let run): run()
            case .line: break
            }
        }
        update { [weak made] in
            let now = picked()
            let at = entries.firstIndex { entry in
                if case .value(_, let value, _) = entry { return value == now }
                return false
            } ?? 0
            if made?.indexOfSelectedItem != at { made?.selectItem(at: at) }
        }
        made.kitAccess(id: "settings." + id)
        return holder
    }

    func linkRule() {
        let browser = browser
        let store = LinkRules.shared
        let draft = linkDraft
        let shell = shell
        let world = { Browsers.linkWorld(from: browser) }
        shape { shell.trail.folder.flatMap { store.rule($0) } != nil }
        guard let id = shell.trail.folder, let rule = store.rule(id) else { return }
        let here = world()
        let fresh = LinkRuleEditor.isBlank(rule)
        if draft.more[id] == nil, LinkRuleEditor.usesMore(rule) { draft.more[id] = true }
        let open = draft.more[id] ?? false
        func kind(_ now: LinkRule) -> LinkRule.Match.Kind? {
            if let kept = draft.kind[id] ?? LinkRuleEditor.kept(now.match) { draft.kind[id] = kept }
            return draft.kind[id]
        }
        func plain(_ target: LinkRule.Target?) -> LinkRule.Target? {
            guard case .space(let space, _) = target else { return target }
            return .space(space, folder: nil)
        }

        var sources: [LinkMenuEntry<LinkRule.From>] = [
            .value("Anywhere", .anywhere, nil), .value("Other Apps", .otherApps, nil), .value("Pages in Broadway", .insideBroadway, nil),
        ]
        var apps: [LinkSender] = []
        if case .app(let bundle, let name) = rule.from { apps.append(LinkSender(bundleID: bundle, name: name)) }
        apps += store.senders.filter { sender in !apps.contains { $0.bundleID.lowercased() == sender.bundleID.lowercased() } }
        apps += Self.runningApps(besides: apps, own: here.broadway)
        if !apps.isEmpty { sources.append(.line) }
        sources += apps.map { .value($0.name, .app(bundleID: $0.bundleID, name: $0.name), Self.appIcon($0.bundleID)) }
        sources.append(.line)
        sources.append(.run("Choose Application…") { [weak self] in
            SettingsPageView.pickApp { picked in
                guard let picked else { return self?.refresh() ?? () }
                store.change(id) { now in
                    let from = LinkRule.From.app(bundleID: picked.bundleID, name: picked.name)
                    now.match = LinkRuleEditor.match(typed: LinkRuleEditor.shown(now), kind: kind(now), from: from)
                    now.from = from
                }
            }
        })

        let spaces = here.usesSpaces ? here.spaces : []
        var places: [LinkMenuEntry<LinkRule.Target>] = spaces.map { space in
            .value(space.name, .space(space.id, folder: nil), browser.spaces.first { $0.id == space.id }?.settingsBadge)
        }
        if !places.isEmpty { places.append(.line) }
        places += [.value("The Space in Front", .frontSpace, nil), .value("Where It's Already Open", .whereOpen, nil),
                   .value("New Window", .window(nil), nil)]
        places += Browsers.linkTargets.map { .value(LinkRouter.words(.window($0.record.id), world: here), .window($0.record.id), nil) }
        places += [.value("Peek", .peek, nil), .line]
        var others: [LinkSender] = []
        if case .app(let bundle, let name) = rule.target { others.append(LinkSender(bundleID: bundle, name: name)) }
        others += Self.browsers().filter { found in !others.contains { $0.bundleID.lowercased() == found.bundleID.lowercased() } }
        places += others.map { .value($0.name, .app(bundleID: $0.bundleID, name: $0.name), Self.appIcon($0.bundleID)) }
        places.append(.run("Another Application…") { [weak self] in
            SettingsPageView.pickApp { picked in
                guard let picked else { return self?.refresh() ?? () }
                store.change(id) { $0.target = .app(bundleID: picked.bundleID, name: picked.name) }
            }
        })
        places += [.line, .value("Ask Every Time", .ask, nil)]

        let says = { () -> (text: String, wrong: Bool) in
            guard let now = store.rule(id) else { return ("", false) }
            let here = world()
            if let needs = LinkRuleWords.needs(now, world: here) { return (needs, needs != LinkRuleWords.blank) }
            return (LinkRuleWords.says(now, world: here), false)
        }
        shape { store.senders.map(\.bundleID) }
        shape { store.rule(id)?.from }
        shape { plain(store.rule(id)?.target).map { "\($0)" } ?? "" }
        shape { Browsers.linkTargets.map(\.record.id) }
        section(footer: says().text) {
            let from = linkMenu("link.from", sources, picked: { store.rule(id)?.from }, set: { chosen in
                store.change(id) { now in
                    now.match = LinkRuleEditor.match(typed: LinkRuleEditor.shown(now), kind: kind(now), from: chosen)
                    now.from = chosen
                }
            })
            _ = line("Links from", id: "link.from", control: from)
            let text = field(LinkRuleWords.field, text: { store.rule(id).map(LinkRuleEditor.shown) ?? "" },
                             prompt: LinkRuleWords.prompt(rule, chosen: draft.kind[id]), submit: { [weak self] in
                guard let self, let now = store.rule(id), LinkRuleEditor.isBlank(now) != fresh else { return }
                self.rebuild()
                self.layoutSubtreeIfNeeded()
                let again = self.kitSubviews(of: NSTextField.self).first { $0.isEditable && $0.accessibilityLabel() == LinkRuleWords.field }
                if let again { self.window?.makeFirstResponder(again) }
            }) { typed in
                store.change(id) { $0.match = LinkRuleEditor.match(typed: typed, kind: kind($0), from: $0.from) }
            }
            update { [weak text] in
                guard let now = store.rule(id) else { return }
                text?.placeholderString = LinkRuleWords.prompt(now, chosen: draft.kind[id])
            }
            labeled("That go to", text)
            let place = linkMenu("link.target", places, picked: { plain(store.rule(id)?.target) }, set: { chosen in
                store.change(id) { $0.target = chosen }
            })
            _ = line("Open in", id: "link.target", control: place)
        }
        if let said = blocks.last?.subviews.first as? SettingsFooter {
            said.setAccessibilityIdentifier("settings.link.says")
            update { [weak said] in
                guard let said else { return }
                let now = says()
                said.words.color = now.wrong ? .systemOrange : .secondaryLabelColor
                guard said.words.text != now.text else { return }
                said.words.text = now.text
                said.setAccessibilityLabel(now.text)
                said.invalidateIntrinsicContentSize()
                said.needsLayout = true
            }
        }

        shape { draft.more[id] ?? false }
        section {
            let mark = NSButton(title: "", target: nil, action: nil)
            mark.bezelStyle = .disclosure
            mark.setButtonType(.pushOnPushOff)
            mark.state = open ? .on : .off
            let flip = { [weak self] in
                draft.more[id] = !open
                self?.refresh()
            }
            mark.kitOnChange { _ in flip() }
            mark.kitAccess(id: "settings.link.more")
            let more = SettingsFoldRow(id: "link.more", title: "More Options",
                                       detail: open ? "" : "How the address is read, a folder, the background, a changed address, a note",
                                       open: open, control: mark, flip: flip)
            put(more)
            guard open else { return }
            let kinds = LinkRuleWords.kinds
            let read = popUp("link.kind", titles: kinds.map(\.1), picked: {
                guard let now = store.rule(id) else { return 0 }
                let shown = LinkRuleEditor.kind(now, chosen: draft.kind[id])
                return kinds.firstIndex { $0.0 == shown } ?? 0
            }, set: { [weak self] at in
                draft.kind[id] = kinds[at].0
                store.change(id) { $0.match = LinkRuleEditor.match(typed: LinkRuleEditor.shown($0), kind: kinds[at].0, from: $0.from) }
                self?.refresh()
            })
            _ = line("Read the address as", id: "link.kind", control: read)
            if case .space(let space, _) = rule.target, let folders = here.space(space)?.folders, !folders.isEmpty {
                let folder = popUp("link.folder", titles: ["No Folder"] + folders.map(\.name), picked: {
                    guard case .space(_, let folder?) = store.rule(id)?.target else { return 0 }
                    return (folders.firstIndex { $0.id == folder } ?? -1) + 1
                }, set: { at in
                    store.change(id) { $0.target = .space(space, folder: at == 0 ? nil : folders[at - 1].id) }
                })
                _ = line("Folder", id: "link.folder", control: folder)
            }
            let behind = toggle("link.background", get: { store.rule(id)?.background ?? false }, set: { on in store.change(id) { $0.background = on } })
            _ = line("Open in the background", "Broadway stays where it is, and so do you", id: "link.background", control: behind)
            let note = field("Note", text: { store.rule(id)?.note ?? "" }, prompt: "Shown in the list") { typed in
                store.change(id) { $0.note = typed }
            }
            labeled("Note", note)
        }

        if open {
            section("Change the address", footer: "A regular expression, and what replaces it, with $1 for the first group. Leave Find empty to keep the address.") {
                let find = field("Find", text: { store.rule(id)?.rewrite?.find ?? "" }, prompt: "^https://zoom\\.us/j/(\\d+)") { typed in
                    store.change(id) { rule in
                        let replace = rule.rewrite?.replace ?? ""
                        rule.rewrite = typed.isEmpty && replace.isEmpty ? nil : LinkRule.Rewrite(find: typed, replace: replace)
                    }
                }
                labeled("Find", find)
                let replace = field("Replace", text: { store.rule(id)?.rewrite?.replace ?? "" }, prompt: "zoommtg://zoom.us/join?confno=$1") { typed in
                    store.change(id) { rule in
                        let find = rule.rewrite?.find ?? ""
                        rule.rewrite = typed.isEmpty && find.isEmpty ? nil : LinkRule.Rewrite(find: find, replace: typed)
                    }
                }
                labeled("Replace", replace)
                let result = SettingsRowView(id: "link.rewrite.result", symbol: nil, title: "Result")
                update { [weak result] in
                    guard let result else { return }
                    let tried = (draft.ruleTried[id] ?? "").trimmingCharacters(in: .whitespaces)
                    guard let rewrite = store.rule(id)?.rewrite, !rewrite.find.isEmpty else {
                        result.say("The address stays as it is")
                        return
                    }
                    guard let url = Address.url(from: tried) ?? URL(string: tried), !tried.isEmpty else {
                        result.say("Type an address under Try It to see the result")
                        return
                    }
                    result.say(LinkRouter.rewritten(url, by: rewrite)?.absoluteString ?? "Not a web address, so the address would stay")
                }
                put(result)
            }
        }

        guard !fresh else { return }
        section("Try it") {
            let typed = field("Try it", text: { draft.ruleTried[id] ?? "" }, prompt: "An address", width: nil) { [weak self] in
                draft.ruleTried[id] = $0
                self?.refresh()
            }
            fitted(typed, name: "link.try")
            let answer = SettingsRowView(id: "link.try.answer", symbol: nil, title: "Type an address to try this rule")
            update { [weak answer] in
                guard let answer, let now = store.rule(id) else { return }
                let text = (draft.ruleTried[id] ?? "").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty, let url = Address.url(from: text) ?? URL(string: text) else {
                    answer.rename("Type an address to try this rule")
                    answer.title.textColor = .secondaryLabelColor
                    answer.say("")
                    return
                }
                answer.title.textColor = .labelColor
                if !LinkRouter.matches(now.match, url) {
                    answer.rename("Doesn't match")
                    answer.say(LinkRouter.broken(now) ?? "")
                    return
                }
                answer.rename("Matches")
                let source: IncomingLink.Source = switch now.from {
                case .insideBroadway: .page(space: browser.spaceID, site: nil)
                case .app(let bundle, let name): .app(bundleID: bundle, name: name)
                default: .unknownApp
                }
                var plain = LinkSettings()
                plain.goesToLiveRow = false
                let alone = LinkRouter.decide(IncomingLink(url: url, source: source), rules: [now], settings: plain, world: world())
                answer.say(alone.steps.dropFirst().joined(separator: "\n"))
            }
            put(answer)
        }

        shape { store.index(of: id) ?? -1 }
        shape { store.rules.count }
        if store.rules.count > 1 {
            section("Order", footer: "The first rule that matches a link decides") {
                let at = store.index(of: id) ?? 0
                let up = button("Move Up") { store.move(id, by: -1) }
                up.isEnabled = at > 0
                up.kitAccess(id: "settings.link.up", label: "Move Up")
                let down = button("Move Down") { store.move(id, by: 1) }
                down.isEnabled = at < store.rules.count - 1
                down.kitAccess(id: "settings.link.down", label: "Move Down")
                let both = NSStackView(views: [up, down])
                both.spacing = 8
                _ = line("Rule \(at + 1) of \(store.rules.count)", id: "link.order", control: both)
            }
        }
        section {
            let remove = SettingsDangerRow(id: "link.delete", symbol: MenuSymbol.close, title: "Delete Rule…",
                                           detail: "Links it took open as if it weren't there") { [weak self] in
                SettingsQuestion.linkRule(store.rule(id).map(LinkRuleWords.named) ?? "").ask(over: self?.window) {
                    store.remove(id)
                    _ = shell.up()
                }
            }
            put(remove)
        }
    }

    static func runningApps(besides listed: [LinkSender], own: String) -> [LinkSender] {
        guard !Store.unitTests else { return [] }
        var seen = Set(listed.map { $0.bundleID.lowercased() } + [own.lowercased()])
        return NSWorkspace.shared.runningApplications.compactMap { app -> LinkSender? in
            guard app.activationPolicy == .regular, let bundle = app.bundleIdentifier, let name = app.localizedName,
                  seen.insert(bundle.lowercased()).inserted else { return nil }
            return LinkSender(bundleID: bundle, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        .prefix(10)
        .map { $0 }
    }

    static func browsers() -> [LinkSender] {
        guard !Store.unitTests, let web = URL(string: "https://example.com") else { return [] }
        return LinkChooser.installedBrowsers(for: web).map { LinkSender(bundleID: $0.bundleID, name: $0.name) }
    }

    static func appIcon(_ bundle: String) -> NSImage? {
        guard !Store.unitTests, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    static func pickApp(_ done: @escaping (LinkSender?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { answer in
            guard answer == .OK, let url = panel.url, let bundle = Bundle(url: url)?.bundleIdentifier else { return done(nil) }
            done(LinkSender(bundleID: bundle, name: FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")))
        }
    }
}
