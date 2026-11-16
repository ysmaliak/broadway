import AppKit
import Observation

extension ImportSource {
    static func defaultBrowserName() -> String? {
        guard let probe = URL(string: "https://example.com"),
              let app = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return nil }
        return name(ofApp: app.lastPathComponent)
    }

    static func openSafari() {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: safariApp), configuration: NSWorkspace.OpenConfiguration())
    }
}

@MainActor
@Observable
final class ImportModel {
    struct Said: Hashable {
        let ok: Bool
        let text: String
    }

    @ObservationIgnored let browser: Browser
    var sources: [ImportSource] = []
    var unreadable: [Chromium.Unavailable] = []
    var folderError: String?
    var looking = true
    var pick: ImportSource?
    var profiles: [String: [ImportSource.Profile]] = [:]
    var usual: [String: String] = [:]
    var chosen: [String: String] = [:]
    var previews: [String: ImportSource.Preview] = [:] { didSet { followExtensions() } }
    var wantsPasswords = true
    var wantsBookmarks = true
    var wantsHistory = true
    var wantsExtensions = false
    var replaceBookmarks = false
    var wantsArc = true
    var arcCounts: [String: (spaces: Int, pinned: Int)] = [:]
    var forExtensions = false
    var bringing = false
    var brought: [Said]?
    var marksLanded = false
    var safari = false
    var onSafari = false
    var openedSafari = 0
    @ObservationIgnored var askForFile: () -> URL? = { Store.testing ? ImportModel.benchFile : Browser.askForExportFile() }
    @ObservationIgnored private var asked: String?
    static var benchFile: URL?

    init(browser: Browser) {
        self.browser = browser
        asked = browser.bringingIn
        if browser.bringingExtensions {
            browser.bringingExtensions = false
            forExtensions = true
            wantsExtensions = true
            wantsPasswords = false
            wantsBookmarks = false
            wantsHistory = false
        }
        look()
    }

    func choose(_ source: ImportSource) {
        guard !bringing else { return }
        pick = source
        onSafari = false
        replaceBookmarks = false
        forExtensions = false
        brought = nil
    }

    func chooseSafari() {
        guard !bringing, safari else { return }
        pick = nil
        onSafari = true
        replaceBookmarks = false
        forExtensions = false
        brought = nil
    }

    func openSafari() {
        openedSafari += 1
        guard !Store.testing else { return }
        ImportSource.openSafari()
    }

    func chooseExport() {
        guard !bringing, browser.fileImport == nil, let url = askForFile() else { return }
        takeExport(url)
    }

    func takeExport(_ url: URL) {
        let browser = browser
        bringing = true
        brought = nil
        marksLanded = false
        Task { @MainActor [weak self] in
            let took = await browser.takeFile(url)
            guard let self else { return }
            bringing = false
            marksLanded = took.bookmarks + took.already > 0
            let landed = took.bookmarks + took.already + took.places + took.kept > 0
            brought = [Said(ok: landed && !took.cancelled, text: took.said)]
        }
    }

    func heard(_ name: String?) {
        guard name != asked else { return }
        asked = name
        guard !bringing else { return }
        if name == ImportSource.safariName, safari {
            chooseSafari()
            return
        }
        guard let found = sources.first(where: { $0.name == name }) else { return }
        pick = found
        onSafari = false
        brought = nil
    }

    private func followExtensions() {
        guard forExtensions, let pick, fresh(pick).isEmpty,
              let other = sources.first(where: { !fresh($0).isEmpty }) else { return }
        self.pick = other
    }

    func key(_ source: ImportSource, _ profile: String?) -> String {
        "\(source.id)/\(profile ?? "")"
    }

    func profile(of source: ImportSource) -> String? {
        let id = chosen[source.id] ?? usual[source.id] ?? ""
        return id.isEmpty ? nil : id
    }

    func pickProfile(_ id: String, for source: ImportSource) {
        chosen[source.id] = id
        brought = nil
        count(source)
    }

    func preview(of source: ImportSource) -> ImportSource.Preview? {
        previews[key(source, profile(of: source))]
    }

    func arc(of source: ImportSource) -> (spaces: Int, pinned: Int)? {
        arcCounts[key(source, profile(of: source))]
    }

    func detail(of source: ImportSource) -> String {
        guard let preview = preview(of: source) else { return "Counting…" }
        func count(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(one)s" }
        var parts: [String] = []
        if let choices = profiles[source.id], choices.count > 1 { parts.append("\(choices.count) profiles") }
        for (n, one) in [(preview.bookmarks, "bookmark"), (preview.places, "place"), (preview.passwords, "password")] where n > 0 {
            parts.append(count(n, one))
        }
        if let arc = arc(of: source), arc.spaces > 0 {
            parts.append(count(arc.spaces, "space"))
        }
        if let record = ImportRecords.of(source.name) {
            parts.append("brought \(record.date.formatted(.dateTime.day().month()))")
        }
        return parts.isEmpty ? "Nothing to bring in" : parts.joined(separator: " · ")
    }

    func broughtBefore(_ record: ImportRecord) -> String {
        func count(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(one)s" }
        let parts = [(record.bookmarks, "bookmark"), (record.places, "place"), (record.passwords, "password"),
                     (record.spaces ?? 0, "space"), (record.pinned ?? 0, "pinned tab")]
            .filter { $0.0 > 0 }.map { count($0.0, $0.1) }
        let what = parts.isEmpty ? "Nothing new" : ListFormatter.localizedString(byJoining: parts)
        return "\(what), \(record.date.formatted(.dateTime.day().month()))"
    }

    func arcDetail(_ arc: (spaces: Int, pinned: Int)) -> String {
        let spaces = arc.spaces == 1 ? "1 space" : "\(arc.spaces) spaces"
        return "\(spaces), \(arc.pinned) pinned. Each becomes a space here, with the favorites as pins and its pinned tabs asleep in it."
    }

    func fresh(_ source: ImportSource) -> [String] {
        guard let preview = preview(of: source) else { return [] }
        let have = Set(Extensions.shared.installed.map(\.id))
        return preview.extensions.filter { !have.contains($0) }
    }

    func canBring(_ source: ImportSource) -> Bool {
        !bringing && (wantsPasswords || wantsBookmarks || wantsHistory || (wantsExtensions && !fresh(source).isEmpty)
                      || (wantsArc && arc(of: source) != nil))
    }

    func look() {
        let wanted = browser.bringingIn ?? ""
        DispatchQueue.global(qos: .userInitiated).async {
            let found = ImportSource.installed()
            let missing = Chromium.unreadable()
            let lists = found.map { ($0.id, $0.profiles, $0.usual) }
            let safari = ImportSource.safari
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                sources = found
                unreadable = missing
                for (id, list, most) in lists {
                    profiles[id] = list
                    usual[id] = most
                }
                self.safari = safari
                onSafari = safari && (wanted == ImportSource.safariName || found.isEmpty)
                pick = onSafari ? nil : found.first { $0.name == wanted } ?? found.first
                looking = false
                found.forEach(count)
            }
        }
    }

    func count(_ source: ImportSource) {
        let profile = profile(of: source)
        let key = key(source, profile)
        guard previews[key] == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let preview = source.preview(profile: profile)
            let arc = source.arcCounts(profile: profile)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let arc { arcCounts[key] = arc }
                previews[key] = preview
            }
        }
    }

    func chooseFolder(for source: Chromium.Source) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = source.root.deletingLastPathComponent()
        panel.message = "Choose \(source.name)'s browser data folder"
        panel.prompt = "Use Folder"
        panel.begin { [weak self] answer in
            guard answer == .OK, let folder = panel.url, let self else { return }
            looking = true
            DispatchQueue.global(qos: .userInitiated).async {
                var selected = source
                selected.rootOverride = folder.resolvingSymlinksInPath()
                let found = !selected.profiles.isEmpty
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard found else {
                        looking = false
                        folderError = "No browser profile was found in \(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")). Choose the folder that contains Default or Profile 1."
                        return
                    }
                    Chromium.useForSession(folder, for: source)
                    folderError = nil
                    previews = [:]
                    profiles = [:]
                    usual = [:]
                    look()
                }
            }
        }
    }

    func bring(from source: ImportSource) {
        let browser = browser
        marksLanded = false
        let profile = profile(of: source)
        let extensions = wantsExtensions ? fresh(source) : []
        let preview = previews[key(source, profile)]
        let passwords = wantsPasswords && source.importsPasswords && preview?.passwords != 0
        let marks = wantsBookmarks && preview?.bookmarks != 0
        let places = wantsHistory && preview?.places != 0
        bringing = true
        var said: [Int: Said] = [:]
        let group = DispatchGroup()
        if passwords {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result { try source.read(profile: profile) }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let found):
                        let kept = browser.keep(found)
                        ImportRecords.note(source.name, passwords: kept)
                        let skipped = found.skipped > 0 ? ", \(found.skipped.formatted()) skipped with no address" : ""
                        let locked = found.undecrypted > 0
                            ? ", and \(found.undecrypted.formatted()) couldn't be decrypted with \(source.name)'s key" : ""
                        said[0] = Said(ok: kept > 0 || found.undecrypted == 0,
                                       text: (kept == 1 ? "1 password" : "\(kept.formatted()) passwords") + skipped + locked)
                    case .failure(Chromium.Trouble.noPassphrase):
                        said[0] = Said(ok: false, text: "macOS didn't hand over \(source.name)'s key. Allow it and try again.")
                    case .failure(Mozilla.Trouble.primaryPassword):
                        said[0] = Said(ok: false, text: "\(source.name) has a primary password. Export your passwords from it and bring in the CSV file.")
                    case .failure:
                        said[0] = Said(ok: false, text: "No passwords readable in \(source.name)")
                    }
                    group.leave()
                }
            }
        }
        if marks {
            let (added, already, kept) = browser.takeBookmarks(from: source, profile: profile, replacing: replaceBookmarks)
            marksLanded = added + already > 0
            said[1] = kept
                ? Said(ok: false, text: "Couldn't read all of \(source.name)'s bookmarks. What came from it before was kept, and \(added.formatted()) are new.")
                : Said(ok: true, text: added == 0 && already == 0 ? "No bookmarks in \(source.name)"
                           : already == 0 ? (added == 1 ? "1 bookmark" : "\(added.formatted()) bookmarks")
                           : (added == 1 ? "1 new bookmark, \(already.formatted()) already here" : "\(added.formatted()) new bookmarks, \(already.formatted()) already here"))
        }
        if places {
            group.enter()
            browser.takePlaces(from: source, profile: profile) { count in
                said[2] = Said(ok: true, text: count == 1 ? "1 place" : "\(count.formatted()) places")
                group.leave()
            }
        }
        if !extensions.isEmpty {
            Task { for id in extensions { await Extensions.shared.install(id: id) } }
            said[3] = Said(ok: true, text: extensions.count == 1 ? "1 extension to confirm" : "\(extensions.count) extensions to confirm")
        }
        if wantsArc, arcCounts[key(source, profile)] != nil, let sidebar = source.arcSidebar(profile: profile) {
            let (spaces, pins, tabs) = browser.takeArc(sidebar, from: source, profile: profile)
            ImportRecords.note(source.name, spaces: spaces, pinned: pins + tabs)
            func count(_ n: Int, _ one: String) -> String { n == 1 ? "1 \(one)" : "\(n.formatted()) \(one)s" }
            said[4] = Said(ok: true, text: spaces + pins + tabs == 0 ? "Arc's spaces and pins were all here already"
                           : "\(count(spaces, "new space")), \(count(pins, "pin")), \(count(tabs, "pinned tab"))")
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            bringing = false
            brought = said.keys.sorted().compactMap { said[$0] }
        }
    }
}

@MainActor
final class ImportPageView: KitFlippedView {
    let browser: Browser
    let model: ImportModel
    let body: ImportBody
    private var plate: KitPlatePage!

    init(browser: Browser) {
        self.browser = browser
        model = ImportModel(browser: browser)
        body = ImportBody(model: model)
        super.init(frame: .zero)
        plate = KitPlatePage("Bring Things Over", content: body, foot: ImportFoot(model: model))
        kitPin(plate)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Bring Things Over")
        identifier = NSUserInterfaceItemIdentifier("import.page")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        model.heard(browser.bringingIn)
        super.layout()
    }
}

@MainActor
final class ImportBody: KitFlippedView {
    let model: ImportModel
    let stack = SettingsPageStack()
    private let scroll = NSScrollView()
    private var built: String?
    private var updates: [() -> Void] = []
    private var card: SettingsCard?

    init(model: ImportModel) {
        self.model = model
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        let document = KitFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: -SettingsMetrics.top),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        addSubview(scroll)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        let shape = shape
        if shape != built {
            built = shape
            rebuild()
        }
        updates.forEach { $0() }
        super.layout()
        scroll.frame = bounds
    }

    private var shape: String {
        var parts: [String] = ["\(model.looking)", "\(model.sources.map(\.id))", "\(model.unreadable.count)", model.folderError ?? "",
                               "\(model.safari)", "\(model.onSafari)"]
        if let source = model.pick {
            let preview = model.preview(of: source)
            parts += [source.id, "\(model.profiles[source.id]?.map(\.id) ?? [])", "\(model.usual[source.id] ?? "")",
                      "\(preview.map { [$0.bookmarks, $0.places, $0.passwords] } ?? [])", "\(model.fresh(source).count)",
                      "\(model.wantsBookmarks)", "\(model.arc(of: source).map { [$0.spaces, $0.pinned] } ?? [])",
                      "\(ImportRecords.of(source.name)?.date.timeIntervalSince1970 ?? 0)"]
        }
        return parts.joined(separator: "|")
    }

    private func section(_ title: String? = nil, _ rows: () -> Void) {
        let made = SettingsCard()
        if let title { stack.add(SettingsHeading(title), inset: 0, top: 20) }
        card = made
        rows()
        card = nil
        if !made.isEmpty { stack.add(made, inset: 0, after: 10) }
    }

    private func put(_ row: NSView) { card?.add(row) }

    private func rebuild() {
        updates = []
        stack.clear()
        let model = model
        section {
            put(SettingsNothing("Nothing in the other browser changes. Passwords go into your keychain."))
            if model.looking {
                put(ImportLooking())
            } else if model.sources.isEmpty, !model.unreadable.isEmpty {
                put(SettingsNothing("Choose a browser's data folder below so Broadway can read it"))
            } else if model.sources.isEmpty, !model.safari {
                put(SettingsNothing("No other browser found on this Mac"))
            }
        }
        if !model.looking, !model.sources.isEmpty || model.safari {
            section("On this Mac") {
                if model.safari {
                    let row = ImportSourceRow(name: ImportSource.safariName) { model.chooseSafari() }
                    row.detail = "From a file Safari exports"
                    updates.append { [weak row] in row?.chosen = model.onSafari }
                    put(row)
                }
                for source in model.sources {
                    let row = ImportSourceRow(name: source.name) { model.choose(source) }
                    updates.append { [weak row] in
                        row?.detail = model.detail(of: source)
                        row?.chosen = model.pick == source
                    }
                    put(row)
                }
            }
        }
        if !model.unreadable.isEmpty || model.folderError != nil {
            section {
                for missing in model.unreadable {
                    let choose = PagePill("Choose Folder…", small: true) { model.chooseFolder(for: missing.source) }
                    put(SettingsRowView(id: "import.unreadable." + missing.source.name, symbol: nil, title: missing.message, control: choose))
                }
                if let error = model.folderError { put(SettingsNothing(error)) }
            }
        }
        if model.onSafari {
            safariWay()
        } else if let source = model.pick {
            options(for: source)
        }
    }

    private func safariWay() {
        let model = model
        section {
            let open = PagePill("Open Safari", small: true) { model.openSafari() }
            open.identifier = NSUserInterfaceItemIdentifier("import.safari.open")
            open.setAccessibilityIdentifier("import.safari.open")
            line("safari.export", "Export from Safari", { "In Safari, choose File › Export Browsing Data and save the file" }, control: open)
            line("safari.file", "Bring in the file", { "Choose the ZIP file Safari saved. Its bookmarks, history and passwords come in." }, control: nil)
        }
    }

    private func toggle(_ id: String, _ title: String, on: @escaping () -> Bool, none: @escaping () -> Bool, set: @escaping (Bool) -> Void) -> KitSwitch {
        let made = KitSwitch(isOn: on(), label: title)
        made.identifier = NSUserInterfaceItemIdentifier("import." + id)
        made.onChange = set
        updates.append { [weak made] in
            guard let made else { return }
            let off = none()
            made.isEnabled = !off
            let value = off ? false : on()
            if made.isOn != value { made.isOn = value }
        }
        return made
    }

    private func line(_ id: String, _ title: String, _ detail: @escaping () -> String, control: NSView?) {
        let row = SettingsRowView(id: "import." + id, symbol: nil, title: title, detail: detail(), control: control.map(ImportOnTitle.init))
        row.detail.font = .systemFont(ofSize: 11)
        updates.append { [weak row] in row?.say(detail()) }
        put(row)
    }

    private func options(for source: ImportSource) {
        let model = model
        section {
            if case .chromium(let chromium) = source, let root = Chromium.chosenRoot(for: chromium.name), !Store.testing {
                let from = SettingsNothing("From \(root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                from.kitSubviews(of: NSTextField.self).forEach { $0.isSelectable = true }
                put(from)
            }
            if let record = ImportRecords.of(source.name) {
                line("before", "Brought before", { model.broughtBefore(record) }, control: nil)
            }
            if let choices = model.profiles[source.id], choices.count > 1 {
                let holder = SettingsPopUp()
                let menu = holder.button
                let ids = choices.map(\.id)
                for profile in choices {
                    menu.addItem(withTitle: profile.id == model.usual[source.id] ? "Most recent: \(profile.name)" : profile.name)
                }
                menu.menu?.addItem(.separator())
                menu.addItem(withTitle: "All profiles")
                menu.kitOnChange { control in
                    guard let index = (control as? NSPopUpButton)?.indexOfSelectedItem else { return }
                    model.pickProfile(index < ids.count ? ids[index] : "", for: source)
                }
                menu.kitAccess(id: "import.profile", label: "Profile")
                updates.append { [weak menu] in
                    let id = model.chosen[source.id] ?? model.usual[source.id] ?? ""
                    let index = ids.firstIndex(of: id) ?? ids.count + 1
                    if menu?.indexOfSelectedItem != index { menu?.selectItem(at: index) }
                }
                let row = SettingsRowView(id: "import.profile", symbol: nil, title: "Profile", control: holder)
                let spaced = NSView()
                spaced.kitPin(row, insets: NSEdgeInsets(top: 0, left: 0, bottom: 1.5, right: 0))
                put(spaced)
            }
            let name = source.name
            let passwords = toggle("passwords", "Passwords", on: { model.wantsPasswords },
                                   none: { !source.importsPasswords || model.preview(of: source)?.passwords == 0 },
                                   set: { model.wantsPasswords = $0 })
            line("passwords", "Passwords", {
                let preview = model.preview(of: source)
                if !source.importsPasswords { return "Not supported for \(name)" }
                if preview?.passwords == 0 { return "None in \(name)" }
                return source.asksForKey ? "macOS asks once for \(name)'s keychain key" : "Read from \(name)'s own files, unless it has a primary password"
            }, control: passwords)
            let bookmarks = toggle("bookmarks", "Bookmarks", on: { model.wantsBookmarks }, none: { model.preview(of: source)?.bookmarks == 0 },
                                   set: { model.wantsBookmarks = $0 })
            line("bookmarks", "Bookmarks", {
                model.preview(of: source)?.bookmarks == 0 ? "None in \(name)" : "In a “\(name)” folder, or at the top if you have none yet"
            }, control: bookmarks)
            if model.wantsBookmarks, model.preview(of: source)?.bookmarks != 0, let record = ImportRecords.of(name) {
                let recorded = !record.bookmarkIDs.isEmpty
                let replace = toggle("replace", "Replace what came from \(name) before", on: { model.replaceBookmarks }, none: { !recorded },
                                     set: { model.replaceBookmarks = $0 })
                line("replace", "Replace what came from \(name) before", {
                    recorded ? "Its bookmarks from \(record.date.formatted(.dateTime.day().month())) go and these come fresh. Passwords only ever add."
                             : "Nothing recorded from \(name) yet, so only what is new comes"
                }, control: replace)
            }
            let history = toggle("history", "History", on: { model.wantsHistory }, none: { model.preview(of: source)?.places == 0 },
                                 set: { model.wantsHistory = $0 })
            line("history", "History", {
                let preview = model.preview(of: source)
                return preview?.places == 0 ? "None in \(name)" : "The last \((preview.map { $0.places } ?? 3000).formatted()) places"
            }, control: history)
            if let arc = model.arc(of: source), arc.spaces + arc.pinned > 0 {
                let spaces = toggle("arc", "Spaces and pinned tabs", on: { model.wantsArc }, none: { false }, set: { model.wantsArc = $0 })
                line("arc", "Spaces and pinned tabs", { model.arcDetail(arc) }, control: spaces)
            }
            let extensions = model.fresh(source)
            if !extensions.isEmpty {
                let take = toggle("extensions", "Extensions", on: { model.wantsExtensions }, none: { false }, set: { model.wantsExtensions = $0 })
                line("extensions", "Extensions", { extensions.count == 1 ? "1 found, which installs from the Chrome Web Store once you approve it" : "\(extensions.count) found, and each installs from the Chrome Web Store once you approve it" }, control: take)
            }
        }
    }
}

final class ImportLooking: NSView {
    init() {
        super.init(frame: .zero)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        let label = SettingsText("Looking on this Mac…", font: SettingsMetrics.titleFont, color: .secondaryLabelColor)
        let row = NSStackView.kit(.horizontal, spacing: 8, [spinner, label])
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.inset),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsMetrics.inset),
            row.topAnchor.constraint(equalTo: topAnchor, constant: SettingsMetrics.rowPad),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsMetrics.rowPad),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

final class ImportSourceRow: NSView {
    private let pick: () -> Void
    private let mark = KitSymbol("circle", style: .init(size: 13), tint: .secondaryLabelColor)
    private let name: SettingsText
    private let line = SettingsText("", font: .monospacedDigitSystemFont(ofSize: 12, weight: .regular), color: .secondaryLabelColor)
    var detail = "" { didSet { if detail != oldValue { line.stringValue = detail; setAccessibilityValue(detail) } } }
    var chosen = false {
        didSet {
            guard chosen != oldValue else { return }
            mark.name = chosen ? "checkmark.circle.fill" : "circle"
            mark.tint = chosen ? .controlAccentColor : .secondaryLabelColor
            setAccessibilitySelected(chosen)
        }
    }

    init(name title: String, pick: @escaping () -> Void) {
        self.pick = pick
        name = SettingsText(title, font: SettingsMetrics.titleFont)
        super.init(frame: .zero)
        for text in [name, line] { text.setContentCompressionResistancePriority(.required, for: .horizontal) }
        let words = NSStackView.kit(.vertical, spacing: 2, alignment: .leading, [name, line])
        for view in [mark, words] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            mark.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsMetrics.inset),
            mark.centerYAnchor.constraint(equalTo: words.centerYAnchor),
            words.leadingAnchor.constraint(equalTo: mark.trailingAnchor, constant: 12),
            words.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -SettingsMetrics.inset),
            words.topAnchor.constraint(equalTo: topAnchor, constant: SettingsMetrics.rowPad),
            words.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -SettingsMetrics.rowPad),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        identifier = NSUserInterfaceItemIdentifier("import.source." + title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { pick() }
    }

    override func accessibilityPerformPress() -> Bool {
        pick()
        return true
    }
}

@MainActor
final class ImportFoot: KitFlippedView {
    let model: ImportModel
    private var lines: [(icon: KitSymbol, text: KitLabel)] = []
    private var said: [ImportModel.Said]?
    private let showBookmarks = PagePill("Show Bookmarks")
    private let showBar = PagePill("Show Bookmarks Bar")
    private let showPasswords = PagePill("Show Passwords")
    private let bring = PagePill("Bring Them In", kind: .primary)
    private let ring = RingView()
    private let file = PagePill("From a File…")

    init(model: ImportModel) {
        self.model = model
        super.init(frame: .zero)
        let browser = model.browser
        showBookmarks.action = { [weak browser] in browser?.lead(to: InternalPage(.bookmarks)) }
        showBar.action = { [weak browser] in browser?.prefs.bookmarksBar = true }
        showPasswords.action = { [weak browser] in browser?.lead(to: InternalPage(.passwords)) }
        bring.action = { [weak model] in
            guard let model else { return }
            if model.onSafari {
                model.chooseExport()
                return
            }
            guard let source = model.pick else { return }
            model.bring(from: source)
        }
        file.action = { [weak browser] in browser?.importFile() }
        bring.identifier = NSUserInterfaceItemIdentifier("import.bring")
        bring.setAccessibilityIdentifier("import.bring")
        file.identifier = NSUserInterfaceItemIdentifier("import.file")
        for view in [showBookmarks, showBar, showPasswords, bring, ring, file] as [NSView] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var width: CGFloat {
        if bounds.width > 0 { return bounds.width }
        return (superview as? KitPlatePage)?.column.width ?? 0
    }

    private func linesHeight(_ width: CGFloat) -> CGFloat {
        guard !lines.isEmpty else { return 0 }
        let text = lines.reduce(CGFloat(0)) { $0 + ceil($1.text.measure(width: max(0, width - 20)).height) }
        return text + CGFloat(lines.count - 1) * 5
    }

    override var intrinsicContentSize: NSSize {
        let top = linesHeight(width)
        return NSSize(width: NSView.noIntrinsicMetric, height: (top > 0 ? top + 10 : 0) + 28)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if changed {
            invalidateIntrinsicContentSize()
            superview?.needsLayout = true
        }
    }

    private func sayLines(_ next: [ImportModel.Said]?) {
        guard next != said else { return }
        said = next
        lines.forEach { $0.icon.removeFromSuperview(); $0.text.removeFromSuperview() }
        lines = (next ?? []).map { line in
            let color: NSColor = line.ok ? .labelColor : .secondaryLabelColor
            let icon = KitSymbol(line.ok ? "checkmark" : "exclamationmark.circle", style: .init(size: 10.5, weight: .semibold), tint: color)
            let text = KitLabel(line.text, font: .systemFont(ofSize: 13), color: color)
            text.lines = 0
            addSubview(icon)
            addSubview(text)
            return (icon, text)
        }
        layer?.kitTransition(Motion.kitSettle)
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    override func layout() {
        sayLines(model.brought)
        super.layout()
        let width = bounds.width
        var y: CGFloat = 0
        for line in lines {
            let height = ceil(line.text.measure(width: max(0, width - 20)).height)
            let first = ceil(line.text.font.ascender - line.text.font.descender + line.text.font.leading)
            line.text.frame = kitSnap(NSRect(x: 20, y: y, width: max(0, width - 20), height: height))
            let iconSize = line.icon.intrinsicContentSize
            line.icon.frame = kitSnap(NSRect(x: (12 - iconSize.width) / 2, y: y + (first - iconSize.height) / 2, width: iconSize.width, height: iconSize.height))
            y += height + 5
        }
        if !lines.isEmpty { y += 5 }
        let brought = model.brought != nil
        let landed = model.onSafari ? model.brought?.contains { $0.ok } == true : brought
        let browser = model.browser
        let bar = landed && model.marksLanded && !browser.prefs.bookmarksBar
        showBookmarks.isHidden = !landed
        showBar.isHidden = !bar
        showPasswords.isHidden = !landed
        bring.isHidden = !model.onSafari && (brought || model.pick == nil)
        ring.isHidden = bring.isHidden || !model.bringing
        bring.title = model.bringing ? "Bringing…" : model.onSafari ? "Choose File…" : "Bring Them In"
        bring.isEnabled = model.onSafari ? !model.bringing : model.pick.map { model.canBring($0) } ?? false
        file.isEnabled = !model.bringing
        file.isHidden = model.onSafari
        var x: CGFloat = 0
        for button in [showBookmarks, showBar, showPasswords, bring] where !button.isHidden {
            let size = button.intrinsicContentSize
            let w = max(64, size.width)
            button.frame = kitSnap(NSRect(x: x, y: y, width: w, height: 28))
            x += w + 8
        }
        ring.frame = kitSnap(NSRect(x: x, y: y + 9, width: 10, height: 10))
        let fileSize = file.intrinsicContentSize
        let fw = max(64, fileSize.width)
        file.frame = kitSnap(NSRect(x: width - fw, y: y, width: fw, height: 28))
    }
}

final class ImportOnTitle: NSView {
    let control: NSView

    init(_ control: NSView) {
        self.control = control
        super.init(frame: .zero)
        addSubview(control)
        control.translatesAutoresizingMaskIntoConstraints = false
        let line = ceil(SettingsMetrics.titleFont.ascender - SettingsMetrics.titleFont.descender + SettingsMetrics.titleFont.leading)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: leadingAnchor),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: line),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let inside = convert(point, from: superview)
        return control.frame.contains(inside) ? control.hitTest(convert(inside, to: control.superview)) ?? control : nil
    }
}
