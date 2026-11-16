import Foundation

struct Globals {
    var json = false
    var quiet = false
    var noColor = false
    var help = false
    var version = false
    var socket: String?
    var world: String?
    var tab: String?
    var tabFlag = false
    var output: String?
    var timeout: Double?

    static func extract(_ words: [String], environment: [String: String]) throws -> (Globals, [String]) {
        var found = Globals()
        found.tab = environment["BROADWAY_TAB"].flatMap { $0.isEmpty ? nil : $0 }
        var rest: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if word == "--" {
                rest.append(contentsOf: words[(index - 1)...])
                break
            }
            let parts = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let flag = word.hasPrefix("--") ? parts[0] : word
            func value() throws -> String {
                if word.hasPrefix("--"), parts.count == 2 { return parts[1] }
                guard index < words.count else { throw Failure.usage("\(flag) needs a value") }
                index += 1
                return words[index - 1]
            }
            switch flag {
            case "--json": found.json = true
            case "-q", "--quiet": found.quiet = true
            case "--no-color": found.noColor = true
            case "-h", "--help": found.help = true
            case "-V", "--version": found.version = true
            case "--socket": found.socket = try value()
            case "--world": found.world = try value()
            case "--tab":
                found.tab = try value()
                found.tabFlag = true
            case "-o", "--output": found.output = try value()
            case "--timeout":
                guard let seconds = Double(try value()), seconds > 0, seconds.isFinite else { throw Failure.usage("--timeout is a number of seconds") }
                found.timeout = seconds
            default: rest.append(word)
            }
        }
        return (found, rest)
    }
}

enum CommandLineInput {
    static let needsTarget: Set<String> = ["click", "hover", "drag", "upload", "choose", "select"]
    static let targetFlags = ["role", "name", "nth", "in", "label", "frames", "at"]

    static func takesTarget(_ command: Command) -> Bool {
        (command.positional + command.flags).contains { $0.name == "ref" || $0.name == "target" }
    }

    static func form(_ command: Command) -> String {
        let targets = takesTarget(command)
        var parts = ["broadway", command.name]
        if targets { parts.append("TARGET") }
        parts += command.positional.filter { $0.required && !(targets && $0.name == "ref") }.map { $0.name.uppercased() }
        return parts.joined(separator: " ")
    }

    static func ref(_ word: String) -> String? {
        var bare = word.hasPrefix("@") ? String(word.dropFirst()) : word
        if !bare.contains("."), let range = bare.range(of: #"^f[0-9]+e[0-9]+$"#, options: .regularExpression) {
            let text = String(bare[range])
            let split = text.dropFirst().firstIndex(of: "e") ?? text.endIndex
            bare = String(text[..<split]) + "." + String(text[split...])
        }
        let parts = bare.split(separator: ".", omittingEmptySubsequences: false)
        guard let element = parts.last, parts.count <= 2, element.count > 1, element.hasPrefix("e"), element.dropFirst().allSatisfy(\.isNumber) else { return nil }
        if parts.count == 2 {
            guard parts[0].count > 1, parts[0].hasPrefix("f"), parts[0].dropFirst().allSatisfy(\.isNumber) else { return nil }
        }
        return bare
    }

    private static func coerce(_ text: String, _ parameter: Parameter, command: Command) throws -> Any {
        let flag = "--\(parameter.name)"
        if !parameter.choices.isEmpty, !parameter.choices.contains(text) {
            throw Failure.usage("\(flag) is one of \(parameter.choices.joined(separator: ", ")), not \(text)")
        }
        if parameter.name == "ref" {
            guard let ref = ref(text) else {
                throw Failure.usage("\(text) isn't a ref", hint: "Refs look like @e12. Run broadway snapshot to get them.")
            }
            return ref
        }
        switch parameter.type {
        case "number":
            guard let number = Double(text), number.isFinite else { throw Failure.usage("\(parameter.name) is a number, not \(text)") }
            return number
        case "integer":
            guard let number = Int(text) else { throw Failure.usage("\(parameter.name) is a whole number, not \(text)") }
            return number
        case "boolean":
            guard let value = ["true": true, "false": false, "yes": true, "no": false][text.lowercased()] else {
                throw Failure.usage("\(parameter.name) is true or false, not \(text)")
            }
            return value
        case "array":
            if let list = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] { return list }
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case "object":
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
                throw Failure.usage("\(parameter.name) is a JSON object")
            }
            return object
        default:
            return text
        }
    }

    private static func point(_ text: String) throws -> [String: Any] {
        let parts = text.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2, let x = parts[0], let y = parts[1], x.isFinite, y.isFinite, x >= 0, y >= 0 else {
            throw Failure.usage("--at is a point in the last shot's pixels, like --at 412,230")
        }
        return ["x": x, "y": y]
    }

    private static func targeted(_ command: Command, _ words: [String]) throws -> (target: [String: Any], rest: [String]) {
        guard takesTarget(command) else { return ([:], words) }
        var target: [String: Any] = [:]
        var rest: [String] = []
        var index = 0
        var literal = false
        while index < words.count {
            let word = words[index]
            index += 1
            if literal || word == "--" || !word.hasPrefix("--") {
                if word == "--" { literal = true }
                rest.append(word)
                continue
            }
            let parts = word.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let name = parts[0]
            guard targetFlags.contains(name), !(command.tool == "scroll" && name == "in") else {
                rest.append(word)
                continue
            }
            if name == "frames" {
                target["frames"] = true
                if command.flags.contains(where: { $0.name == name }) { rest.append(word) }
                continue
            }
            let value: String
            if parts.count == 2 {
                value = parts[1]
            } else {
                guard index < words.count else { throw Failure.usage("--\(name) needs a value") }
                if name != "at" { try unknown(words[index], command) }
                value = words[index]
                index += 1
            }
            switch name {
            case "nth":
                guard let nth = Int(value), nth >= 1 else { throw Failure.usage("--nth is a whole number from 1, not \(value)") }
                target["nth"] = nth
            case "in":
                guard let ref = ref(value) else { throw inRef(value) }
                target["in"] = ref
            case "at":
                target["at"] = try point(value)
            default:
                target[name] = value
            }
            if command.flags.contains(where: { $0.name == name }) { rest += ["--\(name)", value] }
        }
        return (target, rest)
    }

    private static func unknown(_ word: String, _ command: Command) throws {
        guard word.hasPrefix("-"), word.count > 1, Double(word) == nil else { return }
        let name = word.hasPrefix("--") ? String(word.dropFirst(2).split(separator: "=", maxSplits: 1).first ?? "") : ""
        if !name.isEmpty, command.flags.contains(where: { $0.name == name }) || targetFlags.contains(name) { return }
        throw Failure.usage("\(command.name) has no option \(word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word)", hint: "Usage: \(command.usage). Put -- before text that starts with a dash.")
    }

    private static func inRef(_ value: String) -> Failure {
        Failure.usage("--in takes a ref like @e30, not \(value)", hint: "broadway find \"\(value)\" gives its ref")
    }

    private static func free(_ command: Command, _ words: [String]) -> Int {
        var count = 0
        var index = 0
        while index < words.count {
            let word = words[index]
            index += 1
            if word == "--" { return count + words.count - index }
            if word.hasPrefix("--") {
                let parts = word.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 1, let flag = command.flags.first(where: { $0.name == parts[0] }), flag.type != "boolean" { index += 1 }
            } else if !(word.hasPrefix("-") && word.count > 1 && Double(word) == nil) {
                count += 1
            }
        }
        return count
    }

    static func parse(_ command: Command, _ words: [String]) throws -> [String: Any] {
        let split = try targeted(command, words)
        var target = split.target
        let words = split.rest
        var found: [String: Any] = [:]
        var waiting = command.positional
        var literal = false
        var index = 0
        let aimed = ["role", "name", "label", "at"].contains { target[$0] != nil }
        if aimed { waiting.removeAll { $0.name == "ref" } }
        let targets = takesTarget(command)
        var wordsFirst = aimed && targets && free(command, words) > command.positional.filter { $0.name != "ref" }.count
        func take(_ word: String) throws {
            if word.hasPrefix("@") || ref(word) != nil, found["ref"] == nil, target["words"] == nil, let ref = command.flags.first(where: { $0.name == "ref" }) {
                found["ref"] = try coerce(word, ref, command: command)
                waiting.removeAll { $0.name == "ref" }
                return
            }
            if targets, found["ref"] == nil, target["words"] == nil,
               wordsFirst || (!aimed && (waiting.first?.name == "ref" || (waiting.isEmpty && command.positional.isEmpty))) {
                guard !word.isEmpty else { throw Failure.usage("A target needs words or a ref") }
                target["words"] = word
                wordsFirst = false
                waiting.removeAll { $0.name == "ref" }
                return
            }
            guard !waiting.isEmpty else {
                throw Failure.usage("\(command.name) doesn't take \(word)", hint: "Usage: \(command.usage)")
            }
            let parameter = waiting[0]
            let value = try coerce(word, parameter, command: command)
            if parameter.many {
                found[parameter.name] = (found[parameter.name] as? [Any] ?? []) + (parameter.type == "array" ? [word] : [value])
            } else {
                waiting.removeFirst()
                found[parameter.name] = value
            }
        }
        while index < words.count {
            let word = words[index]
            index += 1
            if literal {
                try take(word)
            } else if word == "--" {
                literal = true
            } else if word.hasPrefix("--") {
                let parts = word.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                guard let flag = command.flags.first(where: { $0.name == parts[0] }) else {
                    let near = Near.best(parts[0], in: command.listed.map(\.name)).map { "Did you mean --\($0)?" }
                    throw Failure.usage("\(command.name) has no option --\(parts[0])", hint: near ?? "Run broadway help \(command.name)")
                }
                waiting.removeAll { $0.name == flag.name }
                if parts.count == 2 {
                    found[flag.name] = try coerce(parts[1], flag, command: command)
                } else if flag.type == "boolean" {
                    found[flag.name] = true
                } else {
                    guard index < words.count else { throw Failure.usage("--\(flag.name) needs a value") }
                    try unknown(words[index], command)
                    if flag.name == "in", ref(words[index]) == nil { throw inRef(words[index]) }
                    found[flag.name] = try coerce(words[index], flag, command: command)
                    index += 1
                }
            } else if word.hasPrefix("-"), word.count > 1, Double(word) == nil {
                try unknown(word, command)
            } else {
                try take(word)
            }
        }
        if let ref = found["ref"] as? String, target["words"] == nil {
            target["ref"] = ref
        }
        if command.tool == "screenshot", target["ref"] == nil, target["words"] == nil, let inside = target["in"] as? String, !aimed {
            target = ["ref": inside]
            found["ref"] = inside
        }
        if !target.isEmpty {
            if target["ref"] == nil, target["words"] == nil, !aimed {
                throw Failure.usage("--\(target["in"] != nil ? "in" : "nth") narrows a target, so give one too", hint: "For example: broadway \(command.name) \"Save\" --nth 2, or --role button --name Save")
            }
            found["target"] = target
        }
        let missing = (command.positional + command.flags).filter { $0.required && found[$0.name] == nil && !($0.name == "ref" && found["target"] != nil) }
        if let first = missing.first {
            let named = first.name == "ref" && takesTarget(command) ? "TARGET" : command.positional.contains { $0.name == first.name } ? first.name.uppercased() : "--\(first.name)"
            throw Failure.usage("\(command.name) needs \(named): \(form(command))", hint: "Usage: \(command.usage)")
        }
        if needsTarget.contains(command.tool), found["ref"] == nil, found["target"] == nil {
            throw Failure.usage("\(command.name) needs a target: a @ref, the element's words, or --role or --label", hint: "For example: broadway \(command.name) @e12, or broadway \(command.name) \"Add to basket\"")
        }
        return found
    }
}

struct TaskOptions {
    var cli: String?
    var model: String?
    var effort: String?
    var waitPerson: Double?
    var noPerson = false
    var detach = false
    var stdin = false
    var words: [String] = []
    var flagged = false

    static let flags = ["--cli", "--model", "--effort", "--wait-person", "--no-person", "--detach", "--stdin"]
    static let efforts = ["low", "medium", "high", "xhigh", "max", "ultra"]

    static func parse(_ given: [String]) throws -> TaskOptions {
        var found = TaskOptions()
        var index = 0
        func value(_ flag: String) throws -> String {
            guard index < given.count else { throw Failure.usage("\(flag) needs a value") }
            index += 1
            return given[index - 1]
        }
        while index < given.count {
            let word = given[index]
            index += 1
            switch word {
            case "--":
                found.words.append(contentsOf: given[index...])
                index = given.count
            case "--cli":
                found.cli = try value(word)
                found.flagged = true
                guard ["claude", "codex"].contains(found.cli ?? "") else { throw Failure.usage("--cli is claude or codex") }
            case "-m", "--model":
                found.model = try value(word)
                found.flagged = true
            case "--effort":
                found.effort = try value(word)
                found.flagged = true
                guard efforts.contains(found.effort ?? "") else { throw Failure.usage("--effort is \(efforts.joined(separator: ", "))") }
            case "--wait-person":
                guard let minutes = Double(try value(word)), minutes >= 0 else { throw Failure.usage("--wait-person is a number of minutes") }
                found.waitPerson = minutes
                found.flagged = true
            case "--no-person":
                found.noPerson = true
                found.flagged = true
            case "--detach":
                found.detach = true
                found.flagged = true
            case "--stdin":
                found.stdin = true
                found.flagged = true
            default:
                if word.hasPrefix("-"), word.count > 1, !word.contains(" ") {
                    let near = Near.best(String(word.drop { $0 == "-" }), in: flags.map { String($0.dropFirst(2)) }).map { "Did you mean --\($0)?" }
                    throw Failure.usage("No option named \(word)", hint: near ?? "Run broadway help")
                }
                found.words.append(word)
            }
        }
        if found.noPerson, found.waitPerson != nil { throw Failure.usage("--no-person and --wait-person pull opposite ways, so pick one") }
        return found
    }

    var request: [String: Any] {
        var found: [String: Any] = [:]
        if let cli { found["cli"] = cli }
        if let model { found["model"] = model }
        if let effort { found["effort"] = effort }
        if noPerson { found["person"] = "none" }
        return found
    }
}

enum Address {
    static func looksLike(_ text: String) -> Bool {
        if text.contains(" ") { return false }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return true }
        return text.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
