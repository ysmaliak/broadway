import Foundation

@MainActor
final class TaskLedger {
    struct Entry: Equatable {
        var title: String
    }

    static let shared = TaskLedger()
    private(set) var entries: [UUID: Entry] = [:]

    func open(_ task: UUID, title: String) {
        entries[task] = Entry(title: title)
    }

    func close(_ task: UUID) {
        entries[task] = nil
    }

    func entry(_ task: UUID?) -> Entry? {
        task.flatMap { entries[$0] }
    }
}

@MainActor
enum KnowledgeTools {
    static let specs: [ToolSpec] = [
        ToolSpec(name: "skills", description: "List what Broadway knows about working on sites. Give a url to list only that site's skills.",
                 properties: ["url": ["type": "string"]]),
        ToolSpec(name: "skill", description: "Read one site skill, by its name or by a page's url. Read it before working on a site it covers.",
                 properties: ["name": ["type": "string"], "url": ["type": "string"]]),
    ]

    static let offered = Set(specs.map(\.name))

    static func call(_ name: String, _ arguments: [String: Any]) -> ToolOutcome? {
        switch name {
        case "skills": return skills(arguments)
        case "skill": return skill(arguments)
        default: return nil
        }
    }

    private static func skills(_ arguments: [String: Any], store: SkillStore = .shared) -> ToolOutcome {
        store.reload()
        let url = (arguments["url"] as? String).flatMap(URL.init(string:))
        let listed = url == nil ? store.all : store.skills(for: url)
        return .json(["skills": listed.map { ["name": $0.name, "sites": $0.sites, "about": $0.summary, "yours": !$0.builtIn] as [String: Any] }])
    }

    private static func skill(_ arguments: [String: Any], store: SkillStore = .shared) -> ToolOutcome {
        store.reload()
        let url = (arguments["url"] as? String).flatMap(URL.init(string:))
        let named = (arguments["name"] as? String).flatMap(store.skill(named:))
        guard let found = named ?? store.skills(for: url).first else { return .failure("No skill for that. Call skills for the list.") }
        return .text(found.text)
    }
}

@MainActor
enum Knowledge {
    static func start(for browser: Browser) {
        NowBoard.add("watch") { _, now in ReplyWatches.shared.rows(at: now) }
        ReplyWatches.shared.begin(for: browser)
    }
}
