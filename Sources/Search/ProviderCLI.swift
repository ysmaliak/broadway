import Foundation

protocol CLILines {
    mutating func feed(_ line: String) throws -> [ProviderEvent]
    func ended(status: Int32, stderr: String) throws
}

enum CLIGuard {
    static var realAllowed: Bool {
        ProcessInfo.processInfo.environment["SEARCH_REAL_MODEL"] == "1"
    }

    static var underTest: Bool {
        Store.testing || Store.unitTests
    }

    static func allows(_ executable: URL) -> Bool {
        guard underTest, !realAllowed else { return true }
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return executable.resolvingSymlinksInPath().path.hasPrefix(temporary)
    }
}

enum CLIFinder {
    static func candidates(_ name: String, home: String) -> [String] {
        ["\(home)/.local/bin/\(name)", "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)",
         "\(home)/.claude/local/\(name)", "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)"]
    }

    static func find(_ name: String, home: String = NSHomeDirectory(),
                     exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        candidates(name, home: home).first(where: exists)
    }

    static func fromShell(_ name: String) async -> String? {
        guard !CLIGuard.underTest else { return nil }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let found = await CLIRun.capture(URL(fileURLWithPath: shell), ["-lc", "command -v \(name)"], seconds: 5)
        let path = found.out.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    static var searchPath: String {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .joined(separator: ":")
    }

    static var environment: [String: String] {
        let mine = ProcessInfo.processInfo.environment
        var kept = ["HOME": NSHomeDirectory(), "PATH": searchPath, "TERM": "dumb", "NO_COLOR": "1"]
        for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL", "CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
            if let value = mine[key] { kept[key] = value }
        }
        return kept
    }

    static var room: URL {
        let folder = Store.file("AI Room")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return folder
    }
}

final class CLIRun: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private let feed: AsyncThrowingStream<ProviderEvent, Error>.Continuation
    private var lines: any CLILines
    private var buffer = Data()
    private var complaint = Data()
    private var stopped = false
    private var closed = false
    private var done = false
    private var open = 1
    private let finish = DispatchGroup()

    private init(executable: URL, arguments: [String], folder: URL, environment: [String: String],
                 lines: any CLILines, feed: AsyncThrowingStream<ProviderEvent, Error>.Continuation) {
        self.lines = lines
        self.feed = feed
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    static func start(executable: URL, arguments: [String], folder: URL = CLIFinder.room,
                      environment: [String: String] = CLIFinder.environment, stdin: Data,
                      keepOpen: Bool, framing: (@Sendable (String) -> Data)? = nil, lines: any CLILines) -> ProviderSession {
        var continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation!
        let events = AsyncThrowingStream<ProviderEvent, Error> { continuation = $0 }
        let feed = continuation!
        guard CLIGuard.allows(executable) else {
            feed.finish(throwing: ProviderError.refused("A test run never calls a real model"))
            return ProviderSession(events: events, stopping: {})
        }
        let run = CLIRun(executable: executable, arguments: arguments, folder: folder, environment: environment,
                         lines: lines, feed: feed)
        run.launch(stdin: stdin, keepOpen: keepOpen)
        feed.onTermination = { [weak run] reason in
            if case .cancelled = reason { run?.cancel() }
        }
        var steering: (@Sendable (String) -> Bool)?
        if keepOpen {
            steering = { [run] text in
                let data: Data
                if let framing { data = framing(text) } else { data = Data(Array(text.utf8)) }
                return run.steer(data)
            }
        }
        return ProviderSession(events: events, stopping: { [run] in run.cancel() }, sending: steering)
    }

    private func launch(stdin: Data, keepOpen: Bool) {
        finish.enter()
        finish.enter()
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
                self.finish.leave()
            } else {
                self.took(data)
            }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                self.lock.withLock { if self.complaint.count < 16_384 { self.complaint.append(data) } }
            }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.finish.leave()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self.conclude() }
        }
        finish.notify(queue: .global()) { [weak self] in self?.conclude() }
        do {
            try process.run()
        } catch {
            done = true
            feed.finish(throwing: ProviderError.failed(error.localizedDescription))
            return
        }
        let handle = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            try? handle.write(contentsOf: stdin)
            if !keepOpen { self?.closeInput() }
        }
    }

    private func steer(_ data: Data) -> Bool {
        let live = lock.withLock { () -> Bool in
            guard !closed, !stopped else { return false }
            open += 1
            return true
        }
        guard live else { return false }
        let handle = input.fileHandleForWriting
        DispatchQueue.global(qos: .userInitiated).async { try? handle.write(contentsOf: data) }
        return true
    }

    private func closeInput() {
        let close = lock.withLock { () -> Bool in
            guard !closed else { return false }
            closed = true
            return true
        }
        if close { try? input.fileHandleForWriting.close() }
    }

    private func took(_ data: Data) {
        var turnEnded = false
        var failure: Error?
        var shipped: [ProviderEvent] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let text = String(data: line, encoding: .utf8), !text.isEmpty else { continue }
                do {
                    for event in try lines.feed(text) {
                        if case .finished = event {
                            open -= 1
                            turnEnded = open <= 0
                        }
                        shipped.append(event)
                    }
                } catch {
                    failure = error
                }
            }
        }
        for event in shipped { feed.yield(event) }
        if turnEnded { closeInput() }
        if let failure {
            let first = lock.withLock { () -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            if first { feed.finish(throwing: failure) }
            cancel()
        }
    }

    private func conclude() {
        let already = lock.withLock { () -> Bool in
            let was = done
            done = true
            return was
        }
        guard !already else { return }
        if lock.withLock({ stopped }) {
            feed.finish(throwing: ProviderError.cancelled)
            return
        }
        let said = lock.withLock { String(decoding: complaint, as: UTF8.self) }
        do {
            try lines.ended(status: process.isRunning ? 0 : process.terminationStatus, stderr: said)
            feed.finish()
        } catch {
            feed.finish(throwing: error)
        }
    }

    func cancel() {
        let first = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard first else { return }
        closeInput()
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    struct Captured: Sendable {
        var status: Int32
        var out: String
    }

    static func capture(_ executable: URL, _ arguments: [String], seconds: Double = 10) async -> Captured {
        guard CLIGuard.allows(executable) else { return Captured(status: -1, out: "") }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.environment = CLIFinder.environment
                process.currentDirectoryURL = CLIFinder.room
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = pipe
                do { try process.run() } catch {
                    done.resume(returning: Captured(status: -1, out: error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { if process.isRunning { process.terminate() } }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                done.resume(returning: Captured(status: process.terminationStatus, out: String(decoding: data, as: UTF8.self)))
            }
        }
    }
}

final class ClaudeProvider: Provider, @unchecked Sendable {
    let plan = Plan.claude
    private let path: @Sendable () -> String?

    init(path: @escaping @Sendable () -> String? = { CLIFinder.find("claude") }) {
        self.path = path
    }

    func status() async -> PlanStatus {
        var found = path()
        if found == nil { found = await CLIFinder.fromShell("claude") }
        guard let found else { return PlanStatus() }
        let said = await CLIRun.capture(URL(fileURLWithPath: found), ["auth", "status", "--json"])
        return ClaudeProvider.reading(status: said.out, path: found)
    }

    static func reading(status text: String, path: String) -> PlanStatus {
        var status = PlanStatus(path: path)
        guard let data = text.data(using: .utf8),
              let found = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return status }
        status.connected = found["loggedIn"] as? Bool ?? false
        if let kind = found["subscriptionType"] as? String, !kind.isEmpty {
            status.account = kind.prefix(1).uppercased() + kind.dropFirst() + " plan"
        } else if found["authMethod"] as? String != "claude.ai", status.connected {
            status.account = "not a plan: paid per use"
        }
        return status
    }

    func models() -> [PlanModel] {
        let efforts: [Effort] = [.low, .medium, .high, .xhigh, .max]
        return [PlanModel(id: "sonnet", name: "Sonnet", efforts: efforts, defaultEffort: .medium,
                          note: "The newest Sonnet, fast and capable, for most things"),
                PlanModel(id: "opus", name: "Opus", efforts: efforts, defaultEffort: .high,
                          note: "The newest Opus, slower, for the hardest work"),
                PlanModel(id: "fable", name: "Fable", efforts: efforts, defaultEffort: .high,
                          note: "The newest Fable"),
                PlanModel(id: "haiku", name: "Haiku", note: "The newest Haiku, the quickest, with no effort setting")]
    }

    static func arguments(for request: ProviderRequest) -> [String] {
        var out = ["-p", "--output-format", "stream-json", "--input-format", "stream-json", "--verbose",
                   "--include-partial-messages", "--no-session-persistence", "--no-chrome",
                   "--permission-mode", "dontAsk", "--permission-prompts", "none", "--disable-slash-commands",
                   "--strict-mcp-config", "--tools", "", "--system-prompt", request.system]
        switch request.tools {
        case .none:
            out.append("--safe-mode")
        case .mcp(let server):
            let entry: [String: Any] = ["mcpServers": [server.name: ["command": server.command, "args": server.arguments]]]
            let json = (try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys, .withoutEscapingSlashes]))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            out += ["--restricted", "--mcp-config", json, "--allowedTools", "mcp__\(server.name)"]
        }
        if let model = request.model { out += ["--model", model] }
        if let effort = request.effort { out += ["--effort", effort.rawValue] }
        return out
    }

    static func message(_ text: String, images: [ProviderImage] = []) -> Data {
        var content: [[String: Any]] = images.compactMap { image in
            guard let data = try? Data(contentsOf: image.file) else { return nil }
            return ["type": "image", "source": ["type": "base64", "media_type": image.mediaType,
                                                "data": data.base64EncodedString()]]
        }
        content.append(["type": "text", "text": text])
        let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": content]]
        var out = (try? JSONSerialization.data(withJSONObject: line)) ?? Data()
        out.append(0x0A)
        return out
    }

    func start(_ request: ProviderRequest) -> ProviderSession {
        guard let found = path() else { return Self.failing(.notInstalled(plan)) }
        return CLIRun.start(executable: URL(fileURLWithPath: found), arguments: Self.arguments(for: request),
                            environment: CLIFinder.environment.merging(Self.quiet) { _, new in new },
                            stdin: Self.message(request.prompt, images: request.images), keepOpen: request.keepOpen,
                            framing: { Self.message($0) }, lines: ClaudeLines())
    }

    static let quiet = ["CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "CLAUDE_CODE_DISABLE_CLAUDE_MDS": "1",
                        "MCP_TOOL_TIMEOUT": "1800000"]

    static func failing(_ error: ProviderError) -> ProviderSession {
        let events = AsyncThrowingStream<ProviderEvent, Error> { $0.finish(throwing: error) }
        return ProviderSession(events: events, stopping: {})
    }
}

struct ClaudeLines: CLILines {
    private var streamed = false
    private var opened = Set<String>()
    private var answered = false

    mutating func feed(_ line: String) throws -> [ProviderEvent] {
        guard let data = line.data(using: .utf8),
              let found = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        switch found["type"] as? String {
        case "system":
            if found["subtype"] as? String == "init" { return [.started(model: found["model"] as? String)] }
            return []
        case "rate_limit_event":
            return PlanLimit(claude: found["rate_limit_info"] as? [String: Any] ?? [:]).map { [.rateLimit($0)] } ?? []
        case "stream_event":
            guard let event = found["event"] as? [String: Any], event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String
            else { return [] }
            streamed = true
            return [.text(text)]
        case "assistant":
            let blocks = (found["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            var out: [ProviderEvent] = []
            for block in blocks {
                switch block["type"] as? String {
                case "text":
                    if !streamed, let text = block["text"] as? String { out.append(.text(text)) }
                case "tool_use":
                    guard let id = block["id"] as? String, opened.insert(id).inserted else { continue }
                    let name = block["name"] as? String ?? "tool"
                    out.append(.toolStarted(id: id, name: Self.shortName(name), summary: Self.summary(block["input"])))
                default:
                    break
                }
            }
            streamed = false
            return out
        case "user":
            let blocks = (found["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return blocks.compactMap { block in
                guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
                return .toolFinished(id: id, failed: block["is_error"] as? Bool ?? false)
            }
        case "result":
            answered = true
            if found["is_error"] as? Bool == true || (found["subtype"] as? String ?? "success") != "success" {
                let said = found["result"] as? String ?? (found["errors"] as? [String])?.joined(separator: " ") ?? ""
                throw ProviderError.reading(said, plan: .claude)
            }
            let usage = found["usage"] as? [String: Any]
            return [.finished(ProviderUsage(inputTokens: usage?["input_tokens"] as? Int ?? 0,
                                            outputTokens: usage?["output_tokens"] as? Int ?? 0))]
        default:
            return []
        }
    }

    func ended(status: Int32, stderr: String) throws {
        if !answered { throw ProviderError.reading(stderr, plan: .claude) }
    }

    static func shortName(_ name: String) -> String {
        let parts = name.components(separatedBy: "__")
        return parts.count >= 3 ? parts.dropFirst(2).joined(separator: "__") : name
    }

    static func summary(_ input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        for key in ["url", "ref", "text", "keys", "query", "tab"] {
            if let value = input[key] as? String, !value.isEmpty { return String(value.prefix(80)) }
        }
        return ""
    }
}

final class CodexProvider: Provider, @unchecked Sendable {
    let plan = Plan.chatGPT
    private let path: @Sendable () -> String?
    private let home: String

    init(path: @escaping @Sendable () -> String? = { CLIFinder.find("codex") }, home: String = NSHomeDirectory()) {
        self.path = path
        self.home = home
    }

    func status() async -> PlanStatus {
        var found = path()
        if found == nil { found = await CLIFinder.fromShell("codex") }
        guard let found else { return PlanStatus() }
        let said = await CLIRun.capture(URL(fileURLWithPath: found), ["login", "status"])
        return Self.reading(status: said.out, code: said.status, path: found)
    }

    static func reading(status text: String, code: Int32, path: String) -> PlanStatus {
        var status = PlanStatus(path: path)
        status.connected = code == 0 && text.lowercased().contains("logged in") && !text.lowercased().contains("not logged in")
        if status.connected {
            status.account = text.lowercased().contains("chatgpt") ? "ChatGPT plan" : "not a plan: paid per use"
        }
        return status
    }

    func models() -> [PlanModel] {
        let cache = URL(fileURLWithPath: home).appendingPathComponent(".codex/models_cache.json")
        if let data = try? Data(contentsOf: cache) {
            let found = Self.models(cache: data)
            if !found.isEmpty { return found }
        }
        let config = (try? String(contentsOf: URL(fileURLWithPath: home).appendingPathComponent(".codex/config.toml"), encoding: .utf8)) ?? ""
        return Self.models(config: config)
    }

    static func models(cache data: Data) -> [PlanModel] {
        guard let found = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = found["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { model in
            guard let slug = model["slug"] as? String, (model["visibility"] as? String ?? "list") == "list" else { return nil }
            let levels = (model["supported_reasoning_levels"] as? [[String: Any]] ?? [])
                .compactMap { ($0["effort"] as? String).flatMap(Effort.init(rawValue:)) }
            let chosen = (model["default_reasoning_level"] as? String).flatMap(Effort.init(rawValue:))
            let name = model["display_name"] as? String ?? slug
            return PlanModel(id: slug, name: name, efforts: levels, defaultEffort: chosen,
                             note: note(model["description"] as? String, name: name))
        }
    }

    static func note(_ said: String?, name: String) -> String? {
        guard var said = said?.trimmingCharacters(in: .whitespacesAndNewlines), !said.isEmpty else { return nil }
        if said.hasSuffix(".") { said.removeLast() }
        let plain = said.lowercased().replacingOccurrences(of: "codex model", with: "").trimmingCharacters(in: .whitespaces)
        guard plain != name.lowercased(), said.count <= 90 else { return nil }
        return said
    }

    static func models(config text: String) -> [PlanModel] {
        for line in text.split(separator: "\n") where line.hasPrefix("model") {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "model" else { continue }
            let name = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return [PlanModel(id: name, name: name)]
        }
        return []
    }

    static let closed = ["shell_tool", "unified_exec", "apps", "plugins", "browser_use", "computer_use",
                         "in_app_browser", "memories", "hooks", "multi_agent"]

    static func arguments(for request: ProviderRequest) -> [String] {
        var out = ["exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
                   "--sandbox", "read-only", "-c", "approval_policy=\"never\"", "-c", "web_search=\"disabled\""]
        for feature in closed { out += ["--disable", feature] }
        if let model = request.model { out += ["-m", model] }
        if let effort = request.effort { out += ["-c", "model_reasoning_effort=\"\(effort.rawValue)\""] }
        if case .mcp(let server) = request.tools {
            let list = server.arguments.map { "\"\($0)\"" }.joined(separator: ",")
            out += ["-c", "mcp_servers.\(server.name).command=\"\(server.command)\"",
                    "-c", "mcp_servers.\(server.name).args=[\(list)]",
                    "-c", "mcp_servers.\(server.name).default_tools_approval_mode=\"approve\"",
                    "-c", "mcp_servers.\(server.name).tool_timeout_sec=1800"]
        }
        for image in request.images { out += ["-i", image.file.path] }
        out += ["--color", "never", "-"]
        return out
    }

    static func stdin(for request: ProviderRequest) -> Data {
        Data("\(request.system)\n\n\(request.prompt)".utf8)
    }

    func start(_ request: ProviderRequest) -> ProviderSession {
        guard let found = path() else { return ClaudeProvider.failing(.notInstalled(plan)) }
        return CLIRun.start(executable: URL(fileURLWithPath: found), arguments: Self.arguments(for: request),
                            stdin: Self.stdin(for: request), keepOpen: false, lines: CodexLines())
    }
}

struct CodexLines: CLILines {
    private var spoken: [String: Int] = [:]
    private var answered = false
    private var lastError = ""

    mutating func feed(_ line: String) throws -> [ProviderEvent] {
        guard let data = line.data(using: .utf8),
              let found = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        let payload = found["payload"] as? [String: Any]
        if let limits = (found["rate_limits"] ?? payload?["rate_limits"]) as? [String: Any], let limit = PlanLimit(codex: limits) {
            return [.rateLimit(limit)]
        }
        switch found["type"] as? String {
        case "thread.started":
            return [.started(model: nil)]
        case "item.started", "item.updated", "item.completed":
            return item(found["item"] as? [String: Any] ?? [:], completed: found["type"] as? String == "item.completed",
                        started: found["type"] as? String == "item.started")
        case "turn.completed":
            answered = true
            let usage = found["usage"] as? [String: Any]
            return [.finished(ProviderUsage(inputTokens: usage?["input_tokens"] as? Int ?? 0,
                                            outputTokens: usage?["output_tokens"] as? Int ?? 0))]
        case "turn.failed":
            answered = true
            let error = found["error"] as? [String: Any]
            throw ProviderError.reading(error?["message"] as? String ?? lastError, plan: .chatGPT)
        case "error":
            lastError = found["message"] as? String ?? ""
            return []
        default:
            return []
        }
    }

    private mutating func item(_ item: [String: Any], completed: Bool, started: Bool) -> [ProviderEvent] {
        let id = item["id"] as? String ?? ""
        switch item["type"] as? String {
        case "agent_message":
            guard let text = item["text"] as? String else { return [] }
            let said = spoken[id] ?? 0
            guard text.count > said else { return [] }
            spoken[id] = text.count
            return [.text(String(text.dropFirst(said)))]
        case "reasoning":
            return started ? [.status("Thinking")] : []
        case "command_execution", "mcp_tool_call", "web_search", "file_change":
            if started {
                let name = item["tool"] as? String ?? (item["type"] as? String ?? "tool")
                let summary = item["command"] as? String ?? item["query"] as? String ?? ""
                return [.toolStarted(id: id, name: name, summary: String(summary.prefix(80)))]
            }
            if completed {
                let status = item["status"] as? String ?? "completed"
                return [.toolFinished(id: id, failed: status == "failed" || status == "declined")]
            }
            return []
        default:
            return []
        }
    }

    func ended(status: Int32, stderr: String) throws {
        if !answered { throw ProviderError.reading(lastError.isEmpty ? stderr : lastError, plan: .chatGPT) }
    }
}
