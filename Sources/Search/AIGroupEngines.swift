import Foundation
import FoundationModels

protocol AIGroupEngine: Sendable {
    var local: Bool { get }
}

protocol AIGroupDecider: AIGroupEngine {
    var batch: Int { get }
    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick]
}

protocol AIGroupNamer: AIGroupEngine {
    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName
}

extension AIGroupEngine {
    var local: Bool { false }
}

extension AIGroupDecider {
    var batch: Int { 8 }
}

enum AIGroupEngineKind: String, CaseIterable, Identifiable, Sendable {
    case auto, thisMac, claude, chatGPT, openRouter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .thisMac: return "This Mac"
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .openRouter: return "OpenRouter"
        }
    }

    var plan: Plan? {
        switch self {
        case .thisMac: return .thisMac
        case .claude: return .claude
        case .chatGPT: return .chatGPT
        case .auto, .openRouter: return nil
        }
    }
}

@Generable
struct MacGroupName {
    @Guide(description: "What every one of these tabs is about, in a short phrase")
    var shared: String
    @Guide(description: "True when the folder's current name still says what these tabs share, false when there is none or it has clearly stopped fitting")
    var keep: Bool
    @Guide(description: "The folder name for that subject: one to three words in the tabs' language, never a page title, the search, a site's name alone, a year or words like watch online or free")
    var name: String
    @Guide(description: "One emoji that fits")
    var emoji: String
}

final class MacGroupEngine: AIGroupDecider, AIGroupNamer {
    static var available: Bool {
        SystemLanguageModel.default.isAvailable
    }

    let local = true
    let batch = 4

    static let judging = """
    You decide whether two browser tabs belong in one folder. They belong together only when both are about the same \
    specific thing: the same product, project, piece of work, show, film, person, channel, trip, company, event or errand. \
    Sharing a website, a kind of page (two videos, two articles, two documentation pages) or a word used with different \
    meanings is not enough.
    """

    static let together = ["the same specific thing", "the same errand or task"]

    static let verdict: [[String: Any]] = [
        ["name": "first", "description": "What tab 1 is about, in a few words"],
        ["name": "second", "description": "What tab 2 is about, in a few words"],
        ["name": "link", "description": "What the two tabs have in common",
         "options": together + ["only the website", "only the kind of page", "nothing"]],
        ["name": "thing", "description": "The specific thing or errand both are about, in one to three words, or none"],
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var judged: [String: Bool] = [:]

    static let joining = """
    You decide whether a new browser tab belongs in an existing folder of tabs. It belongs only when it is about the same \
    specific thing as the folder's tabs: the same product, project, piece of work, show, film, person, channel, trip, company, \
    event or errand. Sharing a website, a kind of page (two videos, two articles, two documentation pages) or a word used \
    with different meanings is not enough.
    """

    static let fit: [[String: Any]] = [
        ["name": "folder", "description": "What the folder's tabs are about, in a few words"],
        ["name": "tab", "description": "What the new tab is about, in a few words"],
        ["name": "link", "description": "What the new tab has in common with the folder",
         "options": together + ["only the website", "only the kind of page", "nothing"]],
    ]

    static func belongs(_ group: AIGroupInfo, _ tab: AIGroupTab) async throws -> Bool {
        let question = "Folder \"\(group.name)\":\n" + group.members.prefix(6).map { "- \($0.localLine)" }.joined(separator: "\n")
            + "\nNew tab: \(tab.localLine)"
        if let known = lock.withLock({ judged[question] }) { return known }
        var said: [String: Any] = [:]
        do {
            said = try await probe(instructions: joining, prompt: question, fields: fit, most: 200)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            said = ["link": "no answer: \(error.localizedDescription)"]
        }
        let yes = together.contains(said["link"] as? String ?? "")
        AIGroupTrace.note("belongs", ["folder": group.name, "tab": tab.title, "link": said["link"] as? String ?? "", "together": yes])
        lock.withLock { judged[question] = yes }
        return yes
    }

    static func forget() {
        lock.withLock { judged = [:] }
        AIGroupSubjects.forget()
    }

    static func judge(_ one: AIGroupTab, _ two: AIGroupTab) async throws -> Bool {
        let question = "Tab 1: \(one.localLine)\nTab 2: \(two.localLine)"
        if let known = lock.withLock({ judged[question] }) { return known }
        var said: [String: Any] = [:]
        do {
            said = try await probe(instructions: judging, prompt: question, fields: verdict, most: 200)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            said = ["link": "no answer: \(error.localizedDescription)"]
        }
        let yes = together.contains(said["link"] as? String ?? "")
        AIGroupTrace.note("judge", ["one": one.title, "two": two.title, "link": said["link"] as? String ?? "",
                                    "thing": said["thing"] as? String ?? "", "together": yes])
        lock.withLock {
            if judged.count > 2000 { judged = [:] }
            judged[question] = yes
        }
        return yes
    }

    private func allowed() throws {
        guard !CLIGuard.underTest || CLIGuard.realAllowed else {
            throw ProviderError.refused("A test run never calls a real model")
        }
        guard Self.available else { throw ProviderError.notInstalled(.thisMac) }
    }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        try allowed()
        return try await AIGroupSorter(judge: Self.judge, belongs: Self.belongs, subject: Self.subject, meant: Self.meant,
                                       recalled: { AIGroupSubjects.known($0) }).decide(ask)
    }

    static func probe(instructions: String, prompt: String, fields: [[String: Any]], most: Int = 200) async throws -> [String: Any] {
        let properties = fields.map { field -> DynamicGenerationSchema.Property in
            let name = field["name"] as? String ?? "answer"
            let schema: DynamicGenerationSchema
            if let options = field["options"] as? [String] {
                schema = DynamicGenerationSchema(name: "choice_\(name)", anyOf: options)
            } else if field["type"] as? String == "bool" {
                schema = DynamicGenerationSchema(type: Bool.self)
            } else {
                schema = DynamicGenerationSchema(type: String.self)
            }
            return DynamicGenerationSchema.Property(name: name, description: field["description"] as? String, schema: schema)
        }
        let schema = try GenerationSchema(root: DynamicGenerationSchema(name: "Answer", properties: properties), dependencies: [])
        let session = LanguageModelSession(instructions: instructions)
        let answer = try await session.respond(to: prompt, schema: schema,
                                               options: GenerationOptions(temperature: 0, maximumResponseTokens: most))
        var said: [String: Any] = [:]
        for field in fields {
            guard let name = field["name"] as? String else { continue }
            if field["type"] as? String == "bool", field["options"] == nil {
                said[name] = (try? answer.content.value(Bool.self, forProperty: name)) ?? false
            } else {
                said[name] = (try? answer.content.value(String.self, forProperty: name)) ?? ""
            }
        }
        return said
    }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        try allowed()
        let session = LanguageModelSession(instructions: AIGroupPrompt.naming(emoji: ask.emoji))
        let answer = try await session.respond(to: AIGroupPrompt.naming(ask), generating: MacGroupName.self,
                                               options: GenerationOptions(temperature: 0, maximumResponseTokens: 120))
        let said = answer.content
        guard let name = AIGroupName.cleaned(name: said.name, emoji: ask.emoji ? said.emoji : nil, keep: said.keep && ask.current != nil) else {
            throw ProviderError.failed("No name came back")
        }
        return name
    }
}

final class PlanGroupEngine: AIGroupDecider, AIGroupNamer {
    let provider: Provider
    let model: String
    let effort: Effort?

    init(provider: Provider, model: String, effort: Effort?) {
        self.provider = provider
        self.model = model
        self.effort = effort
    }

    @MainActor
    static func smallest(_ plan: Plan, plans given: Plans? = nil) -> PlanGroupEngine? {
        let plans = given ?? .shared
        guard plan != .thisMac, plans.connected(plan) else { return nil }
        let models = plans.models(plan)
        let model: PlanModel?
        switch plan {
        case .claude:
            model = models.first { $0.id == "haiku" } ?? models.last
        default:
            model = models.first { $0.id.contains("nano") } ?? models.first { $0.id.contains("mini") } ?? models.first
        }
        guard let model else { return nil }
        let effort = model.efforts.contains(.low) ? Effort.low : model.efforts.first
        return PlanGroupEngine(provider: plans.provider(plan), model: model.id, effort: effort)
    }

    private func ask(system: String, prompt: String) async throws -> String {
        let session = provider.start(ProviderRequest(system: system, prompt: prompt, model: model.isEmpty ? nil : model, effort: effort))
        var said = ""
        do {
            for try await event in session.events {
                if case .text(let text) = event { said += text }
            }
        } catch {
            session.cancel()
            throw error
        }
        return said
    }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        let said = try await self.ask(system: AIGroupPrompt.deciding, prompt: AIGroupPrompt.jsonDeciding(ask))
        guard let picks = AIGroupPrompt.picks(json: said, labels: AIGroupPrompt.labels(ask)) else {
            throw ProviderError.failed("The plan didn't say where the tabs go")
        }
        return picks
    }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        let said = try await self.ask(system: AIGroupPrompt.naming(emoji: ask.emoji), prompt: AIGroupPrompt.jsonNaming(ask))
        guard var name = AIGroupPrompt.name(json: said) else { throw ProviderError.failed("The plan didn't name the group") }
        if !ask.emoji { name.emoji = nil }
        return name
    }
}

final class FakeGroupEngine: AIGroupDecider, AIGroupNamer, @unchecked Sendable {
    var local = false
    private let lock = NSLock()
    private var decided: [AIGroupAsk] = []
    private var named: [AIGroupNameAsk] = []
    var delay: Double = 0
    var failing = false

    var asks: [AIGroupAsk] { lock.withLock { decided } }
    var nameAsks: [AIGroupNameAsk] { lock.withLock { named } }

    static func topic(_ title: String) -> String {
        title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first.map { $0.lowercased() } ?? ""
    }

    static let marks = ["lisbon": "✈️", "swift": "🧑‍💻", "recipes": "🍳", "pasta": "🍝", "trip": "🧳", "porto": "🚆"]

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        lock.withLock { decided.append(ask) }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if failing { throw ProviderError.failed("The fake engine failed") }
        var out: [UUID: AIGroupPick] = [:]
        for tab in ask.fresh {
            let topic = Self.topic(tab.title)
            if let group = ask.groups.first(where: { $0.members.contains { Self.topic($0.title) == topic } }) {
                out[tab.id] = .group(group.id)
            } else if let other = (ask.loose + ask.fresh).first(where: { $0.id != tab.id && Self.topic($0.title) == topic }) {
                out[tab.id] = .tab(other.id)
            } else {
                out[tab.id] = AIGroupPick.none
            }
        }
        return out
    }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        lock.withLock { named.append(ask) }
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        if failing { throw ProviderError.failed("The fake engine failed") }
        let topics = ask.tabs.map { Self.topic($0.title) }
        let counted = Dictionary(topics.map { ($0, 1) }, uniquingKeysWith: +)
        let top = counted.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? "tabs"
        let word = top.prefix(1).uppercased() + top.dropFirst()
        let name = counted.count > 1 ? "\(word) and more" : word
        if name == ask.current { return AIGroupName(name: name, emoji: ask.currentEmoji, keep: true) }
        return AIGroupName(name: name, emoji: ask.emoji ? (Self.marks[top] ?? "🗂️") : nil)
    }
}
