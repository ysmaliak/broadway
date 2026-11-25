import Foundation

enum Carry {
    static let most = 25 * 1024 * 1024
    static let piece = 2 * 1024 * 1024

    static func fetch(_ path: String, into folder: URL? = nil, ask: ([String: Any]) throws -> [String: Any]) throws -> URL {
        let room = try folder ?? made()
        var file: URL?
        var handle: FileHandle?
        defer { try? handle?.close() }
        var from = 0
        while true {
            let answer = try ask(["op": "file", "path": path, "from": from])
            guard let text = answer["bytes"] as? String, let bytes = Data(base64Encoded: text) else { throw Failure("failed", "The file didn't arrive") }
            if handle == nil {
                let name = (answer["name"] as? String).map { ($0 as NSString).lastPathComponent } ?? (path as NSString).lastPathComponent
                let target = room.appendingPathComponent(name.isEmpty ? "broadway-file" : name)
                guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]),
                      let opened = FileHandle(forWritingAtPath: target.path) else { throw Failure("failed", "Couldn't keep a copy of \(name) here") }
                file = target
                handle = opened
            }
            try handle?.write(contentsOf: bytes)
            from += bytes.count
            if bytes.isEmpty || from >= answer["size"] as? Int ?? 0 { break }
        }
        guard let file else { throw Failure("failed", "The file didn't arrive") }
        return file
    }

    static func made() throws -> URL {
        let folder = Given.root.appendingPathComponent("broadway-carried-" + UUID().uuidString)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw Failure("failed", "Couldn't make a folder for the copy", hint: error.localizedDescription) }
        return folder
    }

    static func send(_ paths: [String], ask: ([String: Any]) throws -> [String: Any]) throws -> (paths: [String], folder: String?) {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        if Set(names).count < names.count {
            throw Failure.usage("Two files to upload have the same name", hint: "Rename one, or upload them one at a time")
        }
        var total = 0
        for path in paths {
            guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int else {
                throw Failure.usage("\(path) isn't a file on this Mac")
            }
            total += size
        }
        guard total <= most else {
            throw Failure.usage("Files to upload come to more than 25 MB", hint: "Upload them in smaller parts, or put them on the Mac that runs Broadway")
        }
        var folder: String?
        var sent: [String] = []
        for path in paths {
            guard let handle = FileHandle(forReadingAtPath: path) else { throw Failure.usage("Couldn't read \(path)") }
            defer { try? handle.close() }
            var there: String?
            repeat {
                let bytes = (try? handle.read(upToCount: piece)) ?? Data()
                if bytes.isEmpty, there != nil { break }
                var request: [String: Any] = ["op": "give", "name": (path as NSString).lastPathComponent, "bytes": bytes.base64EncodedString()]
                if let folder { request["folder"] = folder }
                let answer = try ask(request)
                folder = answer["folder"] as? String ?? folder
                there = answer["path"] as? String
                if bytes.count < piece { break }
            } while true
            guard let there else { throw Failure("failed", "\((path as NSString).lastPathComponent) didn't arrive") }
            sent.append(there)
        }
        return (sent, folder)
    }
}
