import AppKit
import Foundation
import WebKit

@MainActor
enum PersonPages {
    static let hideForPrint = """
    function deep(root) {
      var all = root.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (el.shadowRoot) deep(el.shadowRoot);
        if (el.hasAttribute('data-broadway-secret')) el.style.setProperty('visibility', 'hidden', 'important');
      }
    }
    deep(document);
    return true;
    """

    static let showAfterPrint = """
    function deep(root) {
      var all = root.querySelectorAll('*');
      for (var i = 0; i < all.length; i++) {
        var el = all[i];
        if (el.shadowRoot) deep(el.shadowRoot);
        if (el.hasAttribute('data-broadway-secret')) el.style.removeProperty('visibility');
      }
    }
    deep(document);
    return true;
    """

    private static func web(_ call: PersonCall) throws -> (tab: Tab, browser: Browser) {
        let page = try call.page
        guard !page.tab.asleep, page.tab.isWeb else { throw PersonRefusal("not_a_page", "That tab isn't showing a web page") }
        if page.tab.agent { Bench.shared.house(page.tab) }
        return page
    }

    private static func leaves(_ page: (tab: Tab, browser: Browser)) throws {
        guard page.tab.agent || page.browser.active !== page.tab else {
            throw PersonRefusal("refused", "The person is on that tab, and an agent never takes it elsewhere. Use open for a tab of your own.")
        }
    }

    static func lines(of text: String, matching wanted: String, matchCase: Bool, words: Bool) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        var options: NSRegularExpression.Options = matchCase ? [] : [.caseInsensitive]
        options.insert(.ignoreMetacharacters)
        let pattern = words ? "\\b" + NSRegularExpression.escapedPattern(for: wanted) + "\\b" : wanted
        if words { options.remove(.ignoreMetacharacters) }
        guard let finder = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            let count = finder.numberOfMatches(in: line, range: NSRange(line.startIndex..., in: line))
            guard count > 0 else { continue }
            rows.append(["line": index + 1, "count": count, "text": String(line.prefix(240))])
        }
        return rows
    }

    static func pdf(_ tab: Tab) async throws -> Data {
        guard await AgentPage.shield(tab),
              await PageSelection.run(tab, hideForPrint) as? Bool == true else {
            throw PersonRefusal("refused", "That page can't be printed safely")
        }
        let made: Data? = await withCheckedContinuation { done in
            tab.web.createPDF(configuration: WKPDFConfiguration()) { done.resume(returning: try? $0.get()) }
        }
        _ = await PageSelection.run(tab, showAfterPrint)
        _ = await PageSelection.run(tab, AgentPage.unshieldScript)
        guard let made else { throw PersonRefusal("failed", "No PDF of that page") }
        return made
    }

    private static func fileName(_ tab: Tab) -> String {
        let bare = tab.title.components(separatedBy: CharacterSet(charactersIn: "/:\\\n\t")).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (bare.isEmpty ? "page" : String(bare.prefix(80))) + ".pdf"
    }

    private static func host(_ call: PersonCall) throws -> String {
        guard let host = call.browser.curtain.host(of: try web(call).tab.pageAddress) else { throw PersonRefusal("not_a_page", "That page has no site") }
        return host
    }

    private static func dress(_ call: PersonCall, _ tab: Tab, _ host: String) {
        let css = call.browser.curtain.css(on: host)
        tab.arm(hiding: css)
        tab.applyVeils(css)
    }

    static func safeSelector(_ selector: String) -> Bool {
        !selector.isEmpty && !selector.contains("{") && !selector.contains("}") && !selector.contains("<") && !AgentPage.readsFields(selector)
    }

    private static func permissions(of url: URL?) -> [[String: Any]] {
        guard let url, let scheme = url.scheme, let host = url.host() else { return [] }
        let origin = Browser.origin(scheme, host, url.port ?? 0)
        return SitePermissions.entries(for: origin, in: Store.settings.dictionaryRepresentation()).map { ["kind": $0.name, "allowed": $0.allowed] }
    }

    static let verbs: [PersonVerb] = [
        PersonVerb("page", "info", .look, tabbed: true) { call in
            let page = try call.page
            var data = call.box.describe(page.tab, page.browser)
            data["website"] = true
            data["zoom"] = Int((page.tab.zoom * 100).rounded())
            data["asleep"] = page.tab.asleep
            data["translated"] = page.tab.translation?.to ?? ""
            data["shields"] = !Shield.shared.isPaused(on: call.browser.curtain.host(of: page.tab.pageAddress)) && call.browser.prefs.shielded
            return data
        },
        PersonVerb("page", "reload", .arrange, tabbed: true) { call in
            let page = try web(call)
            try leaves(page)
            call.box.acting(page.tab, "Reloading")
            page.tab.reload()
            return ["message": "Reloading"]
        },
        PersonVerb("page", "back", .arrange, tabbed: true) { call in
            let page = try web(call)
            try leaves(page)
            call.box.acting(page.tab, "Going back")
            var warned = false
            if page.tab.agent { warned = await call.box.timed(page.tab, AgentPage.warnsScript, seconds: 1) as? Bool == true }
            page.tab.back()
            return warned ? ["message": "Back", "notice": AgentChange.warnedLine] : ["message": "Back"]
        },
        PersonVerb("page", "forward", .arrange, tabbed: true) { call in
            let page = try web(call)
            try leaves(page)
            call.box.acting(page.tab, "Going forward")
            var warned = false
            if page.tab.agent { warned = await call.box.timed(page.tab, AgentPage.warnsScript, seconds: 1) as? Bool == true }
            page.tab.forward()
            return warned ? ["message": "Forward", "notice": AgentChange.warnedLine] : ["message": "Forward"]
        },
        PersonVerb("page", "find", .look, tabbed: true) { call in
            let page = try web(call)
            call.box.acting(page.tab, "Reading")
            guard let read = await AIPage.read(page.tab) else { throw PersonRefusal("no_answer", "There's nothing to read on that page") }
            let rows = lines(of: read.text, matching: try call.need("text"), matchCase: call.flag("case"), words: call.flag("words"))
            return ["website": true, "count": rows.reduce(0) { $0 + ($1["count"] as? Int ?? 0) }, "matches": rows]
        },
        PersonVerb("page", "translate", .arrange, tabbed: true) { call in
            let page = try web(call)
            call.box.acting(page.tab, "Translating")
            let target = call.string("language").map { Locale.Language(identifier: $0) } ?? PageTranslator.reader(for: page.tab)
            let done: [String: Any] = await withCheckedContinuation { finish in
                var once = false
                _ = PageTranslator.start(page.tab, to: target) { said in
                    guard !once else { return }
                    once = true
                    finish.resume(returning: said)
                }
            }
            if let error = done["error"] as? String { throw PersonRefusal("failed", "Couldn't translate this page: \(error)") }
            return ["language": PageTranslator.code(target), "message": "Translated"]
        },
        PersonVerb("page", "original", .arrange, tabbed: true) { call in
            let page = try web(call)
            guard let translator = page.tab.translator else { throw PersonRefusal("refused", "That page isn't translated") }
            translator.end(restore: true)
            return ["message": "As it was written"]
        },
        PersonVerb("page", "pdf", .look, tabbed: true) { call in
            let page = try web(call)
            call.box.acting(page.tab, "Looking")
            return ["file": try await pdf(page.tab).base64EncodedString(), "name": fileName(page.tab), "website": true]
        },
        PersonVerb("page", "zoom", .arrange, tabbed: true, softer: { $0.string("value") == nil ? .look : nil }) { call in
            let page = try web(call)
            switch call.string("value") {
            case nil: break
            case "in": page.tab.magnify(by: 1.1)
            case "out": page.tab.magnify(by: 1 / 1.1)
            case "reset": page.tab.resetZoom()
            case let text?:
                guard let percent = Double(text.replacingOccurrences(of: "%", with: "")), (25...500).contains(percent) else {
                    throw PersonRefusal.usage("Zoom is a percent from 25 to 500, or in, out or reset")
                }
                page.tab.magnify(to: percent / 100)
            }
            return ["zoom": Int((page.tab.zoom * 100).rounded())]
        },
        PersonVerb("site", "info", .look, tabbed: true) { call in
            let page = try call.page
            let host = call.browser.curtain.host(of: page.tab.pageAddress)
            return ["site": host ?? "", "zoom": Int((page.tab.zoom * 100).rounded()), "hidden": call.browser.curtain.veils(on: host).count,
                    "shields": !Shield.shared.isPaused(on: call.browser.curtain.host(of: page.tab.pageAddress)) && call.browser.prefs.shielded,
                    "permissions": permissions(of: page.tab.pageAddress)]
        },
        PersonVerb("site", "hide", .arrange, tabbed: true) { call in
            let selector = try call.need("selector")
            guard safeSelector(selector) else { throw PersonRefusal("refused", "That selector can't be used: it reads a field, or it isn't a single selector") }
            let page = try web(call)
            let host = try host(call)
            call.browser.curtain.hide(selector, label: call.string("label") ?? selector, note: "", on: host)
            dress(call, page.tab, host)
            return ["site": host, "message": "Hidden on \(host)"]
        },
        PersonVerb("site", "hidden", .look, tabbed: true) { call in
            ["hidden": call.browser.curtain.veils(on: try host(call)).map {
                ["selector": $0.selector, "label": $0.label, "date": PersonCommands.stamp($0.date)]
            }]
        },
        PersonVerb("site", "unhide", .arrange, tabbed: true) { call in
            let page = try web(call)
            let host = try host(call)
            let curtain = call.browser.curtain
            if call.flag("all") {
                curtain.restoreAll(on: host)
            } else {
                let selector = try call.need("selector")
                guard let veil = curtain.veils(on: host).first(where: { $0.selector == selector }) else {
                    throw PersonRefusal.missing("hidden element", selector)
                }
                curtain.restore(veil, on: host)
            }
            dress(call, page.tab, host)
            return ["site": host, "message": "It's back"]
        },
    ]
}
