import Foundation
import Observation
import Security
import os

private let log = Logger(subsystem: "com.ysmaliak.broadway", category: "OpenRouter")

enum OpenRouterModels {
    static let grouping = "~typesafe/jev-latest"
    static let naming = "~deepseek/deepseek-flash-latest"
    static let namingEffort = "none"
}

enum OpenRouterTrouble: Error, LocalizedError, Equatable {
    case refused, noCredit, busy, gone, down, unreachable, nonsense, testRun

    var errorDescription: String? { words }

    var words: String {
        switch self {
        case .refused: return "OpenRouter turned this key down"
        case .noCredit: return "Your OpenRouter account is out of credit"
        case .busy: return "OpenRouter asked Broadway to slow down"
        case .gone: return "OpenRouter no longer has the model Broadway uses"
        case .down: return "OpenRouter couldn't answer just now"
        case .unreachable: return "Broadway couldn't reach OpenRouter"
        case .nonsense: return "OpenRouter's answer made no sense"
        case .testRun: return "A test run never calls OpenRouter"
        }
    }

    static func of(status: Int) -> OpenRouterTrouble? {
        switch status {
        case 200..<300: return nil
        case 401, 403: return .refused
        case 402: return .noCredit
        case 404: return .gone
        case 429: return .busy
        case 408, 500...599: return .down
        default: return .nonsense
        }
    }

    static func from(_ error: Error) -> OpenRouterTrouble {
        if let known = error as? OpenRouterTrouble { return known }
        if let failure = error as? ProviderError {
            switch failure {
            case .refused(let said): return said.contains("test run") ? .testRun : .refused
            case .planOut(let said): return said.contains("credit") ? .noCredit : .busy
            case .failed(let said): return said.contains("couldn't be read") ? .nonsense : .unreachable
            default: return .unreachable
            }
        }
        if error is URLError { return .unreachable }
        return .nonsense
    }
}

struct OpenRouterClient: Sendable {
    static let api = URL(string: "https://openrouter.ai/api")!
    static let real = api.appending(path: "v1")

    var base: URL
    var session: URLSession
    var seconds: Double

    init(base: URL? = nil, session: URLSession = .shared, seconds: Double = 12) {
        self.base = base ?? Self.injected ?? Self.real
        self.session = session
        self.seconds = seconds
    }

    static var injected: URL? {
        guard Store.testing || Store.unitTests, let said = ProcessInfo.processInfo.environment["SEARCH_OPENROUTER_BASE"],
              !said.isEmpty else { return nil }
        return URL(string: said)
    }

    var allowed: Bool { Self.allowed(base) }

    static func allowed(_ base: URL) -> Bool {
        guard CLIGuard.underTest, !CLIGuard.realAllowed else { return true }
        return base.host() != real.host()
    }

    static func request(_ url: URL, key: String, seconds: Double) -> URLRequest {
        var made = URLRequest(url: url, timeoutInterval: seconds)
        made.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        return made
    }

    private func request(_ path: String, key: String) throws -> URLRequest {
        guard allowed else { throw OpenRouterTrouble.testRun }
        var made = Self.request(base.appending(path: path), key: key, seconds: seconds)
        made.setValue("https://broadwaybrowser.com", forHTTPHeaderField: "HTTP-Referer")
        made.setValue("Broadway", forHTTPHeaderField: "X-Title")
        return made
    }

    private func send(_ made: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: made)
        } catch {
            throw OpenRouterTrouble.from(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let trouble = OpenRouterTrouble.of(status: status) { throw trouble }
        return data
    }

    func check(key: String) async throws {
        let data = try await send(try request("key", key: key))
        guard let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any], found["data"] is [String: Any] else {
            throw OpenRouterTrouble.nonsense
        }
    }

    struct Answer: Sendable {
        var text: String
        var cost: Double
    }

    static func body(model: String, system: String, prompt: String, effort: String) -> [String: Any] {
        ["model": model,
         "messages": [["role": "system", "content": system], ["role": "user", "content": prompt]],
         "max_tokens": 1200,
         "reasoning": ["effort": effort, "exclude": true],
         "response_format": ["type": "json_object"],
         "usage": ["include": true]]
    }

    func chat(key: String, model: String, system: String, prompt: String, effort: String = OpenRouterModels.namingEffort) async throws -> Answer {
        var made = try request("chat/completions", key: key)
        made.httpMethod = "POST"
        made.setValue("application/json", forHTTPHeaderField: "Content-Type")
        made.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: model, system: system, prompt: prompt, effort: effort))
        let data = try await send(made)
        guard let found = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OpenRouterTrouble.nonsense }
        if found["error"] != nil { throw OpenRouterTrouble.nonsense }
        let choices = found["choices"] as? [[String: Any]] ?? []
        let message = choices.first?["message"] as? [String: Any]
        guard let text = message?["content"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OpenRouterTrouble.nonsense
        }
        let cost = ((found["usage"] as? [String: Any])?["cost"] as? NSNumber)?.doubleValue ?? 0
        return Answer(text: text, cost: cost)
    }
}

protocol OpenRouterKeyStore: AnyObject {
    func read() -> String?
    func write(_ key: String) -> Bool
    func erase()
}

final class OpenRouterMemoryStore: OpenRouterKeyStore {
    private var held: String?
    init(_ key: String? = nil) { held = key }
    func read() -> String? { held }
    func write(_ key: String) -> Bool { held = key; return true }
    func erase() { held = nil }
}

final class OpenRouterKeychain: OpenRouterKeyStore {
    static let service = "Broadway OpenRouter key"

    private var account: String { Store.world.map { "openrouter (\($0))" } ?? "openrouter" }

    private var slot: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: account]
    }

    func read() -> String? {
        let (data, status) = quietly { Keychain.read(slot) }
        guard let data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            if status != errSecSuccess, status != errSecItemNotFound { log.notice("keychain read failed (\(status))") }
            return nil
        }
        return key
    }

    func write(_ key: String) -> Bool {
        let data = Data(key.utf8)
        var item = slot
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = Self.service
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = Keychain.write(slot, [kSecValueData as String: data], orAdd: item, quietly: { quietly($0) }).status
        if status != errSecSuccess { log.notice("keychain write failed (\(status))") }
        return status == errSecSuccess
    }

    func erase() {
        _ = quietly { Keychain.delete(slot) }
    }

    private func quietly<T>(_ body: () -> T) -> T {
        var allowed = DarwinBoolean(true)
        SecKeychainGetUserInteractionAllowed(&allowed)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(allowed.boolValue) }
        return body()
    }
}

@MainActor
@Observable
final class OpenRouterKey {
    static let shared = OpenRouterKey()

    enum State: Equatable {
        case none, checking, saved
    }

    private(set) var state: State = .none
    private(set) var trouble: String?
    @ObservationIgnored private var cached: String?
    @ObservationIgnored var store: OpenRouterKeyStore
    @ObservationIgnored var client: () -> OpenRouterClient = { OpenRouterClient() }

    init(store: OpenRouterKeyStore? = nil) {
        self.store = store ?? (Store.testing || Store.unitTests ? OpenRouterMemoryStore() : OpenRouterKeychain())
        cached = self.store.read()
        state = cached == nil ? .none : .saved
    }

    var key: String? { cached }
    var present: Bool { cached != nil }

    static func plain(_ typed: String) -> String {
        typed.filter { !$0.isWhitespace && !$0.isNewline }
    }

    @discardableResult
    func save(_ typed: String) async -> Bool {
        let key = Self.plain(typed)
        guard !key.isEmpty, state != .checking else { return false }
        let before = state
        state = .checking
        trouble = nil
        do {
            try await client().check(key: key)
        } catch {
            state = before
            trouble = OpenRouterTrouble.from(error).words
            return false
        }
        guard store.write(key) else {
            state = before
            trouble = "Broadway couldn't keep the key in this Mac's Keychain"
            return false
        }
        cached = key
        state = .saved
        return true
    }

    func remove() {
        store.erase()
        cached = nil
        state = .none
        trouble = nil
    }

    func use(_ key: String?, store replacing: OpenRouterKeyStore? = nil) {
        if let replacing { store = replacing }
        cached = key.map(Self.plain).flatMap { $0.isEmpty ? nil : $0 }
        state = cached == nil ? .none : .saved
        trouble = nil
    }

    func note(_ trouble: OpenRouterTrouble?) {
        if let trouble { failed(trouble) } else { worked() }
    }

    func failed(_ trouble: OpenRouterTrouble) {
        guard present, self.trouble != trouble.words else { return }
        self.trouble = trouble.words
    }

    func worked() {
        guard trouble != nil, state == .saved else { return }
        trouble = nil
    }

    func forgetTrouble() {
        trouble = nil
    }
}

final class OpenRouterNamer: AIGroupNamer, @unchecked Sendable {
    let key: String
    let model: String
    let effort: String
    let client: OpenRouterClient
    let report: @Sendable (OpenRouterTrouble?) async -> Void
    private let lock = NSLock()
    private var cost: Double = 0
    private var sent: [String] = []

    init(key: String, model: String = OpenRouterModels.naming, effort: String = OpenRouterModels.namingEffort,
         client: OpenRouterClient = OpenRouterClient(),
         report: @escaping @Sendable (OpenRouterTrouble?) async -> Void = { await OpenRouterKey.shared.note($0) }) {
        self.report = report
        self.key = key
        self.model = model
        self.effort = effort
        self.client = client
    }

    var spent: Double { lock.withLock { cost } }
    var prompts: [String] { lock.withLock { sent } }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        let shown = ask.bare
        let prompt = AIGroupPrompt.remoteNaming(shown)
        lock.withLock { sent.append(prompt) }
        let answer: OpenRouterClient.Answer
        do {
            answer = try await client.chat(key: key, model: model, system: AIGroupPrompt.remoteNaming(emoji: ask.emoji), prompt: prompt,
                                       effort: effort)
        } catch {
            let trouble = OpenRouterTrouble.from(error)
            await report(trouble)
            throw trouble
        }
        lock.withLock { cost += answer.cost }
        guard var name = AIGroupPrompt.name(json: answer.text) else {
            await report(.nonsense)
            throw OpenRouterTrouble.nonsense
        }
        await report(nil)
        if !ask.emoji { name.emoji = nil }
        return name
    }
}

final class AIGroupNamerChain: AIGroupNamer {
    let namers: [any AIGroupNamer]

    init(_ namers: [any AIGroupNamer]) {
        self.namers = namers
    }

    var local: Bool { namers.allSatisfy(\.local) }

    func name(_ ask: AIGroupNameAsk) async throws -> AIGroupName {
        var last: Error = OpenRouterTrouble.nonsense
        for namer in namers {
            do {
                return try await namer.name(namer.local ? ask : ask.bare)
            } catch {
                last = error
            }
        }
        throw last
    }
}

final class AIGroupDeciderChain: AIGroupDecider {
    let remote: any AIGroupDecider
    let mac: (any AIGroupDecider)?
    let seconds: Double
    let report: @Sendable (OpenRouterTrouble?) async -> Void

    init(remote: any AIGroupDecider, mac: (any AIGroupDecider)?, seconds: Double = 18,
         report: @escaping @Sendable (OpenRouterTrouble?) async -> Void = { await OpenRouterKey.shared.note($0) }) {
        self.remote = remote
        self.mac = mac
        self.seconds = seconds
        self.report = report
    }

    var local: Bool { true }
    var batch: Int { remote.batch }

    func decide(_ ask: AIGroupAsk) async throws -> [UUID: AIGroupPick] {
        do {
            let remote = self.remote
            let shown = ask.bare
            let said = try await AIGrouper.within(seconds) { try await remote.decide(shown) }
            await report(nil)
            return said
        } catch {
            if Task.isCancelled || error is CancellationError || error as? ProviderError == .cancelled { throw error }
            let trouble = OpenRouterTrouble.from(error)
            if trouble != .testRun { await report(trouble) }
            AIGroupTrace.note("failed", ["why": trouble.words, "fresh": ask.fresh.map(\.title)])
            guard let mac else { throw trouble }
            return try await mac.decide(ask)
        }
    }

    func fits(_ tab: AIGroupTab, in group: AIGroupInfo) async throws -> AIGroupFit {
        do {
            let remote = self.remote
            let shown = (tab.bare, group.bare)
            let said = try await AIGrouper.within(seconds) { try await remote.fits(shown.0, in: shown.1) }
            await report(nil)
            return said
        } catch {
            if Task.isCancelled || error is CancellationError || error as? ProviderError == .cancelled { throw error }
            let trouble = OpenRouterTrouble.from(error)
            if trouble != .testRun { await report(trouble) }
            AIGroupTrace.note("failed", ["why": trouble.words, "judged": tab.title])
            throw trouble
        }
    }
}
