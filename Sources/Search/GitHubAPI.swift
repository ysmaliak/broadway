import Foundation

enum GraphQL {
    static func body(_ query: String, variables: [String: Any] = [:]) -> Data {
        var payload: [String: Any] = ["query": query]
        if !variables.isEmpty { payload["variables"] = variables }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    static func data(_ answer: Data) -> [String: Any]? {
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any] else { return nil }
        return object["data"] as? [String: Any]
    }

    static func errors(_ answer: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: answer) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]] else { return [] }
        return errors.map { error in
            let code = (error["extensions"] as? [String: Any])?["code"] as? String
            return [error["message"] as? String, code].compactMap { $0 }.joined(separator: " ")
        }
    }
}

enum GitHubAPI {
    static func search(for page: URL?) -> String? {
        guard let page, let host = page.host()?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        let path = page.path().split(separator: "/").map(String.init)
        var typed: String?
        if let query = page.query(percentEncoded: true) {
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[0] == "q" else { continue }
                typed = parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }
        }
        var words: [String]
        switch path.count {
        case 1 where path[0] == "pulls":
            words = [typed ?? "is:open is:pr involves:@me archived:false"]
        case 1 where path[0] == "issues":
            words = [typed ?? "is:open is:issue involves:@me archived:false"]
        case 3 where path[2] == "pulls" || path[2] == "issues":
            let kind = path[2] == "pulls" ? "is:pr" : "is:issue"
            words = [typed ?? "\(kind) is:open"]
            if !(words[0].contains(kind)) { words.append(kind) }
            if !words[0].contains("repo:") { words.append("repo:\(path[0])/\(path[1])") }
        default:
            return nil
        }
        if !words[0].contains("sort:") { words.append("sort:updated-desc") }
        return words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func checks(_ state: String?) -> LiveChecks? {
        switch state {
        case "SUCCESS": return .passing
        case "FAILURE", "ERROR": return .failing
        case "PENDING", "EXPECTED": return .pending
        default: return nil
        }
    }

    static func date(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = format.date(from: text) { return date }
        format.formatOptions = [.withInternetDateTime]
        return format.date(from: text)
    }
}
