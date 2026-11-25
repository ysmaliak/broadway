import AppKit
import WebKit

extension BrowserToolbox {
    struct Looked {
        var lines: [String] = []
        var items: [[String: Any]] = []
        var regions: [[String: Any]] = []
        var shown = 0
        var total = 0
        var cut = false
        var scope = "page"
        var modal = false
        var since: AgentChange?
        var fresh = false
        var header: [String] = []
        var needs: String?
        var ways: [String] = []
        var elsewhere: String?
        var unseen = 0
    }

    func walk(_ tab: Tab, _ arguments: [String: Any], task: UUID?) async -> AgentResult<Looked> {
        let who = Self.who(task)
        let insideText = AgentTarget.bare(arguments["in"] as? String ?? arguments["inside"] as? String ?? "")
        let inside = insideText.isEmpty ? nil : AgentRef(insideText)
        if !insideText.isEmpty, !AgentTarget.isRef(insideText) {
            return .failure(.failure("--in takes a ref like @e30", code: .usage, hint: "Run broadway snapshot for refs"))
        }
        let all = arguments["all"] as? Bool == true
        let limit = all ? 2000 : min(max(AgentTarget.whole(arguments["limit"]) ?? 120, 1), 500)
        var script: [String: Any] = [
            "inside": inside?.ref ?? "", "all": all, "text": arguments["text"] as? Bool == true, "since": arguments["since"] as? Bool == true,
            "who": who, "roles": AgentTarget.roles(arguments["role"]), "find": (arguments["find"] as? String) ?? "",
            "view": arguments["view"] as? Bool == true, "limit": limit,
            "boxes": arguments["boxes"] as? Bool == true, "scale": pixelScale(tab, task: task),
        ]
        let frames = frameNames(tab)
        var places: [(name: String?, frame: WKFrameInfo?)] = [(nil, nil)]
        if let frame = inside?.frame {
            guard let info = frames.first(where: { $0.name == frame })?.frame else {
                return .failure(.failure("That frame has gone. Take a new snapshot.", code: .staleRef))
            }
            places = [(frame, info)]
        }
        var looked = Looked()
        var remaining = limit
        var index = 0
        while index < places.count {
            let place = places[index]
            index += 1
            script["limit"] = max(remaining, 1)
            guard let said = await timed(tab, AgentPage.snapshotScript, script, in: place.frame, seconds: 8) as? [String: Any] else {
                if place.frame == nil { return .failure(.failure("The page gave no answer", code: .noAnswer)) }
                tab.fieldRelay.forget(tab.agentFrames[place.name ?? ""] ?? "")
                continue
            }
            if said["failed"] != nil { return .failure(pageFailure(said, tab: tab, ref: insideText)) }
            if place.frame == nil {
                if let doc = said["doc"] as? String { AgentRefBook.note(tab, doc: doc, title: tab.title, next: said["next"] as? Int) }
                looked.scope = said["scope"] as? String ?? "page"
                looked.modal = said["modal"] as? Bool == true
                if said["since"] as? Bool == true {
                    looked.since = AgentChange(tab: String(tab.id.uuidString.prefix(8)).lowercased(), did: "snapshot",
                                               page: AgentChange.Page(url: AgentSecrets.shown(tab.pageAddress), title: tab.title),
                                               appeared: (said["appeared"] as? [Any] ?? []).compactMap { AgentChange.Element(object: $0) },
                                               went: (said["went"] as? [Any] ?? []).compactMap { AgentChange.Element(object: $0) },
                                               changed: (said["changed"] as? [Any] ?? []).compactMap { AgentChange.Changed(object: $0) },
                                               more: said["more"] as? Int ?? 0)
                    return .success(looked)
                }
                looked.fresh = said["fresh"] as? Bool == true
                if let needs = said["needs"] as? String, !needs.isEmpty {
                    looked.needs = needs
                    looked.elsewhere = await signedInElsewhere(tab)
                }
                if let ways = said["ways"] as? [String], !ways.isEmpty { looked.ways = await signedIn(ways, tab: tab) }
                if inside == nil, looked.scope == "page" { places += frames.map { ($0.name, $0.frame) } }
            }
            let rows = (said["lines"] as? [String] ?? []).map { AgentLinkLine.fixed($0, page: tab.pageAddress) }
            let items = (said["items"] as? [[String: Any]] ?? []).map { AgentLinkLine.fixed($0, page: tab.pageAddress) }
            let shown = said["shown"] as? Int ?? items.count
            looked.total += said["total"] as? Int ?? shown
            looked.cut = looked.cut || said["cut"] as? Bool == true
            looked.unseen += said["unseen"] as? Int ?? 0
            let regions = said["regions"] as? [[String: Any]] ?? []
            if let name = place.name {
                guard remaining > 0, !rows.isEmpty else { continue }
                looked.lines.append("Inside an embedded frame from \(place.frame?.securityOrigin.host ?? ""):")
                looked.lines += rows.map { $0.hasPrefix("@") ? "@\(name).\($0.dropFirst())" : $0 }
                looked.items += items.map { item in
                    var item = item
                    item["ref"] = "\(name).\(item["ref"] as? String ?? "")"
                    if let region = item["region"] as? String { item["region"] = "\(name).\(region)" }
                    item["frame"] = place.frame?.securityOrigin.host ?? ""
                    return item
                }
                looked.regions += regions.map { region in
                    var region = region
                    region["ref"] = "\(name).\(region["ref"] as? String ?? "")"
                    return region
                }
            } else {
                looked.lines += rows
                looked.items += items
                looked.regions += regions
            }
            looked.shown += shown
            remaining -= shown
        }
        return .success(looked)
    }

    func snapshot(_ tab: Tab, _ arguments: [String: Any] = [:], task: UUID?) async -> ToolOutcome {
        var looked: Looked
        switch await walk(tab, arguments, task: task) {
        case .failure(let failure): return failure
        case .success(let found): looked = found
        }
        var empty: AgentReadiness.Why?
        let whole = ((arguments["in"] ?? arguments["inside"]) as? String ?? "").isEmpty && ((arguments["find"] as? String) ?? "").isEmpty && AgentTarget.roles(arguments["role"]).isEmpty
        if looked.since == nil, looked.total == 0, whole, let ready = await readiness(tab), ready.text == 0 {
            let waited = await awaitText(tab)
            if waited?.text ?? 0 > 0, case .success(let again) = await walk(tab, arguments, task: task) { looked = again }
            if looked.total == 0 { empty = AgentReadiness.why(waited, loading: tab.loading, address: tab.pageAddress) }
        }
        let short = String(tab.id.uuidString.prefix(8)).lowercased()
        var header = ["\"\(AgentChange.cell(tab.title))\"  \(AgentChange.short(AgentSecrets.shown(tab.pageAddress)))"]
        var body: [String]
        var noted: String?
        if let since = looked.since {
            let marks = since.marks()
            body = marks.isEmpty ? ["Nothing changed since your last look"] : marks
        } else {
            if looked.fresh, arguments["since"] as? Bool == true { header.append("New page since your last look") }
            if looked.modal { header.append("A dialog is open, so only it is shown (the page behind it: --all)") }
            if looked.unseen > 0 { header.append(Self.unseenLine(looked.unseen)) }
            if let empty { header.append("\(empty.said). \(empty.hint)") }
            if arguments["boxes"] as? Bool == true, let zoom = Self.zoomLine(tab) { header.append(zoom) }
            if let note = siteNote(tab, task: task) {
                header.append("note: Broadway has notes for this site: broadway skill \(note)")
                noted = note
            }
            body = looked.lines
            let more = looked.total - looked.shown
            if more > 0 { body.append("… \(more) more: --all, --in @ref, --role, --find, --view") }
            if looked.cut { body.append("(More on the page: this list stopped at 5000)") }
        }
        var told = looked.since == nil ? looked.needs.map { [AgentChange.Look.needsLine($0)] } ?? [] : []
        if looked.since == nil, let elsewhere = looked.elsewhere { told.append(elsewhere) }
        if looked.since == nil, !looked.ways.isEmpty { told.append(AgentChange.Look.waysLine(looked.ways)) }
        let written = (header.prefix(1) + told + header.dropFirst() + body).joined(separator: "\n")
        let addressed = AIPage.addressesAI(written)
        var data: [String: Any] = ["title": tab.title, "url": AgentSecrets.shown(tab.pageAddress), "tab": short, "lines": header + body]
        if let since = looked.since {
            let object = since.object()
            for key in ["appeared", "went", "changed", "more"] { data[key] = object[key] }
            data["since"] = true
            data["elements"] = [[String: Any]]()
        } else {
            data["elements"] = looked.items
            data["cut"] = looked.cut
            data["shown"] = looked.shown
            data["total"] = looked.total
            data["scope"] = looked.scope
            data["regions"] = looked.regions
            if looked.unseen > 0 { data["hidden"] = looked.unseen }
            if let empty { data["empty"] = empty.kind }
            if let needs = looked.needs { data["needs"] = needs }
            if let elsewhere = looked.elsewhere { data["elsewhere"] = elsewhere }
            if let noted { data["skill"] = noted }
            if !looked.ways.isEmpty { data["ways"] = looked.ways }
            if looked.fresh, arguments["since"] as? Bool == true { data["fresh"] = true }
        }
        if addressed { data["warning"] = String(ToolReply.warning.dropLast()) }
        return ToolOutcome(text: ToolReply.notice + (addressed ? ToolReply.warning : "") + written, data: data)
    }

    static let providers: [String: (hosts: [String], names: Set<String>)] = [
        "Google": (["google.com"], ["SID", "__Secure-1PSID", "__Secure-3PSID"]),
        "GitHub": (["github.com"], ["user_session", "__Host-user_session_same_site"]),
        "Apple": (["apple.com"], ["myacinfo"]),
        "Microsoft": (["login.microsoftonline.com", "login.live.com", "live.com"], ["ESTSAUTHPERSISTENT", "ESTSAUTH", "MSPAuth"]),
        "Facebook": (["facebook.com"], ["c_user"]),
    ]

    func signedIn(_ ways: [String], tab: Tab) async -> [String] {
        let cookies = await tab.web.configuration.websiteDataStore.httpCookieStore.allCookies()
        return ways.filter { way in
            guard let known = Self.providers[way] else { return false }
            return cookies.contains { cookie in
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return known.names.contains(cookie.name) && known.hosts.contains { domain == $0 || domain.hasSuffix("." + $0) }
            }
        }
    }

    static let sessionCookie = try? NSRegularExpression(pattern: "sess|sid|auth|token|login|logged|user|account|remember|jwt", options: [.caseInsensitive])

    static func signsIn(_ cookie: HTTPCookie, site: String) -> Bool {
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard domain == site || domain.hasSuffix("." + site) else { return false }
        if providers.values.contains(where: { $0.names.contains(cookie.name) }) { return true }
        let name = cookie.name
        return sessionCookie?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    func signedInElsewhere(_ tab: Tab) async -> String? {
        guard tab.agent, browser?.prefs.usesSpaces ?? Shared.prefs.usesSpaces, let url = tab.pageAddress,
              let site = AgentSites.site(of: url) else { return nil }
        let mine = tab.web.configuration.websiteDataStore
        var seen: [WKWebsiteDataStore] = [mine]
        for space in browser?.spaces ?? Spaces.read() {
            let store = Spaces.store(for: space.id)
            guard !seen.contains(where: { $0 === store }) else { continue }
            seen.append(store)
            let cookies = await store.httpCookieStore.allCookies()
            guard cookies.contains(where: { Self.signsIn($0, site: site) }) else { continue }
            let name = space.name.contains(where: \.isWhitespace) ? "\"\(space.name)\"" : space.name
            return "signed in in \(space.name): broadway open \(AgentSecrets.shown(url)) --space \(name)"
        }
        return nil
    }

    func siteNote(_ tab: Tab, task: UUID?) -> String? {
        guard let url = tab.pageAddress, let host = url.host()?.lowercased(),
              let skill = siteNotes(url).first else { return nil }
        let key = "\(task?.uuidString ?? "-") \(PageIndex.bare(host))"
        guard !notesTold.contains(key) else { return nil }
        notesTold.insert(key)
        return skill.id
    }

    static func unseenLine(_ count: Int) -> String {
        count == 1 ? "(1 piece of text a person can't see left out)" : "(\(count) pieces of text a person can't see left out)"
    }

    func look(_ tab: Tab, task: UUID?) async -> AgentChange.Look? {
        guard case .success(let looked) = await walk(tab, ["limit": 40], task: task) else { return nil }
        let regions = looked.regions.compactMap { $0["role"] as? String }
        var header: [String] = looked.elsewhere.map { [$0] } ?? []
        if looked.modal { header.append("A dialog is open, so only it is shown (the page behind it: broadway snapshot --all)") }
        return AgentChange.Look(lines: looked.lines, elements: looked.items, shown: looked.shown, total: looked.total,
                                regions: regions, needs: looked.needs, ways: looked.ways, header: header)
    }
}
