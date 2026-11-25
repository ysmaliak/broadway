import Foundation
import Testing
@testable import BroadwayCLI

@Suite(.timeLimit(.minutes(1)))
struct SecretInputTests {
    private func parameter(_ name: String, type: String = "string", required: Bool = false) -> [String: Any] {
        ["name": name, "type": type, "required": required]
    }

    private var type: Command {
        let ref = parameter("ref")
        let text = parameter("text")
        return Command(["name": "type", "tool": "type", "tabbed": true, "positional": [ref, text],
                        "flags": [ref, text, parameter("submit", type: "boolean"), parameter("label"), parameter("secret-env")], "examples": ["broadway type"]])
    }

    private var click: Command {
        let ref = parameter("ref", required: true)
        return Command(["name": "click", "tool": "click", "tabbed": true, "positional": [ref], "flags": [ref], "examples": ["broadway click"]])
    }

    private func asked(_ words: [String], environment: [String: String] = [:], file: Data? = nil, stdin: Data? = nil, secrets: Bool = true) throws -> Browse.Asked {
        try Browse.arguments(type, words, tab: "a8b6db94", tabFlag: true, secrets: secrets, environment: environment, file: { _ in file }, stdin: { stdin })
    }

    @Test func aSecretFromTheEnvironmentTravelsBesideTheArguments() throws {
        let found = try asked(["@e3", "--secret-env", "TOKEN"], environment: ["TOKEN": "s3cret-Value"])

        #expect(found.secret == "s3cret-Value")
        #expect(found.arguments["ref"] as? String == "e3")
        #expect(!"\(found.arguments)".contains("s3cret"))
        #expect(!"\(found.arguments)".contains("TOKEN"))
    }

    @Test func anUnsetVariableIsNamedWithThePipeForSsh() throws {
        do {
            _ = try asked(["@e3", "--secret-env=TOKEN"])
            Issue.record("an unset variable went through")
        } catch let failure as Failure {
            #expect(failure.code == "usage")
            #expect(failure.message.contains("TOKEN is not set"))
            #expect(failure.hint?.contains("--secret-stdin") == true)
        }
    }

    @Test func aFileOrAPipeLosesOneLastNewline() throws {
        #expect(try asked(["--label", "Password", "--secret-file", "/tmp/x"], file: Data("from-a-file\n".utf8)).secret == "from-a-file")
        #expect(try asked(["--label", "Password", "--secret-stdin"], stdin: Data("from-a-pipe\r\n".utf8)).secret == "from-a-pipe")
        #expect(try asked(["--label", "Password", "--secret-stdin"], stdin: Data("two-lines\n\n".utf8)).secret == "two-lines\n")
        #expect((try? asked(["--label", "Password", "--secret-stdin"])) == nil)
        #expect((try? asked(["--label", "Password", "--secret-stdin"], stdin: Data("\n".utf8))) == nil)
    }

    @Test func textAndASecretTogetherAreRefused() {
        #expect((try? asked(["@e3", "plain words", "--secret-env", "TOKEN"], environment: ["TOKEN": "s3cret-Value"])) == nil)
        #expect((try? asked(["@e3", "--secret-env", "TOKEN", "--secret-stdin"], environment: ["TOKEN": "s3cret-Value"], stdin: Data("x".utf8))) == nil)
    }

    @Test func aBatchStepOrAScriptCannotCarryASecret() {
        do {
            _ = try asked(["@e3", "--secret-env", "TOKEN"], environment: ["TOKEN": "s3cret-Value"], secrets: false)
            Issue.record("a batch step took a secret")
        } catch let failure as Failure {
            #expect(failure.message.contains("its own command"))
        } catch {
            Issue.record("\(error)")
        }
    }

    @Test func otherCommandsDoNotTakeTheFlags() {
        #expect((try? Browse.arguments(click, ["@e3", "--secret-env", "TOKEN"], tab: nil, tabFlag: false, environment: ["TOKEN": "s3cret-Value"])) == nil)
    }

    private func line(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theRelayReadsSecretEnvFromItsOwnEnvironment() throws {
        let call = try line(["jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": ["name": "type", "arguments": ["ref": "e3", "secret_env": "TOKEN"]]])

        guard case .forward(let sent)? = SecretInput.relay(call, environment: ["TOKEN": "v4lue-From-Env"]) else {
            Issue.record("the call was not forwarded")
            return
        }
        let params = try #require(try object(sent)["params"] as? [String: Any])

        #expect((params["arguments"] as? [String: Any])?["secret_env"] == nil)
        #expect((params["arguments"] as? [String: Any])?["ref"] as? String == "e3")
        #expect((params["_meta"] as? [String: Any])?["com.broadway/secret"] as? String == "v4lue-From-Env")
    }

    @Test func theRelayAnswersAMissingVariableItself() throws {
        let call = try line(["jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": ["name": "type", "arguments": ["ref": "e3", "secret_env": "TOKEN"]]])

        guard case .answer(let said)? = SecretInput.relay(call, environment: [:]) else {
            Issue.record("the call went on to Broadway")
            return
        }
        let result = try #require(try object(said)["result"] as? [String: Any])

        #expect(result["isError"] as? Bool == true)
        #expect("\(result)".contains("TOKEN is not set"))
    }

    @Test func aSecretPutInMetaByTheAgentIsDropped() throws {
        let call = try line(["jsonrpc": "2.0", "id": 9, "method": "tools/call",
                             "params": ["name": "type", "arguments": ["ref": "e3", "text": "x"], "_meta": ["com.broadway/secret": "smuggled", "progressToken": 3]]])

        guard case .forward(let sent)? = SecretInput.relay(call, environment: [:]) else {
            Issue.record("the call was not forwarded")
            return
        }
        let meta = try #require((try object(sent)["params"] as? [String: Any])?["_meta"] as? [String: Any])

        #expect(meta["com.broadway/secret"] == nil)
        #expect(meta["progressToken"] as? Int == 3)
    }

    @Test func otherToolsPassUntouched() throws {
        let call = try line(["jsonrpc": "2.0", "id": 10, "method": "tools/call", "params": ["name": "click", "arguments": ["ref": "e3", "secret_env": "TOKEN"]]])

        #expect(SecretInput.relay(call, environment: ["TOKEN": "x"]) == nil)
    }
}
