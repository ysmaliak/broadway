import Foundation

enum Plan: String, CaseIterable, Identifiable, Codable, Sendable {
    case claude, chatGPT, thisMac

    static let cloud: [Plan] = [.claude, .chatGPT]

    var id: String { rawValue }

    var name: String {
        switch self {
        case .claude: return "Claude"
        case .chatGPT: return "ChatGPT"
        case .thisMac: return "This Mac"
        }
    }

    var tool: String {
        switch self {
        case .claude: return "Claude Code"
        case .chatGPT: return "Codex"
        case .thisMac: return "Apple Intelligence"
        }
    }

    var executable: String {
        switch self {
        case .claude: return "claude"
        case .chatGPT: return "codex"
        case .thisMac: return ""
        }
    }

    var signIn: String {
        switch self {
        case .claude: return "claude auth login"
        case .chatGPT: return "codex login"
        case .thisMac: return ""
        }
    }

    var install: String {
        switch self {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .chatGPT: return "brew install --cask codex"
        case .thisMac: return ""
        }
    }

    var other: Plan { self == .claude ? .chatGPT : .claude }
}

enum Effort: String, CaseIterable, Codable, Sendable {
    case low, medium, high, xhigh, max, ultra

    var name: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra High"
        case .max: return "Max"
        case .ultra: return "Ultra"
        }
    }
}

struct PlanModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var efforts: [Effort] = []
    var defaultEffort: Effort?
    var note: String?
}

struct ModelChoice: Equatable, Hashable, Codable, Sendable {
    var plan: Plan
    var model: String
    var effort: Effort?

    var label: String {
        let shown = Plans.modelName(model, plan: plan)
        return effort.map { "\(shown) · \($0.name)" } ?? shown
    }
}

struct PlanStatus: Equatable, Sendable {
    var path: String?
    var connected = false
    var account: String?

    var installed: Bool { path != nil }
}

struct MCPLaunch: Equatable, Sendable {
    var name: String
    var command: String
    var arguments: [String]
}

enum ProviderTools: Equatable, Sendable {
    case none
    case mcp(MCPLaunch)
}

struct ProviderImage: Equatable, Sendable {
    var file: URL
    var mediaType: String
}

struct ProviderRequest: Equatable, Sendable {
    var system: String
    var prompt: String
    var images: [ProviderImage] = []
    var model: String?
    var effort: Effort?
    var tools: ProviderTools = .none
    var keepOpen = false
}

struct ProviderUsage: Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
}

struct PlanLimit: Equatable, Sendable {
    var window: String
    var used: Double?
    var resets: Date?
    var out = false
}

enum ProviderEvent: Equatable, Sendable {
    case started(model: String?)
    case text(String)
    case status(String)
    case toolStarted(id: String, name: String, summary: String)
    case toolFinished(id: String, failed: Bool)
    case rateLimit(PlanLimit)
    case finished(ProviderUsage)
}

enum ProviderError: LocalizedError, Equatable, Sendable {
    case notInstalled(Plan)
    case notSignedIn(Plan)
    case planOut(String)
    case refused(String)
    case failed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notInstalled(let plan): return "\(plan.tool) isn't installed on this Mac"
        case .notSignedIn(let plan): return "\(plan.tool) isn't signed in. Run \(plan.signIn) in Terminal."
        case .planOut(let said): return said.isEmpty ? "Your plan has run out for now" : said
        case .refused(let said), .failed(let said): return said
        case .cancelled: return "Stopped"
        }
    }

    static func reading(_ said: String, plan: Plan) -> ProviderError {
        let text = said.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let signIn = ["not logged in", "please run /login", "invalid api key", "authentication", "unauthorized", "log in", "codex login"]
        if signIn.contains(where: lower.contains) { return .notSignedIn(plan) }
        let limits = ["usage limit", "rate limit", "hit your limit", "limit reached", "quota", "credit balance",
                      "usage_limit_reached", "rate_limit_reached", "rate_limit_exceeded", "insufficient_quota"]
        if limits.contains(where: lower.contains) { return .planOut(String(text.prefix(300))) }
        return .failed(text.isEmpty ? "\(plan.tool) stopped without an answer" : String(text.prefix(600)))
    }
}

final class ProviderSession: @unchecked Sendable {
    let events: AsyncThrowingStream<ProviderEvent, Error>
    private let stopping: @Sendable () -> Void
    private let sending: (@Sendable (String) -> Bool)?

    init(events: AsyncThrowingStream<ProviderEvent, Error>,
         stopping: @escaping @Sendable () -> Void,
         sending: (@Sendable (String) -> Bool)? = nil) {
        self.events = events
        self.stopping = stopping
        self.sending = sending
    }

    var canSteer: Bool { sending != nil }

    @discardableResult
    func send(_ text: String) -> Bool { sending?(text) ?? false }

    func cancel() { stopping() }
}

protocol Provider: AnyObject, Sendable {
    var plan: Plan { get }
    func status() async -> PlanStatus
    func models() -> [PlanModel]
    func start(_ request: ProviderRequest) -> ProviderSession
}

final class FakeProvider: Provider, @unchecked Sendable {
    enum Step: Equatable, Sendable {
        case emit(ProviderEvent)
        case wait(Double)
        case fail(ProviderError)
        case hang
    }

    let plan: Plan
    private let lock = NSLock()
    private var scripted: [Step]
    private var seen: [ProviderRequest] = []
    private var steers: [String] = []
    var fakeStatus: PlanStatus
    var fakeModels = [PlanModel(id: "fake", name: "Fake", efforts: [.low, .high], defaultEffort: .low)]
    var echoes: Bool

    init(plan: Plan = .claude, script: [Step] = [], echoes: Bool = false) {
        self.plan = plan
        scripted = script
        self.echoes = echoes
        fakeStatus = PlanStatus(path: "/fake/\(plan.executable)", connected: true, account: "fake")
    }

    var script: [Step] {
        get { lock.withLock { scripted } }
        set { lock.withLock { scripted = newValue } }
    }

    var requests: [ProviderRequest] { lock.withLock { seen } }
    var steered: [String] { lock.withLock { steers } }

    func status() async -> PlanStatus { fakeStatus }

    func models() -> [PlanModel] { fakeModels }

    func start(_ request: ProviderRequest) -> ProviderSession {
        let steps: [Step] = lock.withLock {
            seen.append(request)
            if echoes {
                let line = request.prompt.split(separator: "\n").last.map(String.init) ?? ""
                return [.emit(.started(model: request.model)), .emit(.text("Fake answer: ")), .wait(0.01),
                        .emit(.text(line)), .emit(.finished(ProviderUsage()))]
            }
            return scripted
        }
        var feed: AsyncThrowingStream<ProviderEvent, Error>.Continuation!
        let events = AsyncThrowingStream<ProviderEvent, Error> { feed = $0 }
        let out = feed!
        let worker = Task.detached {
            for step in steps {
                if Task.isCancelled { break }
                switch step {
                case .emit(let event): out.yield(event)
                case .wait(let seconds): try? await Task.sleep(for: .seconds(seconds))
                case .fail(let error):
                    out.finish(throwing: error)
                    return
                case .hang:
                    while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(10)) }
                }
            }
            if Task.isCancelled { out.finish(throwing: ProviderError.cancelled) } else { out.finish() }
        }
        var steering: (@Sendable (String) -> Bool)?
        if request.keepOpen {
            steering = { [weak self] text in
                guard let self else { return false }
                self.lock.withLock { self.steers.append(text) }
                return true
            }
        }
        return ProviderSession(events: events, stopping: { worker.cancel() }, sending: steering)
    }
}
