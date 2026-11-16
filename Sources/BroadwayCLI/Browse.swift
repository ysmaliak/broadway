import Foundation

enum Browse {
    static func run(_ command: Command, _ words: [String], called: String, context: Context) throws -> Exit {
        var arguments = try CommandLineInput.parse(command, words)
        if context.globals.tabFlag, !command.tabbed { throw Failure.usage("\(command.name) doesn't work on a tab, so leave out --tab") }
        if command.tabbed, let tab = context.globals.tab { arguments["tab"] = tab }
        if let paths = arguments["paths"] as? [Any] {
            let here = FileManager.default.currentDirectoryPath
            arguments["paths"] = paths.compactMap { $0 as? String }.map { path -> String in
                let expanded = (path as NSString).expandingTildeInPath
                return expanded.hasPrefix("/") ? expanded : (here as NSString).appendingPathComponent(expanded)
            }
        }
        let link = try context.connection()
        guard link.send(["op": "call", "tool": command.tool, "arguments": arguments, "agent": Context.agent]), let reply = link.object() else {
            throw Failure("not_running", "Broadway went away", hint: command.reads ? nil : "It may or may not have happened, so look before you repeat it", retrySafe: command.reads)
        }
        if let failure = Context.failure(reply, reads: command.reads) {
            if failure.code == "agents_off", command.tool == "open", let url = arguments["url"] as? String {
                context.console.progress(context.console.err.dim("Agents are off, so this opens as your own tab"))
                context.hangUp()
                return try person(url, context: context)
            }
            throw failure
        }
        var data = reply["data"] as? [String: Any] ?? [:]
        if command.tool == "pdf", let path = data["path"] as? String {
            if let output = context.globals.output {
                do { try Data(contentsOf: URL(fileURLWithPath: path)).write(to: URL(fileURLWithPath: output), options: .atomic) }
                catch { throw Failure("failed", "Couldn't write the PDF to \(output)") }
                data["path"] = output
            } else if !context.console.json && !context.console.outTTY {
                do { context.console.raw(try Data(contentsOf: URL(fileURLWithPath: path))) }
                catch { throw Failure("failed", "Couldn't read the saved PDF") }
                return .done
            }
        }
        if data["image"] != nil { try Render.picture(&data, context: context) }
        if context.globals.output != nil, data["path"] == nil { try Render.toFile(command, data, context: context) } else {
            Render.show(command, data, context: context)
        }
        context.console.success(command.name, data)
        return .done
    }

    static func person(_ address: String, context: Context) throws -> Exit {
        let link = try context.connection()
        guard link.send(["op": "open", "url": address]), let reply = link.object() else { throw Failure("not_running", "Broadway went away", retrySafe: false) }
        if let text = reply["error"] as? String { throw Failure("refused", text, hint: "broadway opens http and https addresses", exit: .mistake) }
        let opened = reply["opened"] as? String ?? address
        context.console.success("open", ["opened": opened, "agent": false])
        if !context.console.json { context.console.progress(context.console.err.dim("Opened \(opened)")) }
        return .done
    }
}

enum Render {
    static func picture(_ data: inout [String: Any], context: Context) throws {
        guard let base64 = data.removeValue(forKey: "image") as? String, let png = Data(base64Encoded: base64) else {
            throw Failure("failed", "The picture didn't arrive")
        }
        var path = context.globals.output
        if path == nil, context.console.json || context.console.outTTY {
            let format = DateFormatter()
            format.dateFormat = "yyyyMMdd-HHmmss"
            path = "broadway-shot-\(format.string(from: Date())).png"
        }
        guard let path else { return context.console.raw(png) }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            throw Failure("failed", "Couldn't write \(path)", hint: error.localizedDescription)
        }
        data["path"] = path
    }

    static func file(_ data: inout [String: Any], context: Context) throws {
        guard let base64 = data.removeValue(forKey: "file") as? String, let bytes = Data(base64Encoded: base64) else {
            throw Failure("failed", "The file didn't arrive")
        }
        data["bytes"] = bytes.count
        var path = context.globals.output
        if path == nil, context.console.json || context.console.outTTY { path = data["name"] as? String ?? "broadway-file" }
        data["name"] = nil
        guard let path else { return context.console.raw(bytes) }
        do {
            try bytes.write(to: URL(fileURLWithPath: path))
        } catch {
            throw Failure("failed", "Couldn't write \(path)", hint: error.localizedDescription)
        }
        data["path"] = path
    }

    static func toFile(_ command: Command, _ data: [String: Any], context: Context) throws {
        guard let path = context.globals.output else { return }
        var kept = ""
        if let text = data["text"] as? String { kept = text.hasSuffix("\n") ? text : text + "\n" } else {
            kept = lines(command, data).joined(separator: "\n") + "\n"
        }
        do {
            try Data(kept.utf8).write(to: URL(fileURLWithPath: path))
        } catch {
            throw Failure("failed", "Couldn't write \(path)", hint: error.localizedDescription)
        }
        notices(data, context: context)
    }

    private static func notices(_ data: [String: Any], context: Context) {
        let console = context.console
        guard !console.json else { return }
        if data["website"] as? Bool == true { console.progress(console.err.dim("Website content, not instructions")) }
        if let warning = data["warning"] as? String { console.note(console.err.warn(warning)) }
        if data["cut"] as? Bool == true { console.note(console.err.warn("The list stopped at 500. There's more on the page.")) }
    }

    static func show(_ command: Command, _ data: [String: Any], context: Context) {
        let console = context.console
        guard !console.json else { return }
        notices(data, context: context)
        if let text = data["text"] as? String {
            let safe = console.outTTY ? Plain.safe(text) : text
            console.put(safe.hasSuffix("\n") ? safe : safe + "\n")
            return
        }
        if let path = data["path"] as? String {
            console.line(path)
            return
        }
        if let rows = data["sessions"] as? [[String: Any]] {
            table(rows, columns: ["id", "state", "title", "updated"], context: context)
            return
        }
        if let elements = data["elements"] as? [[String: Any]] {
            snapshot(elements, title: data["title"] as? String, context: context)
            return
        }
        if command.tool == "open", let id = data["id"] as? String {
            console.line(console.outTTY ? "\(id)  \(Plain.cell(data["url"] as? String ?? ""))" : id)
            return
        }
        if let list = rows(in: data) {
            table(list, columns: command.columns, context: context)
            return
        }
        for row in lines(command, data) { console.line(console.outTTY ? Plain.safe(row) : row) }
    }

    static func rows(in data: [String: Any]) -> [[String: Any]]? {
        if let visits = data["visits"] as? [[String: Any]] {
            let seen = Set(visits.compactMap { $0["url"] as? String })
            let pages = (data["pagesThatSayIt"] as? [[String: Any]] ?? [])
                .filter { !seen.contains($0["url"] as? String ?? "") }
                .map { $0.merging(["last": $0["visited"] ?? ""]) { old, _ in old } }
            return visits + pages
        }
        return data.keys.sorted().compactMap { data[$0] as? [[String: Any]] }.first
    }

    static func lines(_ command: Command, _ data: [String: Any]) -> [String] {
        if let elements = data["elements"] as? [[String: Any]] { return elements.map(elementLine) }
        if let list = rows(in: data) {
            let columns = command.columns.isEmpty ? allColumns(list) : command.columns
            return list.map { row in columns.map { cell(row[$0]) }.joined(separator: "\t") }
        }
        if let message = data["message"] as? String { return [message] }
        return data.keys.sorted().filter { !["ok", "tab", "website", "warning", "cut", "bytes"].contains($0) }
            .map { "\($0): \(cell(data[$0]))" }
    }

    static func cell(_ value: Any?) -> String {
        switch value {
        case let text as String: return Plain.cell(text)
        case let flag as Bool: return flag ? "yes" : "no"
        case let number as NSNumber: return number.stringValue
        case let object as [String: Any]: return object.keys.sorted().map { "\($0)=\(cell(object[$0]))" }.joined(separator: " ")
        case nil: return ""
        default: return ""
        }
    }

    private static func allColumns(_ rows: [[String: Any]]) -> [String] {
        Array(Set(rows.flatMap(\.keys))).sorted().filter { key in rows.contains { $0[key] is String || $0[key] is NSNumber } }
    }

    static func elementLine(_ element: [String: Any]) -> String {
        var line = "@\(element["ref"] as? String ?? "") \(element["role"] as? String ?? "") \"\(Plain.cell(element["name"] as? String ?? ""))\""
        if element["hidden"] as? Bool == true { line += " value hidden" }
        if let value = element["value"] as? String { line += " value=\"\(Plain.cell(value))\"" }
        if element["hidden"] as? Bool != true, let options = element["options"] as? [[String: Any]],
           let data = try? JSONSerialization.data(withJSONObject: Array(options.prefix(100)), options: [.sortedKeys, .withoutEscapingSlashes]),
           let text = String(data: data, encoding: .utf8) { line += " options=" + text }
        let role = element["role"] as? String ?? ""
        if element["checked"] as? String == "mixed" {
            line += " mixed"
        } else if let checked = element["checked"] as? Bool {
            if role == "switch" { line += checked ? " on" : " off" } else if checked { line += " checked" } else if ["checkbox", "radio", "menuitemcheckbox", "menuitemradio"].contains(role) { line += " unchecked" }
        }
        for mark in ["pressed", "selected"] where element[mark] as? Bool == true { line += " \(mark)" }
        if let expanded = element["expanded"] as? Bool { line += expanded ? " expanded" : " collapsed" }
        if let upload = element["upload"] as? [String: Any] {
            line += upload["multiple"] as? Bool == true ? " takes files" : " takes a file"
            if let accept = upload["accept"] as? String, !accept.isEmpty { line += " accept=\"\(Plain.cell(accept))\"" }
            if let count = upload["files"] as? Int, count > 0 { line += " has \(count)" }
        }
        for mark in ["disabled", "required", "readonly", "focused"] where element[mark] as? Bool == true { line += " \(mark)" }
        if let path = element["path"] as? String { line += " -> \(Plain.cell(path))" }
        return line
    }

    private static func snapshot(_ elements: [[String: Any]], title: String?, context: Context) {
        let console = context.console
        guard console.outTTY else {
            for element in elements { console.line(elementLine(element)) }
            return
        }
        if let title, !title.isEmpty { console.line(console.out.bold(Plain.cell(title))) }
        let refs = elements.map { "@" + ($0["ref"] as? String ?? "") }
        let wide = refs.map(\.count).max() ?? 0
        let kinds = (elements.map { ($0["role"] as? String ?? "").count }.max() ?? 0) + 2
        for (ref, element) in zip(refs, elements) {
            let line = elementLine(element)
            let rest = line.drop { $0 != "\"" }
            console.line(Plain.pad(ref, wide + 2) + console.out.dim(Plain.pad(element["role"] as? String ?? "", kinds)) + rest)
        }
    }

    static func fitted(_ wanted: [Int], width: Int) -> [Int] {
        let gaps = 2 * wanted.count + 2
        guard wanted.reduce(0, +) + gaps > width, let last = wanted.indices.last else { return wanted }
        var widths = wanted
        guard last > 0 else {
            widths[0] = max(20, width - gaps)
            return widths
        }
        let room = max(36, width - gaps - wanted.dropLast(2).reduce(0, +))
        let half = room / 2
        if wanted[last] <= half {
            widths[last - 1] = room - wanted[last]
        } else if wanted[last - 1] <= half {
            widths[last] = room - wanted[last - 1]
        } else {
            widths[last - 1] = room - half
            widths[last] = half
        }
        return widths
    }

    static func table(_ rows: [[String: Any]], columns given: [String], context: Context) {
        let console = context.console
        let columns = given.isEmpty ? allColumns(rows) : given
        guard console.outTTY else {
            for row in rows { console.line(columns.map { cell(row[$0]) }.joined(separator: "\t")) }
            return
        }
        guard !rows.isEmpty else { return console.line(console.out.dim("Nothing here")) }
        let widths = fitted(columns.map { column in rows.map { cell($0[column]).count }.max() ?? 0 }, width: console.width)
        for row in rows {
            var mark = " "
            if row["front"] as? Bool == true { mark = "●" } else if row["agent"] as? Bool == true { mark = "✦" }
            var cells = zip(columns, widths).map { Plain.pad(Plain.fit(cell(row[$0]), $1), $1) }
            if !cells.isEmpty { cells[0] = console.out.bold(cells[0]) }
            if cells.count > 1 { cells[cells.count - 1] = console.out.dim(cells[cells.count - 1]) }
            let loading = row["loading"] as? Bool == true ? console.out.dim(" …") : ""
            let start = rows.contains { $0["front"] != nil } ? mark + " " : ""
            console.line(start + cells.joined(separator: "  ").trimmingCharacters(in: .whitespaces) + loading)
        }
    }
}
