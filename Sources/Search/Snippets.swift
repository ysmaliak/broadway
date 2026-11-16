import Foundation
import Observation
import Combine

struct Snippet: Codable, Equatable, Identifiable {
    var id = UUID()
    var title = ""
    var keyword = ""
    var text = ""
}

struct SnippetFill: Equatable {
    var text: String
    var tail = ""
}

extension Snippet {
    static let placeholders = ["date", "time", "clipboard", "cursor"]

    static func fill(_ text: String, now: Date = Date(), locale: Locale = .autoupdatingCurrent, clipboard: String?) -> SnippetFill {
        func stamp(date: DateFormatter.Style, time: DateFormatter.Style) -> String {
            let format = DateFormatter()
            format.locale = locale
            format.dateStyle = date
            format.timeStyle = time
            return format.string(from: now)
        }
        var out = ""
        var caret: Int?
        var rest = text[...]
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let from = rest[open...]
            guard let name = placeholders.first(where: { from.hasPrefix("{\($0)}") }) else {
                out += "{"
                rest = from.dropFirst()
                continue
            }
            switch name {
            case "date": out += stamp(date: .long, time: .none)
            case "time": out += stamp(date: .none, time: .short)
            case "clipboard": out += clipboard ?? ""
            default: if caret == nil { caret = out.unicodeScalars.count }
            }
            rest = from.dropFirst(name.count + 2)
        }
        out += rest
        guard let caret else { return SnippetFill(text: out) }
        return SnippetFill(text: out, tail: String(String.UnicodeScalarView(out.unicodeScalars.dropFirst(caret))))
    }
}

@MainActor
@Observable
final class SnippetStore {
    static let shared = SnippetStore(url: Store.folder.appendingPathComponent("snippets.json"))
    private(set) var snippets: [Snippet]
    private(set) var uses: [UUID: Int]
    private let url: URL
    private var usesURL: URL { url.deletingLastPathComponent().appendingPathComponent("snippet-uses.json") }

    init(url: URL) {
        self.url = url
        uses = (try? Data(contentsOf: url.deletingLastPathComponent().appendingPathComponent("snippet-uses.json")))
            .flatMap { try? JSONDecoder().decode([UUID: Int].self, from: $0) } ?? [:]
        if let data = try? Data(contentsOf: url) {
            if let saved = try? JSONDecoder().decode([Snippet].self, from: data) { snippets = saved }
            else {
                Store.quarantine(url)
                snippets = []
            }
        } else { snippets = [] }
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    func problem(_ snippet: Snippet) -> String? {
        let title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyword = Self.normalized(snippet.keyword)
        guard !title.isEmpty, title.count <= 120 else { return "Give the snippet a title of up to 120 characters" }
        guard !keyword.isEmpty, keyword.count <= 40,
              keyword.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return "Keywords can be up to 40 letters, numbers, dashes or underscores, with no semicolon" }
        guard !snippet.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, snippet.text.utf8.count <= 100_000
        else { return "Add some text, up to 100 KB" }
        guard !snippets.contains(where: { $0.id != snippet.id && Self.normalized($0.keyword) == keyword })
        else { return "That keyword belongs to another snippet" }
        return nil
    }

    @discardableResult
    func save(_ snippet: Snippet) -> String? {
        if let problem = problem(snippet) { return problem }
        var saved = snippet
        saved.title = snippet.title.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.keyword = Self.normalized(snippet.keyword)
        var next = snippets
        if let index = next.firstIndex(where: { $0.id == saved.id }) { next[index] = saved }
        else { next.append(saved) }
        return persist(next)
    }

    @discardableResult
    func delete(_ id: Snippet.ID) -> String? {
        let trouble = persist(snippets.filter { $0.id != id })
        if trouble == nil, uses[id] != nil {
            uses[id] = nil
            persistUses()
        }
        return trouble
    }

    func used(_ id: Snippet.ID) {
        guard snippets.contains(where: { $0.id == id }) else { return }
        uses[id, default: 0] += 1
        persistUses()
    }

    private func persistUses() {
        try? FileManager.default.createDirectory(at: usesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? JSONEncoder().encode(uses).write(to: usesURL, options: .atomic)) != nil else { return }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: usesURL.path)
    }

    func listed(matching text: String) -> [Snippet] {
        let words = Self.normalized(text).split(whereSeparator: \.isWhitespace).map { word in
            word.hasPrefix(";") ? String(word.dropFirst()) : String(word)
        }.filter { !$0.isEmpty }
        return snippets.filter { snippet in
            let hay = snippet.title + " " + snippet.keyword
            return words.allSatisfy { hay.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.sorted { left, right in
            let leftUses = uses[left.id] ?? 0
            let rightUses = uses[right.id] ?? 0
            if leftUses != rightUses { return leftUses > rightUses }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }
    }

    private func persist(_ next: [Snippet]) -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            snippets = next
            return nil
        } catch { return "The snippets couldn't be saved. Try again." }
    }

    func matches(_ text: String) -> [Snippet] {
        let query = Self.normalized(text)
        guard !query.isEmpty, query.count <= 120 else { return [] }
        let keyword = query.hasPrefix(";") ? String(query.dropFirst()) : nil
        guard keyword != "", keyword != nil || query.count >= 2 else { return [] }
        return snippets.filter { snippet in
            if let keyword { return Self.normalized(snippet.keyword).hasPrefix(keyword) }
            return Self.normalized(snippet.title).hasPrefix(query)
        }.sorted { left, right in
            let leftExact = keyword.map { Self.normalized(left.keyword) == $0 } ?? (Self.normalized(left.title) == query)
            let rightExact = keyword.map { Self.normalized(right.keyword) == $0 } ?? (Self.normalized(right.title) == query)
            if leftExact != rightExact { return leftExact }
            return left.title.localizedStandardCompare(right.title) == .orderedAscending
        }.prefix(5).map { $0 }
    }

    func isQuery(_ text: String) -> Bool {
        Self.normalized(text).hasPrefix(";") || !matches(text).isEmpty
    }
}
