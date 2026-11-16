import AppKit
import UniformTypeIdentifiers
import WebKit

enum AgentUploadRule {
    static let temporary = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
    static let keyNames = try? NSRegularExpression(pattern: "^id_(rsa|dsa|ecdsa|ed25519)(\\.pub)?$|\\.keychain(-db)?$", options: [.caseInsensitive])

    static func inside(_ path: String, _ folder: String) -> Bool {
        let root = folder.hasSuffix("/") ? String(folder.dropLast()) : folder
        return path == root || path.hasPrefix(root + "/")
    }

    static func refusal(_ path: String, home: String = NSHomeDirectory(), own: String = Store.file("").path,
                        kept: String = AgentDownloads.root.path) -> String? {
        guard path.hasPrefix("/") else { return "Give a full path" }
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") }) { return "Hidden files and dotfiles are never given to a site" }
        let last = parts.last ?? ""
        if let keyNames, keyNames.firstMatch(in: last, range: NSRange(last.startIndex..., in: last)) != nil {
            return "Keys and keychains are never given to a site"
        }
        if inside(path, kept) { return nil }
        if AgentMac.closed(path, home: home, own: own) || inside(path, own) { return "Broadway's own data and the Mac's secrets are never given to a site" }
        if inside(path, home + "/Library") { return "Files in your Library folder are never given to a site" }
        guard inside(path, home) || temporary.contains(where: { inside(path, $0) }) else {
            return "Only files in your home folder or a temporary folder can be given to a site"
        }
        return nil
    }
}

struct AgentFileFacts: Sendable {
    var asked: URL
    var url: URL
    var exists = false
    var folder = false
    var readable = false
    var bytes = 0

    var type: String { UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream" }

    var row: [String: Any] { ["name": url.lastPathComponent, "path": url.path, "bytes": bytes, "type": type] }
}

enum AgentFileLook {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    static func examine(_ asked: URL) -> AgentFileFacts {
        DownloadPlace.stall(asked.path)
        let url = asked.resolvingSymlinksInPath()
        var facts = AgentFileFacts(asked: asked, url: url)
        var folder: ObjCBool = false
        facts.exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &folder)
        facts.folder = folder.boolValue
        guard facts.exists, !facts.folder else { return facts }
        facts.bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if let handle = try? FileHandle(forReadingFrom: url) {
            facts.readable = true
            try? handle.close()
        }
        return facts
    }

    static func look(_ urls: [URL], seconds: Double) async -> [AgentFileFacts]? {
        await withCheckedContinuation { done in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let found = urls.map(examine)
                if once.take() { done.resume(returning: found) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.take() { done.resume(returning: nil) }
            }
        }
    }

    static func bytes(_ urls: [URL], seconds: Double) async -> [Data]? {
        await withCheckedContinuation { done in
            let once = Once()
            DispatchQueue.global(qos: .userInitiated).async {
                let found = urls.compactMap { try? Data(contentsOf: $0) }
                if once.take() { done.resume(returning: found.count == urls.count ? found : nil) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.take() { done.resume(returning: nil) }
            }
        }
    }
}

enum AgentAccept {
    static func takes(_ accept: String, name: String, type: String) -> Bool {
        let wanted = accept.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return true }
        let lowerName = name.lowercased()
        let lowerType = type.lowercased()
        return wanted.contains { token in
            if token.hasPrefix(".") { return lowerName.hasSuffix(token) }
            if token.hasSuffix("/*") { return lowerType.hasPrefix(String(token.dropLast(1))) }
            return lowerType == token
        }
    }
}

@MainActor
final class AgentUploadArm {
    private static var armed: [ObjectIdentifier: AgentUploadArm] = [:]

    let urls: [URL]
    let host: String
    private var waiting: CheckedContinuation<Bool, Never>?
    private(set) var answered: Bool?

    init(urls: [URL], host: String) {
        self.urls = urls
        self.host = host
    }

    static func arm(_ arm: AgentUploadArm, on web: WKWebView) {
        armed[ObjectIdentifier(web)] = arm
    }

    static func disarm(_ web: WKWebView) {
        armed[ObjectIdentifier(web)] = nil
    }

    static func take(_ web: WKWebView, frame: WKFrameInfo, multiple: Bool) -> [URL]? {
        guard let arm = armed.removeValue(forKey: ObjectIdentifier(web)) else { return nil }
        guard frame.securityOrigin.host == arm.host, multiple || arm.urls.count == 1 else {
            arm.settle(false)
            return []
        }
        arm.settle(true)
        return arm.urls
    }

    private func settle(_ given: Bool) {
        answered = given
        waiting?.resume(returning: given)
        waiting = nil
    }

    func wait(seconds: Double) async -> Bool? {
        if let answered { return answered }
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.answered == nil else { return }
            self.waiting?.resume(returning: false)
            self.waiting = nil
        }
        let given = await withCheckedContinuation { self.waiting = $0 }
        timer.cancel()
        return answered == nil ? nil : given
    }
}

extension AgentPage {
    private static let uploadTarget = """
    var input = target && target.tagName === 'INPUT' && target.type === 'file' ? target : null;
    if (!input && el.tagName === 'INPUT' && el.type === 'file') input = el;
    if (!input && el.tagName === 'LABEL' && el.control && el.control.type === 'file') input = el.control;
    if (!input) input = el.querySelector('input[type=file]');
    for (var up = el.parentElement, i = 0; !input && up && i < 2; up = up.parentElement, i++) {
      var near = up.querySelectorAll('input[type=file]');
      if (near.length === 1) input = near[0];
    }
    if (input && (input.disabled || (input.closest && input.closest('fieldset[disabled]')))) return { failed: 'That file field is disabled.' };

    """

    static let uploadLookScript = find + uploadTarget + """
    return { input: !!input, multiple: input ? !!input.multiple : true, accept: input ? (input.accept || '') : '',
             directory: !!(input && input.webkitdirectory), host: location.hostname };
    """

    static let uploadClickScript = find + uploadTarget + """
    if (!input) return { failed: 'That element has no file field.' };
    input.click();
    return { ok: true };
    """

    static let uploadBytesScript = find + uploadTarget + """
    var transfer = new DataTransfer();
    for (var f = 0; f < files.length; f++) {
      var raw = atob(files[f].data), bytes = new Uint8Array(raw.length);
      for (var b = 0; b < raw.length; b++) bytes[b] = raw.charCodeAt(b);
      transfer.items.add(new File([bytes], files[f].name, { type: files[f].type, lastModified: Date.now() }));
    }
    if (input) {
      input.files = transfer.files;
      input.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
      input.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
      return { how: 'field', taken: input.files.length === files.length };
    }
    var r = el.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
    function drag(type) {
      var event = new DragEvent(type, { bubbles: true, cancelable: true, composed: true, clientX: x, clientY: y, dataTransfer: transfer });
      if (!event.dataTransfer) Object.defineProperty(event, 'dataTransfer', { value: transfer });
      return el.dispatchEvent(event);
    }
    drag('dragenter');
    var over = drag('dragover');
    var dropped = drag('drop');
    return { how: 'drop', taken: !over || !dropped };
    """
}

enum AgentDownloads {
    static var root: URL { Store.file("Agent Downloads") }
}

extension BrowserToolbox {
    static let uploadLimit = 25 * 1024 * 1024

    func upload(_ tab: Tab, _ arguments: [String: Any], task: UUID?) async -> ToolOutcome {
        let ref = arguments["ref"] as? String ?? ""
        let paths = (arguments["paths"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard (1...20).contains(paths.count) else { return .failure("upload takes one to twenty files") }
        let asked = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
        for url in asked {
            if let refused = AgentUploadRule.refusal(url.path) { return .failure("\(url.lastPathComponent): \(refused.fullStopped) Nothing was attached.") }
        }
        acting(tab, "Attaching")
        guard let files = await AgentFileLook.look(asked, seconds: 8) else {
            return .failure("macOS is asking the person whether Broadway may open that folder. Nothing was attached. Tell them, then try again.")
        }
        for file in files {
            guard file.exists else { return .failure("There's no file at \(file.asked.path). Nothing was attached.") }
            guard !file.folder else { return .failure("\(file.url.lastPathComponent) is a folder: only files can be given. Nothing was attached.") }
            guard file.readable else { return .failure("Broadway can't read \(file.url.path). Nothing was attached.") }
            if let refused = AgentUploadRule.refusal(file.url.path) { return .failure("\(file.url.lastPathComponent): \(refused.fullStopped) Nothing was attached.") }
        }
        guard let look = await inFrame(tab, ref, AgentPage.uploadLookScript) as? [String: Any] else { return .failure("The page gave no answer") }
        if let failed = look["failed"] as? String { return .failure(failed) }
        let field = look["input"] as? Bool == true
        let accept = look["accept"] as? String ?? ""
        if look["directory"] as? Bool == true { return .failure("That field asks for a folder, and only files can be given. Nothing was attached.") }
        if field, look["multiple"] as? Bool != true, files.count > 1 { return .failure("That field takes one file, and \(files.count) were given. Nothing was attached.") }
        if let wrong = files.first(where: { !AgentAccept.takes(accept, name: $0.url.lastPathComponent, type: $0.type) }) {
            return .failure("That field takes \(accept), and \(wrong.url.lastPathComponent) isn't one. Nothing was attached.")
        }
        let host = look["host"] as? String ?? ""
        let site = AgentSites.site(of: tab.pageAddress)
        let place = tab.pageAddress
        let names = files.map(\.url.lastPathComponent).joined(separator: ", ")
        let outside = TaskLedger.shared.entry(task)?.origin == .outside
        if outside {
            if let refused = await gate(.upload, tab: tab, site: site, task: task, quote: names, said: "Files") { return refused }
        } else if let refused = await gate(.mac, tab: tab, site: site, task: task, quote: files.map(\.url.path).joined(separator: "\n"),
                                           reason: "To give to \(host.isEmpty ? "this site" : host)", said: "It wants to upload") {
            return refused
        }
        guard tab.pageAddress == place else { return .failure("The page changed while the person was answering, so nothing was attached. Look again.") }
        if let again = await inFrame(tab, ref, AgentPage.uploadLookScript) as? [String: Any], let failed = again["failed"] as? String { return .failure(failed) }
        var how = ""
        if field, let web = tab.built {
            let arm = AgentUploadArm(urls: files.map(\.url), host: host)
            AgentUploadArm.arm(arm, on: web)
            let clicked = await inFrame(tab, ref, AgentPage.uploadClickScript) as? [String: Any]
            if let failed = clicked?["failed"] as? String {
                AgentUploadArm.disarm(web)
                return .failure(failed)
            }
            let given = await arm.wait(seconds: 2)
            AgentUploadArm.disarm(web)
            if given == false { return .failure("That field refused the files. Nothing was attached.") }
            if given == true { how = "chooser" }
        }
        if how.isEmpty {
            guard files.reduce(0, { $0 + $1.bytes }) <= Self.uploadLimit else {
                return .failure("That control takes files only by dropping, and Broadway drops at most 25 MB at once. Nothing was attached.")
            }
            guard let datas = await AgentFileLook.bytes(files.map(\.url), seconds: 8) else { return .failure("Broadway couldn't read those files in time. Nothing was attached.") }
            let rows: [[String: Any]] = zip(files, datas).map { ["name": $0.url.lastPathComponent, "type": $0.type, "data": $1.base64EncodedString()] }
            guard let said = await inFrame(tab, ref, AgentPage.uploadBytesScript, ["files": rows]) as? [String: Any] else { return .failure("The page gave no answer") }
            if let failed = said["failed"] as? String { return .failure(failed) }
            guard said["taken"] as? Bool == true else { return .failure("The page didn't take the files. Nothing was attached.") }
            how = said["how"] as? String ?? "field"
        }
        if !tab.shy { Uploads.shared.add(files.map(\.url), to: host) }
        let total = files.reduce(0) { $0 + $1.bytes }
        let text = "Attached \(names) (\(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))) to \(host.isEmpty ? "the page" : host)"
        return ToolOutcome(text: text, data: ["attached": files.map(\.row), "site": host, "how": how, "message": text])
    }
}
