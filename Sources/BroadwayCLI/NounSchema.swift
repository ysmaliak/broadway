import Foundation

public enum NounSchema {
    public struct Argument: Equatable, Sendable {
        public let name: String
        public let type: String
        public let required: Bool
        public let many: Bool
        public let choices: [String]
    }

    public struct Line: Equatable, Sendable {
        public let noun: String
        public let verb: String
        public let line: String
        public let summary: String
        public let about: String
        public let hidden: Bool
        public let fromStdin: Bool
        public let tabbed: Bool
        public let arguments: [Argument]
    }

    public static var lines: [Line] {
        Nouns.all.flatMap { noun in
            noun.verbs.map { verb in
                let command = verb.command
                return Line(noun: noun.name, verb: verb.name, line: verb.line, summary: verb.summary, about: verb.about,
                            hidden: verb.hidden, fromStdin: verb.fromStdin, tabbed: command.tabbed,
                            arguments: command.flags.map { Argument(name: $0.name, type: $0.type, required: $0.required, many: $0.many, choices: $0.choices) })
            }
        }
    }

    public static func text(noun: String, verb: String, data: [String: Any]) -> String {
        guard let found = Nouns.noun(noun)?.verb(verb) else { return Render.lines(Command([:]), data).joined(separator: "\n") }
        return Render.lines(found.command, data).joined(separator: "\n")
    }
}
