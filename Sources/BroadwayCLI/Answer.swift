import Foundation

enum Answer {
    static let caps = (appeared: 8, went: 5, changed: 5)
    static let lookLines = 40

    static func shaped(_ data: [String: Any]) -> Bool {
        data["did"] is String && data["page"] is [String: Any]
    }

    static func opens(_ data: [String: Any]) -> Bool {
        ["open", "go", "navigate"].contains(data["did"] as? String ?? "")
    }

    static func page(_ data: [String: Any]) -> [String: Any] { data["page"] as? [String: Any] ?? [:] }

    static func headline(_ data: [String: Any]) -> String {
        if let said = data["message"] as? String, !said.isEmpty { return said }
        let page = page(data)
        let tab = data["tab"] as? String ?? ""
        if opens(data) { return "\(tab)  \(cell(page["title"] as? String ?? ""))  \(short(page["url"] as? String ?? ""))" }
        let did = data["did"] as? String ?? ""
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
        case "wait": lead = "Waited \(seconds(data["ms"] as? Int ?? 0)) s"
        default: lead = did
        }
        guard let target = data["target"] as? [String: Any], let ref = target["ref"] as? String else { return lead }
        return "\(lead) \(describe(target)) @\(ref)"
    }

    static func lines(_ data: [String: Any], look: Bool = true) -> [String] {
        [headline(data)] + (expected(data).map { [$0] } ?? []) + body(data, look: look)
    }

    static func expected(_ data: [String: Any]) -> String? {
        guard let expect = data["expect"] as? [String: Any], let want = expect["want"] as? String else { return nil }
        let met = expect["met"] as? Bool == true
        let after = (expect["after"] as? Double).map { seconds(Int(($0 * 1000).rounded())) } ?? seconds(data["ms"] as? Int ?? 0)
        let quoted = "\"\(cell(want))\""
        switch expect["kind"] as? String {
        case "gone": return "Expected \(quoted) to go: \(met ? "gone" : "still there") after \(after) s"
        case "url": return "Expected the address to have \(quoted): \(met ? "it does" : "it doesn't") after \(after) s"
        default: return "Expected \(quoted): \(met ? "there" : "not there") after \(after) s"
        }
    }

    static func body(_ data: [String: Any], look: Bool = true) -> [String] {
        var found: [String] = []
        let page = page(data)
        let settled = data["settled"] as? String ?? "quiet"
        let dialog = data["dialog"] as? [String: Any]
        let opened = ((data["tabs"] as? [String: Any])?["opened"] as? [[String: Any]]) ?? []
        let shown = look ? lookLines(data) : []
        if opens(data) {
            found.append(data["did"] as? String == "open" ? "New tab, now your current tab" : "Went there")
            if data["did"] as? String == "open", let line = placed(data["space"]) { found.append(line) }
            if let count = tabCount(data) { found.append("tabs: \(count)") }
            for id in data["same"] as? [String] ?? [] { found.append("You already have this address in tab \(id). Use it: broadway tab \(id)") }
        } else if settled != "skipped", dialog == nil || dialog?["accepted"] as? Bool == true, opened.isEmpty {
            if page["navigated"] as? Bool == true {
                found.append("Went to: \(cell(page["title"] as? String ?? ""))  \(short(page["url"] as? String ?? ""))   (new page: refs start again)")
                if shown.isEmpty {
                    let headings = (data["headings"] as? [String] ?? []).prefix(5).map(cell)
                    if !headings.isEmpty { found.append("Headings: " + headings.joined(separator: " · ")) }
                    found.append("Next: broadway snapshot")
                }
            } else if data["most"] as? Bool == true, !shown.isEmpty {
                found.append("Most of the page changed:")
            } else {
                found.append("Same page: \(cell(page["title"] as? String ?? ""))")
            }
        }
        found += facts(data)
        let marked = marks(data)
        found += marked
        if marked.isEmpty, data["nothing"] as? Bool == true { found.append("Nothing on the page changed") }
        found += notes(data)
        found += errors(data)
        if settled == "capped", !noted(data, "busy", "loading") { found.append(busy(data)) }
        found += shown
        return found
    }

    static func placed(_ space: Any?) -> String? {
        guard let space = space as? [String: Any], space["first"] as? Bool == true,
              let name = space["name"] as? String, let why = space["why"] as? String else { return nil }
        if why == "as asked" {
            return space["kept"] as? Bool == true ? "In \(name), as asked. This folder's tabs go there from now on." : "In \(name), as asked"
        }
        return "In \(name), \(why). Run broadway open URL --space NAME to pick another and keep it for this folder."
    }

    static func tail(_ data: [String: Any]) -> [String] {
        var found = facts(data) + marks(data) + notes(data) + errors(data)
        if data["settled"] as? String == "capped", !noted(data, "busy", "loading") { found.append(busy(data)) }
        return found + lookLines(data)
    }

    static func errors(_ data: [String: Any]) -> [String] {
        guard let errors = data["errors"] as? [String: Any], let count = errors["count"] as? Int, count > 0, let cursor = errors["cursor"] as? String else { return [] }
        let listed = (errors["list"] as? [String] ?? []).prefix(3).map { "  \"" + cell($0) + "\"" }
        return ["! \(count) page error\(count == 1 ? "" : "s"). All of them: broadway console --since \(cursor)"] + listed
    }

    static func notes(_ data: [String: Any]) -> [String] {
        (data["notes"] as? [String] ?? []).filter { !$0.isEmpty }
    }

    static func noted(_ data: [String: Any], _ words: String...) -> Bool {
        notes(data).contains { note in words.contains { note.localizedCaseInsensitiveContains($0) } }
    }

    static func lookLines(_ data: [String: Any]) -> [String] {
        guard let look = data["look"] as? [String: Any] else { return [] }
        let given = look["lines"] as? [String]
        let elements = look["elements"] as? [[String: Any]] ?? []
        guard given != nil || look["elements"] is [[String: Any]] else { return [] }
        var found = (look["header"] as? [String] ?? []) + Render.needs(look)
        found += given ?? Render.elementLines(elements, regions: look["regions"] as? [[String: Any]] ?? [])
        let count = given?.count ?? elements.count
        let total = look["total"] as? Int ?? count
        let shown = look["shown"] as? Int ?? count
        if total > shown, !(found.last ?? "").hasPrefix("… ") { found.append("… \(total - shown) more: broadway snapshot, or --in @ref, --role, --find") }
        return found
    }

    static func tabCount(_ data: [String: Any]) -> Int? {
        (data["tabs"] as? Int) ?? ((data["tabs"] as? [String: Any])?["count"] as? Int)
    }

    private static func busy(_ data: [String: Any]) -> String {
        let open = (data["busy"] as? [String: Any])?["requests"] as? Int ?? 0
        let what = open == 0 ? "the page keeps changing" : open == 1 ? "1 request open" : "\(open) requests open"
        return "Still busy after \(seconds(data["ms"] as? Int ?? 0)) s: \(what). broadway wait to wait longer."
    }

    static func facts(_ data: [String: Any]) -> [String] {
        var found: [String] = []
        if let dialog = data["dialog"] as? [String: Any] {
            let kind = dialog["kind"] as? String ?? "page"
            let message = cell(dialog["message"] as? String ?? "")
            if dialog["accepted"] as? Bool == true {
                found.append(kind == "alert" ? "The page showed an alert: \"\(message)\". Broadway closed it." : "The page said (\(kind), accepted): \"\(message)\"")
            } else {
                found.append("\(kind.first.map { "aeiou".contains($0) } == true ? "An" : "A") \(kind) dialog is open: \"\(message)\"")
                switch kind {
                case "alert": found.append("Close it: broadway dialog accept")
                case "prompt": found.append("Answer it: broadway dialog accept \"TEXT\", or broadway dialog dismiss")
                default: found.append("Answer it: broadway dialog accept, or broadway dialog dismiss")
                }
            }
        }
        let tabs = data["tabs"] as? [String: Any] ?? [:]
        for opened in tabs["opened"] as? [[String: Any]] ?? [] {
            let id = opened["id"] as? String ?? ""
            let line = "New tab \(id): \(cell(opened["title"] as? String ?? ""))  \(short(opened["url"] as? String ?? ""))"
            found.append(tabs["working"] as? String == id ? line + ". It is now your current tab" : line + ". Switch to it: broadway tab \(id)")
        }
        for site in tabs["blocked"] as? [String] ?? [] { found.append("A new tab for \(site) was closed. The person never lets agents use that site.") }
        for closed in tabs["closed"] as? [String] ?? [] { found.append("Tab \(closed) closed") }
        if let picker = data["picker"] as? [String: Any], picker["closed"] as? Bool == true, !noted(data, "file picker") {
            let ref = (data["target"] as? [String: Any])?["ref"] as? String
            found.append("The page opened a file picker, which Broadway closed, so give it a file with broadway upload \(ref.map { "@" + $0 } ?? "REF") PATH")
        }
        if let download = data["download"] as? [String: Any] {
            let name = cell(download["name"] as? String ?? "")
            if download["state"] as? String == "done" {
                found.append("Downloaded \(name)" + ((download["path"] as? String).map { ": \($0)" } ?? ""))
            } else {
                found.append("Download started: \(name). Wait for it: broadway wait --download.")
            }
        }
        return found
    }

    static func marks(_ data: [String: Any]) -> [String] {
        var found: [String] = []
        var hidden = data["more"] as? Int ?? 0
        for (index, element) in (data["appeared"] as? [[String: Any]] ?? []).enumerated() {
            if index < caps.appeared { found.append("+ @\(element["ref"] as? String ?? "") \(describe(element))") } else { hidden += 1 }
        }
        for (index, element) in (data["went"] as? [[String: Any]] ?? []).enumerated() {
            if index < caps.went { found.append("- @\(element["ref"] as? String ?? "") \(describe(element))") } else { hidden += 1 }
        }
        let texts = (data["text"] as? [[String: Any]] ?? []).map { "~ \"\(cell($0["was"] as? String ?? ""))\" → \"\(cell($0["now"] as? String ?? ""))\"" }
        let changes = (data["reordered"] as? [String] ?? []).map { "~ " + $0 } + (data["changed"] as? [[String: Any]] ?? []).map(changeLine) + texts
        for (index, line) in changes.enumerated() {
            if index < caps.changed { found.append(line) } else { hidden += 1 }
        }
        if hidden > 0 { found.append("… \(hidden) more: broadway snapshot --since") }
        return found
    }

    private static func changeLine(_ element: [String: Any]) -> String {
        let was = element["was"] as? [String: Any] ?? [:]
        let name = element["name"] as? String ?? ""
        var line = "~ @\(element["ref"] as? String ?? "") \(element["role"] as? String ?? "")"
        if let old = was["name"] as? String {
            line += " \"\(cell(old))\" → \"\(cell(name))\""
        } else if !name.isEmpty {
            line += " \"\(cell(name))\""
        }
        if let old = was["value"] as? String {
            line += " \"\(cell(old))\" → \"\(cell(element["value"] as? String ?? ""))\""
        } else if was["name"] == nil, was["state"] == nil, let value = element["value"] as? String {
            line += " \"\(cell(value))\""
        }
        if let old = was["state"] as? String {
            let now = element["state"] as? String ?? ""
            line += old.isEmpty ? " now \(now)" : now.isEmpty ? " no longer \(old)" : " \(old) → \(now)"
        } else if was["name"] == nil, was["value"] == nil, let state = element["state"] as? String {
            line += " \(state)"
        }
        return line
    }

    static func describe(_ element: [String: Any]) -> String {
        var line = element["role"] as? String ?? ""
        if let name = element["name"] as? String, !name.isEmpty { line += " \"\(cell(name))\"" }
        if let value = element["value"] as? String, !value.isEmpty { line += " = \"\(cell(value))\"" }
        if let state = element["state"] as? String, !state.isEmpty { line += " \(state)" }
        return line
    }

    static func cell(_ text: String) -> String {
        let flat = Plain.cell(text)
        return flat.count > 120 ? String(flat.prefix(119)) + "…" : flat
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
