import AppKit
import WebKit

enum AgentResult<Value> {
    case success(Value)
    case failure(ToolOutcome)
}

struct AgentPoint: Equatable {
    var x: Double
    var y: Double
}

struct AgentTarget: Equatable {
    var ref: String?
    var words: String?
    var roles: [String] = []
    var label: String?
    var nth: Int?
    var inside: String?
    var frames = false

    static func bare(_ text: String) -> String {
        var found = text.trimmingCharacters(in: .whitespaces)
        if found.hasPrefix("@") { found.removeFirst() }
        if let match = found.range(of: "^f[0-9]+e[0-9]+$", options: .regularExpression), match == found.startIndex..<found.endIndex,
           let at = found.dropFirst().firstIndex(of: "e") {
            found.insert(".", at: at)
        }
        return found
    }

    static func isRef(_ text: String) -> Bool {
        bare(text).range(of: "^(f[0-9]+\\.)?e[0-9]+$", options: .regularExpression) != nil
    }

    static func roles(_ value: Any?) -> [String] {
        if let list = value as? [Any] { return list.compactMap { ($0 as? String)?.lowercased() }.filter { !$0.isEmpty } }
        guard let text = value as? String else { return [] }
        return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    }

    static func flag(_ value: Any?) -> Bool {
        guard let value, value is NSNumber else { return false }
        return CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    static func whole(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, !flag(value) { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    init(ref: String? = nil, words: String? = nil, roles: [String] = [], label: String? = nil, nth: Int? = nil, inside: String? = nil, frames: Bool = false) {
        self.ref = ref
        self.words = words
        self.roles = roles
        self.label = label
        self.nth = nth
        self.inside = inside
        self.frames = frames
    }

    init(_ arguments: [String: Any], key: String = "ref") {
        let given = arguments["target"] as? [String: Any] ?? [:]
        func text(_ name: String) -> String? {
            let value = (given[name] as? String) ?? (given.isEmpty ? arguments[name] as? String : nil)
            return value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        }
        let refText = (given["ref"] as? String) ?? (arguments[key] as? String)
        if let refText, !refText.trimmingCharacters(in: .whitespaces).isEmpty {
            if Self.isRef(refText) { ref = Self.bare(refText) } else { words = refText }
        }
        if let target = arguments["target"] as? String, !target.isEmpty {
            if Self.isRef(target) { ref = Self.bare(target) } else { words = target }
        }
        words = words ?? text("words") ?? text("name")
        roles = Self.roles(given["role"] ?? (given.isEmpty ? arguments["role"] : nil))
        label = text("label")
        nth = Self.whole(given["nth"] ?? arguments["nth"])
        inside = text("in").map(Self.bare)
        frames = (given["frames"] ?? arguments["frames"]) as? Bool == true
        at = Self.point(given["at"] ?? (given.isEmpty ? arguments["at"] : nil))
    }

    var at: AgentPoint?

    static func point(_ value: Any?) -> AgentPoint? {
        if let pair = value as? [String: Any], let x = number(pair["x"]), let y = number(pair["y"]) { return AgentPoint(x: x, y: y) }
        if let text = value as? String {
            let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2, let x = parts[0], let y = parts[1] { return AgentPoint(x: x, y: y) }
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    var given: Bool { ref != nil || words != nil || label != nil || !roles.isEmpty || at != nil }

    var described: String {
        if let label { return "labelled \"\(AgentChange.cell(label))\"" }
        if let words { return "\"\(AgentChange.cell(words))\"" }
        return roles.joined(separator: " or ")
    }
}

extension BrowserToolbox {
    static let targeted: Set<String> = ["click", "type", "choose", "hover", "drag", "upload", "download", "select", "scroll", "screenshot", "press"]

    static func prefer(_ tool: String) -> [String] {
        switch tool {
        case "type": ["textbox", "searchbox", "combobox", "spinbutton"]
        case "choose": ["combobox", "listbox"]
        case "upload": ["file", "button", "dropzone"]
        default: []
        }
    }

    static func command(_ tool: String) -> String {
        AgentCatalog.shapes[tool]?.command ?? tool.replacingOccurrences(of: "_", with: "-")
    }

    func frameNames(_ tab: Tab) -> [(name: String, frame: WKFrameInfo)] {
        let reach = tab.fieldRelay.reach
        var names = tab.agentFrames.filter { reach[$0.value] != nil }
        let used = Set(names.values)
        var number = names.keys.compactMap { Int($0.dropFirst()) }.max() ?? 0
        for token in reach.keys.sorted() where !used.contains(token) {
            number += 1
            names["f\(number)"] = token
        }
        tab.agentFrames = names
        return names.compactMap { name, token in reach[token].map { (name, $0) } }
            .sorted { (Int($0.name.dropFirst()) ?? 0) < (Int($1.name.dropFirst()) ?? 0) }
    }

    func sameSite(_ tab: Tab, _ frame: WKFrameInfo) -> Bool {
        let host = frame.securityOrigin.host
        let home = AgentSites.site(of: tab.pageAddress)
        return home != nil && AgentSites.site(of: URL(string: "https://\(host)")) == home
    }

    func pageFailure(_ said: [String: Any], tab: Tab, ref: String = "") -> ToolOutcome {
        var text = said["failed"] as? String ?? "That didn't work"
        let code = said["code"] as? String
        let frame = AgentRef(ref).frame
        if let frame { text = text.replacingOccurrences(of: "@e", with: "@\(frame).e") }
        var data: [String: Any] = [:]
        var hint: String?
        switch code {
        case "stale_ref":
            if said["why"] as? String == "unknown", frame == nil {
                if let earlier = AgentRefBook.earlier(tab, ref: AgentRef(ref).ref, now: said["doc"] as? String) {
                    text = "@\(AgentRef(ref).ref) was on \(AgentChange.cell(earlier.title.isEmpty ? "another page" : earlier.title)), this tab is now on \(AgentChange.cell(tab.title.isEmpty ? "another page" : tab.title))"
                    data["website"] = true
                }
            }
        case "ref_changed":
            if let now = said["now"] as? [String: Any] {
                var element = now
                if let frame { element["ref"] = "\(frame).\(now["ref"] as? String ?? "")" }
                data["element"] = element
                data["website"] = true
                text = "@\(element["ref"] as? String ?? AgentRef(ref).ref) now reads \(now["role"] as? String ?? "") \"\(AgentChange.cell(now["name"] as? String ?? ""))\". Run the same command again to act on it as it is now"
            }
        case "not_actionable":
            data["reason"] = said["reason"] as? String ?? "hidden"
            if let by = said["by"] as? [String: Any] {
                data["by"] = by
                data["website"] = true
                if let close = said["close"] as? String { hint = "Close that first: broadway click @\(frame.map { "\($0)." } ?? "")\(close)" }
            }
        default:
            break
        }
        if let given = said["hint"] as? String { hint = given }
        return .failure(AgentChange.cell(text, most: 300), code: code ?? ToolFailure.code(text), hint: hint, data: data.isEmpty ? nil : data)
    }

    func toldTab(_ arguments: [String: Any], _ data: [String: Any]) -> Tab? {
        if let tab = find(arguments)?.tab { return tab }
        let id = (data["id"] as? String) ?? (data["tab"] as? String)
        return id.flatMap { find(["tab": $0])?.tab }
    }

    func resolve(_ target: AgentTarget, tab: Tab, tool: String, task: UUID? = nil) async -> AgentResult<String> {
        if let ref = target.ref {
            if !ref.contains(".") {
                let doc = await timed(tab, AgentPage.docScript, seconds: 2) as? String
                if AgentRefBook.wasTold(task, tab, doc: doc, ref: ref) == false {
                    var text = "@\(ref) is from before this page changed, so it may name something else now"
                    if let earlier = AgentRefBook.earlier(tab, ref: ref, now: doc) {
                        text = "@\(ref) was on \(AgentChange.cell(earlier.title.isEmpty ? "another page" : earlier.title)), this tab is now on \(AgentChange.cell(tab.title.isEmpty ? "another page" : tab.title))"
                    }
                    return .failure(.failure(text, code: .staleRef, hint: "Run broadway snapshot for this page's refs"))
                }
            }
            return .success(ref)
        }
        if let at = target.at { return await resolve(at: at, tab: tab) }
        guard target.given else {
            return .failure(.failure("\(Self.command(tool)) needs a target: a ref like @e12, or the element's words", code: .usage,
                                     hint: "Run broadway snapshot or broadway find WORDS for refs"))
        }
        let found = await candidates(target, tab: tab, tool: tool, most: 50)
        if let failure = found.failure { return .failure(failure) }
        let list = found.list
        let command = Self.command(tool)
        let what = target.described
        if list.isEmpty {
            let kind = target.roles.first ?? (target.label != nil ? "field" : "element")
            let message: String
            if target.label != nil { message = "No field is labelled \(what)" }
            else if target.words != nil { message = "No \(kind) is named \(what)" }
            else { message = "No \(kind) on this page" }
            let look = (target.words ?? target.label ?? target.roles.first ?? "").split(separator: " ").first.map { String($0).lowercased() } ?? ""
            return .failure(.failure(message, code: .notFound, hint: look.isEmpty ? nil : "broadway find \(look), or broadway snapshot --find \(look)",
                                     data: ["website": true]))
        }
        if let nth = target.nth {
            guard nth >= 1, nth <= found.count, nth <= list.count else {
                return .failure(.failure("Only \(found.count) element\(found.count == 1 ? "" : "s") fit \(what), so there is no number \(nth)",
                                         code: .notFound, hint: "Pick one from 1 to \(min(found.count, list.count)) with --nth", data: ["website": true]))
            }
            return .success(list[nth - 1]["ref"] as? String ?? "")
        }
        guard found.count == 1, let only = list.first else {
            let first = list.prefix(3).map { "@\($0["ref"] as? String ?? "") \"\(AgentChange.cell(Self.near($0), most: 60))\"" }.joined(separator: ", ")
            let words = target.words.map { "\"\(AgentChange.cell($0))\"" } ?? ""
            let shown = words.isEmpty ? "" : " \(words)"
            return .failure(.failure("\(what) fits \(found.count) elements", code: .ambiguous,
                                     hint: "Pick one: broadway \(command)\(shown) --nth 1, or --in @ref. First ones: \(first)",
                                     data: ["candidates": Array(list.prefix(5)), "count": found.count, "website": true]))
        }
        return .success(only["ref"] as? String ?? "")
    }

    static func near(_ element: [String: Any]) -> String {
        if let within = element["within"] as? [String: Any], let name = within["name"] as? String, !name.isEmpty { return name }
        if let near = element["near"] as? String, !near.isEmpty { return near }
        return element["name"] as? String ?? ""
    }

    func resolve(at point: AgentPoint, tab: Tab) async -> AgentResult<String> {
        let scale = (shotScale[tab.id] ?? 1) * max(tab.web.pageZoom, 0.1)
        let arguments: [String: Any] = ["x": point.x / scale, "y": point.y / scale]
        guard let said = await timed(tab, AgentPage.pointScript, arguments, seconds: 5) as? [String: Any] else {
            return .failure(.failure("The page gave no answer", code: .noAnswer))
        }
        if let failed = said["failed"] as? String {
            return .failure(.failure(failed, code: said["code"] as? String ?? "not_found",
                                     hint: "broadway screenshot shows the window, and broadway snapshot gives refs"))
        }
        guard let ref = said["ref"] as? String else { return .failure(.failure("Nothing is at that point", code: "not_found")) }
        return .success(ref)
    }

    func candidates(_ target: AgentTarget, tab: Tab, tool: String, most: Int) async -> (list: [[String: Any]], count: Int, failure: ToolOutcome?) {
        var inside = target.inside.map { AgentRef($0) }
        var arguments: [String: Any] = ["inside": inside?.ref ?? "", "roles": target.roles, "words": target.words ?? "", "label": target.label ?? "",
                                        "prefer": Self.prefer(tool), "most": most]
        var places: [(name: String?, frame: WKFrameInfo?)] = []
        let frames = frameNames(tab)
        if let frame = inside?.frame {
            guard let info = frames.first(where: { $0.name == frame })?.frame else {
                return ([], 0, .failure("That frame has gone. Take a new snapshot.", code: .staleRef))
            }
            places = [(frame, info)]
        } else {
            places = [(nil, nil)]
            if inside == nil {
                places += frames.filter { target.frames || sameSite(tab, $0.frame) }.map { ($0.name, $0.frame) }
            }
        }
        if inside?.ref.isEmpty == true { inside = nil }
        var list: [[String: Any]] = []
        var count = 0
        for place in places {
            guard let said = await timed(tab, AgentPage.resolveScript, arguments, in: place.frame, seconds: 5) as? [String: Any] else {
                if place.frame == nil { return ([], 0, .failure("The page gave no answer", code: .noAnswer)) }
                continue
            }
            if said["failed"] != nil { return ([], 0, pageFailure(said, tab: tab, ref: target.inside ?? "")) }
            if place.frame == nil, let doc = said["doc"] as? String { AgentRefBook.note(tab, doc: doc, title: tab.title, next: said["next"] as? Int) }
            count += said["count"] as? Int ?? 0
            for item in said["found"] as? [[String: Any]] ?? [] {
                var item = item
                if let name = place.name {
                    item["ref"] = "\(name).\(item["ref"] as? String ?? "")"
                    item["frame"] = place.frame?.securityOrigin.host ?? ""
                }
                list.append(item)
            }
            arguments["most"] = max(0, most - list.count)
        }
        return (list, count, nil)
    }

    func locate(_ tab: Tab, _ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        var target = AgentTarget(arguments, key: "ref")
        if target.words == nil, let words = arguments["text"] as? String, !words.trimmingCharacters(in: .whitespaces).isEmpty { target.words = words }
        guard target.words != nil || !target.roles.isEmpty || target.label != nil else {
            return .failure("find needs words, a role, or both", code: .usage, hint: "broadway find \"Add to basket\" --role button")
        }
        acting(tab, "Reading")
        let limit = min(max(AgentTarget.whole(arguments["limit"]) ?? 20, 1), 200)
        let found = await candidates(target, tab: tab, tool: "locate", most: limit)
        if let failure = found.failure { return failure }
        let lines = found.list.map { element -> String in
            var line = "@\(element["ref"] as? String ?? "") \(element["role"] as? String ?? "") \"\(AgentChange.cell(element["name"] as? String ?? ""))\""
            if let within = element["within"] as? [String: Any] {
                line += "   in \(within["role"] as? String ?? "part") \"\(AgentChange.cell(within["name"] as? String ?? ""))\""
            }
            return line
        }
        let more = found.count > found.list.count ? ["… \(found.count - found.list.count) more: --limit, --in @ref"] : []
        let written = (lines + more).joined(separator: "\n")
        let addressed = AIPage.addressesAI(written)
        TaskLedger.shared.saw(tab.pageAddress, addressed: addressed, task: task)
        let shown = found.list.map { element -> [String: Any] in
            var element = element
            if let within = element.removeValue(forKey: "within") { element["in"] = within }
            return element
        }
        var data: [String: Any] = ["elements": shown, "count": found.count, "website": true]
        if addressed { data["warning"] = String(ToolReply.warning.dropLast()) }
        return ToolOutcome(text: ToolReply.notice + (addressed ? ToolReply.warning : "") + (written.isEmpty ? "Nothing fits" : written), data: data)
    }

    func everything(_ tab: Tab) async -> [[String: Any]]? {
        guard let main = await timed(tab, AgentPage.everythingScript, [:], seconds: 8) as? [String: Any] else { return nil }
        if let doc = main["doc"] as? String { AgentRefBook.note(tab, doc: doc, title: tab.title, next: main["next"] as? Int) }
        var items = main["items"] as? [[String: Any]] ?? []
        for place in frameNames(tab) {
            guard let found = await timed(tab, AgentPage.everythingScript, [:], in: place.frame, seconds: 3) as? [String: Any] else { continue }
            items += (found["items"] as? [[String: Any]] ?? []).map { item in
                var item = item
                item["ref"] = "\(place.name).\(item["ref"] as? String ?? "")"
                item["frame"] = place.frame.securityOrigin.host
                return item
            }
        }
        return items
    }
}
