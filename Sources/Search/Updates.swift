import AppKit
import Combine
import Observation
import Sparkle

struct UpdateFeed: Equatable {
    static let addressKey = "SUFeedURL"
    static let signatureKey = "SUPublicEDKey"

    let address: URL
    let key: String

    static func read(_ info: [String: Any]) -> UpdateFeed? {
        guard let text = info[addressKey] as? String, let address = URL(string: text), address.host != nil,
              ["https", "http"].contains(address.scheme ?? ""),
              let key = info[signatureKey] as? String, Data(base64Encoded: key)?.count == 32 else { return nil }
        return UpdateFeed(address: address, key: key)
    }

    static func live(info: [String: Any], probed: Bool, unitTests: Bool, executable: String?) -> UpdateFeed? {
        guard !probed, !unitTests, executable?.contains("/.build/") != true else { return nil }
        return read(info)
    }
}

enum UpdatePlace: String {
    case diskImage, downloaded

    static func found(path: String, readOnly: Bool) -> UpdatePlace? {
        if path.contains("/AppTranslocation/") { return .downloaded }
        return readOnly ? .diskImage : nil
    }

    static func found(_ bundle: URL) -> UpdatePlace? {
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return found(path: bundle.path, readOnly: readOnly)
    }

    var title: String { "Move Broadway to your Applications folder" }

    var words: String {
        switch self {
        case .diskImage:
            return "Broadway is running from its disk image, where it can't update itself. Quit, drag Broadway to Applications, and open it from there."
        case .downloaded:
            return "Broadway is running from where it was downloaded, and macOS keeps it from updating itself there. Quit, drag Broadway to Applications, and open it from there."
        }
    }
}

enum UpdateWords {
    static let none = "This build doesn't update itself"
    static let install = "Install Update"
    static let check = "Check for Updates…"
    static let checking = "Checking for updates"
    static let installing = "Installing"
    static let failed = "Couldn't update"
    static let upToDate = "Broadway is up to date"
    static let checkFailed = "Couldn't check for updates"

    static func available(_ version: String) -> String { "Broadway \(version) is available" }

    static func newest(_ version: String) -> String { "Version \(version) is the newest" }

    static func percent(_ progress: Double) -> String { "\(Int((min(1, max(0, progress)) * 100).rounded(.down)))%" }

    static func downloading(_ progress: Double?) -> String { progress.map { "Downloading \(percent($0))" } ?? "Downloading" }

    static func reason(_ error: Error) -> String {
        let text = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = text.components(separatedBy: ". ").first ?? text
        guard first.hasSuffix("."), !first.hasSuffix("..") else { return first }
        return String(first.dropLast())
    }

    @MainActor static func status(_ flow: UpdateFlow) -> String? {
        switch flow.phase {
        case .checking: return checking
        case .downloading where flow.pressed: return downloading(flow.progress)
        case .installing where flow.pressed: return installing
        case .failed: return flow.trouble.map { "\(failed) · \($0)" } ?? failed
        default:
            if let found = flow.found { return available(found.version) }
            return flow.trouble != nil && !flow.card ? checkFailed : nil
        }
    }

    @MainActor static func help(_ flow: UpdateFlow) -> String? {
        status(flow) == checkFailed ? flow.trouble : nil
    }

    static func checked(_ last: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let last else { return "Not checked yet" }
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = calendar.locale ?? .current
        time.dateStyle = .none
        time.timeStyle = .short
        if calendar.isDate(last, inSameDayAs: now) { return "Last checked today at \(time.string(from: last))" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(last, inSameDayAs: yesterday) {
            return "Last checked yesterday at \(time.string(from: last))"
        }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = calendar.locale ?? .current
        day.dateStyle = .medium
        day.timeStyle = .none
        return "Last checked \(day.string(from: last))"
    }

    static func line(version: String, runs: Bool, stuck: UpdatePlace? = nil, status: String? = nil, last: Date?, now: Date = Date(),
                     calendar: Calendar = .current) -> String {
        guard runs else { return "\(version) · \(none)" }
        if stuck != nil { return "\(version) · Move Broadway to Applications to get updates" }
        if let status { return "\(version) · \(status)" }
        return "\(version) · \(checked(last, now: now, calendar: calendar))"
    }
}

struct UpdateFeedItem: Equatable {
    var version = ""
    var build = ""
    var minimum: String?
    var maximum: String?
    var channel: String?
    var informational = false
}

final class UpdateFeedParser: NSObject, XMLParserDelegate {
    private(set) var items: [UpdateFeedItem] = []
    private var current: UpdateFeedItem?
    private var text = ""

    static func items(_ data: Data) -> [UpdateFeedItem] {
        let parser = XMLParser(data: data)
        let reader = UpdateFeedParser()
        parser.delegate = reader
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return [] }
        return reader.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        if name == "item" { current = UpdateFeedItem() }
        guard current != nil else { return }
        if name == "enclosure" {
            if let build = attributes["sparkle:version"], current?.build.isEmpty == true { current?.build = build }
            if let short = attributes["sparkle:shortVersionString"], current?.version.isEmpty == true { current?.version = short }
        }
        if name == "sparkle:informationalUpdate" { current?.informational = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        switch name {
        case "item":
            if let item = current, !item.build.isEmpty { items.append(item) }
            current = nil
        case "sparkle:version": current?.build = value
        case "sparkle:shortVersionString": current?.version = value
        case "sparkle:minimumSystemVersion": current?.minimum = value
        case "sparkle:maximumSystemVersion": current?.maximum = value
        case "sparkle:channel": current?.channel = value
        default: break
        }
    }

    static func newest(_ items: [UpdateFeedItem], system: String) -> UpdateFound? {
        let compare = SUStandardVersionComparator.default
        let fits = items.filter { item in
            guard item.channel == nil, !item.informational else { return false }
            if let minimum = item.minimum, compare.compareVersion(minimum, toVersion: system) == .orderedDescending { return false }
            if let maximum = item.maximum, compare.compareVersion(system, toVersion: maximum) == .orderedDescending { return false }
            return true
        }
        let best = fits.max { compare.compareVersion($0.build, toVersion: $1.build) == .orderedAscending }
        return best.map { UpdateFound(version: $0.version.isEmpty ? $0.build : $0.version, build: $0.build) }
    }

    static var system: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
    }
}

@MainActor
@Observable
final class Updates: NSObject, SPUUpdaterDelegate, UpdateEngine, NSMenuItemValidation {
    nonisolated static let feed = UpdateFeed.live(info: Bundle.main.infoDictionary ?? [:], probed: Store.probed,
                                      unitTests: Store.unitTests, executable: Bundle.main.executablePath)
    static let shared = Updates()

    nonisolated static var runs: Bool { feed != nil }

    nonisolated static let moveOffer: UpdatePlace? = runs ? UpdatePlace.found(Bundle.main.bundleURL) : nil

    nonisolated static let installsKey = "SUAutomaticallyUpdate"

    @ObservationIgnored private var updater: SPUUpdater?
    @ObservationIgnored private var driver: UpdateDriver?
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private(set) var restartsAsked = 0
    @ObservationIgnored private var pretended: Bool?
    let flow = UpdateFlow()
    private(set) var turn = 0

    var trouble: String? { flow.trouble }

    var waiting: String? { flow.found.map { "Version \($0.version)" } }

    private override init() {
        super.init()
        flow.installsQuietly = { [weak self] in self?.installs ?? false }
        flow.cardSeen = { Updates.cardSeen }
        flow.tell = { UpdateAlerts.show($0) }
        guard Updates.feed != nil else { return }
        let driver = UpdateDriver(flow: flow)
        self.driver = driver
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        flow.engine = self
    }

    static var cardSeen: Bool {
        Browsers.all.contains { browser in
            guard !browser.isPrivate, !browser.folded, let window = browser.window else { return false }
            return window.isVisible && !window.isMiniaturized
        }
    }

    func start() {
        guard let updater, !started else { return }
        do {
            try updater.start()
        } catch {
            flow.failed(UpdateWords.reason(error))
            return
        }
        started = true
        turn += 1
        offerMove()
        watches = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in MainActor.assumeIsolated { self?.turn += 1 } },
            updater.observe(\.sessionInProgress) { [weak self] _, _ in MainActor.assumeIsolated { self?.turn += 1 } },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in MainActor.assumeIsolated { self?.turn += 1 } },
        ]
    }

    func offerMove() {
        guard let place = Updates.moveOffer else { return }
        let timer = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                if UpdateAlerts.modal(UpdateAlerts.move(place)) { NSApp.terminate(nil) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    var busy: Bool { updater?.sessionInProgress ?? false }

    var running: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "" }

    var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }

    func begin() {
        guard let updater else { return }
        updater.checkForUpdates()
    }

    func read(_ done: @escaping (UpdateFound?, String?) -> Void) {
        guard let address = updater?.feedURL ?? Updates.feed?.address else { return done(nil, UpdateWords.none) }
        var request = URLRequest(url: address, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.setValue("application/rss+xml,*/*;q=0.1", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let items = data.map(UpdateFeedParser.items) ?? []
            let newest = UpdateFeedParser.newest(items, system: UpdateFeedParser.system)
            let failure: String? = error.map(UpdateWords.reason) ?? (code >= 400 ? HTTPURLResponse.localizedString(forStatusCode: code).capitalized
                : items.isEmpty ? "The update feed couldn't be read" : nil)
            DispatchQueue.main.async { done(newest, failure) }
        }.resume()
        session.finishTasksAndInvalidate()
    }

    func menuItem() -> NSMenuItem? {
        guard updater != nil else { return nil }
        let item = NSMenuItem(title: UpdateWords.check, action: #selector(checkFromMenu), keyEquivalent: "")
        item.target = self
        return item
    }

    func installItem() -> NSMenuItem {
        let item = UpdateMenuItem(title: UpdateWords.install, action: #selector(installFromMenu), keyEquivalent: "")
        item.target = self
        item.isHidden = !flow.offered
        item.watch = kitObserve(distinct: true, { [weak self] in self?.flow.offered == true }) { [weak item] on in item?.isHidden = !on }
        return item
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(checkFromMenu): return canCheck
        case #selector(installFromMenu): return flow.canInstall
        default: return true
        }
    }

    @objc private func checkFromMenu() { check() }

    @objc private func installFromMenu() { install(over: NSApp.keyWindow ?? Browsers.front?.window) }

    func install(over window: NSWindow?) {
        guard flow.canInstall else { return }
        UpdateRestart.ask(over: window) { [weak self] in
            guard let self else { return }
            if Store.testing, let quits = pretended {
                restartsAsked += 1
                guard quits else { return }
                if !NSRunningApplication.current.terminate() { NSApp.terminate(nil) }
                return
            }
            flow.press()
        }
    }

    func check() {
        guard canCheck else { return }
        flow.checkNow()
    }

    func pretend(version: String, build: String, phase: UpdatePhase = .available, progress: Double? = nil, trouble: String? = nil,
                 staged: Bool = false, quits: Bool = false) {
        guard Store.testing else { return }
        pretended = quits
        flow.pretend(phase, found: UpdateFound(version: version, build: build), staged: staged, progress: progress, trouble: trouble)
    }

    func unpretend() {
        guard Store.testing else { return }
        pretended = nil
        flow.reset()
        restartsAsked = 0
    }

    var canCheck: Bool {
        _ = turn
        return started && updater != nil && flow.canCheck
    }

    var lastChecked: Date? {
        _ = turn
        return updater?.lastUpdateCheckDate
    }

    var checks: Bool {
        get {
            _ = turn
            return updater?.automaticallyChecksForUpdates ?? false
        }
        set {
            guard let updater, updater.automaticallyChecksForUpdates != newValue else { return }
            updater.automaticallyChecksForUpdates = newValue
            turn += 1
        }
    }

    var installs: Bool {
        get {
            _ = turn
            guard updater != nil else { return false }
            if let kept = UserDefaults.standard.object(forKey: Updates.installsKey) as? Bool { return kept }
            return Bundle.main.object(forInfoDictionaryKey: Updates.installsKey) as? Bool ?? false
        }
        set {
            guard updater != nil, installs != newValue else { return }
            UserDefaults.standard.set(newValue, forKey: Updates.installsKey)
            turn += 1
        }
    }

    var canInstall: Bool { checks }

    var line: String {
        UpdateWords.line(version: AboutWindow.version, runs: Updates.runs || flow.found != nil, stuck: Updates.moveOffer,
                         status: UpdateWords.status(flow), last: lastChecked)
    }

    var facts: [String: Any] {
        var said: [String: Any] = ["runs": Updates.runs, "version": AboutWindow.version, "line": line, "staged": flow.staged.map { "Version \($0.version)" } ?? "",
                                   "card": flow.card, "restartsAsked": restartsAsked, "phase": flow.shown.rawValue, "flow": flow.phase.rawValue,
                                   "found": flow.found.map { ["version": $0.version, "build": $0.build] } ?? NSNull(),
                                   "progress": flow.progress ?? NSNull(), "pressed": flow.pressed, "quiet": flow.quiet,
                                   "trouble": flow.trouble ?? "", "waiting": waiting ?? "",
                                   "told": flow.told.map { "\($0)" }, "trail": flow.trail]
        guard let updater else { return said }
        said["feed"] = updater.feedURL?.absoluteString ?? ""
        said["started"] = started
        said["canCheck"] = canCheck
        said["checks"] = updater.automaticallyChecksForUpdates
        said["installs"] = installs
        said["sparkleDownloads"] = updater.automaticallyDownloadsUpdates
        said["interval"] = updater.updateCheckInterval
        said["busy"] = updater.sessionInProgress
        said["sparkleCanCheck"] = updater.canCheckForUpdates
        said["lastChecked"] = updater.lastUpdateCheckDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        return said
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        turn += 1
        flow.cycleEnded()
    }
}

final class UpdateMenuItem: NSMenuItem {
    var watch: AnyCancellable?
}

@MainActor
enum UpdateAlerts {
    static func show(_ tell: UpdateTell) {
        let alert = alert(for: tell)
        let install: (Bool) -> Void = { yes in
            guard yes, case .available = tell else { return }
            Updates.shared.install(over: NSApp.keyWindow ?? Browsers.front?.window)
        }
        if let yes = Ask.rehearsed(alert.messageText) {
            install(yes)
            return
        }
        present(alert, install)
    }

    static func alert(for tell: UpdateTell) -> NSAlert {
        switch tell {
        case .upToDate(let version):
            Ask.plain(UpdateWords.upToDate, detail: UpdateWords.newest(version), buttons: ["OK"])
        case .checkFailed(let reason):
            Ask.plain(UpdateWords.checkFailed, detail: reason, buttons: ["OK"])
        case .available(let found):
            Ask.plain(UpdateWords.available(found.version), buttons: ["Install", "Not Now"])
        }
    }

    static func move(_ place: UpdatePlace) -> NSAlert {
        Ask.plain(place.title, detail: place.words, buttons: ["Quit Broadway", "Not Now"])
    }

    private static var window: NSWindow? {
        guard let front = Browsers.front?.window, front.isVisible, !front.isMiniaturized, front.attachedSheet == nil else { return nil }
        return front
    }

    private static func present(_ alert: NSAlert, _ done: @escaping (Bool) -> Void) {
        if let window {
            alert.beginSheetModal(for: window) { done($0 == .alertFirstButtonReturn) }
            return
        }
        done(modal(alert))
    }

    static func modal(_ alert: NSAlert) -> Bool {
        NSApp.activate()
        UpdateWindows.answerWhileModal(true)
        let answer = alert.runModal()
        UpdateWindows.answerWhileModal(false)
        return answer == .alertFirstButtonReturn
    }
}

@MainActor
enum UpdateWindows {
    private static func ours(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        return window.className.contains("Alert") || window is NSPanel && window.styleMask.contains(.titled) && window.level == .modalPanel
    }

    private static func buttons(_ window: NSWindow) -> [NSButton] {
        (window.contentView?.kitSubviews(of: NSButton.self) ?? []).filter { !$0.isHidden && !$0.title.isEmpty }
    }

    static func read() -> [[String: Any]] {
        NSApp.windows.filter(ours).map { window in
            let texts = (window.contentView?.kitSubviews(of: NSTextField.self) ?? [])
                .filter { !$0.isHidden && !$0.stringValue.isEmpty }.map(\.stringValue)
            return ["id": window.windowNumber, "title": window.title, "kind": window.className, "texts": texts,
                    "buttons": buttons(window).map(\.title), "modal": NSApp.modalWindow === window]
        }
    }

    private static var modal: Timer?
    static var asked: URL { Store.file("updates.ask") }
    static var said: URL { Store.file("updates.say") }

    static func answerWhileModal(_ on: Bool) {
        modal?.invalidate()
        modal = nil
        guard on, Store.testing else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let data = try? Data(contentsOf: asked) else { return }
                try? FileManager.default.removeItem(at: asked)
                let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
                var answer: [String: Any] = ["windows": read()]
                if let title = request["press"] as? String { answer["pressed"] = press(title, later: false) }
                guard let out = try? JSONSerialization.data(withJSONObject: answer) else { return }
                try? out.write(to: said, options: .atomic)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        modal = timer
    }

    static func press(_ title: String, later: Bool) -> Bool {
        for window in NSApp.windows.filter(ours) {
            guard let button = buttons(window).first(where: { $0.title == title && $0.isEnabled }) else { continue }
            if later { DispatchQueue.main.async { button.performClick(nil) } } else { button.performClick(nil) }
            return true
        }
        return false
    }

    static func press(_ title: String) -> Bool { press(title, later: true) }
}
