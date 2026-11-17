import Foundation

struct Parameter: Equatable {
    var name: String
    var type: String
    var description: String
    var required: Bool
    var choices: [String]
    var many: Bool
    var unlisted = false
    var repeats = false

    var shown: String {
        if type == "boolean" { return "[--\(name)]" }
        if repeats { return "[--\(name) TEXT]" + String(repeating: ".", count: 3) }
        if !choices.isEmpty { return "[--\(name) \(choices.joined(separator: "|"))]" }
        let value = ["number": "N", "integer": "N", "array": "LIST", "object": "JSON"][type] ?? name.uppercased()
        return "[--\(name) \(value)]"
    }

    init(_ found: [String: Any]) {
        name = found["name"] as? String ?? ""
        type = found["type"] as? String ?? "string"
        description = found["description"] as? String ?? ""
        required = found["required"] as? Bool ?? false
        choices = found["choices"] as? [String] ?? []
        many = found["many"] as? Bool ?? false
        unlisted = found["unlisted"] as? Bool ?? false
        repeats = found["repeats"] as? Bool ?? false
    }
}

struct Command: Equatable {
    var name: String
    var tool: String
    var aliases: [String]
    var summary: String
    var description: String
    var tabbed: Bool
    var reads: Bool
    var positional: [Parameter]
    var flags: [Parameter]
    var examples: [String]
    var columns: [String]
    var wholeUsage: String?
    var findsHere = false

    init(_ found: [String: Any]) {
        name = found["name"] as? String ?? ""
        tool = found["tool"] as? String ?? name
        aliases = found["aliases"] as? [String] ?? []
        summary = found["summary"] as? String ?? ""
        description = found["description"] as? String ?? summary
        tabbed = found["tabbed"] as? Bool ?? false
        reads = found["reads"] as? Bool ?? false
        positional = (found["positional"] as? [[String: Any]] ?? []).map(Parameter.init)
        flags = (found["flags"] as? [[String: Any]] ?? []).map(Parameter.init)
        examples = found["examples"] as? [String] ?? []
        columns = found["columns"] as? [String] ?? []
        if tool == "text", !flags.contains(where: { $0.name == "find" }) {
            flags.append(Parameter(["name": "find", "type": "string", "description": "Only the lines holding these words"]))
            findsHere = true
        }
    }

    var listed: [Parameter] { flags.filter { !$0.unlisted } }

    var usage: String {
        if let wholeUsage { return wholeUsage }
        var parts = ["broadway", name]
        let targets = CommandLineInput.takesTarget(self)
        if targets {
            let needed = CommandLineInput.needsTarget.contains(tool) || positional.contains { $0.name == "ref" && $0.required }
            parts.append(needed ? "WORDS|@ref" : "[WORDS|@ref]")
        }
        parts += positional.filter { !(targets && $0.name == "ref") }.map { $0.required ? "<\($0.name)>" : "[\($0.name)]" }
        if targets { parts += ["[--role ROLE]", "[--name NAME]"] }
        let aiming = Set(CommandLineInput.targetFlags + ["ref", "target"])
        parts += listed.filter { flag in !positional.contains { $0.name == flag.name } && !(targets && aiming.contains(flag.name)) }.map(\.shown)
        if tabbed { parts.append("[--tab ID]") }
        return parts.joined(separator: " ")
    }
}

struct Catalog {
    var commands: [Command] = []
    var known = false

    init(_ found: [[String: Any]]?) {
        commands = (found ?? []).map(Command.init)
        known = found != nil
    }

    static let older = ["find": "locate", "locate": "find"]

    func find(_ word: String) -> Command? {
        if let found = commands.first(where: { $0.name == word || $0.aliases.contains(word) }) { return found }
        guard let other = Catalog.older[word] else { return nil }
        return commands.first { $0.name == other || $0.aliases.contains(other) }
    }

    var names: [String] { commands.map(\.name) }

    static func app(beside binary: String) -> String? {
        let folder = (binary as NSString).deletingLastPathComponent
        let candidates = [(folder as NSString).deletingLastPathComponent + "/MacOS/Broadway", folder + "/Search"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func offline(binary: String) -> [[String: Any]]? {
        guard let app = app(beside: binary) else { return nil }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: app)
        process.arguments = ["--broadway-catalog"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["commands"] as? [[String: Any]]
    }
}

enum Near {
    static func distance(_ left: String, _ right: String) -> Int {
        let a = Array(left), b = Array(right)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let held = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = held
            }
        }
        return row[b.count]
    }

    static func best(_ word: String, in names: [String]) -> String? {
        let lower = word.lowercased()
        let reach = lower.count <= 3 ? 1 : 2
        var closest: String?
        var nearest = reach + 1
        for name in names.sorted() {
            let far = distance(lower, name.lowercased())
            if far < nearest {
                closest = name
                nearest = far
            }
        }
        if let closest { return closest }
        return lower.count >= 3 ? names.first { $0.hasPrefix(lower) } : nil
    }
}
