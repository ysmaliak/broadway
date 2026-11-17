import AppKit
import WebKit

@MainActor
final class SaveAskReply {
    private var completion: ((URL?) -> Void)?
    private(set) var finished = false

    init(_ completion: @escaping (URL?) -> Void) { self.completion = completion }

    func finish(_ file: URL?) {
        guard !finished else { return }
        finished = true
        let completion = completion
        self.completion = nil
        completion?(file)
    }

    deinit { completion?(nil) }
}

@MainActor
final class SaveAsk {
    static let shared = SaveAsk()
    static let foldersKey = "downloads.ask.folders"
    static let latestKey = "latest"

    @MainActor
    final class Question {
        let id = UUID()
        let name: String
        let folder: URL
        let tab: Tab.ID?
        let space: String?
        let download: ObjectIdentifier?
        let reply: SaveAskReply
        weak var window: NSWindow?
        let windowKey: ObjectIdentifier?
        fileprivate(set) var up = false
        fileprivate var panel: NSSavePanel?
        fileprivate var real: Bool

        fileprivate init(name: String, folder: URL, tab: Tab.ID?, space: String?, download: ObjectIdentifier?,
                         window: NSWindow?, real: Bool, reply: SaveAskReply) {
            self.name = name
            self.folder = folder
            self.tab = tab
            self.space = space
            self.download = download
            self.window = window
            self.windowKey = window.map(ObjectIdentifier.init)
            self.real = real
            self.reply = reply
        }

        var sheetShown: Bool { panel != nil }
        var keepsFolder: Bool { space != nil }
    }

    private(set) var questions: [Question] = []
    var realNext = 0
    private var watched: [ObjectIdentifier: Any] = [:]

    static var held: Bool { Store.testing }

    func ask(_ name: String, from webView: WKWebView?, in browser: Browser, download: WKDownload? = nil, quiet: Bool = false,
             then completion: @escaping (URL?) -> Void) {
        let owners = [browser] + Browsers.all.filter { $0 !== browser }
        let found = webView.flatMap { web in
            owners.lazy.compactMap { owner in owner.anyTab(for: web).map { (owner, $0) } }.first
        }
        let owner = found?.0 ?? browser
        let tab = found?.1
        let shy = quiet || owner.isPrivate || tab?.shy == true || webView?.configuration.websiteDataStore.isPersistent == false
        let spaceID = tab.map { tab in
            owner.tabs.contains { $0.id == tab.id } ? owner.spaceID
                : owner.parked.first { $0.value.tabs.contains { $0.id == tab.id } }?.key ?? owner.spaceID
        } ?? owner.spaceID
        let space = shy ? nil : spaceID.uuidString
        let start = Self.lastFolder(for: space) ?? (shy ? owner.downloadsFolder : owner.downloadsFolder(in: spaceID))
        let window = webView?.window ?? owner.window ?? browser.window
        let real = !Self.held || realNext > 0
        realNext = max(0, realNext - 1)
        let question = Question(name: name, folder: start, tab: tab?.id, space: space, download: download.map(ObjectIdentifier.init),
                                window: window, real: real, reply: SaveAskReply(completion))
        questions.append(question)
        if let window, watched[ObjectIdentifier(window)] == nil {
            watched[ObjectIdentifier(window)] = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.windowClosed(window)
                }
            }
        }
        advance(question.windowKey)
    }

    func answer(_ file: URL, id: UUID? = nil) -> Bool {
        guard let question = pick(id), question.up else { return false }
        finish(question, with: file)
        return true
    }

    func cancel(id: UUID? = nil) -> Bool {
        guard let question = pick(id) else { return false }
        finish(question, with: nil)
        return true
    }

    func save(id: UUID? = nil) -> Bool {
        guard let question = pick(id), question.up, let panel = question.panel,
              let window = question.window, window.attachedSheet === panel else { return false }
        panel.makeKeyAndOrderFront(nil)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, characters: "\r",
                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
        return true
    }

    func tabClosed(_ ids: Set<Tab.ID>) {
        for question in questions where question.tab.map(ids.contains) == true { finish(question, with: nil) }
    }

    func downloadEnded(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        for question in questions where question.download == key { finish(question, with: nil) }
    }

    func windowClosed(_ window: NSWindow) {
        let key = ObjectIdentifier(window)
        for question in questions where question.windowKey == key { finish(question, with: nil) }
        if let observer = watched.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
    }

    func cancelAll() {
        for question in questions { finish(question, with: nil) }
    }

    private func pick(_ id: UUID?) -> Question? {
        guard let id else { return questions.first { $0.up } ?? questions.first }
        return questions.first { $0.id == id }
    }

    private func advance(_ key: ObjectIdentifier?) {
        guard let next = questions.first(where: { $0.windowKey == key }), !next.up else { return }
        if key != nil, next.window == nil { return finish(next, with: nil) }
        next.up = true
        guard next.real else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = next.name
        panel.directoryURL = next.folder
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        next.panel = panel
        let done: (NSApplication.ModalResponse) -> Void = { [weak self, weak next, weak panel] response in
            guard let self, let next, !next.reply.finished else { return }
            let file = response == .OK ? panel?.url : nil
            next.panel = nil
            self.finish(next, with: file)
        }
        if let window = next.window {
            panel.beginSheetModal(for: window, completionHandler: done)
        } else {
            panel.begin(completionHandler: done)
        }
    }

    private func finish(_ question: Question, with file: URL?) {
        guard !question.reply.finished, let index = questions.firstIndex(where: { $0 === question }) else { return }
        questions.remove(at: index)
        if let panel = question.panel {
            question.panel = nil
            if let window = question.window, window.attachedSheet === panel { window.endSheet(panel, returnCode: .cancel) }
            else { panel.cancel(nil) }
        }
        if let file {
            Self.clear(file)
            if let space = question.space { Self.remember(file.deletingLastPathComponent(), for: space) }
        }
        question.reply.finish(file)
        advance(question.windowKey)
    }

    private static func clear(_ file: URL) {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true || values.isSymbolicLink == true else { return }
        do {
            try FileManager.default.trashItem(at: file, resultingItemURL: nil)
        } catch {
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func lastFolder(for space: String?) -> URL? {
        let kept = Store.settings.dictionary(forKey: foldersKey) as? [String: String] ?? [:]
        guard let path = kept[space ?? latestKey] else { return nil }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func remember(_ folder: URL, for space: String) {
        var kept = Store.settings.dictionary(forKey: foldersKey) as? [String: String] ?? [:]
        kept[space] = folder.path
        kept[latestKey] = folder.path
        Store.settings.set(kept, forKey: foldersKey)
    }

    func state() -> [String: Any] {
        ["questions": questions.map { question -> [String: Any] in
            [
                "id": question.id.uuidString.lowercased(), "name": question.name, "folder": question.folder.path,
                "tab": question.tab?.uuidString.lowercased() ?? "", "window": question.window?.windowNumber ?? 0,
                "private": !question.keepsFolder, "up": question.up, "real": question.real, "sheet": question.sheetShown,
                "attached": question.window?.attachedSheet.map { String(describing: type(of: $0)) } ?? "",
                "attachedIsPanel": question.panel != nil && question.window?.attachedSheet === question.panel,
                "attachedNumber": question.window?.attachedSheet?.windowNumber ?? 0,
                "shownName": question.panel?.nameFieldStringValue ?? "",
            ]
        }, "realNext": realNext]
    }
}
