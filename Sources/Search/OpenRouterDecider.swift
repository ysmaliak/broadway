import Foundation

final class OpenRouterDecider: AIGroupDecider {
    struct Thresholds: Equatable, Sendable {
        var yes: Double
        var no: Double

        static let jev = Thresholds(yes: 0.6, no: 0.5)
        static let unmeasured = Thresholds(yes: 0.75, no: 0.5)

        static func standard(for model: String) -> Thresholds {
            let plain = model.hasPrefix("~") ? String(model.dropFirst()) : model
            return plain.hasPrefix("typesafe/jev") ? jev : unmeasured
        }
    }

    struct Seen: Encodable, Equatable {
        var title: String
        var site: String
        var by: String?

        init(_ tab: AIGroupTab) {
            title = tab.title
            site = tab.host
            let author = tab.by.trimmingCharacters(in: .whitespacesAndNewlines)
            by = author.isEmpty ? nil : String(author.prefix(60))
        }
    }

    struct Folder: Encodable, Equatable {
        var name: String
        var tabs: [Seen]
    }

    struct Instructions: Encodable, Equatable {
        var question: String
        var other: Seen?
        var folder: Folder?
    }

    struct Criteria: Encodable, Equatable {
        var yes: String
        var no: String

        enum CodingKeys: String, CodingKey {
            case yes = "true"
            case no = "false"
        }
    }

    struct Question: Encodable, Equatable {
        var type = "noul"
        var instructions: Instructions
        var criteria: Criteria
    }

    struct Body: Encodable, Equatable {
        var model: String
        var state: [String: Seen]
        var questions: [String: Question]
    }

    enum Candidate: Hashable {
        case group(UUID)
        case tab(UUID)
        case member(UUID, UUID)
    }

    struct Request {
        var tab: AIGroupTab
        var body: Body
        var asked: [String: Candidate]
        var named: [String: String]
    }

    struct Heard {
        var model: String
        var cost: Double?
        var yes: [String: Double]
        var refused: Set<String> = []
    }

    static let jev = "~typesafe/jev-latest"
    static let home = URL(string: "https://openrouter.ai/api")!
    static let longest = 30_000
    static let shown = [(6, 6), (3, 3), (1, 1), (1, 0)]

    static let tasks = "such as planning one trip, choosing one purchase, finding one flat, applying for one job, fixing one bug, following one story or learning one subject"
    static let sameTab = "Would a person with `tab` and `other` open be using them for one task, \(tasks)?"
    static let sameFolder = "Would a person with `tab` and the tabs in `folder` open be using them all for one task, \(tasks)?"
    static let sameCreator = "Are `tab` and `other` made by one creator the person follows, such as one YouTube channel, one podcast or one writer?"
    static let creator = Criteria(
        yes: "The same channel, podcast or writer made both",
        no: "Different creators, or one news outlet, shop, company or site publishing about different things"
    )
    static let criteria = Criteria(
        yes: "They all serve that one task",
        no: "They only share a website, a kind of page such as two videos or two articles, a broad field, or a word, or they serve different tasks"
    )

    let key: String
    let model: String
    let base: URL
    let session: URLSession
    let thresholds: Thresholds
    let local = false
    let batch = 8
    let seconds: Double = 12

    convenience init(key: String, model: String, base: URL = URL(string: "https://openrouter.ai/api")!, session: URLSession = .shared) {
        self.init(key: key, model: model, base: base, session: session, thresholds: Thresholds.standard(for: model))
    }

    init(key: String, model: String, base: URL, session: URLSession, thresholds: Thresholds) {
        self.key = key
        self.model = model
        self.base = base
        self.session = session
        self.thresholds = thresholds
    }

    var endpoint: URL { base.appending(path: "alpha/decisions") }

    func requests(_ ask: AIGroupAsk) -> [Request] {
        ask.fresh.compactMap { tab in
            for (index, most) in Self.shown.enumerated() {
                let made = request(for: tab, in: ask, showing: most.0, pairing: most.1)
                if index == Self.shown.count - 1 || ((try? Self.encoded(made.body).count) ?? 0) <= Self.longest { return made.asked.isEmpty ? nil : made }
            }
            return nil
        }
    }

    func request(for tab: AIGroupTab, in ask: AIGroupAsk, showing most: Int, pairing: Int) -> Request {
        var questions: [String: Question] = [:]
        var asked: [String: Candidate] = [:]
        var named: [String: String] = [:]
        for (index, group) in ask.groups.enumerated() where !group.refused.contains(tab.key) && !group.members.isEmpty {
            let id = "folder\(index + 1)"
            let folder = Folder(name: group.name, tabs: group.members.prefix(most).map(Seen.init))
            questions[id] = Question(instructions: Instructions(question: Self.sameFolder, folder: folder), criteria: Self.criteria)
            asked[id] = .group(group.id)
            named[id] = "folder " + group.name
            for (place, member) in group.members.prefix(pairing).enumerated() {
                let pair = id + "tab\(place + 1)"
                questions[pair] = Question(instructions: Instructions(question: Self.sameTab, other: Seen(member)), criteria: Self.criteria)
                asked[pair] = .member(group.id, member.id)
                named[pair] = group.name + ": " + member.title
                guard Self.creators(tab, member) else { continue }
                questions[pair + "by"] = Question(instructions: Instructions(question: Self.sameCreator, other: Seen(member)), criteria: Self.creator)
                asked[pair + "by"] = .member(group.id, member.id)
                named[pair + "by"] = group.name + ": by " + member.by
            }
        }
        for (index, other) in (ask.loose + ask.fresh).enumerated() where other.id != tab.id {
            let id = "tab\(index + 1)"
            questions[id] = Question(instructions: Instructions(question: Self.sameTab, other: Seen(other)), criteria: Self.criteria)
            asked[id] = .tab(other.id)
            named[id] = other.title
            guard Self.creators(tab, other) else { continue }
            questions[id + "by"] = Question(instructions: Instructions(question: Self.sameCreator, other: Seen(other)), criteria: Self.creator)
            asked[id + "by"] = .tab(other.id)
            named[id + "by"] = "by " + other.by
        }
        return Request(tab: tab, body: Body(model: model, state: ["tab": Seen(tab)], questions: questions), asked: asked, named: named)
    }

    static func creators(_ one: AIGroupTab, _ two: AIGroupTab) -> Bool {
        Seen(one).by != nil && Seen(two).by != nil
    }

    static func encoded(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        func text(_ value: String) throws -> Data { try encoder.encode(value) }
        func object(_ fields: [(String, Data?)]) throws -> Data {
            var out = Data("{".utf8)
            for (index, field) in fields.compactMap({ name, value in value.map { (name, $0) } }).enumerated() {
                if index > 0 { out += Data(",".utf8) }
                out += try text(field.0) + Data(":".utf8) + field.1
            }
            return out + Data("}".utf8)
        }
        func seen(_ tab: Seen) throws -> Data {
            try object([("title", text(tab.title)), ("site", text(tab.site)), ("by", tab.by.map(text))])
        }
        func question(_ asked: Question) throws -> Data {
            let folder = try asked.instructions.folder.map { folder in
                try object([("name", text(folder.name)), ("tabs", Data("[".utf8) + Data(folder.tabs.map(seen).joined(separator: Data(",".utf8))) + Data("]".utf8))])
            }
            let instructions = try object([("question", text(asked.instructions.question)), ("other", asked.instructions.other.map(seen)), ("folder", folder)])
            return try object([("type", text(asked.type)), ("instructions", instructions),
                               ("criteria", object([("true", text(asked.criteria.yes)), ("false", text(asked.criteria.no))]))])
        }
        func ordered(_ ids: some Collection<String>) -> [String] {
            ids.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        }
        return try object([("model", text(body.model)),
                           ("state", object(ordered(body.state.keys).map { ($0, try seen(body.state[$0]!)) })),
                           ("questions", object(ordered(body.questions.keys).map { ($0, try question(body.questions[$0]!)) }))])
    }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        let made = requests(ask)
        guard !made.isEmpty else { return Self.picks(ask, heard: [:], thresholds: thresholds) }
        try allowed()
        var heard = try await hear(made)
        heard.merge(try await hear(confirmations(ask, heard: heard))) { one, _ in one }
        return Self.picks(ask, heard: heard, thresholds: thresholds)
    }

    func fits(_ tab: AIGroupTab, in group: AIGroupInfo) async throws -> AIGroupFit {
        var folder = group
        folder.refused = []
        guard let made = requests(AIGroupAsk(groups: [folder], loose: [], fresh: [tab])).first else { return .unsure }
        try allowed()
        let said = try await send(made.body)
        note(made, said)
        var heard: [Candidate: Double] = [:]
        for (id, candidate) in made.asked where !said.refused.contains(id) {
            heard[candidate] = max(heard[candidate] ?? 0, said.yes[id] ?? 0)
        }
        guard let own = heard[.group(group.id)], let chance = Self.chance([tab.id: heard], tab.id, .group(group.id), thresholds: thresholds) else {
            AIGroupTrace.note("fits", ["tab": tab.title, "folder": group.name, "fit": AIGroupFit.unsure.rawValue, "why": "no answer about the folder"])
            return .unsure
        }
        let closest = heard.compactMap { candidate, said -> Double? in
            if case .member = candidate { return said }
            return nil
        }.max()
        let fit: AIGroupFit
        if chance >= thresholds.yes {
            fit = .yes
        } else if let closest, own < thresholds.no, closest < thresholds.no {
            fit = .no
        } else {
            fit = .unsure
        }
        var fields: [String: Any] = ["tab": tab.title, "folder": group.name, "chance": chance, "said": own, "fit": fit.rawValue]
        if let closest { fields["closest"] = closest } else { fields["why"] = "no answer about its tabs" }
        AIGroupTrace.note("fits", fields)
        return fit
    }

    func confirmations(_ ask: AIGroupAsk, heard: [UUID: [Candidate: Double]]) -> [Request] {
        ask.loose.compactMap { loose in
            let raters = ask.fresh.filter { (heard[$0.id]?[.tab(loose.id)] ?? 0) >= thresholds.yes }
            guard !raters.isEmpty else { return nil }
            let made = request(for: loose, in: AIGroupAsk(groups: [], loose: [], fresh: raters + [loose]), showing: 0, pairing: 0)
            return made.asked.isEmpty ? nil : made
        }
    }

    func hear(_ made: [Request]) async throws -> [UUID: [Candidate: Double]] {
        guard !made.isEmpty else { return [:] }
        return try await withThrowingTaskGroup(of: (UUID, [Candidate: Double]).self) { group in
            for request in made {
                group.addTask {
                    let said = try await self.send(request.body)
                    var out: [Candidate: Double] = [:]
                    for (id, candidate) in request.asked { out[candidate] = max(out[candidate] ?? 0, said.yes[id] ?? 0) }
                    self.note(request, said)
                    return (request.tab.id, out)
                }
            }
            var all: [UUID: [Candidate: Double]] = [:]
            for try await (id, out) in group { all[id] = out }
            return all
        }
    }

    static func chance(_ heard: [UUID: [Candidate: Double]], _ tab: UUID, _ candidate: Candidate, thresholds: Thresholds) -> Double? {
        guard let said = heard[tab]?[candidate] else { return nil }
        if case .tab(let other) = candidate, let back = heard[other]?[.tab(tab)] {
            return min(said, back)
        }
        if case .group(let group) = candidate {
            let members = heard[tab]?.compactMap { asked, chance -> Double? in
                if case .member(group, _) = asked { return chance }
                return nil
            } ?? []
            let sorted = members.sorted(by: >)
            if let closest = sorted.first {
                if closest < thresholds.yes { return min(said, closest) }
                return max(said, sorted.count >= 2 ? sorted[1] : closest)
            }
        }
        return said
    }

    static func picks(_ ask: AIGroupAsk, heard: [UUID: [Candidate: Double]], thresholds: Thresholds) -> [UUID: AIGroupPick] {
        func chance(_ tab: UUID, _ candidate: Candidate) -> Double? {
            Self.chance(heard, tab, candidate, thresholds: thresholds)
        }
        var picks: [UUID: AIGroupPick] = [:]
        var strength: [UUID: Double] = [:]
        for tab in ask.fresh {
            picks[tab.id] = AIGroupPick.none
            var best: (candidate: Candidate, chance: Double)?
            for group in ask.groups {
                guard let said = chance(tab.id, .group(group.id)), said >= thresholds.yes, said > (best?.chance ?? -1) else { continue }
                best = (.group(group.id), said)
            }
            let housed = best != nil
            for other in ask.loose + ask.fresh where other.id != tab.id && !housed {
                guard let said = chance(tab.id, .tab(other.id)), said >= thresholds.yes, said > (best?.chance ?? -1) else { continue }
                best = (.tab(other.id), said)
            }
            guard let best else { continue }
            switch best.candidate {
            case .group(let id): picks[tab.id] = .group(id)
            case .tab(let id): picks[tab.id] = .tab(id)
            case .member: continue
            }
            strength[tab.id] = best.chance
        }
        while let weakest = conflict(ask, picks: picks, strength: strength, chance: chance, no: thresholds.no) {
            picks[weakest] = AIGroupPick.none
            strength[weakest] = nil
        }
        return merged(ask, picks: picks, chance: chance, yes: thresholds.yes)
    }

    static func merged(_ ask: AIGroupAsk, picks: [UUID: AIGroupPick], chance: (UUID, Candidate) -> Double?, yes: Double) -> [UUID: AIGroupPick] {
        var picks = picks
        let fresh = ask.fresh.map(\.id)
        func free() -> [[UUID]] {
            var parent = Dictionary(uniqueKeysWithValues: fresh.map { ($0, $0) })
            func root(_ id: UUID) -> UUID {
                var at = id
                while let up = parent[at], up != at { at = up }
                return at
            }
            var settled: Set<UUID> = []
            for id in fresh {
                guard case .tab(let other) = picks[id] ?? AIGroupPick.none, parent[other] != nil else { settled.insert(id); continue }
                let a = root(id), b = root(other)
                if a != b { parent[b] = a }
            }
            var clusters: [UUID: [UUID]] = [:]
            var order: [UUID] = []
            for id in fresh {
                let top = root(id)
                if clusters[top] == nil { order.append(top) }
                clusters[top, default: []].append(id)
            }
            return order.compactMap { clusters[$0] }.filter { $0.count >= 2 && settled.isDisjoint(with: $0) }
        }
        func agree(_ one: [UUID], _ two: [UUID]) -> Bool {
            one.allSatisfy { a in two.allSatisfy { b in (chance(a, .tab(b)) ?? 0) >= yes } }
        }
        func star(_ members: [UUID]) {
            guard let anchor = members.first, let partner = members.dropFirst().first else { return }
            for id in members.dropFirst() { picks[id] = .tab(anchor) }
            picks[anchor] = .tab(partner)
        }
        var joining = true
        while joining {
            joining = false
            let clusters = free()
            search: for (index, one) in clusters.enumerated() {
                for two in clusters.dropFirst(index + 1) where agree(one, two) {
                    star(one + two)
                    joining = true
                    break search
                }
            }
        }
        for cluster in free() {
            let fits = ask.groups.compactMap { group -> (UUID, Double)? in
                let least = cluster.map { chance($0, .group(group.id)) ?? 0 }.min() ?? 0
                return least >= yes ? (group.id, least) : nil
            }
            guard let best = fits.max(by: { $0.1 < $1.1 }) else { continue }
            for id in cluster { picks[id] = .group(best.0) }
        }
        return picks
    }

    static func conflict(_ ask: AIGroupAsk, picks: [UUID: AIGroupPick], strength: [UUID: Double],
                         chance: (UUID, Candidate) -> Double?, no: Double) -> UUID? {
        var parent: [UUID: UUID] = [:]
        func root(_ id: UUID) -> UUID {
            var at = id
            while let up = parent[at], up != at { at = up }
            return at
        }
        for tab in ask.fresh { parent[tab.id] = tab.id }
        for tab in ask.fresh {
            guard case .tab(let other) = picks[tab.id] ?? AIGroupPick.none else { continue }
            if parent[other] == nil { parent[other] = other }
            let a = root(tab.id), b = root(other)
            if a != b { parent[b] = a }
        }
        let fresh = ask.fresh.map(\.id)
        var clusters: [UUID: [UUID]] = [:]
        for id in fresh { clusters[root(id), default: []].append(id) }
        for id in fresh.map(root).reduce(into: [UUID](), { if !$0.contains($1) { $0.append($1) } }) {
            let members = clusters[id] ?? []
            var clashing: [UUID] = []
            for (index, one) in members.enumerated() {
                for two in members.dropFirst(index + 1) {
                    if let said = chance(one, .tab(two)), said < no { clashing += [one, two] }
                }
            }
            let target = members.lazy.compactMap { member -> UUID? in
                if case .group(let group) = picks[member] ?? AIGroupPick.none { return group }
                return nil
            }.first
            if let target {
                for member in members {
                    if case .group = picks[member] ?? AIGroupPick.none { continue }
                    if let said = chance(member, .group(target)), said < no { clashing.append(member) }
                }
            }
            guard !clashing.isEmpty else { continue }
            let picked = members.filter { strength[$0] != nil }
            if let weakest = picked.min(by: { (strength[$0] ?? 0, $0.uuidString) < (strength[$1] ?? 0, $1.uuidString) }) {
                return weakest
            }
        }
        return nil
    }

    private func allowed() throws {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.refused("There's no OpenRouter key")
        }
        if CLIGuard.underTest, !CLIGuard.realAllowed, base.host() == Self.home.host() {
            throw ProviderError.refused("A test run never calls a real model")
        }
    }

    func send(_ body: Body) async throws -> Heard {
        var request = URLRequest(url: endpoint, timeoutInterval: seconds)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encoded(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.reason(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw reason(status: status) }
        guard let heard = Self.read(data, asked: Set(body.questions.keys)) else {
            throw ProviderError.failed("The answer from \(model) couldn't be read")
        }
        return heard
    }

    static func read(_ data: Data, asked: Set<String>) -> Heard? {
        guard let found = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let answers = found["answers"] as? [String: Any] else { return nil }
        var yes: [String: Double] = [:]
        var refused: Set<String> = []
        for id in asked {
            guard let answer = answers[id] as? [String: Any], let type = answer["type"] as? String else { return nil }
            switch type {
            case "noul":
                guard let said = answer["noul"] as? NSNumber, CFGetTypeID(said) != CFBooleanGetTypeID(),
                      (0...1).contains(said.doubleValue) else { return nil }
                yes[id] = said.doubleValue
            case "refusal":
                yes[id] = 0
                refused.insert(id)
            default:
                return nil
            }
        }
        let usage = found["usage"] as? [String: Any]
        return Heard(model: found["model"] as? String ?? "", cost: (usage?["cost"] as? NSNumber)?.doubleValue, yes: yes, refused: refused)
    }

    static func reason(_ error: Error) -> ProviderError {
        if error is CancellationError { return .cancelled }
        guard let failure = error as? URLError else { return .failed("Can't reach OpenRouter") }
        switch failure.code {
        case .cancelled: return .cancelled
        case .timedOut: return .failed("OpenRouter took too long")
        default: return .failed("Can't reach OpenRouter")
        }
    }

    func reason(status: Int) -> ProviderError {
        switch status {
        case 401: return .refused("OpenRouter didn't accept the key")
        case 402: return .planOut("The OpenRouter account is out of credits")
        case 403: return .refused("OpenRouter didn't allow the key to ask")
        case 404: return .failed("OpenRouter has no model called \(model)")
        case 408, 524: return .failed("OpenRouter took too long")
        case 429: return .planOut("OpenRouter is holding back requests for now")
        case 400, 413, 422: return .failed("\(model) didn't take the question")
        case 500...599: return .failed("OpenRouter couldn't answer just now")
        default: return .failed("OpenRouter answered with error \(status)")
        }
    }

    private func note(_ request: Request, _ heard: Heard) {
        var fields: [String: Any] = ["tab": request.tab.title, "model": heard.model, "asked": request.asked.count,
                                     "yes": heard.yes.sorted { $0.key < $1.key }.map { "\(String(format: "%.2f", $0.value)) \(request.named[$0.key] ?? $0.key)" }]
        if let cost = heard.cost { fields["cost"] = cost }
        AIGroupTrace.note("decisions", fields)
    }
}

struct OpenRouterBench: AIGroupDecider, AIGroupNamer {
    let decider: OpenRouterDecider
    let namer: any AIGroupNamer

    var batch: Int { decider.batch }

    init?(_ request: [String: Any]) {
        guard let key = request["key"] as? String, !key.isEmpty else { return nil }
        let model = request["model"] as? String ?? OpenRouterDecider.jev
        var thresholds = OpenRouterDecider.Thresholds.standard(for: model)
        if let yes = request["yes"] as? Double { thresholds.yes = yes }
        if let no = request["no"] as? Double { thresholds.no = no }
        let base = (request["base"] as? String).flatMap(URL.init(string:)) ?? OpenRouterDecider.home
        decider = OpenRouterDecider(key: key, model: model, base: base, session: .shared, thresholds: thresholds)
        let mac = request["namer"] as? String != "fake" && MacGroupEngine.available
        namer = mac ? MacGroupEngine() : FakeGroupEngine()
    }

    var said: [String: Any] {
        ["engine": "openrouter", "model": decider.model, "yes": decider.thresholds.yes, "no": decider.thresholds.no,
         "namer": namer is MacGroupEngine ? "thisMac" : "fake"]
    }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        try await decider.decide(ask)
    }

    func fits(_ tab: AIGroupTab, in group: AIGroupInfo) async throws -> AIGroupFit {
        try await decider.fits(tab, in: group)
    }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        try await namer.name(ask)
    }
}