import Darwin
import Foundation

enum SecretInput {
    static let flags = ["--secret-env", "--secret-file", "--secret-stdin"]

    static let sshHint = "Over ssh, pipe it in: printf %s \"$TOKEN\" | ssh HOST broadway type TARGET --secret-stdin"

    static func trimmed(_ text: String) -> String {
        text.hasSuffix("\n") || text.hasSuffix("\r\n") ? String(text.dropLast()) : text
    }

    static func read(_ flag: String, _ value: String, environment: [String: String], file: (String) -> Data?, stdin: () -> Data?) throws -> String {
        let found: String
        switch flag {
        case "--secret-env":
            guard !value.isEmpty else { throw Failure.usage("--secret-env needs the name of a variable") }
            guard let held = environment[value], !held.isEmpty else {
                throw Failure.usage("\(value) is not set where this broadway runs, so nothing was typed", hint: sshHint)
            }
            found = held
        case "--secret-file":
            let path = (value as NSString).expandingTildeInPath
            guard let data = file(path) else { throw Failure.usage("Couldn't read \(value), so nothing was typed") }
            found = trimmed(String(decoding: data, as: UTF8.self))
        default:
            guard let data = stdin() else {
                throw Failure.usage("--secret-stdin reads a pipe, and nothing was piped in", hint: "printf %s \"$TOKEN\" | broadway type TARGET --secret-stdin")
            }
            found = trimmed(String(decoding: data, as: UTF8.self))
        }
        guard !found.isEmpty else { throw Failure.usage("The secret is empty, so nothing was typed") }
        return found
    }

    static func piped() -> Data? {
        guard isatty(STDIN_FILENO) == 0 else { return nil }
        return FileHandle.standardInput.readDataToEndOfFile()
    }

    enum Relayed {
        case forward(Data)
        case answer(Data)
    }

    static func relay(_ line: Data, environment: [String: String]) -> Relayed? {
        guard var object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], object["method"] as? String == "tools/call",
              var params = object["params"] as? [String: Any], params["name"] as? String == "type" else { return nil }
        var meta = params["_meta"] as? [String: Any] ?? [:]
        let carried = meta.removeValue(forKey: "com.broadway/secret") != nil
        var arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let name = arguments.removeValue(forKey: "secret_env") as? String else {
            guard carried else { return nil }
            params["_meta"] = meta
            object["params"] = params
            return (try? JSONSerialization.data(withJSONObject: object)).map { .forward($0 + Data([0x0A])) }
        }
        guard let value = environment[name], !value.isEmpty else {
            let message = "secret_env \(name) is not set in the environment broadway mcp runs in, so nothing was typed"
            let hint = "Set it where your MCP client starts broadway mcp, or run broadway type TARGET --secret-env NAME in a shell"
            let answer: [String: Any] = ["jsonrpc": "2.0", "id": object["id"] ?? NSNull(), "result": [
                "content": [["type": "text", "text": message + "\nhint: " + hint]], "isError": true,
                "_meta": ["com.broadway/error": ["code": "usage", "message": message, "hint": hint, "retry_safe": true]],
            ] as [String: Any]]
            return (try? JSONSerialization.data(withJSONObject: answer)).map { .answer($0 + Data([0x0A])) }
        }
        meta["com.broadway/secret"] = value
        params["_meta"] = meta
        params["arguments"] = arguments
        object["params"] = params
        return (try? JSONSerialization.data(withJSONObject: object)).map { .forward($0 + Data([0x0A])) }
    }
}
