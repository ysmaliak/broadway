import BroadwayCLI
import Foundation

struct AgentRef: Equatable {
    var frame: String?
    var ref: String

    init(_ text: String) {
        if text.hasPrefix("f"), let dot = text.firstIndex(of: "."), text[text.index(after: text.startIndex)..<dot].allSatisfy(\.isNumber) {
            frame = String(text[..<dot])
            ref = String(text[text.index(after: dot)...])
        } else {
            ref = text
        }
    }
}

enum AgentSecrets {
    private static let names = try? NSRegularExpression(
        pattern: "pass(word|wd|code|phrase)?$|^pwd$|^pin$|^otp$|token|secret|api.?key|session|^auth|^code$|^key$|^sig(nature)?$|card|cvv|cvc|ssn",
        options: [.caseInsensitive])

    private static func sensitive(_ name: String) -> Bool {
        guard let names else { return true }
        let decoded = name.removingPercentEncoding ?? name
        return names.firstMatch(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)) != nil
    }

    private static func pairs(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0 == "&" || $0 == ";" }).map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "" }
    }

    static func carriesSecret(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return true }
        if parts.password != nil { return true }
        return (pairs(parts.percentEncodedQuery) + pairs(parts.percentEncodedFragment)).contains(where: sensitive)
    }

    static func shown(_ url: URL?) -> String {
        guard let url else { return "" }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "" }
        parts.user = nil
        parts.password = nil
        func kept(_ text: String?) -> String? {
            guard let text, !text.isEmpty else { return text }
            return text.split(whereSeparator: { $0 == "&" || $0 == ";" }).map { pair in
                let name = pair.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
                return sensitive(name) ? "\(name)=hidden" : String(pair)
            }.joined(separator: "&")
        }
        parts.percentEncodedQuery = kept(parts.percentEncodedQuery)
        parts.percentEncodedFragment = kept(parts.percentEncodedFragment)
        return parts.string ?? ""
    }

    static func diagnosticURL(_ text: String) -> String {
        guard !text.isEmpty, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return text.isEmpty ? "" : "[source hidden]" }
        return diagnostic(shown(url))
    }

    static func diagnostic(_ text: String) -> String {
        var result = DevCopy.strip(text)
        if let urls = try? NSRegularExpression(pattern: #"https?://[^\s<>\"']+"#, options: .caseInsensitive) {
            for match in urls.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let range = Range(match.range, in: result), let url = URL(string: String(result[range])) else { continue }
                result.replaceSubrange(range, with: shown(url))
            }
        }
        result = result.replacingOccurrences(of: #"(?i)([\"']?(?:authorization|proxy-authorization|cookie|set-cookie)[\"']?\s*[:=]\s*)[^\r\n]+"#, with: "$1[hidden]", options: .regularExpression)
        if let pairs = try? NSRegularExpression(pattern: #"[\"']?([A-Za-z_][A-Za-z0-9_-]*)[\"']?\s*[:=]\s*("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|[^\s,;&{}\[\]"']+)"#) {
            for match in pairs.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
                guard let key = Range(match.range(at: 1), in: result), sensitive(String(result[key])), let value = Range(match.range(at: 2), in: result) else { continue }
                result.replaceSubrange(value, with: "[hidden]")
            }
        }
        return result
    }

    private struct Form {
        let text: String
        let options: String.CompareOptions
    }

    private static func forms(_ sealed: Set<String>) -> [Form] {
        var out: [Form] = []
        for value in sealed.sorted(by: { $0.count > $1.count }) {
            out.append(Form(text: value, options: []))
            out += written(value).map { Form(text: $0, options: .caseInsensitive) }
            let spaced = value.enumerated().map { $0.offset > 0 && $0.offset % 4 == 0 ? " \($0.element)" : String($0.element) }.joined()
            if value.allSatisfy(\.isNumber) { out.append(Form(text: spaced, options: [])) }
        }
        return out
    }

    private static func replaced(_ text: String, _ forms: [Form]) -> String {
        var out = text
        for form in forms { out = out.replacingOccurrences(of: form.text, with: "••••", options: form.options) }
        return out
    }

    static func scrub(_ text: String, sealed: Set<String>) -> String {
        replaced(text, forms(sealed))
    }

    static func written(_ value: String) -> [String] {
        var forms: Set<String> = []
        for kept in ["-._~", "-_.!~*'()", "*-._"] {
            var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            allowed.insert(charactersIn: kept)
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            forms.insert(encoded)
            forms.insert(encoded.replacingOccurrences(of: "%20", with: "+"))
        }
        for allowed in [CharacterSet.urlQueryAllowed, .urlPathAllowed] {
            if let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) { forms.insert(encoded) }
        }
        for options: JSONSerialization.WritingOptions in [[.fragmentsAllowed], [.fragmentsAllowed, .withoutEscapingSlashes]] {
            if let data = try? JSONSerialization.data(withJSONObject: value, options: options) {
                forms.insert(String(String(decoding: data, as: UTF8.self).dropFirst().dropLast()))
            }
        }
        forms.insert(value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;"))
        forms.remove(value)
        return forms.filter { $0.count >= 4 }.sorted { $0.count > $1.count }
    }

    static func scrub(_ outcome: ToolOutcome, sealed: Set<String>) -> ToolOutcome {
        guard !sealed.isEmpty else { return outcome }
        let forms = forms(sealed)
        var said = outcome
        said.text = said.text.map { replaced($0, forms) }
        said.plain = said.plain.map { replaced($0, forms) }
        said.hint = said.hint.map { replaced($0, forms) }
        said.data = said.data.map { $0.mapValues { scrubbed($0, forms) } }
        return said
    }

    static func scrub(_ data: [String: Any], sealed: Set<String>) -> [String: Any] {
        let forms = forms(sealed)
        guard !forms.isEmpty else { return data }
        return data.mapValues { scrubbed($0, forms) }
    }

    private static func scrubbed(_ value: Any, _ forms: [Form]) -> Any {
        switch value {
        case let text as String: replaced(text, forms)
        case let list as [Any]: list.map { scrubbed($0, forms) }
        case let object as [String: Any]: object.mapValues { scrubbed($0, forms) }
        default: value
        }
    }

    static func fenced(_ text: String) -> String {
        MCPRelay.fenced(text)
    }
}
