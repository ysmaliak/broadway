import Darwin
import Foundation

final class Context {
    let globals: Globals
    let console: Console
    let place: Place
    let environment: [String: String]
    let binary: String
    private var link: Link?
    private var loaded: Catalog?

    init(globals: Globals, console: Console, place: Place, environment: [String: String], binary: String) {
        self.globals = globals
        self.console = console
        self.place = place
        self.environment = environment
        self.binary = binary
    }

    var home: String { Place.home(environment) }

    private(set) lazy var cli: String = Setup.version(binary: binary) ?? "dev"

    func call(_ tool: String, _ arguments: Any) -> [String: Any] {
        ["op": "call", "tool": tool, "arguments": arguments, "agent": Context.agent, "cli": cli]
    }

    func catalog() -> Catalog {
        if let loaded { return loaded }
        var found = Catalog(nil)
        if link == nil { link = place.connect() }
        if let link, link.send(["op": "tools"]), let reply = link.object(), let commands = reply["commands"] as? [[String: Any]] {
            found = Catalog(commands)
        } else {
            link = nil
            found = Catalog(Catalog.offline(binary: binary))
        }
        loaded = found
        return found
    }

    func connection() throws -> Link {
        if let link { return link }
        let reached = try place.reach(console: console)
        link = reached
        return reached
    }

    func hangUp() {
        link = nil
    }

    func ask(_ request: [String: Any]) throws -> [String: Any] {
        let link = try connection()
        self.link = nil
        guard link.send(request), let reply = link.object() else { throw Failure("not_running", "Broadway went away", retrySafe: false) }
        if let failure = Context.failure(reply) { throw failure }
        return reply["data"] as? [String: Any] ?? [:]
    }

    static func exit(for code: String) -> Exit {
        switch code {
        case "usage", "unknown_command", "unknown_tool", "too_many": .mistake
        case "needs_you": .needsYou
        case "not_answering", "deadline": .unanswered
        default: .failed
        }
    }

    static func failure(_ reply: [String: Any], reads: Bool = true) -> Failure? {
        if let error = reply["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "failed"
            return Failure(code, error["message"] as? String ?? "That didn't work", hint: error["hint"] as? String,
                           retrySafe: error["retry_safe"] as? Bool ?? reads, exit: exit(for: code),
                           data: reply["data"] as? [String: Any])
        }
        if let text = reply["error"] as? String { return Failure("failed", text, retrySafe: reads) }
        return nil
    }
}

struct Builtin {
    var name: String
    var usage: String
    var summary: String
    var group: String
    var details: String = ""
    var examples: [String] = []
    var hidden = false
    var run: (Context, [String]) throws -> Exit
}

enum Builtins {
    static let all: [Builtin] = batchCommands + appCommands + setupCommands + everydayCommands + [
        Builtin(name: "help", usage: "broadway help [command]", summary: "How to use broadway, or read about one command", group: "Help",
                examples: ["broadway help", "broadway help click", "broadway help bookmarks add"]) { context, words in
            Help.show(words, context: context)
        },
        Builtin(name: "guide", usage: "broadway guide [mcp]", summary: "A compact guide for coding agents", group: "Help",
                details: "Read this first if you are an agent driving Broadway",
                examples: ["broadway guide", "broadway guide mcp"]) { context, words in
            Help.guide(words.first, context: context)
        },
        Builtin(name: "__complete", usage: "broadway __complete WORDS… -- CURRENT", summary: "", group: "", hidden: true) { context, words in
            Completions.answer(words, context: context)
        },
    ]

    static func find(_ word: String) -> Builtin? {
        all.first { $0.name == word }
    }

    static var names: [String] { all.filter { !$0.hidden }.map(\.name) }
}

public enum BroadwayCommand {
    public static func run(_ arguments: [String]) -> Int32 {
        let environment = ProcessInfo.processInfo.environment
        let binary = realpath(CommandLine.arguments[0], nil).map { path -> String in
            defer { free(path) }
            return String(cString: path)
        } ?? selfPath()
        let console: Console
        let globals: Globals
        let words: [String]
        do {
            (globals, words) = try Globals.extract(arguments, environment: environment)
            console = Console(json: globals.json, quiet: globals.quiet, noColor: globals.noColor, environment: environment)
        } catch {
            let failure = error as? Failure ?? Failure.usage("\(error)")
            let console = Console(json: arguments.contains("--json"), quiet: false, noColor: false, environment: environment)
            console.failure("", failure)
            return failure.exit.rawValue
        }
        let place = Place.resolve(socket: globals.socket, world: globals.world, environment: environment, binary: binary)
        let context = Context(globals: globals, console: console, place: place, environment: environment, binary: binary)
        let name = words.first ?? ""
        Link.watch = Link.Watch(socket: place.socket, deadline: deadline(words, globals: globals), reads: reads(words, context: context))
        do {
            let exit = try route(words, context: context)
            if let halted = Link.halted { throw halted }
            return exit.rawValue
        } catch {
            let failure = Link.halted ?? error as? Failure ?? Failure("failed", "\(error)", retrySafe: false)
            console.failure(name, failure)
            return failure.exit.rawValue
        }
    }

    static let streams: Set<String> = ["watch", "serve", "mcp", "__complete"]

    static func deadline(_ words: [String], globals: Globals) -> Date? {
        if let seconds = globals.timeout { return Date().addingTimeInterval(seconds) }
        guard let first = words.first, !streams.contains(first), !first.contains(where: \.isWhitespace) else { return nil }
        var seconds = 600.0
        if let at = words.firstIndex(of: "--wait-person"), at + 1 < words.count, let minutes = Double(words[at + 1]) { seconds = max(seconds, minutes * 60 + 60) }
        if first == "handoff" || first == "ask", let at = words.firstIndex(of: "--seconds"), at + 1 < words.count, let wait = Double(words[at + 1]) { seconds = max(seconds, min(wait, 900) + 60) }
        return Date().addingTimeInterval(seconds)
    }

    private static func reads(_ words: [String], context: Context) -> Bool {
        guard let first = words.first else { return true }
        return ["tabs", "snapshot", "read", "shot", "console", "network", "wait", "history", "status", "help", "guide", "find", "locate", "audit", "timings", "styles"].contains(first)
            || words.dropFirst().first.map { ["list", "get", "find", "show"].contains($0) } == true
    }

    private static func selfPath() -> String {
        var size: UInt32 = 4096
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0, let resolved = realpath(buffer, nil) else { return CommandLine.arguments[0] }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private static func route(_ words: [String], context: Context) throws -> Exit {
        if context.globals.version { return Help.version(context) }
        guard let first = words.first else { return Help.show([], context: context) }
        if let builtin = Builtins.find(first) {
            if context.globals.help { return Help.show([first], context: context) }
            return try builtin.run(context, Array(words.dropFirst()))
        }
        if context.globals.help {
            if Help.knows(words) { return Help.show(words, context: context) }
            if context.catalog().find(first) != nil { return Help.show([first], context: context) }
            return Help.show([], context: context)
        }
        if first == "pdf", let command = context.catalog().find(first) {
            return try Browse.run(command, Array(words.dropFirst()), called: first, context: context)
        }
        if gone.contains(first) { throw noTasks }
        if notesGone.contains(first) { throw noNotes }
        if let routed = try Nouns.route(words) { return try Person.run(routed.noun, routed.verb, routed.rest, context: context, bare: Person.bare(words)) }
        let spaced = first.contains(where: \.isWhitespace)
        if !spaced, !first.hasPrefix("-") {
            if words.count == 1, Address.looksLike(first) { return try Browse.person(first, context: context) }
            if let command = context.catalog().find(first) {
                return try Browse.run(command, Array(words.dropFirst()), called: first, context: context)
            }
        }
        if words.count == 1, !spaced { throw unknown(first, context: context) }
        if !spaced, !first.hasPrefix("-"), let near = nearest(first, context: context) {
            throw Failure.usage("Unknown command \(first). Did you mean \(near)?", hint: "Run broadway help for the list")
        }
        throw noTasks
    }

    static let gone: Set<String> = ["task", "session", "plans", "tasks", "helpers"]

    static let notesGone: Set<String> = ["memory", "notes"]

    static let noNotes = Failure("no_notes", "Broadway no longer keeps notes for agents. Site skills stay, in broadway skills.", retrySafe: false, exit: .mistake)

    static let noTasks = Failure("no_tasks", "Broadway no longer runs tasks. An agent you start yourself uses Broadway with the broadway command.", retrySafe: false, exit: .mistake)

    private static func nearest(_ word: String, context: Context) -> String? {
        Near.best(word, in: Builtins.names + Nouns.names + context.catalog().names)
    }

    private static func unknown(_ word: String, context: Context) -> Failure {
        if let near = nearest(word, context: context) {
            return Failure.usage("Unknown command \(word). Did you mean \(near)?", hint: "Run broadway help for the list")
        }
        return Failure.usage("Unknown command \(word)", hint: "Run broadway help for the list")
    }
}
