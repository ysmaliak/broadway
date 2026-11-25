import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(5)))
struct GiveTests {
    private let answer: [String: Any] = ["user": "sam@example.com", "password": "hunter2-swordfish", "site": "example.com", "message": "Broadway gave the password for example.com"]

    @Test func thePasswordAloneHasNoLineEndInAPipe() {
        #expect(Give.text(answer, passwordOnly: true, tty: false) == "hunter2-swordfish")
        #expect(Give.text(answer, passwordOnly: true, tty: true) == "hunter2-swordfish\n")
        #expect(Give.text(answer, passwordOnly: false, tty: false) == "sam@example.com\nhunter2-swordfish\n")
    }

    @Test func overSSHItIsRefusedBeforeAnythingIsSent() throws {
        for key in ["SSH_CONNECTION", "SSH_CLIENT", "SSH_TTY"] {
            #expect(throws: (any Error).self) { try Give.check([:], json: false, output: nil, environment: [key: "10.0.0.2 51000 10.0.0.1 22"]) }
            do {
                try Give.check([:], json: false, output: nil, environment: [key: "x"])
            } catch let failure as Failure {
                #expect(failure.code == "person_only")
                #expect(failure.message.contains("Only on the Mac that runs Broadway"))
            }
        }
        try Give.check(["password-only": true], json: false, output: nil, environment: ["SSH_CONNECTION": ""])
    }

    @Test func itWritesOnlyToStandardOutput() {
        #expect(throws: (any Error).self) { try Give.check([:], json: false, output: "pw.txt", environment: [:]) }
        #expect(throws: (any Error).self) { try Give.check(["password-only": true], json: true, output: nil, environment: [:]) }
    }

    @Test func theVerbIsALoginsVerbWithItsFlags() throws {
        let noun = try #require(Nouns.all.first { $0.name == "logins" })
        let verb = try #require(noun.verbs.first { $0.name == "give" })
        let command = verb.command

        #expect(Give.applies(noun, verb))
        #expect(command.positional.map(\.name) == ["site"])
        #expect(Set(command.flags.map(\.name)).isSuperset(of: ["account", "password-only"]))
    }
}
