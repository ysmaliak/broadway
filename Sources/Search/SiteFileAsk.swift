import AppKit
import Observation
import WebKit

@MainActor
@Observable
final class SiteFileAsk {
    static let shared = SiteFileAsk()

    struct Began {
        let tab: Tab.ID
        let clickTab: Tab.ID
        let page: URL?
        let start: FileStart
        let store: String
    }

    private struct Waiting {
        let tab: Tab.ID
        let card: UUID
        let store: String
        let download: ObjectIdentifier
        let reply: (Bool) -> Void
    }

    private(set) var cards: [Tab.ID: FileCards] = [:]
    @ObservationIgnored private var began: [ObjectIdentifier: Began] = [:]
    @ObservationIgnored private var waiting: [UUID: Waiting] = [:]
    @ObservationIgnored private var answers = SiteFileAnswers()
    @ObservationIgnored var publicHosts: Set<String> = []
    @ObservationIgnored private(set) var dropped: [String] = []

    func card(for tab: Tab.ID?) -> FileCard? {
        tab.flatMap { cards[$0]?.front }
    }

    func holds(_ download: WKDownload) -> Bool {
        let key = ObjectIdentifier(download)
        return waiting.values.contains { $0.download == key }
    }

    func note(_ download: WKDownload, _ began: Began) {
        self.began[ObjectIdentifier(download)] = began
    }

    func take(_ download: WKDownload) -> Began? {
        began.removeValue(forKey: ObjectIdentifier(download))
    }

    func kept(site: String, store: String) -> Bool? {
        answers.answer(site: site, store: store)
    }

    func local(_ host: String) -> Bool {
        !publicHosts.contains(host.lowercased()) && SiteFiles.local(host)
    }

    func ask(_ verdict: FileVerdict, download: WKDownload, tab: Tab.ID, store: String, site: String, host: String, name: String,
             more: Bool, then reply: @escaping (Bool) -> Void) {
        var deck = cards[tab] ?? FileCards()
        let file = UUID()
        guard let card = deck.add(verdict, file: file, name: name, site: site, host: host, more: more) else { return reply(true) }
        waiting[file] = Waiting(tab: tab, card: card, store: store, download: ObjectIdentifier(download), reply: reply)
        cards[tab] = deck
        if Store.testing { DownloadTrace.note("site-file-asked", ["name": name, "site": site, "kind": verdict == .askInsecure ? "insecure" : "site"]) }
    }

    func answer(_ id: UUID, allow: Bool) {
        guard let entry = cards.first(where: { $0.value.cards.contains { $0.id == id } }) else { return }
        var deck = entry.value
        guard let card = deck.answer(id) else { return }
        cards[entry.key] = deck.isEmpty ? nil : deck
        if card.kind == .site, let store = card.files.lazy.compactMap({ self.waiting[$0]?.store }).first {
            answers.keep(allow, site: card.site, store: store)
        }
        for file in card.files { waiting.removeValue(forKey: file)?.reply(allow) }
    }

    func downloadEnded(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        began.removeValue(forKey: key)
        for (file, wait) in waiting where wait.download == key { leave(file, allow: false) }
    }

    func tabClosed(_ ids: Set<Tab.ID>) {
        for (file, wait) in waiting where ids.contains(wait.tab) { leave(file, allow: false) }
    }

    func forget(store: String) {
        answers.forget(store: store)
    }

    func forgetAll() {
        answers = SiteFileAnswers()
        dropped = []
    }

    func cancelAll() {
        for file in Array(waiting.keys) { leave(file, allow: false) }
    }

    private func leave(_ file: UUID, allow: Bool) {
        guard let wait = waiting.removeValue(forKey: file) else { return }
        if var deck = cards[wait.tab] {
            _ = deck.leave(file)
            cards[wait.tab] = deck.isEmpty ? nil : deck
        }
        wait.reply(allow)
    }

    func dropping(_ name: String) {
        if Store.testing { dropped.append(name) }
    }

    func state() -> [String: Any] {
        [
            "cards": cards.flatMap { tab, deck in
                deck.cards.enumerated().map { index, card -> [String: Any] in
                    ["id": card.id.uuidString.lowercased(), "tab": tab.uuidString.lowercased(), "kind": card.kind == .site ? "site" : "insecure",
                     "title": card.title, "text": card.text ?? "", "files": card.names, "front": index == 0,
                     "allow": card.allow, "deny": card.deny]
                }
            },
            "kept": answers.count,
            "public": Array(publicHosts).sorted(),
            "dropped": dropped,
        ]
    }

    static func storeKey(_ store: WKWebsiteDataStore) -> String {
        String(describing: ObjectIdentifier(store))
    }

    static func site(of url: URL?) -> String? {
        guard let host = url?.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if Hosts.isAddress(host) { return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
        return Hosts.display(Vault.registrable(Hosts.ascii(host)))
    }
}

extension Browser {
    func noteFileAction(_ action: WKNavigationAction, in webView: WKWebView) {
        guard action.targetFrame?.isMainFrame == true, let tab = popupTab(for: webView) else { return }
        let flag: (String) -> Bool = { key in
            action.responds(to: NSSelectorFromString(key)) && (action.value(forKey: key) as? Bool) == true
        }
        if flag("_isRedirect") { return }
        let own = (webView as? PageView)?.started.map { started in
            action.responds(to: NSSelectorFromString("_mainFrameNavigation")) && (action.value(forKey: "_mainFrameNavigation") as AnyObject?) === started
        } ?? false
        tab.fileTyped = own
    }

    func noteFileBegan(_ download: WKDownload, from webView: WKWebView?, start: FileStart) {
        guard let webView, let tab = anyTab(for: webView) else { return }
        let all = tabs + parkedTabs
        let opener = tab.committed == nil ? tab.opener.flatMap { id in all.first { $0.id == id } } : nil
        let clickTab = opener ?? tab
        let typed = start == .page && tab.fileTyped && tab.committed == nil
        if start == .page, tab.fileTyped { tab.fileTyped = false }
        let page = typed ? nil : clickTab.committed
        let leaving = tab.committed == nil && tab.pin == nil && opener != nil && tabs.count > 1
        SiteFileAsk.shared.note(download, SiteFileAsk.Began(
            tab: leaving ? clickTab.id : tab.id, clickTab: clickTab.id, page: page,
            start: typed ? .typed : start, store: SiteFileAsk.storeKey(webView.configuration.websiteDataStore)))
    }

    func gateSiteFile(_ download: WKDownload, response: URLResponse, name: String, agent: Bool,
                      then go: @escaping () -> Void, drop: @escaping () -> Void) -> Bool {
        let ask = SiteFileAsk.shared
        guard let began = ask.take(download) else { return false }
        let all = tabs + parkedTabs
        let clickTab = all.first { $0.id == began.clickTab }
        guard let url = response.url ?? download.originalRequest?.url else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        let clicked = began.start == .page && clickTab?.fileClicks.take(at: now) == true
        let facts = FileFacts(start: began.start, agent: agent || clickTab?.agent == true, clicked: clicked, url: url,
                              pageSecure: began.page?.scheme?.lowercased() == "https")
        let site = SiteFileAsk.site(of: began.page) ?? SiteFileAsk.site(of: url) ?? ""
        let verdict = SiteFiles.verdict(facts, kept: ask.kept(site: site, store: began.store), local: ask.local)
        switch verdict {
        case .go:
            return false
        case .drop:
            ask.dropping(name)
            drop()
            return true
        case .askSite, .askInsecure:
            let host = url.host(percentEncoded: false).map { Hosts.display(Hosts.ascii($0)) } ?? site
            let more = verdict == .askSite && clickTab?.fileClicks.spentLately(at: now) == true
            ask.ask(verdict, download: download, tab: began.tab, store: began.store, site: site, host: host, name: name, more: more) { [weak self] allowed in
                self?.fetches.heldChanged()
                if allowed { go() } else { ask.dropping(name); drop() }
            }
            fetches.heldChanged()
            return true
        }
    }

    func dropSiteFile(_ download: WKDownload) {
        if let ended = fetches.destinationCancelled(download) {
            ended.owner.relinquish(download)
        } else {
            relinquish(download)
        }
    }

    func answerFileCard(allow: Bool, id: UUID? = nil) {
        let ask = SiteFileAsk.shared
        guard let card = id.map({ id in ask.cards.values.lazy.compactMap { $0.cards.first { $0.id == id } }.first }) ?? ask.card(for: activeID)
        else { return }
        ask.answer(card.id, allow: allow)
    }

    func escapeFileCard() -> Bool {
        guard let card = SiteFileAsk.shared.card(for: activeID), card.kind == .insecure else { return false }
        answerFileCard(allow: false, id: card.id)
        return true
    }
}

final class SiteFileQuestionView: QuestionView {
    let browser: Browser
    let title: SiteWrapLabel
    let detail: SiteWrapLabel
    private var keys: [KitGlassKey] = []
    var card: FileCard { didSet { if card != oldValue { refresh() } } }
    static let most: CGFloat = 420

    init(browser: Browser, card: FileCard) {
        self.browser = browser
        self.card = card
        title = SiteWrapLabel(card.title, font: .systemFont(ofSize: 13, weight: .semibold), color: KitColor.ink)
        detail = SiteWrapLabel(card.text ?? "", font: .systemFont(ofSize: 12), color: KitColor.muted)
        super.init(radius: 16, leading: 16, trailing: 16, vertical: 12)
        body.addSubview(title)
        body.addSubview(detail)
        identifier = NSUserInterfaceItemIdentifier("site.file.question")
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title.text = card.title
        detail.text = card.text ?? ""
        detail.isHidden = card.text == nil
        keys.forEach { $0.removeFromSuperview() }
        let id = card.id
        let insecure = card.kind == .insecure
        let deny = KitGlassKey(title: card.deny, kind: insecure ? .primary : .secondary) { [weak browser] in browser?.answerFileCard(allow: false, id: id) }
        let allow = KitGlassKey(title: card.allow, kind: insecure ? .secondary : .primary) { [weak browser] in browser?.answerFileCard(allow: true, id: id) }
        keys = insecure ? [allow, deny] : [deny, allow]
        keys.forEach(body.addSubview)
        setAccessibilityLabel(card.text.map { card.title + ", " + $0 } ?? card.title)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override func arrange(_ width: CGFloat?, place: Bool) -> NSSize {
        let actions = buttonsRow(keys, spacing: SurfaceLook.keyGap)
        let natural = max(QuestionView.width(title), card.text == nil ? 0 : QuestionView.width(detail), actions)
        let wide = min(Self.most, width ?? natural, natural)
        let titleHeight = QuestionView.height(title, width: wide)
        let detailHeight = card.text == nil ? 0 : QuestionView.height(detail, width: wide)
        let keyHeight = keys.map(\.intrinsicContentSize.height).max() ?? 0
        var y: CGFloat = 0
        if place { put(title, NSRect(x: 0, y: y, width: wide, height: titleHeight)) }
        y += titleHeight
        if card.text != nil {
            y += 2
            if place { put(detail, NSRect(x: 0, y: y, width: wide, height: detailHeight)) }
            y += detailHeight
        }
        y += 12
        if place {
            var x = wide
            for key in keys.reversed() {
                let size = key.intrinsicContentSize
                x -= size.width
                put(key, NSRect(x: x, y: y + (keyHeight - size.height) / 2, width: size.width, height: size.height))
                x -= SurfaceLook.keyGap
            }
        }
        return NSSize(width: wide, height: y + keyHeight)
    }
}

@MainActor
enum BenchSiteFiles {
    static let verbs: Set<String> = ["sitefiles"]

    static func run(_ request: [String: Any], _ browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "sitefiles only works on a --test run"]) }
        let ask = SiteFileAsk.shared
        let id = (request["id"] as? String).flatMap(UUID.init(uuidString:))
        switch request["action"] as? String ?? "state" {
        case "allow", "deny":
            let owner = Browsers.all.first { owner in owner.tabs.contains { tab in ask.cards[tab.id] != nil } } ?? browser
            guard id != nil || ask.card(for: owner.activeID) != nil else { return answer(["error": "no card is up to answer"]) }
            owner.answerFileCard(allow: request["action"] as? String == "allow", id: id)
        case "public":
            guard let host = request["host"] as? String, !host.isEmpty else { return answer(["error": "sitefiles public needs a host"]) }
            ask.publicHosts.insert(host.lowercased())
        case "local":
            ask.publicHosts = []
        case "forget":
            ask.forgetAll()
        case "state":
            break
        default:
            return answer(["error": "sitefiles takes state, allow, deny, public HOST, local or forget"])
        }
        var state = ask.state()
        state["shown"] = Browsers.all.compactMap { ask.card(for: $0.activeID)?.title }
        answer(state)
    }
}
