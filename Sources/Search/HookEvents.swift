import AppKit
import UniformTypeIdentifiers
import WebKit

enum HookLinkAnswer: Equatable {
    case space(UUID, String)
    case app(String, String)
    case privately
}

@MainActor
enum HookLinks {
    static func read(_ object: [String: Any], spaces: [(id: UUID, name: String)], usesSpaces: Bool, broadway: String,
                     app: (String) -> String?) -> HookReading<HookLinkAnswer> {
        let known: Set<String> = ["space", "private", "app"]
        let given = Set(object.keys)
        guard given.isSubset(of: known) else { return .wrong("Its answer named nothing Broadway knows") }
        guard given.count == 1, let key = given.first else { return .wrong("It gave more than one answer") }
        switch key {
        case "space":
            guard let name = object["space"] as? String else { return .wrong("Its space wasn't a name") }
            guard usesSpaces else { return .wrong("It named a space, and spaces are off") }
            let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
            guard let space = spaces.first(where: { $0.name.lowercased() == wanted }) else {
                return .wrong("It named a space that doesn't exist: \(name)")
            }
            return .answer(.space(space.id, space.name))
        case "private":
            guard object["private"] as? Bool == true else { return .wrong("Its private answer wasn't true") }
            return .answer(.privately)
        default:
            guard let bundle = object["app"] as? String, !bundle.isEmpty else { return .wrong("Its app wasn't an identifier") }
            guard bundle.lowercased() != broadway.lowercased() else { return .wrong("It named Broadway itself") }
            guard let name = app(bundle) else { return .wrong("It named an app that isn't installed: \(bundle)") }
            return .answer(.app(bundle, name))
        }
    }

    static func installed(_ bundle: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func fields(_ link: IncomingLink, url: URL, front: Browser) -> [String: Any] {
        var from = ""
        if case .app(let bundle, _) = link.source { from = bundle }
        return ["url": url.absoluteString, "from": from, "space": front.prefs.usesSpaces ? front.space.name : ""]
    }

    static func consider(_ link: IncomingLink, front: Browser? = nil, book: HookBook = .shared, deliver: @escaping (IncomingLink) -> Void) {
        guard link.source.outside, !link.chooses, link.hooked == nil, !book.ready(for: .link).isEmpty,
              ["http", "https"].contains(link.url.scheme?.lowercased() ?? ""),
              let front = front ?? Browsers.front ?? Browsers.primary, !front.isPrivate else { return deliver(link) }
        let (decision, _) = Browsers.decide(link, from: front)
        guard decision.defaulted else { return deliver(link) }
        let spaces = front.spaces.map { (id: $0.id, name: $0.name) }
        let uses = front.prefs.usesSpaces
        let broadway = Bundle.main.bundleIdentifier ?? ""
        HookGate.ask(.link, fields(link, url: decision.url, front: front), scene: .outside, book: book, read: { object in
            read(object, spaces: spaces, usesSpaces: uses, broadway: broadway, app: installed)
        }) { answer in
            guard let answer else { return deliver(link) }
            if answer == .privately {
                Browsers.newPrivateWindow().land(decision.url, background: false)
                return
            }
            var hooked = link
            hooked.hooked = answer
            deliver(hooked)
        }
    }

    static func decision(_ answer: HookLinkAnswer, over decided: LinkDecision, world: LinkWorld) -> LinkDecision {
        guard decided.defaulted else { return decided }
        var decision = decided
        switch answer {
        case .space(let id, _):
            guard world.usesSpaces, world.space(id) != nil else { return decided }
            decision.place = id == world.front ? .here : .space(id, folder: nil)
        case .app(let bundle, let name):
            decision.place = .app(bundleID: bundle, name: name)
        case .privately:
            return decided
        }
        decision.defaulted = false
        decision.steps.append("Your hook chose it: " + LinkRouter.words(decision.place, world: world).lowercasedFirst)
        return decision
    }
}

@MainActor
enum HookAsk {
    static func wants(_ type: WKMediaCaptureType) -> [String] {
        switch type {
        case .camera: ["camera"]
        case .microphone: ["microphone"]
        case .cameraAndMicrophone: ["camera", "microphone"]
        @unknown default: []
        }
    }

    static func read(_ object: [String: Any]) -> HookReading<Bool> {
        guard Set(object.keys) == ["answer"] else { return .wrong("Its answer named nothing Broadway knows") }
        switch object["answer"] as? String {
        case "allow": return .answer(true)
        case "deny": return .answer(false)
        default: return .wrong("Its answer wasn't allow or deny")
        }
    }

    static func permission(site: String, wants: [String], scene: HookScene?, book: HookBook = .shared, done: @escaping (Bool?) -> Void) {
        guard !wants.isEmpty else { return done(nil) }
        HookGate.ask(.permission, ["site": site, "wants": wants], scene: scene, book: book, read: read, done: done)
    }

    static func permission(site: String, wants: [String], tab: Tab?, in browser: Browser, asker: String? = nil,
                           done: @escaping (Bool?) -> Void) {
        if let asker, Browser.extensionScheme(asker) { return done(nil) }
        permission(site: site, wants: wants, scene: HookScene.of(tab, in: browser), done: done)
    }
}

@MainActor
enum HookDownloads {
    static func read(_ object: [String: Any], home: URL) -> HookReading<URL> {
        guard Set(object.keys) == ["folder"] else { return .wrong("Its answer named nothing Broadway knows") }
        guard var text = object["folder"] as? String, !text.isEmpty else { return .wrong("Its folder wasn't a path") }
        if text == "~" { text = home.path } else if text.hasPrefix("~/") { text = home.path + "/" + text.dropFirst(2) }
        guard text.hasPrefix("/") else { return .wrong("Its folder wasn't a full path") }
        let folder = URL(fileURLWithPath: text).standardizedFileURL.resolvingSymlinksInPath()
        guard HookGate.inside(folder, home) else { return .wrong("Its folder is outside your home folder") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &directory), directory.boolValue else {
            return .wrong("Its folder doesn't exist")
        }
        return .answer(folder)
    }

    static func type(of file: URL) -> String {
        UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func eligible(asksWhereToSave: Bool, privateWindow: Bool, agentDownload: Bool) -> Bool {
        !asksWhereToSave && !privateWindow && !agentDownload
    }

    static func finished(_ download: WKDownload, file: URL, source: URL?, in browser: Browser) {
        guard eligible(asksWhereToSave: browser.prefs.asksWhereToSave, privateWindow: browser.isPrivate,
                       agentDownload: AgentDownloadWatch.watches(download)) else { return }
        let scene: HookScene?
        if let web = download.webView, let tab = browser.anyTab(for: web) {
            scene = HookScene.of(tab, in: browser)
        } else {
            scene = HookScene(privately: download.webView.map { !$0.configuration.websiteDataStore.isPersistent } ?? false)
        }
        finished(file, site: source?.host() ?? "", scene: scene, loot: browser.loot)
    }

    static func finished(_ file: URL, site: String, scene: HookScene?, loot: Loot, book: HookBook = .shared, home: URL? = nil,
                         done: ((URL?) -> Void)? = nil) {
        let home = home ?? HookGate.home
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        let fields: [String: Any] = ["file": file.path, "site": site, "type": type(of: file), "size": size]
        HookGate.ask(.download, fields, scene: scene, book: book, read: { read($0, home: home) }) { folder in
            guard let folder else {
                done?(nil)
                return
            }
            Task.detached(priority: .utility) {
                let moved = move(file, to: folder)
                await MainActor.run {
                    if let moved, moved != file, let kept = loot.kept.first(where: { $0.path == file.path }) {
                        loot.forget(kept)
                        loot.restore(Keep(name: moved.lastPathComponent, from: kept.from, path: moved.path, date: kept.date))
                    }
                    done?(moved)
                }
            }
        }
    }

    nonisolated static func move(_ file: URL, to folder: URL) -> URL? {
        guard file.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath() != folder else { return file }
        let name = file.lastPathComponent
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name)
        var number = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)")
            number += 1
        }
        do {
            try FileManager.default.moveItem(at: file, to: target)
            return target
        } catch {
            return nil
        }
    }
}

@MainActor
enum HookClock {
    private static var timer: Timer?
    private(set) static var started = Date()
    private(set) static var last: [UUID: Date] = [:]
    private static var running: Set<UUID> = []

    static func start() {
        guard timer == nil else { return }
        started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    static func reset(at date: Date = Date()) {
        started = date
        last = [:]
        running = []
    }

    static func tick(now: Date = Date(), book: HookBook = .shared) {
        for hook in book.ready(for: .timer) where !running.contains(hook.id) {
            let since = last[hook.id] ?? started
            guard now.timeIntervalSince(since) >= Double(hook.minutes * 60) else { continue }
            last[hook.id] = now
            running.insert(hook.id)
            let fields: [String: Any] = ["time": ISO8601DateFormatter().string(from: now), "minutes": hook.minutes]
            HookGate.ask(.timer, fields, scene: .outside, book: book, only: hook.id, read: { _ -> HookReading<Bool> in .nothing }) { _ in
                running.remove(hook.id)
            }
        }
    }
}
