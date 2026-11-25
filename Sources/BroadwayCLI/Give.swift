import Foundation

enum Give {
    static func applies(_ noun: Noun, _ verb: Verb) -> Bool { noun.name == "logins" && verb.name == "give" }

    static let scriptNames = ["logins_give", "give"]
    static let alone = "A saved password is given only by broadway logins give run on its own in a terminal, never as a step or in a script. Nothing was given."
    static let aloneHint = "Run broadway logins give SITE --password-only by itself"

    static func asked(_ words: [String]) -> Bool { words.count >= 2 && words[0] == "logins" && words[1] == "give" }

    static func remote(_ environment: [String: String]) -> Bool {
        ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"].contains { environment[$0].map { !$0.isEmpty } == true }
    }

    static func check(_ arguments: [String: Any], json: Bool, output: String?, environment: [String: String]) throws {
        if remote(environment) {
            throw Failure("person_only", "Only on the Mac that runs Broadway, never over ssh. Nothing was given.", hint: "Ask the person to type the password where it is wanted")
        }
        if output != nil { throw Failure.usage("logins give writes to standard output only, so leave out -o") }
        if arguments["password-only"] as? Bool == true, json { throw Failure.usage("--password-only prints the password alone, so leave out --json") }
    }

    static func text(_ data: [String: Any], passwordOnly: Bool, tty: Bool) -> String {
        let password = data["password"] as? String ?? ""
        if passwordOnly { return tty ? password + "\n" : password }
        return (data["user"] as? String ?? "") + "\n" + password + "\n"
    }

    static func present(_ data: [String: Any], arguments: [String: Any], context: Context) {
        let console = context.console
        if console.json { return console.success("logins give", data) }
        let only = arguments["password-only"] as? Bool == true
        console.put(text(data, passwordOnly: only, tty: console.outTTY))
        if !only, let site = data["site"] as? String { console.progress(console.err.dim("The user name, then the password, for \(site)")) }
    }
}
