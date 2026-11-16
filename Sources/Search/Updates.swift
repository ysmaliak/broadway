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
    static let ready = "An update is ready"
    static let restart = "Restart to Update"

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

    static func line(version: String, runs: Bool, stuck: UpdatePlace? = nil, waiting: String?, last: Date?, now: Date = Date(),
                     calendar: Calendar = .current) -> String {
        guard runs else { return "\(version) · \(none)" }
        if stuck != nil { return "\(version) · Move Broadway to Applications to get updates" }
        if waiting != nil { return "\(version) · \(ready)" }
        return "\(version) · \(checked(last, now: now, calendar: calendar))"
    }
}

@MainActor
@Observable
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    nonisolated static let feed = UpdateFeed.live(info: Bundle.main.infoDictionary ?? [:], probed: Store.probed,
                                      unitTests: Store.unitTests, executable: Bundle.main.executablePath)
    static let shared = Updates()

    nonisolated static var runs: Bool { feed != nil }

    nonisolated static let moveOffer: UpdatePlace? = runs ? UpdatePlace.found(Bundle.main.bundleURL) : nil

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var watches: [NSKeyValueObservation] = []
    @ObservationIgnored private var started = false
    @ObservationIgnored private var restartWatch: AnyCancellable?
    @ObservationIgnored private(set) var restartsAsked = 0
    let wait = UpdateWait()
    private(set) var turn = 0
    private(set) var trouble: String?

    var waiting: String? { wait.staged.map { "Version \($0.version)" } }

    private override init() {
        super.init()
        guard Updates.feed != nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    }

    private var updater: SPUUpdater? { controller?.updater }

    func start() {
        guard let controller, !started else { return }
        started = true
        controller.startUpdater()
        let updater = controller.updater
        offerMove()
        watches = [
            updater.observe(\.canCheckForUpdates) { [weak self] _, _ in MainActor.assumeIsolated { self?.turn += 1 } },
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in MainActor.assumeIsolated { self?.turn += 1 } },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in MainActor.assumeIsolated { self?.turn += 1 } },
        ]
    }

    func offerMove() {
        guard let place = Updates.moveOffer else { return }
        let timer = Timer(timeInterval: 1, repeats: false) { _ in
            MainActor.assumeIsolated {
                let alert = NSAlert()
                alert.messageText = place.title
                alert.informativeText = place.words
                alert.addButton(withTitle: "Quit Broadway")
                alert.addButton(withTitle: "Not Now")
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    func menuItem() -> NSMenuItem? {
        guard let controller else { return nil }
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = controller
        return item
    }

    func restartItem() -> NSMenuItem {
        let item = NSMenuItem(title: UpdateWords.restart, action: #selector(restartFromMenu), keyEquivalent: "")
        item.target = self
        restartWatch = kitObserve(distinct: true, { [weak self] in self?.wait.staged != nil }) { [weak item] on in item?.isHidden = !on }
        return item
    }

    @objc private func restartFromMenu() { restart(over: NSApp.keyWindow ?? Browsers.front?.window) }

    func restart(over window: NSWindow?) { UpdateRestart.ask(wait, over: window) }

    func pretend(version: String, build: String, quits: Bool = false) {
        guard Store.testing else { return }
        wait.stage(StagedUpdate(version: version, build: build)) { [weak self] in
            self?.restartsAsked += 1
            guard quits else { return }
            if !NSRunningApplication.current.terminate() { NSApp.terminate(nil) }
        }
    }

    func unpretend() {
        guard Store.testing else { return }
        wait.clear()
        restartsAsked = 0
    }

    var canCheck: Bool {
        _ = turn
        return started && updater?.canCheckForUpdates == true
    }

    func check() {
        guard canCheck else { return }
        controller?.checkForUpdates(nil)
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
            return updater?.automaticallyDownloadsUpdates ?? false
        }
        set {
            guard let updater, updater.automaticallyDownloadsUpdates != newValue else { return }
            updater.automaticallyDownloadsUpdates = newValue
            turn += 1
        }
    }

    var canInstall: Bool {
        _ = turn
        return updater?.allowsAutomaticUpdates ?? false
    }

    var line: String {
        UpdateWords.line(version: AboutWindow.version, runs: Updates.runs || wait.staged != nil, stuck: Updates.moveOffer, waiting: waiting,
                         last: lastChecked)
    }

    var facts: [String: Any] {
        var said: [String: Any] = ["runs": Updates.runs, "version": AboutWindow.version, "line": line, "staged": waiting ?? "",
                                   "card": wait.card, "restartsAsked": restartsAsked]
        guard let updater else { return said }
        said["feed"] = updater.feedURL?.absoluteString ?? ""
        said["started"] = started
        said["canCheck"] = canCheck
        said["checks"] = updater.automaticallyChecksForUpdates
        said["installs"] = updater.automaticallyDownloadsUpdates
        said["interval"] = updater.updateCheckInterval
        said["busy"] = updater.sessionInProgress
        said["lastChecked"] = updater.lastUpdateCheckDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        said["waiting"] = waiting ?? ""
        said["trouble"] = trouble ?? ""
        return said
    }

    func standardUserDriverWillShowModalAlert() { UpdateWindows.answerWhileModal(true) }

    func standardUserDriverDidShowModalAlert() { UpdateWindows.answerWhileModal(false) }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        wait.stage(StagedUpdate(version: item.displayVersionString, build: item.versionString), install: immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        guard failure.domain == SUSparkleErrorDomain, failure.code != Int(SUError.noUpdateError.rawValue) else { return }
        trouble = "\(failure.code): \(failure.localizedDescription)"
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if error == nil { trouble = nil }
        turn += 1
    }
}

@MainActor
enum UpdateWindows {
    private static func ours(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        let sparkle = Bundle(for: SPUUpdater.self)
        if let holder = window.windowController, Bundle(for: type(of: holder)) == sparkle { return true }
        if Bundle(for: type(of: window)) == sparkle { return true }
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
