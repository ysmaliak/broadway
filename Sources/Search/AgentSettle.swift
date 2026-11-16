import AppKit
import WebKit

@MainActor
final class AgentLoads: NSObject {
    private static var kept: [ObjectIdentifier: AgentLoads] = [:]
    private weak var web: WKWebView?
    private var open: [UInt64: (started: Date, stream: Bool)] = [:]
    private(set) var lastEnded = Date.distantPast

    static let longest: TimeInterval = 10

    static func on(_ web: WKWebView?) -> AgentLoads? {
        guard let web else { return nil }
        kept = kept.filter { $0.value.web != nil }
        let id = ObjectIdentifier(web)
        if let found = kept[id] { return found }
        let setter = NSSelectorFromString("_setResourceLoadDelegate:")
        guard web.responds(to: setter) else { return nil }
        let made = AgentLoads()
        made.web = web
        web.perform(setter, with: made)
        kept[id] = made
        return made
    }

    private nonisolated static func number(_ load: NSObject) -> UInt64? {
        guard load.responds(to: NSSelectorFromString("resourceLoadID")) else { return nil }
        return (load.value(forKey: "resourceLoadID") as? NSNumber)?.uint64Value
    }

    @objc(webView:resourceLoad:didSendRequest:)
    nonisolated func sent(_ web: WKWebView, resourceLoad: NSObject, didSendRequest request: NSURLRequest) {
        guard let id = Self.number(resourceLoad) else { return }
        let stream = (request.value(forHTTPHeaderField: "Accept") ?? "").contains("text/event-stream")
        MainActor.assumeIsolated { open[id] = (Date(), stream) }
    }

    @objc(webView:resourceLoad:didCompleteWithError:response:)
    nonisolated func ended(_ web: WKWebView, resourceLoad: NSObject, didCompleteWithError error: NSError?, response: URLResponse?) {
        guard let id = Self.number(resourceLoad) else { return }
        MainActor.assumeIsolated {
            if open.removeValue(forKey: id) != nil { lastEnded = Date() }
        }
    }

    func busy(since: Date, now: Date = Date()) -> Int {
        open.values.filter { !$0.stream && $0.started >= since && now.timeIntervalSince($0.started) < Self.longest }.count
    }
}

enum AgentSettleRule {
    static let quiet: TimeInterval = 0.5
    static let cap: TimeInterval = 5
    static let longest: TimeInterval = 30

    static func cap(_ arguments: [String: Any]) -> TimeInterval? {
        if arguments["settle"] as? Bool == false || arguments["no_settle"] as? Bool == true || arguments["no-settle"] as? Bool == true { return nil }
        guard let seconds = (arguments["settle"] as? NSNumber)?.doubleValue, !(arguments["settle"] is Bool) else { return cap }
        return seconds <= 0 ? nil : min(seconds, longest)
    }

    static func verdict(elapsed: TimeInterval, quietFor: TimeInterval, busy: Int, navigating: Bool, cap: TimeInterval) -> AgentChange.Settled? {
        if !navigating, busy == 0, quietFor >= quiet { return .quiet }
        if elapsed >= cap { return .capped }
        return nil
    }
}

struct AgentExpect: Equatable {
    var kind: String
    var want: String

    init?(_ arguments: [String: Any]) {
        if let object = arguments["expect"] as? [String: Any], let kind = object["kind"] as? String, let want = object["want"] as? String,
           ["text", "gone", "url"].contains(kind), !want.isEmpty {
            self.kind = kind
            self.want = want
            return
        }
        for (key, kind) in [("expect", "text"), ("expect_gone", "gone"), ("expect-gone", "gone"), ("expect_url", "url"), ("expect-url", "url")] {
            if let want = arguments[key] as? String, !want.isEmpty {
                self.kind = kind
                self.want = want
                return
            }
        }
        return nil
    }
}

struct AgentWatch {
    var tab: Tab
    var frame: WKFrameInfo?
    var doc: String?
    var started: Date
    var tabs: Set<UUID>
    var loads: AgentLoads?
    var who: String
}

@MainActor
final class AgentWatchBox {
    var watch: AgentWatch?
    var target: AgentChange.Element?
    var said: String?
    var notes: [String] = []
    var kept: [String: Any] = [:]
    var expectNavigation = false

    @TaskLocal static var current: AgentWatchBox?
}

@MainActor
enum AgentFilePicker {
    private static var asked: [ObjectIdentifier: Date] = [:]

    static func note(_ web: WKWebView) { asked[ObjectIdentifier(web)] = Date() }

    static func take(_ web: WKWebView?, since: Date) -> Bool {
        guard let web, let when = asked[ObjectIdentifier(web)] else { return false }
        asked[ObjectIdentifier(web)] = nil
        return when >= since
    }
}

@MainActor
enum AgentDialogsSeen {
    private static var told: [String: UUID] = [:]

    static func key(_ tab: Tab, _ who: String) -> String { "\(who)|\(tab.id.uuidString)" }

    static func tell(_ tab: Tab, who: String, _ question: PaneQuestion) { told[key(tab, who)] = question.id }

    static func last(_ tab: Tab, who: String) -> UUID? { told[key(tab, who)] }
}

@MainActor
enum AgentNoEffect {
    private static var counts: [String: (key: String, times: Int)] = [:]

    static func note(who: String, tab: Tab, did: String, target: String?, nothing: Bool) -> Int {
        let place = "\(who)|\(tab.id.uuidString)"
        let key = "\(did)|\(target ?? "")"
        guard nothing, target != nil else {
            counts[place] = nil
            return 0
        }
        let times = counts[place]?.key == key ? (counts[place]?.times ?? 0) + 1 : 1
        counts[place] = (key, times)
        return times
    }
}

extension AgentChange.Dialog {
    @MainActor
    init(_ question: PaneQuestion) {
        let kind: String
        switch question.kind {
        case .alert: kind = "alert"
        case .confirm: kind = "confirm"
        case .prompt: kind = "prompt"
        }
        self.init(id: question.id.uuidString, kind: kind, message: AgentSecrets.diagnostic(question.message), site: question.host)
    }
}

extension BrowserToolbox {
    static func who(_ task: UUID?) -> String {
        task.map { AgentTasks.shared.root($0).uuidString } ?? "none"
    }

    func timed(_ tab: Tab, _ script: String, _ arguments: [String: Any] = [:], in frame: WKFrameInfo? = nil, seconds: Double = 3) async -> Any? {
        guard let web = tab.built, tab.agentDialog?.open != true else { return nil }
        return await withCheckedContinuation { (done: CheckedContinuation<Any?, Never>) in
            var answered = false
            web.callAsyncJavaScript(script, arguments: arguments, in: frame, in: Web.world) { result in
                guard !answered else { return }
                answered = true
                done.resume(returning: try? result.get())
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                guard !answered else { return }
                answered = true
                done.resume(returning: nil)
            }
        }
    }

    func frameInfo(_ tab: Tab, _ ref: String) -> WKFrameInfo? {
        guard let frame = AgentRef(ref).frame, let token = tab.agentFrames[frame] else { return nil }
        return tab.fieldRelay.reach[token]
    }

    func sessionTabs(_ task: UUID?) -> Set<UUID> {
        guard let task else { return [] }
        let root = AgentTasks.shared.root(task)
        return Set(visible.filter { $0.tab.agentTask == root }.map(\.tab.id))
    }

    func mark(_ tab: Tab, ref: String = "", task: UUID?, keep: Bool = false) async {
        guard let box = AgentWatchBox.current, box.watch == nil else { return }
        let frame = frameInfo(tab, ref)
        let loads = AgentLoads.on(tab.built)
        if keep {
            box.watch = AgentWatch(tab: tab, frame: nil, doc: AgentRefBook.latest(tab), started: Date(), tabs: sessionTabs(task), loads: loads, who: Self.who(task))
            return
        }
        let begun = await timed(tab, AgentPage.beforeScript, [:], in: frame, seconds: 3) as? [String: Any]
        box.watch = AgentWatch(tab: tab, frame: frame, doc: begun?["doc"] as? String, started: Date(), tabs: sessionTabs(task), loads: loads, who: Self.who(task))
        if let doc = begun?["doc"] as? String, frame == nil { AgentRefBook.note(tab, doc: doc, title: tab.title, next: begun?["next"] as? Int) }
    }

    struct Settling {
        var settled: AgentChange.Settled
        var busy: Int
        var navigated: Bool
        var ms: Int
        var loading: Bool
        var expect: [String: Any]?
        var alerted: AgentChange.Dialog?
    }

    func settle(_ watch: AgentWatch, cap: TimeInterval?, expect: AgentExpect? = nil, navigation: Bool = false) async -> Settling {
        let tab = watch.tab
        let start = watch.started
        guard let cap else {
            return Settling(settled: .skipped, busy: 0, navigated: false, ms: 0, loading: tab.loading, expect: nil)
        }
        let limit = max(cap, expect == nil ? 0 : cap)
        var lastBusy = start
        var navigated = false
        var expected: [String: Any]?
        var alerted: AgentChange.Dialog?
        while true {
            let now = Date()
            let elapsed = now.timeIntervalSince(start)
            if let question = tab.agentDialog, question.open, case .alert = question.kind, alerted == nil {
                alerted = AgentChange.Dialog(question)
                question.answer(ok: true, text: nil)
                tab.agentDialog = nil
                lastBusy = now
            }
            if tab.agentDialog?.open == true {
                return Settling(settled: .dialog, busy: 0, navigated: navigated, ms: Int(elapsed * 1000), loading: tab.loading, expect: expected, alerted: alerted)
            }
            let poll = await timed(tab, AgentPage.pollScript, [:], in: watch.frame, seconds: 0.4) as? [String: Any]
            if tab.agentDialog?.open == true { continue }
            if let doc = poll?["doc"] as? String, let was = watch.doc, doc != was { navigated = true }
            let ready = poll?["ready"] as? String ?? "loading"
            let navigating = (tab.loading && (!navigated || ready == "loading")) || (navigation && !navigated && elapsed < cap && tab.loading)
            let busy = watch.loads?.busy(since: start, now: now) ?? 0
            if busy > 0 { lastBusy = now }
            if watch.loads == nil, let last = tab.devLog.entries.last(where: { $0.kind == .request && $0.recorded >= start })?.recorded, last > lastBusy {
                lastBusy = last
            }
            let mutationQuiet = poll.map { ($0["quiet"] as? Double ?? 0) / 1000 } ?? 0
            let quietFor = min(mutationQuiet, now.timeIntervalSince(lastBusy))
            if let expect, expected?["met"] as? Bool != true, !navigating {
                if await met(expect, tab: tab, frame: watch.frame) {
                    expected = ["kind": expect.kind, "want": expect.want, "met": true, "after": (elapsed * 10).rounded() / 10]
                    return Settling(settled: navigated ? .navigated : .quiet, busy: 0, navigated: navigated, ms: Int(elapsed * 1000), loading: tab.loading, expect: expected, alerted: alerted)
                }
            }
            if expect == nil || elapsed >= limit {
                if let verdict = AgentSettleRule.verdict(elapsed: elapsed, quietFor: quietFor, busy: busy, navigating: navigating, cap: limit) {
                    if let expect { expected = ["kind": expect.kind, "want": expect.want, "met": false, "after": (elapsed * 10).rounded() / 10] }
                    let settled: AgentChange.Settled = verdict == .quiet && navigated ? .navigated : verdict
                    return Settling(settled: settled, busy: busy, navigated: navigated, ms: Int(elapsed * 1000), loading: tab.loading, expect: expected, alerted: alerted)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func met(_ expect: AgentExpect, tab: Tab, frame: WKFrameInfo?) async -> Bool {
        switch expect.kind {
        case "url":
            return (tab.pageAddress?.absoluteString ?? "").localizedCaseInsensitiveContains(expect.want)
        default:
            let there = await pageSays(tab, expect.want)
            return expect.kind == "gone" ? there == false : there == true
        }
    }

    func pageSays(_ tab: Tab, _ words: String) async -> Bool? {
        let script = AgentPage.walkBase + """

        var want = String(words).toLowerCase().replace(/\\s+/g, ' ').trim();
        var body = document.body ? broadwayVisibleText(document.body) : '';
        if (body.toLowerCase().replace(/\\s+/g, ' ').indexOf(want) >= 0) return true;
        var fields = document.querySelectorAll('input,textarea');
        for (var i = 0; i < fields.length; i++) {
          if (broadwaySecret(fields[i]) || fields[i].type === 'hidden') continue;
          if (String(fields[i].value || '').toLowerCase().indexOf(want) >= 0) return true;
        }
        return false;
        """
        var found = await timed(tab, script, ["words": words], seconds: 1) as? Bool
        if found == true { return true }
        let home = AgentSites.site(of: tab.pageAddress)
        for frame in tab.fieldRelay.reach.values where AgentSites.site(of: URL(string: "https://\(frame.securityOrigin.host)")) == home {
            if await timed(tab, script, ["words": words], in: frame, seconds: 1) as? Bool == true { return true }
            found = found ?? false
        }
        return found
    }

    func answered(_ name: String, _ arguments: [String: Any], tab: Tab, task: UUID?, body: () async -> ToolOutcome) async -> ToolOutcome {
        if AgentWatchBox.current != nil { return await body() }
        let box = AgentWatchBox()
        let said = await AgentWatchBox.$current.withValue(box) { await body() }
        guard !said.failed else { return said }
        var kept = said.data ?? [:]
        if kept.isEmpty, let text = said.text, !text.isEmpty, (try? JSONSerialization.jsonObject(with: Data(text.utf8))) == nil { kept["said"] = text }
        for (key, value) in box.kept { kept[key] = value }
        return await finish(box, did: name, arguments: arguments, tab: tab, task: task, kept: kept)
    }

    static func did(_ name: String) -> String {
        switch name {
        case "navigate": "go"
        case "fill_form": "fill"
        default: name
        }
    }

    func finish(_ box: AgentWatchBox, did name: String, arguments: [String: Any], tab: Tab, task: UUID?, kept given: [String: Any]) async -> ToolOutcome {
        let did = Self.did(name)
        var kept = given
        kept.removeValue(forKey: "message")
        kept.removeValue(forKey: "ok")
        let short = String(tab.id.uuidString.prefix(8)).lowercased()
        guard let watch = box.watch else {
            var change = AgentChange(tab: short, did: did, said: box.said, target: box.target, settled: .skipped,
                                     page: AgentChange.Page(url: AgentSecrets.shown(tab.pageAddress), title: tab.title), kept: kept)
            change.notes = box.notes
            return outcome(change, tab: tab, task: task)
        }
        let settling = await settle(watch, cap: AgentSettleRule.cap(arguments), expect: AgentExpect(arguments), navigation: box.expectNavigation)
        var change = AgentChange(tab: short, did: did, said: box.said, target: box.target, settled: settling.settled, ms: settling.ms,
                                 page: AgentChange.Page(url: AgentSecrets.shown(tab.pageAddress), title: tab.title), kept: kept)
        change.notes = box.notes
        change.expect = settling.expect
        change.alerted = settling.alerted
        if settling.settled == .capped { change.busy = AgentChange.Busy(requests: settling.busy) }
        if let question = tab.agentDialog, question.open {
            change.settled = .dialog
            change.dialog = AgentChange.Dialog(question)
            AgentDialogsSeen.tell(tab, who: watch.who, question)
        } else if let after = await timed(tab, AgentPage.afterScript, ["who": watch.who, "most": 40], in: watch.frame, seconds: 4) as? [String: Any] {
            let fresh = after["fresh"] as? Bool == true || (watch.doc != nil && after["doc"] as? String != watch.doc)
            if let doc = after["doc"] as? String, watch.frame == nil { AgentRefBook.note(tab, doc: doc, title: tab.title, next: after["next"] as? Int) }
            if fresh, watch.frame == nil {
                change.page.navigated = true
                if change.settled == .quiet { change.settled = .navigated }
                change.headings = after["headings"] as? [String] ?? []
                if let look = await look(tab, task: task) { change.look = look }
            } else {
                change.appeared = (after["appeared"] as? [Any] ?? []).compactMap { AgentChange.Element(object: $0) }
                change.went = (after["went"] as? [Any] ?? []).compactMap { AgentChange.Element(object: $0) }
                change.changed = (after["changed"] as? [Any] ?? []).compactMap { AgentChange.Changed(object: $0) }
                change.text = (after["text"] as? [[String: Any]] ?? []).map { AgentChange.TextChange(was: $0["was"] as? String ?? "", now: $0["now"] as? String ?? "") }
                change.more = after["more"] as? Int ?? 0
                let counted = after["counted"] as? Int ?? 0
                let total = max(after["total"] as? Int ?? 0, 1)
                if counted > 60 || (counted * 3 > total * 2 && counted > 8), let look = await look(tab, task: task) {
                    change.look = look
                    change.most = true
                }
            }
        }
        let now = sessionTabs(task)
        let opened = visible.filter { now.contains($0.tab.id) && !watch.tabs.contains($0.tab.id) && $0.tab.id != tab.id }
        change.tabs.opened = opened.map { AgentChange.OpenedTab(id: String($0.tab.id.uuidString.prefix(8)).lowercased(), title: $0.tab.title, url: AgentSecrets.shown($0.tab.pageAddress)) }
        if let record = AgentDownloadWatch.latest(tab.id, since: watch.started) {
            let row = record.row
            change.download = AgentChange.Download(name: row["name"] as? String ?? record.source?.lastPathComponent ?? "", state: record.done ? "done" : "started",
                                                   path: record.done ? row["path"] as? String : nil)
        }
        if change.settled == .capped, settling.loading { change.notes.append("The page is still loading") }
        if AgentFilePicker.take(tab.built, since: watch.started) {
            let ref = change.target.map { "@\($0.ref)" } ?? "REF"
            change.notes.append("A file picker opened and Broadway closed it, so put a file on the page with broadway upload \(ref) PATH")
            change.kept["picker"] = ["closed": true]
        }
        let times = AgentNoEffect.note(who: watch.who, tab: tab, did: did, target: change.target?.ref, nothing: change.nothing)
        if times >= 2 { change.notes.append("\(did) on this target had no effect \(times) times, so try another way or ask the person") }
        return outcome(change, tab: tab, task: task)
    }

    func outcome(_ change: AgentChange, tab: Tab, task: UUID?) -> ToolOutcome {
        let lines = change.lines().joined(separator: "\n")
        let addressed = AIPage.addressesAI(lines)
        TaskLedger.shared.saw(tab.pageAddress, addressed: addressed, task: task)
        var data = change.object()
        if addressed { data["warning"] = String(ToolReply.warning.dropLast()) }
        return ToolOutcome(text: ToolReply.notice + (addressed ? ToolReply.warning : "") + lines, data: data)
    }
}

@MainActor
enum AgentRefBook {
    struct Page {
        var doc: String
        var title: String
        var next: Int
    }

    private static var pages: [UUID: [Page]] = [:]

    static func note(_ tab: Tab, doc: String, title: String, next: Int?) {
        var list = pages[tab.id] ?? []
        if let index = list.firstIndex(where: { $0.doc == doc }) {
            list[index].title = title.isEmpty ? list[index].title : title
            list[index].next = max(list[index].next, next ?? 0)
        } else {
            list.append(Page(doc: doc, title: title, next: next ?? 0))
            if list.count > 4 { list.removeFirst() }
        }
        pages[tab.id] = list
    }

    static func latest(_ tab: Tab) -> String? { pages[tab.id]?.last?.doc }

    private static var told: [String: (doc: String, refs: Set<String>)] = [:]

    static func key(_ task: UUID?, _ tab: Tab) -> String {
        "\(task.map { AgentTasks.shared.root($0).uuidString } ?? "-")|\(tab.id.uuidString)"
    }

    static func tell(_ task: UUID?, _ tab: Tab, doc: String, refs: Set<String>) {
        let key = key(task, tab)
        if told[key]?.doc != doc { told[key] = (doc, []) }
        told[key]?.refs.formUnion(refs)
    }

    static func wasTold(_ task: UUID?, _ tab: Tab, doc: String?, ref: String) -> Bool? {
        guard let page = told[key(task, tab)] else { return nil }
        return page.doc == doc && page.refs.contains(ref)
    }

    static func refs(in data: [String: Any]) -> Set<String> {
        let navigated = (data["page"] as? [String: Any])?["navigated"] as? Bool == true
        var found: Set<String> = []
        func walk(_ value: Any, key: String?) {
            if key == "went" || (navigated && key == "target") { return }
            if let object = value as? [String: Any] {
                if let ref = object["ref"] as? String { found.insert(ref) }
                for (name, inner) in object where name != "ref" { walk(inner, key: name) }
            } else if let list = value as? [Any] {
                for inner in list { walk(inner, key: key) }
            }
        }
        walk(data, key: nil)
        return found
    }

    static func earlier(_ tab: Tab, ref: String, now doc: String?) -> Page? {
        guard let number = Int(ref.dropFirst()), ref.hasPrefix("e") else { return nil }
        return pages[tab.id]?.reversed().first { $0.doc != doc && $0.next > number }
    }
}
