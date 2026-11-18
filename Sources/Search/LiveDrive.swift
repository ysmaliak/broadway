import Foundation
import WebKit

enum LiveDrive {
    static let recent = "https://drive.google.com/drive/recent"
    static let source = LiveSource(kind: .page, address: recent)
    static let every: TimeInterval = 15 * 60
    static let marker = "_DRIVE_ivd"
    static let signInHosts: Set<String> = ["accounts.google.com", "consent.google.com", "workspace.google.com"]

    struct File: Equatable {
        var id: String
        var title: String
        var mime: String
        var modified: Date
        var link: URL?
    }

    struct Look: Equatable {
        var landed: URL?
        var status: Int?
        var headers: [String: String] = [:]
        var script: String?
    }

    static func reads(_ source: LiveSource) -> Bool {
        guard source.kind == .page, let url = URL(string: source.address), url.host()?.lowercased() == "drive.google.com" else { return false }
        let path = url.path().split(separator: "/").map(String.init)
        return path == ["drive", "recent"] || (path.count == 4 && path[0] == "drive" && path[1] == "u" && Int(path[2]) != nil && path[3] == "recent")
    }

    static func literal(in text: String) -> String? {
        let chars = Array(text.unicodeScalars)
        let mark = Array(marker.unicodeScalars)
        var from = 0
        while let start = find(mark, in: chars, from: from) {
            from = start + mark.count
            var i = from
            while i < chars.count, chars[i] == "'" || chars[i] == "\"" || chars[i] == "]" || chars[i] == " " { i += 1 }
            guard i + 1 < chars.count, chars[i] == "=", chars[i + 1] != "=" else { continue }
            i += 1
            while i < chars.count, chars[i] == " " { i += 1 }
            guard i < chars.count, chars[i] == "'" || chars[i] == "\"" else { return nil }
            return unescaped(chars, from: i + 1, quote: chars[i])
        }
        return nil
    }

    private static func find(_ mark: [Unicode.Scalar], in chars: [Unicode.Scalar], from: Int) -> Int? {
        guard mark.count <= chars.count else { return nil }
        var i = from
        while i + mark.count <= chars.count {
            if chars[i] == mark[0], Array(chars[i..<i + mark.count]) == mark { return i }
            i += 1
        }
        return nil
    }

    private static func hex(_ chars: [Unicode.Scalar], _ at: Int, _ count: Int) -> UInt32? {
        guard at + count <= chars.count else { return nil }
        return UInt32(String(String.UnicodeScalarView(chars[at..<at + count])), radix: 16)
    }

    private static func unescaped(_ chars: [Unicode.Scalar], from start: Int, quote: Unicode.Scalar) -> String? {
        var out = String.UnicodeScalarView()
        var i = start
        while i < chars.count {
            let c = chars[i]
            i += 1
            if c == quote { return String(out) }
            guard c == "\\" else {
                out.append(c)
                continue
            }
            guard i < chars.count else { return nil }
            let e = chars[i]
            i += 1
            switch e {
            case "x":
                guard let v = hex(chars, i, 2), let s = Unicode.Scalar(v) else { return nil }
                out.append(s)
                i += 2
            case "u":
                guard var v = hex(chars, i, 4) else { return nil }
                i += 4
                if (0xD800..<0xDC00).contains(v), i + 5 < chars.count, chars[i] == "\\", chars[i + 1] == "u",
                   let low = hex(chars, i + 2, 4), (0xDC00..<0xE000).contains(low) {
                    v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                    i += 6
                }
                guard let s = Unicode.Scalar(v) else { return nil }
                out.append(s)
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "b": out.append("\u{8}")
            case "f": out.append("\u{c}")
            default: out.append(e)
            }
        }
        return nil
    }

    static func files(in script: String, now: Date = Date()) -> [File]? {
        guard let text = literal(in: script),
              let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any],
              let list = json.first as? [Any] else { return nil }
        var out: [File] = []
        for entry in list {
            guard let fields = entry as? [Any], let made = file(from: fields, now: now) else { return nil }
            out.append(made)
        }
        return out
    }

    private static func slot(_ file: [Any], _ at: Int) -> Any? {
        file.indices.contains(at) && !(file[at] is NSNull) ? file[at] : nil
    }

    private static func millis(_ value: Any?, now: Date) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let ms = number.doubleValue
        guard ms > 1e12, ms < (now.timeIntervalSince1970 + 2 * 86_400) * 1000 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    private static func file(from file: [Any], now: Date) -> File? {
        guard let id = LiveDocuments.driveID(slot(file, 0) as? String),
              let title = (slot(file, 2) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let mime = (slot(file, 3) as? String)?.lowercased(),
              mime.range(of: #"^[a-z]+/[a-z0-9.+_-]+$"#, options: .regularExpression) != nil,
              let modified = millis(slot(file, 10), now: now) else { return nil }
        var link: URL?
        if let given = slot(file, 114) {
            guard let text = given as? String, let url = URL(string: text), url.scheme == "https",
                  LiveIdentity.of(text) == "drive:" + id else { return nil }
            link = url
        }
        return File(id: id, title: title, mime: mime, modified: modified, link: link)
    }

    static func kind(_ mime: String) -> String? {
        let apps = "application/vnd.google-apps."
        if mime.hasPrefix(apps) {
            switch mime.dropFirst(apps.count) {
            case "folder", "shortcut": return nil
            case "document": return "Doc"
            case "spreadsheet": return "Sheet"
            case "presentation": return "Slides"
            case "form": return "Form"
            case "drawing": return "Drawing"
            case "site": return "Site"
            default: return "File"
            }
        }
        if mime == "application/pdf" { return "PDF" }
        if mime.contains("wordprocessingml") || mime == "application/msword" { return "Word" }
        if mime.contains("spreadsheetml") || mime == "application/vnd.ms-excel" { return "Excel" }
        if mime.contains("presentationml") || mime == "application/vnd.ms-powerpoint" { return "PowerPoint" }
        if mime.hasPrefix("image/") { return "Image" }
        if mime.hasPrefix("video/") { return "Video" }
        if mime.hasPrefix("audio/") { return "Audio" }
        if mime.hasPrefix("text/") { return "Text" }
        return "File"
    }

    static func link(_ file: File) -> URL? {
        if let given = file.link { return given }
        let editors = ["application/vnd.google-apps.document": "document", "application/vnd.google-apps.spreadsheet": "spreadsheets",
                       "application/vnd.google-apps.presentation": "presentation", "application/vnd.google-apps.drawing": "drawings",
                       "application/vnd.google-apps.form": "forms"]
        if let editor = editors[file.mime] { return URL(string: "https://docs.google.com/\(editor)/d/\(file.id)/edit") }
        return URL(string: "https://drive.google.com/file/d/\(file.id)/view")
    }

    static func items(_ files: [File]) -> [LiveItem] {
        files.enumerated()
            .filter { kind($0.element.mime) != nil }
            .sorted { ($0.element.modified, -$0.offset) > ($1.element.modified, -$1.offset) }
            .compactMap { entry in
                link(entry.element).map { LiveItem(key: $0.absoluteString, title: entry.element.title, label: kind(entry.element.mime),
                                                   updated: entry.element.modified) }
            }
    }

    static func signedOut(_ landed: URL?) -> Bool {
        guard let host = landed?.host()?.lowercased() else { return false }
        return signInHosts.contains(host)
    }

    static func answer(_ look: Look, source: LiveSource, now: Date = Date()) -> LiveReader.Answer {
        if look.script == nil, let miss = LiveLimit.miss(status: look.status, headers: look.headers, page: false, now: now) {
            return .missed(miss)
        }
        if signedOut(look.landed) { return .signIn }
        guard look.landed?.host()?.lowercased() == "drive.google.com", let status = look.status, (200..<300).contains(status),
              let script = look.script, let files = files(in: script, now: now) else { return .failed }
        let all = items(files)
        let cap = source.cap
        return .read(LiveRead(items: Array(all.prefix(cap)), whole: true, marked: files.isEmpty,
                              more: all.count > cap ? source.address : nil))
    }

    @MainActor
    static func stage(settings: UserDefaults = Store.settings, testing: Bool = Store.testing) -> URL? {
        Integrations.fixture(.gitHub, settings: settings, testing: testing)?.deletingLastPathComponent().appendingPathComponent("stage")
    }

    static func staged(_ url: URL, root: URL) -> URL {
        let query = url.query(percentEncoded: true).map { "?" + $0 } ?? ""
        return URL(string: root.absoluteString + "/" + (url.host() ?? "") + url.path(percentEncoded: true) + query) ?? url
    }

    static func unstaged(_ url: URL, root: URL) -> URL {
        let text = url.absoluteString
        let prefix = root.absoluteString + "/"
        guard text.hasPrefix(prefix) else { return url }
        return URL(string: "https://" + text.dropFirst(prefix.count)) ?? url
    }

    @MainActor
    static func read(_ folder: LiveFolder, settings: UserDefaults = Store.settings, testing: Bool = Store.testing) async -> LiveReader.Answer? {
        guard reads(folder.source), let asked = URL(string: folder.source.address) else { return nil }
        let root = stage(settings: settings, testing: testing)
        if testing, root == nil { return .failed }
        return await read(asked, root: root, source: folder.source, store: Spaces.store(for: folder.space))
    }

    @MainActor
    static func read(_ asked: URL, root: URL?, source: LiveSource, store: WKWebsiteDataStore, now: Date = Date()) async -> LiveReader.Answer {
        let url = root.map { staged(asked, root: $0) } ?? asked
        guard var look = await LiveDriveLoad.look(url, store: store) else { return .failed }
        if let root, let landed = look.landed { look.landed = unstaged(landed, root: root) }
        return answer(look, source: source, now: now)
    }
}

extension LiveSource {
    var heavy: Bool { LiveDrive.reads(self) }
}

@MainActor
final class LiveDriveLoad: NSObject, WKNavigationDelegate {
    private static var running: [LiveDriveLoad] = []
    private(set) static var loads = 0
    private var finished: CheckedContinuation<Bool, Never>?
    private var status: Int?
    private var headers: [String: String] = [:]

    static let script = """
    (function () {
      var found = null, all = document.getElementsByTagName('script');
      for (var i = 0; i < all.length; i++) {
        var text = all[i].textContent || '';
        if (text.indexOf('\(LiveDrive.marker)') >= 0) { found = text; break; }
      }
      return JSON.stringify({ href: location.href, script: found });
    })()
    """

    private struct Seen: Decodable {
        var href: String
        var script: String?
    }

    static func look(_ url: URL, store: WKWebsiteDataStore) async -> LiveDrive.Look? {
        loads += 1
        let load = LiveDriveLoad()
        running.append(load)
        defer { running.removeAll { $0 === load } }
        return await load.look(url, store: store)
    }

    private func look(_ url: URL, store: WKWebsiteDataStore) async -> LiveDrive.Look? {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: configuration)
        web.navigationDelegate = self
        defer {
            web.stopLoading()
            web.navigationDelegate = nil
        }
        let loaded = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            finished = done
            web.load(URLRequest(url: url, timeoutInterval: 25))
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in self?.finish(false) }
        }
        guard loaded else { return nil }
        var seen: Seen?
        for wait in [0.2, 1.0, 2.0] {
            try? await Task.sleep(for: .seconds(wait))
            guard let text = try? await web.evaluateJavaScript(Self.script, contentWorld: .defaultClient) as? String,
                  let now = try? JSONDecoder().decode(Seen.self, from: Data(text.utf8)) else { continue }
            seen = now
            if now.script != nil { break }
        }
        return LiveDrive.Look(landed: seen.flatMap { URL(string: $0.href) } ?? web.url, status: status, headers: headers, script: seen?.script)
    }

    private func finish(_ worked: Bool) {
        finished?.resume(returning: worked)
        finished = nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            status = http.statusCode
            headers = Dictionary(http.allHeaderFields.compactMap { key, value in (key as? String).map { ($0, "\(value)") } },
                                 uniquingKeysWith: { a, _ in a })
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}
