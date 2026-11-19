import AppKit
import Observation
import Foundation

struct Skill: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var sites: [String]
    var body: String
    var builtIn: Bool
    var text: String

    var summary: String {
        body.split(whereSeparator: \.isNewline).first.map(String.init) ?? name
    }

    func serves(_ url: URL?) -> Bool {
        guard let url, let host = url.host()?.lowercased() else { return false }
        return sites.contains { Skill.matches($0, host: PageIndex.bare(host), path: url.path) }
    }

    static func matches(_ site: String, host: String, path: String) -> Bool {
        let parts = site.lowercased().split(separator: "/", maxSplits: 1).map(String.init)
        guard let wanted = parts.first.map(PageIndex.bare), host == wanted || host.hasSuffix("." + wanted) else { return false }
        return parts.count < 2 || path.lowercased().hasPrefix("/" + parts[1])
    }

    static func slug(_ name: String) -> String {
        let kept = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(kept).split(separator: "-").joined(separator: "-")
    }

    static func parse(_ text: String, builtIn: Bool = false) -> Skill? {
        var name: String?
        var sites: [String] = []
        var bodyLines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if name == nil, line.hasPrefix("# ") {
                name = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.lowercased().hasPrefix("sites:"), bodyLines.allSatisfy(\.isEmpty) {
                sites = line.dropFirst("sites:".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                continue
            }
            bodyLines.append(raw)
        }
        guard let name, !name.isEmpty, !sites.isEmpty else { return nil }
        let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return Skill(id: slug(name), name: name, sites: sites, body: body, builtIn: builtIn, text: text)
    }
}

enum SkillSaved: Equatable {
    case saved
    case unreadable
    case failed
}

@MainActor
@Observable
final class SkillStore {
    static let shared = SkillStore(folder: Store.file("Skills"))

    let folder: URL
    private(set) var mine: [Skill] = []
    let builtIn: [Skill]

    init(folder: URL) {
        self.folder = folder
        builtIn = BuiltInSkills.texts.compactMap { Skill.parse($0, builtIn: true) }
        reload()
    }

    func reload() {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        mine = names.filter { $0.pathExtension.lowercased() == "md" }.compactMap { file -> Skill? in
            guard let text = try? String(contentsOf: file, encoding: .utf8), var skill = Skill.parse(text) else { return nil }
            skill.id = file.deletingPathExtension().lastPathComponent
            return skill
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    var all: [Skill] {
        let overridden = Set(mine.map(\.id))
        return mine + builtIn.filter { !overridden.contains($0.id) }
    }

    func skill(named name: String) -> Skill? {
        let wanted = Skill.slug(name)
        return all.first { $0.id == wanted }
    }

    func skills(for url: URL?) -> [Skill] {
        all.filter { $0.serves(url) }
    }

    func file(_ skill: Skill) -> URL { folder.appendingPathComponent(skill.id + ".md") }

    @discardableResult
    func save(_ text: String, replacing old: Skill? = nil) -> SkillSaved {
        guard let skill = Skill.parse(text) else { return .unreadable }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let old, !old.builtIn, old.id != skill.id { try? FileManager.default.removeItem(at: file(old)) }
            try text.write(to: file(skill), atomically: true, encoding: .utf8)
        } catch {
            return .failed
        }
        reload()
        return .saved
    }

    @discardableResult
    func duplicate(_ skill: Skill) -> Skill? {
        guard save(skill.text) == .saved else { return nil }
        return mine.first { $0.id == skill.id }
    }

    func delete(_ skill: Skill) {
        guard !skill.builtIn else { return }
        try? FileManager.default.removeItem(at: file(skill))
        reload()
    }

    func reveal(_ skill: Skill) {
        NSWorkspace.shared.activateFileViewerSelecting([file(skill)])
    }

    static let template = """
    # New skill
    sites: example.com

    What an agent should know about working on this site.
    """
}
