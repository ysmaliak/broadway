import Darwin
import Foundation

struct PersonOptions {
    var wait: Double?
    var nobody = false
    var words: [String] = []

    static func parse(_ given: [String]) throws -> PersonOptions {
        var found = PersonOptions()
        var index = 0
        while index < given.count {
            let word = given[index]
            index += 1
            switch word {
            case "--":
                found.words.append(contentsOf: given[(index - 1)...])
                index = given.count
            case "--no-person":
                found.nobody = true
            case "--wait-person":
                guard index < given.count, let minutes = Double(given[index]), minutes >= 0 else { throw Failure.usage("--wait-person is a number of minutes") }
                found.wait = minutes * 60
                index += 1
            default:
                found.words.append(word)
            }
        }
        if found.nobody, found.wait != nil { throw Failure.usage("--no-person and --wait-person pull opposite ways, so pick one") }
        return found
    }

    func seconds(interactive: Bool) -> Double {
        if nobody { return 0 }
        return wait ?? (interactive ? 120 : 0)
    }
}

enum Person {
    static func bare(_ words: [String]) -> Bool {
        words.first == "tabs" && words.dropFirst().allSatisfy { $0.hasPrefix("-") }
    }

    static func run(_ noun: Noun, _ verb: Verb, _ words: [String], context: Context, bare: Bool = false) throws -> Exit {
        let options = try PersonOptions.parse(words)
        let command = verb.command
        var arguments = try CommandLineInput.parse(command, options.words)
        if noun.name == "agents", verb.name == "idle", let hook = arguments["hook"] as? String { return AgentHook.run(hook, context: context) }
        if bare { arguments["mine"] = true }
        if context.globals.tabFlag, !command.tabbed, noun.name != "agents" { throw Failure.usage("\(command.name) doesn't work on a tab, so leave out --tab") }
        if command.tabbed, let tab = context.globals.tab { arguments["tab"] = tab }
        if verb.fromStdin { arguments["text"] = try source(arguments, context: context) }
        if Give.applies(noun, verb) { try Give.check(arguments, json: context.console.json, output: context.globals.output, environment: ProcessInfo.processInfo.environment) }
        let interactive = isatty(STDIN_FILENO) == 1 && context.console.errTTY && !context.console.json
        let agent = Context.agent
        Clock.mark("ancestor")
        var request: [String: Any] = ["op": "do", "noun": noun.name, "verb": verb.name, "arguments": arguments,
                                      "wait": options.seconds(interactive: interactive), "agent": agent]
        if options.nobody { request["person"] = "none" }
        let link = try context.connection()
        guard link.send(request) else { throw Failure("not_running", "Broadway went away", retrySafe: false) }
        while let reply = link.object() {
            Clock.mark("reply")
            if reply["event"] as? String == "asking" {
                context.console.progress(context.console.err.dim(reply["message"] as? String ?? "Waiting for your yes in Broadway"))
                continue
            }
            if let failure = Context.failure(reply, reads: false) { throw failure }
            if Give.applies(noun, verb) {
                Give.present(reply["data"] as? [String: Any] ?? [:], arguments: arguments, context: context)
                return .done
            }
            present(command, reply["data"] as? [String: Any] ?? [:], context: context)
            return .done
        }
        throw Failure("not_running", "Broadway went away", hint: "It may or may not have happened, so look before you repeat it", retrySafe: false)
    }

    private static func source(_ arguments: [String: Any], context: Context) throws -> String {
        if let path = arguments["file"] as? String {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw Failure.usage("Couldn't read \(path)") }
            return String(decoding: data, as: UTF8.self)
        }
        guard isatty(STDIN_FILENO) == 0 else { throw Failure.usage("Give a file, or pipe the text in") }
        return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

    static let spoken: Set<String> = ["agents done", "agents disconnect", "agents idle"]

    static func present(_ command: Command, _ given: [String: Any], context: Context) {
        var data = given
        let console = context.console
        do {
            if context.console.json, context.globals.output == Shots.stream, data["file"] != nil || data["send"] != nil {
                throw Failure.usage("--out - writes the file's bytes to standard output, so leave out --json")
            }
            if data["file"] != nil { try Render.file(&data, context: context) }
            if data["send"] != nil { try Render.sent(&data, context: context) }
        } catch {
            console.failure(command.name, error as? Failure ?? Failure("failed", "\(error)"))
            return
        }
        if data["streamed"] as? Bool == true { return }
        defer { console.success(command.name, data) }
        guard !console.json else { return }
        if let notice = data["notice"] as? String { console.progress(console.err.dim(notice)) }
        if let message = data["message"] as? String { console.progress(console.err.dim(message)) }
        if spoken.contains(command.name) { return }
        var shown = data
        for key in ["message", "notice", "done"] { shown[key] = nil }
        if context.globals.output != nil, shown["path"] == nil {
            try? Render.toFile(command, shown, context: context)
            return
        }
        let hidden: Set<String> = ["ok", "tab", "website", "warning", "cut", "bytes"]
        let left = shown.keys.filter { !hidden.contains($0) }
        if left.isEmpty { return }
        if left == ["id"], let id = shown["id"] as? String { return console.line(id) }
        Render.show(command, shown, context: context)
    }
}

enum Watch {
    static let kinds = ["tabs", "spaces", "downloads", "approvals"]

    struct Options {
        var only: [String] = kinds
        var count: Int?
        var seconds: Double?
    }

    static func parse(_ words: [String]) throws -> Options {
        var found = Options()
        var index = 0
        func value(_ flag: String) throws -> String {
            guard index < words.count else { throw Failure.usage("\(flag) needs a value") }
            index += 1
            return words[index - 1]
        }
        while index < words.count {
            let word = words[index]
            index += 1
            switch word {
            case "--only":
                found.only = try value(word).split(separator: ",").map(String.init)
                if let wrong = found.only.first(where: { !kinds.contains($0) }) { throw Failure.usage("--only takes \(kinds.joined(separator: ",")), not \(wrong)") }
            case "--count":
                guard let count = Int(try value(word)), count > 0 else { throw Failure.usage("--count is a whole number") }
                found.count = count
            case "--seconds":
                guard let seconds = Double(try value(word)), seconds > 0 else { throw Failure.usage("--seconds is a number") }
                found.seconds = seconds
            default:
                throw Failure.usage("watch doesn't take \(word)", hint: "Usage: broadway watch [--only LIST] [--count N] [--seconds S]")
            }
        }
        return found
    }

    static func line(_ event: [String: Any]) -> String {
        let time = (event["at"] as? String).map { String($0.dropFirst(11).prefix(8)) } ?? ""
        let what = event["event"] as? String ?? ""
        let rest = ["id", "space", "title", "name", "url", "detail"].compactMap { (event[$0] as? String).flatMap { $0.isEmpty ? nil : Plain.cell($0) } }
        return ([time, what] + rest).joined(separator: "  ")
    }

    static func run(_ words: [String], context: Context) throws -> Exit {
        let options = try parse(words)
        let link = try context.connection()
        guard link.send(["op": "watch", "only": options.only]) else { throw Failure("not_running", "Broadway went away") }
        guard let hello = link.object() else { throw Failure("not_running", "Broadway went away") }
        if let failure = Context.failure(hello) { throw failure }
        signal(SIGINT, SIG_IGN)
        let stop = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        stop.setEventHandler { exit(Exit.stopped.rawValue) }
        stop.resume()
        if let seconds = options.seconds {
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { exit(Exit.done.rawValue) }
        }
        context.console.progress(context.console.err.dim("Watching. Stop with Control-C."))
        var seen = 0
        while let reply = link.object() {
            if let failure = Context.failure(reply) { throw failure }
            let event = reply["data"] as? [String: Any] ?? reply
            context.console.success("watch", event)
            if !context.console.json { context.console.line(line(event)) }
            seen += 1
            if let count = options.count, seen >= count { return .done }
        }
        context.console.progress(context.console.err.dim("Broadway went away"))
        return .done
    }
}

extension Builtins {
    static let everydayCommands: [Builtin] = [
        Builtin(name: "watch", usage: "broadway watch [--only LIST] [--count N] [--seconds S]", summary: "A live stream of what is happening in Broadway", group: "Broadway",
                details: """
                One line for each thing that happens, until you stop it. With --json, one envelope a line.
                --only     any of tabs,spaces,downloads,approvals
                --count    stop after this many
                --seconds  stop after this long
                Private tabs never appear.
                """,
                examples: ["broadway watch", "broadway watch --only tabs,downloads", "broadway watch --json | jq -r .data.event"]) { context, words in
            try Watch.run(words, context: context)
        },
        Builtin(name: "completions", usage: "broadway completions fish|zsh|bash", summary: "Print the completion script for a shell", group: "Setup",
                details: "broadway setup installs these for you",
                examples: ["broadway completions fish > ~/.config/fish/completions/broadway.fish"]) { context, words in
            guard let shell = words.first, let script = ["fish": Completions.fish, "zsh": Completions.zsh, "bash": Completions.bash][shell] else {
                throw Failure.usage("completions takes fish, zsh or bash")
            }
            context.console.success("completions", ["shell": shell, "script": script])
            if !context.console.json { context.console.put(script) }
            return .done
        },
        Builtin(name: "__nouns", usage: "broadway __nouns [--app]", summary: "", group: "", hidden: true) { context, words in
            if words.contains("--app") {
                let data = try context.ask(["op": "do-list"])
                context.console.success("__nouns", data)
                return .done
            }
            let verbs = Nouns.all.flatMap { $0.verbs.map(\.fullName) }.sorted()
            context.console.success("__nouns", ["verbs": verbs])
            if !context.console.json { verbs.forEach(context.console.line) }
            return .done
        },
    ]
}
