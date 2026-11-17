import AppKit
import Observation
import Combine

@MainActor
@Observable
final class SettingsShell {
    var trail = SettingsTrail(page: SettingsPage.named(Store.settings.string(forKey: "settings.page") ?? "") ?? .general)
    var query = ""
    var space: UUID?
    @ObservationIgnored var lit: String?

    var page: SettingsPage { trail.page }
    var hits: [SettingsItem] { SettingsIndex.find(query) }
    var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var title: String { searching ? "Search" : trail.detail?.title ?? page.title }

    func walk(_ change: (inout SettingsTrail) -> Void) {
        var next = trail
        change(&next)
        guard next != trail else { return }
        trail = next
    }

    func go(to page: SettingsPage) { walk { $0.go(to: page) } }

    func drill(_ detail: SettingsDetail) {
        query = ""
        walk { $0.open(detail) }
    }

    func follow(_ asked: String?) {
        guard let asked else { return }
        if let detail = SettingsDetail.named(asked) {
            drill(detail)
            return
        }
        guard let wanted = SettingsPage.named(asked), wanted != page || trail.detail != nil else { return }
        go(to: wanted)
    }

    func back() -> Bool {
        guard trail.canGoBack else { return false }
        walk { $0.back() }
        return true
    }

    func forward() -> Bool {
        guard trail.canGoForward else { return false }
        walk { $0.forward() }
        return true
    }

    func up() -> Bool {
        guard trail.detail != nil else { return false }
        walk { $0.up() }
        return true
    }
}

@MainActor
final class SettingsPageView: SettingsFormStack {
    let browser: Browser
    let shell: SettingsShell
    var prefs: Preferences { browser.prefs }
    var litAt: ((NSRect) -> Void)?
    var covered: ((NSPoint) -> Bool)?
    var pointed: (() -> Void)?
    private var hoverName: String?
    private var focusName: String?
    private var pointerLast = false
    private var lastPoint: NSPoint?
    private var area: NSTrackingArea?
    private var focusWatch: NSKeyValueObservation?
    private var scrollWatch: NSObjectProtocol?

    let drafts = SettingsDrafts()
    let linkDraft = SettingsLinkDraft()
    private var updates: [() -> Void] = []
    private var shapes: [(() -> AnyHashable, AnyHashable)] = []
    private var built: String?
    private var draft: Keyword?

    init(browser: Browser, shell: SettingsShell) {
        self.browser = browser
        self.shell = shell
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("settings.page")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var place: String {
        shell.searching ? "find:" + shell.query
            : shell.trail.detail.map { "detail:" + $0.rawValue + (shell.trail.folder.map { ":" + $0.uuidString } ?? "")
                + (shell.trail.space.map { ":space:" + $0.uuidString } ?? "") } ?? "page:" + shell.page.rawValue
    }

    func refresh() {
        if built != place || shapes.contains(where: { $0.0() != $0.1 }) {
            rebuild()
        } else {
            updates.forEach { $0() }
        }
    }

    func rebuild() {
        built = place
        updates = []
        shapes = []
        close()
        clear()
        top = !shell.searching && SettingsStageMap.pictured(shell.trail.here) ? SettingsStageLook.under : SettingsMetrics.top
        if shell.searching {
            results()
        } else if let detail = shell.trail.detail {
            head()
            drillPage(detail)
        } else {
            head()
            page(shell.page)
        }
        close()
        end(with: SettingsMetrics.foot)
        updates.forEach { $0() }
        if let lit = shell.lit {
            needsLayout = true
            layoutSubtreeIfNeeded()
            if let frame = frame(of: lit) { litAt?(frame) }
        }
        repoint()
    }

    private func head() {
        let place = shell.trail.here
        guard !SettingsStageMap.pictured(place) else { return }
        let made = SettingsHead()
        update { [weak self, weak made] in
            guard let self, let made else { return }
            let words = SettingsStageWords.head(place, browser: browser, space: spaceID)
            made.show(crumb: SettingsStageWords.crumb(place), title: words.title, summary: words.summary)
        }
        add(made, inset: SettingsMetrics.margin + SettingsMetrics.inset, top: SettingsHead.above, after: SettingsHead.below)
    }

    var heading: SettingsHead? { blocks.lazy.compactMap { $0.subviews.first as? SettingsHead }.first }

    var markedRow: String? {
        pointerLast && hoverName != nil ? hoverName : focusName ?? hoverName
    }

    var cards: [SettingsCard] { kitSubviews(of: SettingsCard.self) }

    func named(_ name: String) -> NSView? {
        for card in cards {
            if let row = card.rows.first(where: { card.name(of: $0) == name }) { return row }
        }
        return nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let made = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(made)
        area = made
    }

    override func mouseMoved(with event: NSEvent) { point(at: event.locationInWindow) }
    override func mouseEntered(with event: NSEvent) { point(at: event.locationInWindow) }
    override func mouseExited(with event: NSEvent) { point(at: nil) }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let scrollWatch { NotificationCenter.default.removeObserver(scrollWatch) }
        scrollWatch = nil
        guard let clip = superview as? NSClipView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollWatch = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.repoint() }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusWatch = window?.observe(\.firstResponder) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.focusMoved() }
        }
        focusMoved()
    }

    @discardableResult
    func point(at spot: NSPoint?) -> String? {
        lastPoint = spot
        var name: String?
        if let spot, covered?(spot) != true, visibleRect.contains(convert(spot, from: nil)) {
            for card in cards {
                guard let hit = card.row(at: card.convert(spot, from: nil)) else { continue }
                name = card.name(of: hit)
                break
            }
        }
        let before = markedRow
        hoverName = name
        pointerLast = true
        if markedRow != before { pointed?() }
        return name
    }

    private func repoint() {
        guard lastPoint != nil || hoverName != nil else { return }
        let last = pointerLast
        point(at: lastPoint)
        pointerLast = last
    }

    func focusMoved() {
        var view = window?.firstResponder as? NSView
        if let editor = view as? NSTextView, editor.isFieldEditor { view = editor.delegate as? NSView }
        var name: String?
        if let view, view.isDescendant(of: self) {
            for card in cards {
                guard let row = card.row(holding: view) else { continue }
                name = card.name(of: row)
                break
            }
        }
        guard name != focusName else { return }
        let before = markedRow
        focusName = name
        if name != nil { pointerLast = false }
        if markedRow != before { pointed?() }
    }

    func shape(_ value: @escaping () -> AnyHashable) {
        shapes.append((value, value()))
    }

    func update(_ run: @escaping () -> Void) { updates.append(run) }

    @discardableResult
    func row(_ id: String, control: NSView? = nil, wide: Bool = false, detail: (() -> String)? = nil) -> SettingsRowView {
        let item = SettingsIndex.item(id)
        let folded = false
        let base = item?.detail ?? ""
        let more = item?.more
        let line = folded ? [base, more ?? ""].filter { !$0.isEmpty }.joined(separator: base.isEmpty ? "" : ". ") : base
        let made = SettingsRowView(id: id, symbol: item?.icon, title: item?.title ?? id, detail: line,
                                   more: folded ? nil : more, wide: wide || item?.kind == .wide, control: control)
        made.lit = shell.lit == id
        if let control, !(control is SettingsPopUp) { control.kitAccess(id: "settings." + id, label: item?.title ?? id) }
        if let detail {
            update { [weak made] in
                let said = detail()
                made?.say(folded && said == base ? line : said)
            }
        }
        if let item, !SettingsIndex.applies(item, prefs) {
            made.say(SettingsIndex.needs(item))
            made.dim(true)
        }
        put(made)
        return made
    }

    func line(_ title: String, _ detail: String? = nil, symbol: String? = nil, id: String? = nil, control: NSView? = nil) -> SettingsRowView {
        let made = SettingsRowView(id: id ?? title, symbol: symbol, title: title, detail: detail ?? "", control: control)
        control?.kitAccess(label: title)
        put(made)
        return made
    }

    func drillRow(_ detail: SettingsDetail, line: String? = nil, count: (() -> Int?)? = nil, value: (() -> String?)? = nil) {
        let id = detail.item ?? "detail." + detail.rawValue
        let item = SettingsIndex.item(id)
        let made = SettingsDrillRow(id: id, symbol: item?.icon ?? detail.symbol, title: item?.title ?? detail.title,
                                    line: line ?? item?.detail) { [weak self] in self?.shell.drill(detail) }
        made.lit = shell.lit == id
        made.identifier = NSUserInterfaceItemIdentifier("detail." + detail.rawValue)
        update { [weak made] in
            made?.mark.show(count: count?(), value: nil)
            made?.tell(value?())
        }
        put(made)
    }

    func toggle(_ id: String, get: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> KitSwitch {
        let made = KitSwitch(isOn: get(), small: true, system: true)
        made.onChange = set
        update { [weak made] in made?.set(get(), animated: true) }
        made.kitAccess(id: "settings." + id)
        return made
    }

    func flag(_ id: String, _ path: ReferenceWritableKeyPath<Preferences, Bool>, detail: (() -> String)? = nil) {
        let prefs = prefs
        row(id, control: toggle(id, get: { prefs[keyPath: path] }, set: { prefs[keyPath: path] = $0 }), detail: detail)
    }

    func button(_ title: String, primary: Bool = false, act: @escaping () -> Void) -> SettingsPill {
        SettingsPill(title, kind: primary ? .primary : .secondary, action: act)
    }

    func popUp(_ id: String, titles: [String], picked: @escaping () -> Int, set: @escaping (Int) -> Void) -> SettingsPopUp {
        let holder = SettingsPopUp()
        let made = holder.button
        made.addItems(withTitles: titles)
        made.kitOnChange { set(($0 as? NSPopUpButton)?.indexOfSelectedItem ?? 0) }
        update { [weak made] in
            let at = picked()
            if made?.indexOfSelectedItem != at { made?.selectItem(at: at) }
        }
        made.kitAccess(id: "settings." + id)
        return holder
    }

    func choice(_ id: String, _ options: [String], picked: @escaping () -> Int, set: @escaping (Int) -> Void) -> KitChoice {
        let made = KitChoice(SettingsIndex.item(id)?.title ?? id, options: options.map { KitChoice.Option(title: $0) }, picked: picked())
        made.pick = set
        update { [weak made] in
            let at = picked()
            if made?.picked != at { made?.picked = at }
        }
        made.kitAccess(id: "settings." + id)
        return made
    }

    func pictures(_ id: String, _ titles: [String], scenes: @escaping () -> [WindowScene], picked: @escaping () -> Int,
                  set: @escaping (Int) -> Void) -> SettingsPictureChoice {
        let options = zip(titles, scenes()).map { SettingsPictureChoice.Option(title: $0, scene: $1) }
        let made = SettingsPictureChoice(SettingsIndex.item(id)?.title ?? id, options: options, picked: picked())
        made.pick = set
        update { [weak made] in
            made?.show(scenes: scenes())
            let at = picked()
            if made?.picked != at { made?.picked = at }
        }
        made.kitAccess(id: "settings." + id)
        return made
    }

    func lookRow() {
        let prefs = prefs
        let browser = browser
        let looks: [Look] = [.system, .light, .dark]
        row("look", control: pictures("look", ["Auto", "Light", "Dark"], scenes: {
            let base = WindowScene.live(prefs, browser.space.look)
            return looks.map { look in
                var scene = base
                scene.auto = look == .system
                scene.dark = look == .system ? nil : look == .dark
                return scene
            }
        }, picked: { looks.firstIndex(of: prefs.look) ?? 0 }, set: { prefs.look = looks[$0] }), wide: true)
    }

    func appIconRow() {
        let prefs = prefs
        let icons = AppIcon.allCases
        let options = icons.map { SettingsPictureChoice.Option(title: $0.title, picture: .appIcon($0.rawValue)) }
        let made = SettingsPictureChoice(SettingsIndex.item(AppIcon.key)?.title ?? AppIcon.key, options: options,
                                         picked: icons.firstIndex(of: prefs.appIcon) ?? 0)
        made.pick = { prefs.appIcon = icons[$0] }
        update { [weak made] in
            let at = icons.firstIndex(of: prefs.appIcon) ?? 0
            if made?.picked != at { made?.picked = at }
        }
        made.kitAccess(id: "settings." + AppIcon.key)
        row(AppIcon.key, control: made, wide: true)
    }

    func newTabRow() {
        let prefs = prefs
        let browser = browser
        row("newtab.floating", control: pictures("newtab.floating", ["Page", "Floating Field"], scenes: {
            let base = WindowScene.live(prefs, browser.space.look)
            return [false, true].map { floating in
                var scene = base
                scene.newTabPage = !floating
                scene.floatingField = floating
                return scene
            }
        }, picked: { prefs.floatingNewTab ? 1 : 0 }, set: { prefs.floatingNewTab = $0 == 1 }), wide: true)
    }

    func field(_ title: String, text: @escaping () -> String, prompt: String, secure: Bool = false, width: CGFloat? = 300,
               submit: (() -> Void)? = nil, set: @escaping (String) -> Void) -> NSTextField {
        let made: NSTextField = secure ? NSSecureTextField(string: text()) : NSTextField(string: text())
        made.placeholderString = prompt
        made.bezelStyle = .roundedBezel
        made.usesSingleLineMode = true
        made.lineBreakMode = .byTruncatingTail
        made.font = .systemFont(ofSize: 13)
        made.kitAccess(label: title)
        let watcher = SettingsFieldWatcher(set: set, submit: submit)
        made.delegate = watcher
        objc_setAssociatedObject(made, &SettingsFieldWatcher.key, watcher, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        update { [weak made] in
            guard let made, made.currentEditor() == nil, made.stringValue != text() else { return }
            made.stringValue = text()
        }
        made.translatesAutoresizingMaskIntoConstraints = false
        if let width { made.widthAnchor.constraint(equalToConstant: width).isActive = true }
        return made
    }

    func labeled(_ title: String, _ field: NSView) {
        let made = SettingsRowView(id: "field." + title, symbol: nil, title: title, control: field)
        put(made)
    }

    func note(_ text: String) {
        put(SettingsNothing(text))
    }

    func row(_ view: NSView) { put(view) }
}

final class SettingsFieldWatcher: NSObject, NSTextFieldDelegate {
    static var key: UInt8 = 0
    let set: (String) -> Void
    let submit: (() -> Void)?

    init(set: @escaping (String) -> Void, submit: (() -> Void)?) {
        self.set = set
        self.submit = submit
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        set(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)), let submit else { return false }
        submit()
        return true
    }
}

extension SettingsPageView {
    func page(_ page: SettingsPage) {
        switch page {
        case .general: general()
        case .field: addressField()
        case .appearance: appearance()
        case .websites: websites()
        case .links: links()
        case .tabs: tabs()
        case .shortcuts: hosted(SettingsForms.shortcuts(browser))
        case .passwords: passwords()
        case .privacy: privacy()
        case .agents: agents()
        case .liveFolders: liveFolders()
        case .extensions: hosted(SettingsForms.extensions(browser))
        }
    }

    func updatesVersionRow() {
        let updates = Updates.shared
        let check = button("Check Now") { [weak self] in
            updates.wait.staged == nil ? updates.check() : updates.restart(over: self?.window)
        }
        update { [weak check] in
            let waiting = updates.wait.staged != nil
            check?.title = waiting ? UpdateWords.restart : "Check Now"
            check?.isEnabled = waiting || updates.canCheck
            check?.superview?.needsLayout = true
        }
        row("updates.version", control: check, detail: { updates.line })
    }

    private func updatesSection() {
        let updates = Updates.shared
        section("Updates") {
            settingRow("updates.version")
            settingRow("updates.check")
            settingRow("updates.install")
            shape { updates.canInstall }
        }
    }

    func drillPage(_ detail: SettingsDetail) {
        switch detail {
        case .linkRule: linkRule()
        case .liveFolder: liveFolder()
        case .languages: languages()
        }
    }

    private func general() {
        let prefs = prefs
        section("The basics") {
            settingRow("general.default")
            settingRow("general.import")
            languagesRow()
        }
        section("Downloads") {
            settingRow("downloads.folder")
        }
        updatesSection()
        section("Help") {
            settingRow("support.email")
        }
        section("Calendars") {
            settingRow("calendars")
            shape { prefs.usesCalendars && Meetings.shared.hasAccess }
            if prefs.usesCalendars && Meetings.shared.hasAccess {
                settingRow("meetings.calendars")
                settingRow("meetings.faces")
            }
        }
        let info = Bundle.main.infoDictionary
        let version = "Broadway \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "dev"))"
        let foot = SettingsText(version, font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
        foot.alignment = .center
        foot.isSelectable = true
        foot.identifier = NSUserInterfaceItemIdentifier("settings.version")
        add(foot)
    }

    private func addressField() {
        let prefs = prefs
        section("Searching") {
            settingRow("search.engine")
            shape { prefs.engine == .custom }
            if prefs.engine == .custom {
                labeled("Search address", field("Search address", text: { prefs.customEngine },
                                                prompt: "https://example.com/search?q=%s", set: { prefs.customEngine = $0 }))
            }
            settingRow("search.suggest")
            settingRow(IntegrationNow.key)
        }
        section("Site shortcuts") {
            settingRow("search.keywords")
            if draft != nil {
                labeled("Word", field("Word", text: { [weak self] in self?.draft?.keyword ?? "" }, prompt: "yt",
                                      set: { [weak self] in
                                          self?.draft?.keyword = $0
                                          self?.refresh()
                                      }))
                labeled("Search address", field("Search address", text: { [weak self] in self?.draft?.template ?? "" },
                                                prompt: "https://www.youtube.com/results?search_query=%s",
                                                submit: { [weak self] in self?.saveDraft() },
                                                set: { [weak self] in
                                                    self?.draft?.template = $0
                                                    self?.refresh()
                                                }))
            }
            shape { prefs.keywords.map(\.id) }
            for entry in prefs.keywords {
                let remove = NSButton()
                remove.image = KitGlyph.plain("xmark.circle.fill", label: "Remove \(entry.keyword)")
                remove.isBordered = false
                remove.contentTintColor = .tertiaryLabelColor
                remove.kitOnChange { [weak self] _ in
                    SettingsQuestion.keyword(entry.keyword).ask(over: self?.window) { prefs.keywords.removeAll { $0.id == entry.id } }
                }
                remove.kitAccess(label: "Remove \(entry.keyword)")
                let made = line(entry.keyword, entry.template, id: "keyword." + entry.id.uuidString, control: remove)
                made.detail.lineBreakMode = .byTruncatingMiddle
            }
        }
        hosted(SettingsForms.quickActions(browser))
        section("Snippets") {
            snippets()
        }
    }

    private func appearance() {
        section("Look and new tabs") {
            settingRow("look")
            settingRow("newtab.floating")
        }
        homePage()
        section("App icon") {
            settingRow(AppIcon.key)
        }
        section("Sidebar") {
            settingRow("sidebar.button")
        }
    }

    private func websites() {
        let prefs = prefs
        section("Site permissions") {
            settingRow("notifications.ask")
            settingRow("privacy.forget")
            shape { SiteNotifications.allowed }
            for site in SiteNotifications.allowed {
                _ = line(URL(string: site).map(SiteCard.site) ?? site, "Can send notifications", id: "site.notify." + site,
                         control: button("Remove…") { [weak self] in
                             SettingsQuestion.notifications(URL(string: site).map(SiteCard.site) ?? site).ask(over: self?.window) {
                                 SiteNotifications.forget(site)
                                 self?.refresh()
                             }
                         })
            }
            shape { LocalNetworkGuard.sites.map { "\($0.origin)\($0.allowed)" } }
            for site in LocalNetworkGuard.sites {
                _ = line(URL(string: site.origin).map(SiteCard.site) ?? site.origin,
                         site.allowed ? "Can reach your local network" : "Can't reach your local network",
                         id: "site.network." + site.origin, control: button("Remove…") { [weak self] in
                             SettingsQuestion.localNetwork(URL(string: site.origin).map(SiteCard.site) ?? site.origin).ask(over: self?.window) {
                                 LocalNetworkGuard.shared.forget(site.origin)
                                 self?.refresh()
                             }
                         })
            }
        }
        shape { prefs.popupSites.sorted() }
        let sites = prefs.popupSites.sorted()
        if !sites.isEmpty {
            section("Pop-ups") {
                for site in sites {
                    _ = line(site, "Can open pop-ups without a click", id: "site.popup." + site, control: button("Remove…") { [weak self] in
                        SettingsQuestion.popups(site).ask(over: self?.window) { prefs.popupSites.remove(site) }
                    })
                }
            }
        }
        section("Pages") {
            settingRow("pageZoom")
            settingRow(PullRefresh.key)
        }
        section("Video") {
            settingRow("video.quality")
            settingRow("video.speed")
            videoSpeedSites()
        }
        section("Mini player") {
            miniPlayerRows()
        }
    }

    private func tabs() {
        let prefs = prefs
        shape { prefs.usesSpaces }
        if prefs.usesSpaces {
            section("Spaces") {
                settingRow("spaces.stacked")
            }
        }
        section("Folders") {
            groupTabsRow()
            openRouterRow()
        }
        section("Old tabs") {
            settingRow("tabs.close.after")
        }
    }

    func groupTabsRow() {
        let groups = AIGroups.shared
        let key = OpenRouterKey.shared
        shape { [groups.deciding != nil, key.present] }
        row("ai.groups", control: toggle("ai.groups", get: { groups.deciding != nil && groups.on }, set: { groups.on = $0 }),
            detail: { groups.sends })
    }

    func openRouterRow() {
        let key = OpenRouterKey.shared
        let groups = AIGroups.shared
        let drafts = drafts
        shape { key.state == .saved }
        let control: NSView
        if key.state == .saved {
            control = button("Remove") { [weak self] in
                key.remove()
                self?.refresh()
            }
        } else {
            let typed = field(AIGroupWords.keyTitle, text: { drafts.openRouterKey }, prompt: AIGroupWords.keyPrompt, secure: true, width: 190,
                              submit: { [weak self] in self?.saveOpenRouterKey() },
                              set: { [weak self] in
                                  drafts.openRouterKey = $0
                                  self?.refresh()
                              })
            typed.setAccessibilityIdentifier("settings.groups.openrouter.field")
            let add = button("Add", primary: true) { [weak self] in self?.saveOpenRouterKey() }
            update { [weak add] in add?.isEnabled = key.state != .checking && !OpenRouterKey.plain(drafts.openRouterKey).isEmpty }
            control = pair(typed, add)
        }
        row("groups.openrouter", control: control,
            detail: { AIGroupWords.keyLine(state: key.state, trouble: key.trouble, remoteDecides: groups.remoteDecides) })
    }

    func saveOpenRouterKey() {
        let drafts = drafts
        let typed = drafts.openRouterKey
        guard !OpenRouterKey.plain(typed).isEmpty, OpenRouterKey.shared.state != .checking else { return }
        let saving = Task { await OpenRouterKey.shared.save(typed) }
        refresh()
        Task { [weak self] in
            if await saving.value { drafts.openRouterKey = "" }
            self?.refresh()
        }
    }

    private func homePage() {
        let extensions = Extensions.shared
        shape { extensions.newTabAskers.map(\.id) }
        let askers = extensions.newTabAskers
        guard !askers.isEmpty else { return }
        section {
            let ids = [nil] + askers.map { Optional($0.id) }
            let pick = popUp("homepage", titles: ["Broadway's own"] + askers.map(\.name),
                             picked: { ids.firstIndex(of: extensions.newTabPageID) ?? 0 },
                             set: { extensions.setNewTabPage(ids[$0]) })
            let made = line("Home page", Self.homeDetail(askers, extensions.newTabPageID), symbol: "house", id: "homepage", control: pick)
            update { [weak made] in made?.detail.stringValue = Self.homeDetail(extensions.newTabAskers, extensions.newTabPageID) }
        }
    }

    private static func homeDetail(_ askers: [Installed], _ current: String?) -> String {
        if let current, let name = askers.first(where: { $0.id == current })?.name {
            return "New tabs show \(name)'s page, since you let it replace them"
        }
        return askers.count == 1
            ? "New tabs open blank. \(askers[0].name) asked to show its page instead."
            : "New tabs open blank. \(askers.count) extensions asked to show their page instead."
    }

    func keywordsRow() {
        let adding = NSStackView()
        adding.orientation = .horizontal
        adding.spacing = 6
        shape { [weak self] in self?.draft != nil }
        if draft == nil {
            adding.addArrangedSubview(button("Add") { [weak self] in
                self?.draft = Keyword()
                self?.leaveSearch(for: "search.keywords")
                self?.refresh()
            })
        } else {
            adding.addArrangedSubview(button("Cancel") { [weak self] in
                self?.draft = nil
                self?.refresh()
            })
            let save = button("Save", primary: true) { [weak self] in self?.saveDraft() }
            adding.addArrangedSubview(save)
            update { [weak self, weak save] in save?.isEnabled = self?.draftProblem == nil }
        }
        row("search.keywords", control: adding, detail: { [weak self] in self?.keywordDetail ?? "" })
    }

    private var draftProblem: String? {
        guard let draft else { return nil }
        return Keyword.problem(word: draft.keyword, template: draft.template, among: prefs.keywords)
    }

    private var keywordDetail: String {
        guard let draft else { return SettingsIndex.item("search.keywords")?.detail ?? "" }
        if draft.keyword.isEmpty, draft.template.isEmpty {
            return "A word, then the site's search address with %s where the words go"
        }
        return draftProblem ?? "\(draft.keyword.trimmingCharacters(in: .whitespacesAndNewlines)) will search \(draft.name)"
    }

    private func saveDraft() {
        guard let current = draft, draftProblem == nil else { return }
        prefs.keywords.append(Keyword(
            keyword: current.keyword.trimmingCharacters(in: .whitespacesAndNewlines),
            template: current.template.trimmingCharacters(in: .whitespacesAndNewlines)
        ))
        draft = nil
        refresh()
    }

    static func suggestDetail(_ prefs: Preferences) -> String {
        let name = prefs.engine.name(custom: prefs.customEngine)
        guard EngineSuggest.endpoint(for: prefs.engine) != nil else {
            return "A custom engine has no suggestions, so nothing is sent"
        }
        return "What you type is sent to \(name) as you type"
    }

    static func searchDetail(_ prefs: Preferences) -> String {
        guard prefs.engine == .custom else { return "Where words that aren't an address go" }
        guard Engine.accepts(prefs.customEngine) else {
            return "An http or https address with %s where the words go. Google until then."
        }
        return "Words go to \(prefs.engine.name(custom: prefs.customEngine))"
    }

    private func passwords() {
        section("Sign-ins") {
            settingRow("passwords.open")
            settingRow("passwords.fill")
            shape { Vault.never.isEmpty }
            if !Vault.never.isEmpty {
                settingRow("passwords.never")
            }
        }
        section("Apple Passwords") {
            settingRow("passwords.apple")
            applePairing()
        }
        section("One-time codes") {
            settingRow("codes.gmail")
        }
        section("Forms") {
            autofill()
        }
    }

    private func privacy() {
        let prefs = prefs
        let browser = browser
        let shield = Shield.shared
        section("Tracking") {
            settingRow("shield")
            shape { shield.trouble }
            if let trouble = shield.trouble {
                _ = line(trouble, "Nothing is being blocked until this clears. Try again, or restart Broadway.", id: "shield.trouble",
                         control: button("Try Again") { shield.compile() })
            }
            let host = browser.hereHost
            shape { [browser.hereHost ?? "", prefs.shielded ? "on" : "off"] }
            if let host, prefs.shielded, shield.trouble == nil {
                _ = line("Block on \(host)", "Turn off here if the site breaks. The page reloads.", symbol: "checkmark.shield", id: "shield.here",
                         control: toggle("shield.here", get: { !Shield.shared.isPaused(on: host) }, set: { on in
                             Shield.shared.pause(host, !on)
                             browser.reload()
                         }))
            }
            shape { shield.paused.sorted() }
            for site in shield.paused.sorted() {
                _ = line(site, "Ads and trackers are allowed here", id: "shield.paused." + site, control: button("Block Again") { [weak self] in
                    shield.pause(site, false)
                    self?.refresh()
                })
            }
            settingRow("sites.keep")
        }
        section("What Broadway keeps") {
            settingRow("history.pageText")
        }
        section("Danger zone") {
            for clearing in Browser.Clearing.allCases { settingRow(clearing.rawValue) }
        }
    }

    private func results() {
        let hits = shell.hits
        if hits.isEmpty {
            section { note("Nothing by that name. Try “dark”, “tabs” or “passwords”.") }
            return
        }
        let byGroup = Dictionary(grouping: hits, by: \.group)
        for group in SettingsIndex.groups where byGroup[group.id] != nil {
            let items = byGroup[group.id] ?? []
            let shown = items.first { !$0.findOnly && !SettingsIndex.doors.contains($0.id) }
            let title = "\(group.page.title)  ›  \(group.detail?.title ?? group.title)"
            add(SettingsResultHeading(title, name: "settings.result." + group.id) { [weak self] in
                guard let self else { return }
                shell.lit = shown?.id
                shell.query = ""
                if let detail = group.detail { shell.drill(detail) } else { shell.go(to: group.page) }
                unlightSoon()
            })
            section {
                for item in items { found(item) }
            }
        }
    }

    private func found(_ item: SettingsItem) {
        if item.kind == .note || item.findOnly {
            let always = SettingsText(item.findOnly && item.detail.hasPrefix("Always there") ? "Always on" : "", font: SettingsMetrics.titleFont,
                                      color: .secondaryLabelColor)
            put(SettingsRowView(id: item.id, symbol: item.icon, title: item.title, detail: item.detail, control: always))
            return
        }
        if let detail = SettingsDetail.opened(by: item.id) {
            if !settingRow(item.id) { drillRow(detail) }
            return
        }
        if SettingsIndex.doors.contains(item.id) {
            let page = item.page
            let made = SettingsDrillRow(id: item.id, symbol: item.icon, title: item.title, line: item.detail) { [weak self] in
                self?.shell.query = ""
                self?.shell.go(to: page)
            }
            made.identifier = NSUserInterfaceItemIdentifier("page." + page.rawValue)
            put(made)
            return
        }
        if !settingRow(item.id) { row(item.id) }
    }
}

final class SettingsResultHeading: NSView {
    private let act: () -> Void

    init(_ title: String, name: String, act: @escaping () -> Void) {
        self.act = act
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier(name)
        setAccessibilityIdentifier(name)
        let label = SettingsText(title, font: SettingsMetrics.headingFont)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.headingInset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsMetrics.headingGap),
        ])
        toolTip = "Open \(title)"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { act() }
    }

    override func mouseDown(with event: NSEvent) {}
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        act()
        return true
    }
}

final class SettingsDefaultMark: NSView {
    var make: (() -> Void)?
    private let done = NSStackView()
    private lazy var button = SettingsPill("Make Default", kind: .primary) { [weak self] in self?.make?() }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let check = KitSymbol("checkmark", style: KitSymbol.Style(size: 12, weight: .semibold), tint: .secondaryLabelColor)
        let label = SettingsText("Default", font: .systemFont(ofSize: 13), color: .secondaryLabelColor)
        done.orientation = .horizontal
        done.spacing = 4
        done.addArrangedSubview(check)
        done.addArrangedSubview(label)
        for view in [done, button] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
                view.centerYAnchor.constraint(equalTo: centerYAnchor),
                view.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            ])
        }
        button.kitAccess(label: "Make Default")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ isDefault: Bool) {
        done.isHidden = !isDefault
        button.isHidden = isDefault
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let shown: NSView = done.isHidden ? button : done
        return shown.fittingSize
    }
}

@MainActor
final class SettingsFolderPopUp: NSPopUpButton {
    private let prefs: Preferences

    init(prefs: Preferences) {
        self.prefs = prefs
        super.init(frame: .zero, pullsDown: false)
        kitOnChange { [weak self] _ in self?.picked() }
        show()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        removeAllItems()
        let folder = NSMenuItem(title: FileManager.default.displayName(atPath: prefs.downloads.path), action: nil, keyEquivalent: "")
        let icon = NSWorkspace.shared.icon(forFile: prefs.downloads.path)
        icon.size = NSSize(width: 16, height: 16)
        folder.image = icon
        folder.toolTip = prefs.downloads.path
        menu?.addItem(folder)
        menu?.addItem(.separator())
        menu?.addItem(NSMenuItem(title: "Ask Each Time", action: nil, keyEquivalent: ""))
        menu?.addItem(.separator())
        menu?.addItem(NSMenuItem(title: "Other…", action: nil, keyEquivalent: ""))
        selectItem(at: prefs.asksWhereToSave ? 2 : 0)
    }

    private func picked() {
        switch indexOfSelectedItem {
        case 2: prefs.asksWhereToSave = true
        case 4: choose()
        default: prefs.asksWhereToSave = false
        }
        show()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = prefs.downloads
        panel.prompt = "Use This Folder"
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.chose(response == .OK ? panel.url : nil)
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    func chose(_ folder: URL?) {
        if let folder {
            prefs.downloads = folder
            prefs.asksWhereToSave = false
        }
        show()
    }
}

@MainActor
final class SettingsCalendars: NSView {
    private let grid = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 6
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        Task { [weak self] in
            let calendars = await Meetings.shared.calendars()
            self?.show(calendars)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func show(_ calendars: [MeetingCalendar]) {
        grid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !calendars.isEmpty else {
            grid.addArrangedSubview(SettingsText("No calendars on this Mac yet", font: SettingsMetrics.titleFont, color: .secondaryLabelColor))
            return
        }
        for calendar in calendars {
            let box = NSButton(checkboxWithTitle: calendar.title, target: nil, action: nil)
            box.state = MeetingAlertPrefs.shared.skipped.contains(calendar.id) ? .off : .on
            box.toolTip = calendar.account
            box.kitOnChange { control in
                let shown = (control as? NSButton)?.state == .on
                if shown { MeetingAlertPrefs.shared.skipped.remove(calendar.id) } else { MeetingAlertPrefs.shared.skipped.insert(calendar.id) }
            }
            grid.addArrangedSubview(box)
        }
    }
}
