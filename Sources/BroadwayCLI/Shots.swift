import Foundation

enum Shots {
    static let stream = "-"

    static func elsewhere(_ context: Context, example: String, carried: String? = nil) -> String? {
        if let carried, context.forwarded, context.globals.output != stream {
            return "This file is on the Mac that runs Broadway. Get a copy here with \(carried)"
        }
        guard let connection = context.environment["SSH_CONNECTION"], !connection.isEmpty, context.globals.output != stream else { return nil }
        return "This file is on the Mac that runs Broadway. Over ssh, add --out - to get its bytes where you are: \(example)"
    }

    static func say(_ context: Context, _ data: inout [String: Any], example: String, carried: String? = nil) {
        guard let line = elsewhere(context, example: example, carried: carried) else { return }
        data["ssh"] = line
        if !context.console.json { context.console.note(context.console.err.dim(line)) }
    }

    static func answer(_ command: Command, _ given: [String: Any], context: Context) throws -> Exit {
        var data = given
        let console = context.console
        let output = context.globals.output
        if console.json, output == stream { throw Failure.usage("--out - writes the picture's bytes to standard output, so leave out --json") }
        if data["tiles"] != nil { return try tiles(command, data, context: context) }
        if data["website"] as? Bool == true, !console.json, output != stream { console.website() }
        if data["unchanged"] as? Bool == true {
            data["image"] = nil
            let said = "Unchanged since your last shot of this tab (\(data["changed"] as? String ?? "0%") of pixels)"
            data["message"] = said
            if !console.json {
                if output == stream { console.note(said) } else { console.line(said) }
            }
            console.success(command.name, data)
            return .done
        }
        let streamed = output == stream
        try Render.picture(&data, context: context)
        if !console.json, let warning = data["warning"] as? String { console.note(console.err.warn(warning)) }
        if streamed { return .done }
        if !console.json {
            if let path = data["path"] as? String { console.line(path) }
            if let width = data["width"] as? Int, let height = data["height"] as? Int {
                var said = "\(width) by \(height) pixels"
                if let marks = data["marks"] as? [Any] { said += marks.isEmpty ? ", no refs in view to mark" : ", \(marks.count) ref\(marks.count == 1 ? "" : "s") marked" }
                console.note(console.err.dim(said))
            }
        }
        say(context, &data, example: "broadway shot --out - > page.\(data["format"] as? String == "jpeg" ? "jpg" : "png")")
        console.success(command.name, data)
        return .done
    }

    static func tiles(_ command: Command, _ given: [String: Any], context: Context) throws -> Exit {
        var data = given
        let console = context.console
        let output = context.globals.output
        var rows = data["tiles"] as? [[String: Any]] ?? []
        let files = rows.compactMap { row -> (name: String, path: String)? in
            guard let path = row["path"] as? String else { return nil }
            return ((path as NSString).lastPathComponent, path)
        }
        if output == stream {
            var archive = Tar()
            for file in files {
                guard let bytes = FileManager.default.contents(atPath: file.path) else { throw Failure("failed", "Couldn't read \(file.path)") }
                archive.add(file.name, bytes)
            }
            console.raw(archive.finished())
            if !console.quiet { for line in lines(data, rows: rows) where !line.hasPrefix("tile ") { console.note(console.err.dim(line)) } }
            return .done
        }
        if let output {
            let folder = (output as NSString).expandingTildeInPath
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder), !isFolder.boolValue {
                throw Failure.usage("With --tiles, -o names a folder, and \(output) is a file")
            }
            do { try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true) }
            catch { throw Failure("failed", "Couldn't make the folder \(output)", hint: error.localizedDescription) }
            for index in rows.indices {
                guard let path = rows[index]["path"] as? String else { continue }
                let target = (folder as NSString).appendingPathComponent((path as NSString).lastPathComponent)
                try? FileManager.default.removeItem(atPath: target)
                do { try FileManager.default.copyItem(atPath: path, toPath: target) }
                catch { throw Failure("failed", "Couldn't write \(target)", hint: error.localizedDescription) }
                rows[index]["path"] = target
            }
            data["tiles"] = rows
            data["folder"] = folder
        }
        if !console.json {
            if data["website"] as? Bool == true { console.website() }
            for line in lines(data, rows: rows) { console.line(line) }
        }
        say(context, &data, example: "broadway shot --tiles --out - | tar -x")
        console.success(command.name, data)
        return .done
    }

    static func lines(_ data: [String: Any], rows: [[String: Any]]) -> [String] {
        let total = data["total"] as? Int ?? rows.count
        let first = data["from"] as? Int ?? 1
        let last = data["to"] as? Int ?? first
        var found = [first == 1 && last == total ? "The page is \(total) tile\(total == 1 ? "" : "s") high" : "Tiles \(first) to \(last) of \(total)"]
        if let row = rows.first(where: { $0["width"] != nil }), let width = row["width"] as? Int, let height = row["height"] as? Int {
            found[0] += ", \(width) by \(height) pixels each"
        }
        for row in rows {
            let number = row["tile"] as? Int ?? 0, offset = row["offset"] as? Int ?? 0
            if row["unchanged"] as? Bool == true {
                found.append("tile \(number) at \(offset): unchanged since your last shot of it (\(row["changed"] as? String ?? "0%") of pixels)")
            } else {
                var line = "tile \(number) at \(offset): \(row["path"] as? String ?? "")"
                if let marks = row["marks"] as? [Any] { line += "  \(marks.count) ref\(marks.count == 1 ? "" : "s") marked" }
                found.append(line)
            }
        }
        if data["stuck"] as? Bool == true { found.append("The page doesn't scroll as a whole, so tiles stop here. Scroll its own part with broadway scroll --in @ref, then shot.") }
        if last < total { found.append("More: broadway shot --tiles --from \(last + 1)") }
        return found
    }
}

enum Given {
    static var root: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0 else { return FileManager.default.temporaryDirectory.resolvingSymlinksInPath() }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true).resolvingSymlinksInPath()
    }

    static func take(_ words: [String], context: Context) throws -> (words: [String], folder: URL?) {
        var kept: [String] = []
        var name: String?
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if word == "--" {
                kept += words[(index - 1)...]
                break
            }
            if word == "--stdin" {
                guard index < words.count else { throw Failure.usage("--stdin needs the file's name, like --stdin report.pdf") }
                name = words[index]
                index += 1
            } else if word.hasPrefix("--stdin=") {
                name = String(word.dropFirst("--stdin=".count))
            } else {
                kept.append(word)
            }
        }
        guard let asked = name else { return (words, nil) }
        let clean = String((asked as NSString).lastPathComponent.drop { $0 == "." }).trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty, clean != "/" else { throw Failure.usage("--stdin needs the file's name, like --stdin report.pdf") }
        guard isatty(STDIN_FILENO) == 0 else {
            throw Failure.usage("--stdin reads the file from standard input, so pipe it in", hint: "ssh mac broadway upload @e7 --stdin report.pdf < report.pdf")
        }
        let bytes = FileHandle.standardInput.readDataToEndOfFile()
        guard !bytes.isEmpty else { throw Failure.usage("Nothing came on standard input for \(clean)") }
        let folder = root.appendingPathComponent("broadway-stdin-" + UUID().uuidString)
        let file = folder.appendingPathComponent(clean)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw Failure("failed", "Couldn't keep \(clean) for the upload", hint: error.localizedDescription)
        }
        return (kept + [file.path], folder)
    }
}

extension Render {
    static func sent(_ data: inout [String: Any], context: Context) throws {
        data["send"] = nil
        guard var path = data["path"] as? String else { throw Failure("failed", "The file didn't arrive") }
        if context.forwarded {
            path = try context.local(path)
            data["path"] = path
        }
        let output = context.globals.output
        if output == Shots.stream {
            guard let handle = FileHandle(forReadingAtPath: path) else { throw Failure("failed", "Couldn't read \(path)") }
            defer { try? handle.close() }
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty { context.console.raw(chunk) }
            data["streamed"] = true
            return
        }
        if let output {
            let target = (output as NSString).expandingTildeInPath
            try? FileManager.default.removeItem(atPath: target)
            do { try FileManager.default.copyItem(atPath: path, toPath: target) }
            catch { throw Failure("failed", "Couldn't write \(output)", hint: error.localizedDescription) }
            data["path"] = target
            return
        }
        Shots.say(context, &data, example: "broadway downloads get \(data["id"] as? String ?? "ID") --out - > \(data["name"] as? String ?? "file")")
    }
}

struct Tar {
    private var data = Data()

    mutating func add(_ name: String, _ bytes: Data, mode: Int = 0o644, date: Date = Date()) {
        var header = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at offset: Int, size: Int) {
            for (index, byte) in Array(text.utf8).prefix(size).enumerated() { header[offset + index] = byte }
        }
        func octal(_ value: Int, at offset: Int, size: Int) {
            put(String(String(value, radix: 8).suffix(size - 1)).leftPadded(size - 1), at: offset, size: size - 1)
        }
        put(String(name.prefix(100)), at: 0, size: 100)
        octal(mode, at: 100, size: 8)
        octal(0, at: 108, size: 8)
        octal(0, at: 116, size: 8)
        octal(bytes.count, at: 124, size: 12)
        octal(Int(date.timeIntervalSince1970), at: 136, size: 12)
        put("        ", at: 148, size: 8)
        header[156] = UInt8(ascii: "0")
        put("ustar", at: 257, size: 6)
        put("00", at: 263, size: 2)
        let sum = header.reduce(0) { $0 + Int($1) }
        put(String(String(sum, radix: 8)).leftPadded(6), at: 148, size: 6)
        header[154] = 0
        header[155] = UInt8(ascii: " ")
        data.append(contentsOf: header)
        data.append(bytes)
        let pad = (512 - bytes.count % 512) % 512
        data.append(Data(count: pad))
    }

    func finished() -> Data {
        data + Data(count: 1024)
    }
}

extension String {
    func leftPadded(_ size: Int) -> String {
        count >= size ? self : String(repeating: "0", count: size - count) + self
    }
}
