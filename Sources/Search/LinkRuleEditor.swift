import Foundation

enum LinkRuleEditor {
    static let everything = "*"

    static func isAny(_ match: LinkRule.Match) -> Bool {
        guard case .pattern(let text) = match else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) == everything
    }

    static func isEmpty(_ match: LinkRule.Match) -> Bool {
        match.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func isBlank(_ rule: LinkRule) -> Bool {
        isEmpty(rule.match) && rule.from == .anywhere && rule.note.isEmpty && rule.rewrite == nil
    }

    static func shown(_ rule: LinkRule) -> String {
        isAny(rule.match) && rule.from != .anywhere ? "" : rule.match.text
    }

    static func reading(_ typed: String) -> LinkRule.Match.Kind {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("*") { return .pattern }
        var rest = Substring(text)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        guard let cut = rest.firstIndex(where: { "/?#".contains($0) }) else { return .site }
        return rest[cut...].count > 1 ? .starts : .site
    }

    static func kept(_ match: LinkRule.Match) -> LinkRule.Match.Kind? {
        match.kind == reading(match.text) ? nil : match.kind
    }

    static func kind(_ rule: LinkRule, chosen: LinkRule.Match.Kind?) -> LinkRule.Match.Kind {
        chosen ?? (shown(rule).isEmpty ? kept(rule.match) ?? .site : rule.match.kind)
    }

    static func match(typed: String, kind: LinkRule.Match.Kind?, from: LinkRule.From) -> LinkRule.Match {
        if typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return from == .anywhere ? .make(kind ?? .site, "") : .pattern(everything)
        }
        return .make(kind ?? reading(typed), typed)
    }

    static func usesMore(_ rule: LinkRule) -> Bool {
        if case .space(_, .some) = rule.target { return true }
        return rule.background || rule.rewrite != nil || !rule.note.isEmpty || (!isEmpty(rule.match) && kept(rule.match) != nil)
    }
}
