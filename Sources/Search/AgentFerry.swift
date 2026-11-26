import Foundation

@MainActor
enum AgentFerry {
    static let most = 25 * 1024 * 1024
    static let piece = 2 * 1024 * 1024
    static let made = ["broadway-pdf-", "broadway-tiles-"]
    static var downloads: () -> [URL] = {
        Browsers.all.flatMap { $0.loot.kept.map { URL(fileURLWithPath: $0.path) } } + AgentDownloadWatch.files
    }
    static var temporary: () -> URL = { FileManager.default.temporaryDirectory }

    static func real(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func allowed(_ path: String) -> URL? {
        let file = URL(fileURLWithPath: path)
        let found = real(file)
        let folder = file.deletingLastPathComponent()
        if real(folder.deletingLastPathComponent()) == real(temporary()), made.contains(where: folder.lastPathComponent.hasPrefix) { return URL(fileURLWithPath: found) }
        if downloads().contains(where: { real($0) == found }) { return URL(fileURLWithPath: found) }
        return nil
    }

    static func ours(_ path: String) -> Bool {
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        return real(folder.deletingLastPathComponent()) == real(temporary()) && made.contains(where: folder.lastPathComponent.hasPrefix)
    }

    static func fetch(_ request: [String: Any], browser: Browser, box: BrowserToolbox, link: AgentLink?) async -> [String: Any] {
        if let path = request["path"] as? String, allowed(path) != nil, !ours(path) {
            var call = PersonCall(noun: "downloads", verb: "get", arguments: [:], browser: browser, box: box)
            call.link = link
            call.request = request
            do {
                try await PersonCommands.approve(.look, call, site: nil, request: request, channel: PersonChannel { _ in })
            } catch let refused as PersonRefusal {
                return failure(refused.code, refused.message, hint: refused.hint)
            } catch {
                return failure("failed", "That didn't work")
            }
        }
        return read(request)
    }

    static func failure(_ code: String, _ message: String, hint: String? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let hint { error["hint"] = hint }
        return ["ok": false, "error": error]
    }

    static func read(_ request: [String: Any]) -> [String: Any] {
        guard let path = request["path"] as? String, let file = allowed(path) else {
            return failure("not_found", "Broadway hands over only files it made or downloaded", hint: "Use the path from an answer, such as broadway downloads get ID")
        }
        guard let handle = try? FileHandle(forReadingFrom: file) else { return failure("failed", "Couldn't read \(file.lastPathComponent)") }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map { Int($0) } ?? 0
        let from = min(max(0, request["from"] as? Int ?? 0), size)
        try? handle.seek(toOffset: UInt64(from))
        let bytes = (try? handle.read(upToCount: piece)) ?? Data()
        return ["ok": true, "data": ["name": file.lastPathComponent, "bytes": bytes.base64EncodedString(), "size": size, "from": from]]
    }

    static func name(_ given: String?) -> String? {
        guard let given else { return nil }
        let clean = String((given as NSString).lastPathComponent.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        return clean.isEmpty || clean == "/" ? nil : clean
    }

    static func take(_ request: [String: Any]) -> [String: Any] {
        guard let name = name(request["name"] as? String), let text = request["bytes"] as? String, let bytes = Data(base64Encoded: text) else {
            return failure("usage", "A file to upload needs a name and its bytes")
        }
        let root = AgentGiven.root
        let folder: URL
        if let named = request["folder"] as? String {
            folder = URL(fileURLWithPath: named)
            guard real(folder.deletingLastPathComponent()) == real(root), folder.lastPathComponent.hasPrefix(AgentGiven.prefix),
                  FileManager.default.fileExists(atPath: folder.path) else { return failure("usage", "That upload folder isn't one Broadway made") }
        } else {
            folder = root.appendingPathComponent(AgentGiven.prefix + UUID().uuidString)
            do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { return failure("failed", "Couldn't keep \(name) for the upload") }
            expire(folder)
        }
        let file = folder.appendingPathComponent(name)
        let held = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey]))?
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
        guard held + bytes.count <= most else {
            AgentGiven.drop(folder)
            return failure("usage", "Files to upload come to more than 25 MB", hint: "Upload them in smaller parts, or put them on the Mac that runs Broadway")
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            guard FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                return failure("failed", "Couldn't keep \(name) for the upload")
            }
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return failure("failed", "Couldn't keep \(name) for the upload") }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        } catch { return failure("failed", "Couldn't keep \(name) for the upload") }
        return ["ok": true, "data": ["folder": folder.path, "path": file.path]]
    }

    static func expire(_ folder: URL, after: Duration = .seconds(600)) {
        Task { @MainActor in
            try? await Task.sleep(for: after)
            if !AgentGiven.holds(folder) { AgentGiven.drop(folder) }
        }
    }
}