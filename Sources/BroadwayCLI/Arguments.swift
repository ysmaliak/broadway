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
    static func ref(_ word: String) -> String? {
        let bare = word.hasPrefix("@") ? String(word.dropFirst()) : word
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

    static func parse(_ command: Command, _ words: [String]) throws -> [String: Any] {
        var found: [String: Any] = [:]
        var waiting = command.positional
        var literal = false
        var index = 0
        func take(_ word: String) throws {
            if word.hasPrefix("@"), found["ref"] == nil, let ref = command.flags.first(where: { $0.name == "ref" }) {
                found["ref"] = try coerce(word, ref, command: command)
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
                    let near = Near.best(parts[0], in: command.flags.map(\.name)).map { "Did you mean --\($0)?" }
                    throw Failure.usage("\(command.name) has no option --\(parts[0])", hint: near ?? "Run broadway help \(command.name)")
                }
                waiting.removeAll { $0.name == flag.name }
                if parts.count == 2 {
                    found[flag.name] = try coerce(parts[1], flag, command: command)
                } else if flag.type == "boolean" {
                    found[flag.name] = true
                } else {
                    guard index < words.count else { throw Failure.usage("--\(flag.name) needs a value") }
                    found[flag.name] = try coerce(words[index], flag, command: command)
                    index += 1
                }
            } else if word.hasPrefix("-"), word.count > 1, Double(word) == nil {
                throw Failure.usage("\(command.name) has no option \(word)", hint: "Run broadway help \(command.name). Put -- before text that starts with a dash.")
            } else {
                try take(word)
            }
        }
        let missing = (command.positional + command.flags).filter { $0.required && found[$0.name] == nil }
        if let first = missing.first {
            throw Failure.usage("\(command.name) needs \(first.name)", hint: "Usage: \(command.usage)")
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
