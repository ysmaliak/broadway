import Foundation

struct AgentChange {
    enum Settled: String {
        case quiet, navigated, dialog, capped, skipped
    }

    struct Element: Equatable {
        var ref: String
        var role: String
        var name: String
        var value: String?
        var state: String?

        init(ref: String, role: String, name: String, value: String? = nil, state: String? = nil) {
            self.ref = ref
            self.role = role
            self.name = name
            self.value = value
            self.state = state
        }

        func object() -> [String: Any] {
            var found: [String: Any] = ["ref": ref, "role": role, "name": name]
            if let value { found["value"] = value }
            if let state { found["state"] = state }
            return found
        }

        init?(object: Any?) {
            guard let object = object as? [String: Any], let ref = object["ref"] as? String else { return nil }
            self.init(ref: ref, role: object["role"] as? String ?? "", name: object["name"] as? String ?? "",
                      value: object["value"] as? String, state: object["state"] as? String)
        }
    }

    struct Was: Equatable {
        var name: String?
        var value: String?
        var state: String?

        init(name: String? = nil, value: String? = nil, state: String? = nil) {
            self.name = name
            self.value = value
            self.state = state
        }

        func object() -> [String: Any] {
            var found: [String: Any] = [:]
            if let name { found["name"] = name }
            if let value { found["value"] = value }
            if let state { found["state"] = state }
            return found
        }
    }

    struct Changed: Equatable {
        var element: Element
        var was: Was

        init(_ element: Element, was: Was) {
            self.element = element
            self.was = was
        }

        func object() -> [String: Any] {
            var found = element.object()
            found["was"] = was.object()
            return found
        }

        init?(object: Any?) {
            guard let element = Element(object: object) else { return nil }
            let was = (object as? [String: Any])?["was"] as? [String: Any] ?? [:]
            self.init(element, was: Was(name: was["name"] as? String, value: was["value"] as? String, state: was["state"] as? String))
        }
    }

    struct TextChange: Equatable {
        var was: String
        var now: String

        init(was: String, now: String) {
            self.was = was
            self.now = now
        }
    }

    struct Page: Equatable {
        var url: String
        var title: String
        var navigated: Bool
        var loaded: Bool?

        init(url: String, title: String, navigated: Bool = false, loaded: Bool? = nil) {
            self.url = url
            self.title = title
            self.navigated = navigated
            self.loaded = loaded
        }

        func object() -> [String: Any] {
            var found: [String: Any] = ["url": url, "title": title, "navigated": navigated]
            if let loaded { found["loaded"] = loaded }
            return found
        }
    }

    struct Dialog: Equatable {
        var id: String
        var kind: String
        var message: String
        var site: String

        init(id: String, kind: String, message: String, site: String) {
            self.id = id
            self.kind = kind
            self.message = message
            self.site = site
        }

        func object() -> [String: Any] {
            ["id": id, "kind": kind, "message": message, "site": site]
        }
    }

    struct OpenedTab: Equatable {
        var id: String
        var title: String
        var url: String
        var popup: Bool

        init(id: String, title: String, url: String, popup: Bool = true) {
            self.id = id
            self.title = title
            self.url = url
            self.popup = popup
        }

        func object() -> [String: Any] {
            ["id": id, "title": title, "url": url, "popup": popup]
        }
    }

    struct Tabs: Equatable {
        var opened: [OpenedTab]
        var closed: [String]
        var working: String?
        var count: Int?
        var blocked: [String]

        init(opened: [OpenedTab] = [], closed: [String] = [], working: String? = nil, count: Int? = nil, blocked: [String] = []) {
            self.opened = opened
            self.closed = closed
            self.working = working
            self.count = count
            self.blocked = blocked
        }

        func object() -> [String: Any] {
            var found: [String: Any] = ["opened": opened.map { $0.object() }, "closed": closed, "working": working ?? NSNull()]
            if let count { found["count"] = count }
            if !blocked.isEmpty { found["blocked"] = blocked }
            return found
        }
    }

    struct Download: Equatable {
        var name: String
        var state: String
        var path: String?

        init(name: String, state: String, path: String? = nil) {
            self.name = name
            self.state = state
            self.path = path
        }

        func object() -> [String: Any] {
            var found: [String: Any] = ["name": name, "state": state]
            if let path {
                found["path"] = path
                if !path.isEmpty { found["id"] = PersonStuff.stableID(path) }
            }
            return found
        }
    }

    struct Busy: Equatable {
        var requests: Int

        init(requests: Int) {
            self.requests = requests
        }
    }

    struct Look {
        var lines: [String]
        var elements: [[String: Any]]
        var shown: Int
        var total: Int
        var regions: [String]
        var needs: String?
        var ways: [String]
        var header: [String]

        init(lines: [String], elements: [[String: Any]] = [], shown: Int, total: Int, regions: [String] = [], needs: String? = nil,
             ways: [String] = [], header: [String] = []) {
            self.lines = lines
            self.elements = elements
            self.shown = shown
            self.total = total
            self.regions = regions
            self.needs = needs
            self.ways = ways
            self.header = header
        }

        func object() -> [String: Any] {
            var found: [String: Any] = ["elements": elements, "shown": shown, "total": total, "regions": regions, "lines": lines,
                                        "needs": needs ?? NSNull()]
            if !ways.isEmpty { found["ways"] = ways }
            if !header.isEmpty { found["header"] = header }
            return found
        }

        init?(object: Any?) {
            guard let object = object as? [String: Any], let lines = object["lines"] as? [String] else { return nil }
            self.init(lines: lines, elements: object["elements"] as? [[String: Any]] ?? [], shown: object["shown"] as? Int ?? lines.count,
                      total: object["total"] as? Int ?? lines.count, regions: object["regions"] as? [String] ?? [],
                      needs: object["needs"] as? String, ways: object["ways"] as? [String] ?? [], header: object["header"] as? [String] ?? [])
        }

        static func needsLine(_ needs: String, overMCP: Bool = false) -> String {
            switch (needs, overMCP) {
            case ("captcha", false): "needs: a captcha, so run broadway handoff \"Solve the captcha\" and wait, never solving it yourself"
            case ("captcha", true): "needs: a captcha, so call handoff with \"Solve the captcha\" and wait, never solving it yourself"
            case ("code", false): "needs: a one-time code, so run broadway fill code (Broadway fills a code mailed to Gmail, you never see it). For one sent by text or an app, run broadway handoff \"Type the code you were sent\"."
            case ("code", true): "needs: a one-time code, so call fill_code (Broadway fills a code mailed to Gmail, you never see it). For one sent by text or an app, call handoff with \"Type the code you were sent\""
            case (_, false): "needs: a password, so run broadway fill login (Broadway fills it after the person's yes, you never see it)"
            case (_, true): "needs: a password, so call fill_login (Broadway fills it after the person's yes, you never see it)"
            }
        }

        static func overMCP(_ text: String) -> String {
            guard text.contains("needs: ") else { return text }
            return ["captcha", "code", "password"].reduce(text) { $0.replacingOccurrences(of: needsLine($1), with: needsLine($1, overMCP: true)) }
        }

        static func waysLine(_ ways: [String]) -> String {
            "signs in with: " + ways.joined(separator: ", ") + (ways.count == 1 ? " (this space is signed in to it)" : " (this space is signed in to each)")
        }

        func text() -> [String] {
            (needs.map { [Self.needsLine($0)] } ?? []) + (ways.isEmpty ? [] : [Self.waysLine(ways)]) + header + lines + (total > shown ? ["… \(total - shown) more: broadway snapshot, or --in @ref, --role, --find"] : [])
        }
    }

    static let caps = (appeared: 8, went: 5, changed: 5)

    var tab: String
    var did: String
    var said: String?
    var same: [String]
    var target: Element?
    var settled: Settled
    var busy: Busy?
    var ms: Int
    var page: Page
    var headings: [String]
    var appeared: [Element]
    var went: [Element]
    var changed: [Changed]
    var text: [TextChange]
    var dialog: Dialog?
    var tabs: Tabs
    var download: Download?
    var more: Int
    var website: Bool
    var kept: [String: Any]
    var notes: [String] = []
    var expect: [String: Any]?
    var look: Look?
    var most = false
    var alerted: Dialog?
    var reordered: [String] = []

    static func reorderLine(_ said: [String: Any]) -> String {
        let name = cell(said["name"] as? String ?? "")
        let table = said["table"] as? Bool == true
        let whole = name.isEmpty ? (table ? "the table" : "the list") : "\"\(name)\""
        return "the \(said["kind"] as? String ?? "items") of \(whole) are in a new order"
    }

    init(tab: String, did: String, said: String? = nil, same: [String] = [], target: Element? = nil, settled: Settled = .quiet,
         busy: Busy? = nil, ms: Int = 0, page: Page, headings: [String] = [], appeared: [Element] = [], went: [Element] = [],
         changed: [Changed] = [], text: [TextChange] = [], dialog: Dialog? = nil, tabs: Tabs? = nil, download: Download? = nil,
         more: Int = 0, website: Bool = true, kept: [String: Any] = [:]) {
        self.tab = tab
        self.did = did
        self.said = said
        self.same = same
        self.target = target
        self.settled = settled
        self.busy = busy
        self.ms = ms
        self.page = page
        self.headings = headings
        self.appeared = appeared
        self.went = went
        self.changed = changed
        self.text = text
        self.dialog = dialog
        self.tabs = tabs ?? Tabs(working: tab)
        self.download = download
        self.more = more
        self.website = website
        self.kept = kept
    }

    func object() -> [String: Any] {
        var found: [String: Any] = [
            "tab": tab, "did": did, "target": target?.object() ?? NSNull(), "settled": settled.rawValue, "ms": ms,
            "page": page.object(), "headings": headings, "appeared": appeared.map { $0.object() }, "went": went.map { $0.object() },
            "changed": changed.map { $0.object() }, "text": text.map { ["was": $0.was, "now": $0.now] },
            "dialog": dialog?.object() ?? NSNull(), "tabs": tabs.object(), "download": download?.object() ?? NSNull(),
            "more": more, "website": website, "message": headline,
        ]
        if !same.isEmpty { found["same"] = same }
        if let busy { found["busy"] = ["requests": busy.requests] }
        if nothing { found["nothing"] = true }
        if let expect { found["expect"] = expect }
        if let look { found["look"] = look.object() }
        if most { found["most"] = true }
        if !notes.isEmpty { found["notes"] = notes }
        if !reordered.isEmpty { found["reordered"] = reordered }
        if let alerted {
            var said = alerted.object()
            said["accepted"] = true
            found["alerted"] = said
            if dialog == nil { found["dialog"] = said }
        }
        for (key, value) in kept where found[key] == nil { found[key] = value }
        return found
    }

    init?(object: [String: Any]) {
        guard let tab = object["tab"] as? String, let did = object["did"] as? String,
              let page = object["page"] as? [String: Any] else { return nil }
        let tabs = object["tabs"] as? [String: Any] ?? [:]
        let dialog = object["dialog"] as? [String: Any]
        let download = object["download"] as? [String: Any]
        let busy = object["busy"] as? [String: Any]
        self.init(
            tab: tab, did: did, said: object["message"] as? String, same: object["same"] as? [String] ?? [],
            target: Element(object: object["target"]),
            settled: Settled(rawValue: object["settled"] as? String ?? "") ?? .quiet,
            busy: busy.map { Busy(requests: $0["requests"] as? Int ?? 0) },
            ms: object["ms"] as? Int ?? 0,
            page: Page(url: page["url"] as? String ?? "", title: page["title"] as? String ?? "",
                       navigated: page["navigated"] as? Bool ?? false, loaded: page["loaded"] as? Bool),
            headings: object["headings"] as? [String] ?? [],
            appeared: (object["appeared"] as? [Any] ?? []).compactMap { Element(object: $0) },
            went: (object["went"] as? [Any] ?? []).compactMap { Element(object: $0) },
            changed: (object["changed"] as? [Any] ?? []).compactMap { Changed(object: $0) },
            text: (object["text"] as? [[String: Any]] ?? []).map { TextChange(was: $0["was"] as? String ?? "", now: $0["now"] as? String ?? "") },
            dialog: dialog.flatMap { $0["accepted"] as? Bool == true ? nil : Dialog(id: $0["id"] as? String ?? "", kind: $0["kind"] as? String ?? "",
                                        message: $0["message"] as? String ?? "", site: $0["site"] as? String ?? "") },
            tabs: Tabs(opened: (tabs["opened"] as? [[String: Any]] ?? []).map {
                           OpenedTab(id: $0["id"] as? String ?? "", title: $0["title"] as? String ?? "",
                                     url: $0["url"] as? String ?? "", popup: $0["popup"] as? Bool ?? true)
                       },
                       closed: tabs["closed"] as? [String] ?? [], working: tabs["working"] as? String,
                       count: tabs["count"] as? Int, blocked: tabs["blocked"] as? [String] ?? []),
            download: download.map { Download(name: $0["name"] as? String ?? "", state: $0["state"] as? String ?? "", path: $0["path"] as? String) },
            more: object["more"] as? Int ?? 0,
            website: object["website"] as? Bool ?? true)
        notes = object["notes"] as? [String] ?? []
        expect = object["expect"] as? [String: Any]
        look = Look(object: object["look"])
        most = object["most"] as? Bool ?? false
        reordered = object["reordered"] as? [String] ?? []
        if let said = object["alerted"] as? [String: Any] {
            alerted = Dialog(id: said["id"] as? String ?? "", kind: said["kind"] as? String ?? "alert",
                             message: said["message"] as? String ?? "", site: said["site"] as? String ?? "")
        }
    }

    var nothing: Bool {
        appeared.isEmpty && went.isEmpty && changed.isEmpty && text.isEmpty && reordered.isEmpty && more == 0 && !page.navigated && dialog == nil
            && alerted == nil && tabs.opened.isEmpty && tabs.closed.isEmpty && download == nil && look == nil && settled != .skipped && settled != .capped
    }

    var opens: Bool { did == "open" || did == "go" || did == "navigate" }

    var headline: String {
        if opens { return said ?? "\(tab)  \(Self.cell(page.title))  \(Self.short(page.url))" }
        let line = action
        return line.hasSuffix(" in \(tab)") ? line : line + " in \(tab)"
    }

    private var action: String {
        if let said { return said }
        let lead: String
        switch did {
        case "click": lead = "Clicked"
        case "hover": lead = "Hovered over"
        case "type": lead = "Typed into"
        case "fill", "fill_form": lead = "Filled"
        case "choose": lead = "Chose an option in"
        case "press": lead = "Pressed"
        case "scroll": lead = "Scrolled"
        case "drag": lead = "Dragged"
        case "upload": lead = "Attached files to"
        case "download": lead = "Downloading from"
        case "dialog": lead = "Answered the dialog"
        case "back": lead = "Went back"
        case "forward": lead = "Went forward"
        case "reload": lead = "Reloaded"
        case "wait": lead = "Waited \(Self.seconds(ms)) s"
        default: lead = did
        }
        guard let target else { return lead }
        return "\(lead) \(Self.describe(target)) @\(target.ref)"
    }

    func lines() -> [String] {
        parts().map(\.text)
    }

    func parts() -> [(text: String, page: Bool)] {
        var found: [(text: String, page: Bool)] = [(headline, target != nil || opens || said != nil)]
        if let expectLine { found.append((expectLine, true)) }
        if opens {
            found.append((did == "open" ? "New tab, now your current tab" : "Went there", false))
            if did == "open", let line = AgentPlaces.line(kept["space"]) { found.append((line, false)) }
            for id in same { found.append(("You already have this address in tab \(id). Use it: broadway tab \(id)", false)) }
            if let look { found += look.text().map { ($0, true) } }
        } else if settled != .skipped, dialog == nil, tabs.opened.isEmpty {
            if page.navigated {
                found.append(("Went to: \(Self.cell(page.title))  \(Self.short(page.url))   (new page: refs start again)", true))
                if let look {
                    found += look.text().map { ($0, true) }
                } else {
                    if !headings.isEmpty { found.append(("Headings: " + headings.prefix(5).map { Self.cell($0) }.joined(separator: " · "), true)) }
                    found.append(("Next: broadway snapshot", false))
                }
            } else if nothing {
                found.append(("Nothing on the page changed", false))
            } else if most, let look {
                found.append(("Most of the page changed:", false))
                found += look.text().map { ($0, true) }
            } else {
                found.append(("Same page: \(Self.cell(page.title))", true))
            }
        }
        found += facts().map { ($0, true) }
        if !(most && look != nil && !page.navigated) { found += marks().map { ($0, !$0.hasPrefix("… ")) } }
        found += notes.map { ($0, false) }
        if settled == .capped { found.append((busyLine, false)) }
        return found
    }

    private var expectLine: String? {
        guard let expect, let kind = expect["kind"] as? String, let want = expect["want"] as? String else { return nil }
        let met = expect["met"] as? Bool == true
        let after = Self.seconds(Int(((expect["after"] as? Double) ?? 0) * 1000))
        switch kind {
        case "gone": return "Expected \"\(Self.cell(want))\" to go: " + (met ? "gone after \(after) s" : "still there after \(after) s")
        case "url": return "Expected the address to have \"\(Self.cell(want))\": " + (met ? "it did after \(after) s" : "not after \(after) s")
        default: return "Expected \"\(Self.cell(want))\": " + (met ? "there after \(after) s" : "not there after \(after) s")
        }
    }

    private var busyLine: String {
        let open = busy?.requests ?? 0
        let what = open == 0 ? "the page keeps changing" : open == 1 ? "1 request open" : "\(open) requests open"
        return "Still busy after \(Self.seconds(ms)) s: \(what). broadway wait to wait longer."
    }

    static func article(_ kind: String) -> String {
        kind.first.map { "aeiou".contains($0) } == true ? "An" : "A"
    }

    private func facts() -> [String] {
        var found: [String] = []
        if let alerted { found.append(Self.closedAlert(alerted.message)) }
        if let dialog {
            found.append("\(Self.article(dialog.kind)) \(dialog.kind) dialog is open: \"\(Self.cell(dialog.message))\"")
            switch dialog.kind {
            case "alert": found.append("Close it: broadway dialog accept")
            case "prompt": found.append("Answer it: broadway dialog accept \"TEXT\", or broadway dialog dismiss")
            default: found.append("Answer it: broadway dialog accept, or broadway dialog dismiss")
            }
        }
        for opened in tabs.opened {
            let line = "New tab \(opened.id): \(Self.cell(opened.title))  \(Self.short(opened.url))"
            found.append(tabs.working == opened.id ? line + ". It is now your current tab" : line + ". Switch to it: broadway tab \(opened.id)")
        }
        for site in tabs.blocked { found.append("A new tab for \(site) was closed. The person never lets agents use that site.") }
        for closed in tabs.closed { found.append("Tab \(closed) closed") }
        if let download {
            if download.state == "done" {
                found.append("Downloaded \(Self.cell(download.name))" + (download.path.map { ": \($0)" } ?? ""))
            } else {
                found.append("Download started: \(Self.cell(download.name)). Wait for it: broadway wait --download.")
            }
        }
        return found
    }

    func marks() -> [String] {
        var found: [String] = []
        var hidden = more
        for (index, element) in appeared.enumerated() {
            if index < Self.caps.appeared { found.append("+ @\(element.ref) \(Self.describe(element))") } else { hidden += 1 }
        }
        for (index, element) in went.enumerated() {
            if index < Self.caps.went { found.append("- @\(element.ref) \(Self.describe(element))") } else { hidden += 1 }
        }
        let changes = reordered.map { "~ " + $0 } + changed.map(Self.changeLine) + text.map { "~ \"\(Self.cell($0.was))\" → \"\(Self.cell($0.now))\"" }
        for (index, line) in changes.enumerated() {
            if index < Self.caps.changed { found.append(line) } else { hidden += 1 }
        }
        if hidden > 0 { found.append("… \(hidden) more: broadway snapshot --since") }
        return found
    }

    private static func changeLine(_ change: Changed) -> String {
        let element = change.element
        let was = change.was
        var line = "~ @\(element.ref) \(element.role)"
        if let old = was.name {
            line += " \"\(cell(old))\" → \"\(cell(element.name))\""
        } else if !element.name.isEmpty {
            line += " \"\(cell(element.name))\""
        }
        if let old = was.value {
            line += " \"\(cell(old))\" → \"\(cell(element.value ?? ""))\""
        } else if was.name == nil, was.state == nil, let value = element.value {
            line += " \"\(cell(value))\""
        }
        if let old = was.state {
            let now = element.state ?? ""
            line += old.isEmpty ? " now \(now)" : now.isEmpty ? " no longer \(old)" : " \(old) → \(now)"
        } else if was.name == nil, was.value == nil, let state = element.state {
            line += " \(state)"
        }
        return line
    }

    static func describe(_ element: Element) -> String {
        var line = element.role
        if !element.name.isEmpty { line += " \"\(cell(element.name))\"" }
        if let value = element.value, !value.isEmpty { line += " = \"\(cell(value))\"" }
        if let state = element.state, !state.isEmpty { line += " \(state)" }
        return line
    }

    static func errorLines(count: Int, listed: [String], cursor: String) -> [String] {
        ["! \(count) page error\(count == 1 ? "" : "s"). All of them: broadway console --since \(cursor)"] + listed.map { "  \"" + $0 + "\"" }
    }

    static func closedAlert(_ message: String) -> String {
        "The page showed an alert: \"\(cell(message))\". Broadway closed it."
    }

    static let warnedLine = "The page warned that changes may not be saved. Broadway left it anyway."

    static func cell(_ text: String, most: Int = 120) -> String {
        let flat = String(String.UnicodeScalarView(text.unicodeScalars.map { $0.value < 32 || $0.value == 127 ? " " : $0 }))
        return flat.count > most ? String(flat.prefix(most - 1)) + "…" : flat
    }

    static func short(_ url: String) -> String {
        var found = url
        for scheme in ["https://", "http://"] where found.hasPrefix(scheme) {
            found.removeFirst(scheme.count)
        }
        if found.hasSuffix("/"), found.filter({ $0 == "/" }).count == 1 { found.removeLast() }
        found = cell(found)
        return found.count > 80 ? String(found.prefix(79)) + "…" : found
    }

    static func seconds(_ ms: Int) -> String {
        let tenths = Int((Double(ms) / 100).rounded())
        return tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }
}
