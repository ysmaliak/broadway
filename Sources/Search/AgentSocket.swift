import AppKit
import Foundation

enum AgentConsent {
    private static let service = "com.ysmaliak.broadway.agents"

    static var given: Bool { ConsentMark.present("consent", service: service) }
    static var bypassGiven: Bool { ConsentMark.present("bypass", service: service) }

    @discardableResult static func grant() -> Bool { ConsentMark.put("consent", service: service) }
    static func revoke() { ConsentMark.take("consent", service: service) }
    @discardableResult static func grantBypass() -> Bool { ConsentMark.put("bypass", service: service) }
    static func revokeBypass() { ConsentMark.take("bypass", service: service) }
}

extension Preferences {
    var agentsAllowed: Bool { agentsOn }
}

enum AgentCommand {
    static var socket: URL { Store.file("broadway.sock") }

    static var path: String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/broadway").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        let beside = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("broadway").path
        if let beside, FileManager.default.isExecutableFile(atPath: beside) { return beside }
        return nil
    }

    static func helper(_ words: [String]) async -> [String: Any]? {
        guard let path else { return nil }
        return await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = words + ["--json"] + (Store.world.map { ["--world", $0] } ?? [])
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["data"] as? [String: Any]
        }.value
    }

    static func isSetUp(_ checks: [[String: Any]]) -> Bool {
        checks.first { $0["name"] as? String == "command" }?["ok"] as? Bool == true
    }

    static func summary(_ checks: [[String: Any]]) -> String {
        guard !checks.isEmpty else { return "Run tasks, snapshot pages, click and more, from Terminal" }
        guard isSetUp(checks) else { return "Puts broadway on your PATH, with shell completions and skills for Claude Code and Codex" }
        let named = [("fish", "fish"), ("zsh", "zsh"), ("bash", "bash"), ("claude", "Claude Code"), ("codex", "Codex")]
        let good = named.filter { name, _ in
            checks.first { $0["name"] as? String == name }.map { $0["ok"] as? Bool == true && $0["detail"] as? String != "not used here" } == true
        }.map(\.1)
        let broken = checks.first { $0["ok"] as? Bool == false && $0["name"] as? String != "running" && $0["name"] as? String != "agents" && $0["name"] as? String != "plan" }
        if let broken { return "On your PATH, but \(broken["detail"] as? String ?? "something is off"). Run broadway doctor." }
        return good.isEmpty ? "On your PATH. Try broadway status." : "On your PATH, set up for \(good.joined(separator: ", ")). Try broadway doctor."
    }

    static func mcpConfig(path: String) -> String {
        let config: [String: Any] = ["mcpServers": ["broadway-browser": ["command": path, "args": ["mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class AgentTasks {
    static let shared = AgentTasks()

    private(set) var running: [UUID: Conversation] = [:]
    var helpers: [UUID: [AgentHelper]] = [:]
    var helperCommand: String?

    func stop(_ id: UUID) {
        running[id]?.stop()
        stopHelpers(of: id)
    }

    private func settle(_ id: UUID, mood: AgentMood) {
        let conversation = running.removeValue(forKey: id)
        let goesOn = AgentSessions.shared.waiting[id] != nil || conversation?.steering == true || conversation?.queued.isEmpty == false
        guard !goesOn else { return }
        TaskLedger.shared.close(id)
        AgentBoard.finish(id, mood: mood)
        stopHelpers(of: id)
    }

    func start(prompt: String, choice: ModelChoice?, prefs: Preferences, command: String? = AgentCommand.path, parent: UUID? = nil,
               origin: TaskOrigin = .user, allowed: Set<String>? = nil,
               chat given: Chat? = nil, material: String? = nil,
               happened: @escaping (Conversation.Happening) -> Void) -> Conversation? {
        guard let command else {
            happened(.failed("The broadway tool isn't in this copy of Broadway"))
            return nil
        }
        let chat = given ?? Chat(kind: origin.chatKind, model: choice.map { Plans.shared.roomy($0, prefs) })
        let conversation = Conversation(chat: chat, saved: parent == nil, prefs: prefs)
        if let material { conversation.attachments = [Attachment(label: "Text piped to the broadway command", kind: .text(material))] }
        conversation.keepOpen = true
        conversation.seen = { parent != nil }
        conversation.tools = .mcp(MCPLaunch(name: "broadway", command: command,
                                            arguments: ["mcp", "--socket", AgentCommand.socket.path, "--task", chat.id.uuidString]))
        let id = chat.id
        if parent == nil { AgentLinks.shared.join(.task(id), name: Conversation.title(prompt)) }
        conversation.happened = { [weak self] event in
            happened(event)
            if case .step(let name, let summary) = event {
                PersonWatch.step(task: id, name: name, summary: summary)
                AgentLinks.shared.step(AgentTasks.shared.root(id), summary.isEmpty ? name : summary)
            }
            switch event {
            case .done, .stopped:
                self?.settle(id, mood: .done)
            case .failed:
                self?.settle(id, mood: .failed)
            default: break
            }
        }
        running[id] = conversation
        TaskLedger.shared.open(id, origin: origin, title: Conversation.title(prompt), allowed: allowed)
        ChatStore.shared.load()
        conversation.send(prompt)
        return conversation
    }
}

@MainActor
final class AgentSocket {
    static let shared = AgentSocket()

    private var server: UnixLineServer?
    private weak var browser: Browser?
    let box = BrowserToolbox()
    var serving = false
    var currentTab: String?
    private var woken = false
    private var lastUsed = Date()
    private var idleClock: Timer?

    func start(for browser: Browser) {
        guard server == nil else { return }
        self.browser = browser
        let server = UnixLineServer(path: AgentCommand.socket.path)
        server.connected = { [weak self] connection in
            MainActor.assumeIsolated { self?.greet(connection) }
        }
        guard server.start() else { return }
        self.server = server
        AgentBoard.startClock()
        woken = CommandLine.arguments.contains(AgentIdle.wakeFlag)
        guard woken else { return }
        idleClock = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitIfIdle() }
        }
    }

    private func quitIfIdle() {
        let quiet = Date().timeIntervalSince(lastUsed)
        if AgentIdle.shouldQuit(woken: woken, hidden: NSApp.isHidden, serving: serving, tasks: AgentSessions.shared.live.count, quiet: quiet) {
            NSApp.terminate(nil)
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    private func greet(_ connection: LineConnection) {
        connection.onLine = { [weak self, weak connection] request in
            MainActor.assumeIsolated {
                guard let self, let connection else { return }
                self.handle(request, on: connection)
            }
        }
    }

    private func handle(_ request: [String: Any], on connection: LineConnection) {
        guard let browser = Browsers.front ?? browser else {
            connection.send(["error": "Broadway has no window open"])
            return connection.close()
        }
        lastUsed = Date()
        switch request["op"] as? String {
        case "status":
            Task { @MainActor in
                if !Plans.shared.looked { await Plans.shared.refresh() }
                connection.send(status(browser))
                connection.close()
            }
        case "open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            else {
                connection.send(["error": "broadway opens web addresses"])
                return connection.close()
            }
            browser.arrive(url)
            if !Store.testing { NSApp.activate() }
            connection.send(["opened": url.absoluteString])
            connection.close()
        case "task":
            runTask(request, browser: browser, on: connection)
        case "mcp":
            var task = (request["task"] as? String).flatMap(UUID.init(uuidString:))
            if task == nil, browser.prefs.agentsAllowed {
                let held = UUID()
                task = link(for: request, create: true, connection: held, name: AgentLinks.mcpName(request["client"] as? String))?.id
                let gone = connection.onClose
                connection.onClose = {
                    gone?()
                    MainActor.assumeIsolated { AgentLinks.shared.endConnection(held) }
                }
            }
            let server = MCPServer(box: box, task: task) { [weak connection] message in connection?.send(message) }
            server.named = { client in
                guard let task, let name = AgentLinks.mcpName(client) else { return }
                AgentLinks.shared.rename(task, name)
            }
            box.browser = browser
            aim(server, browser: browser, link: task)
            connection.onLine = { line in MainActor.assumeIsolated { server.handle(line) } }
            var greeting: [String: Any] = ["mcp": true]
            if let task, request["task"] == nil { greeting["link"] = task.uuidString.lowercased() }
            connection.send(greeting)
        default:
            guard !command(request, browser: browser, on: connection) else { return }
            connection.send(["error": "broadway status, open, task, every, mcp, tools, call, session, quit or serve"])
            connection.close()
        }
    }

    private func status(_ browser: Browser) -> [String: Any] {
        var plans: [String: Any] = [:]
        for plan in Plan.cloud {
            let found = Plans.shared.statuses[plan]
            plans[plan.rawValue] = ["installed": found?.installed ?? false, "connected": found?.connected ?? false,
                                    "account": found?.account ?? ""] as [String: Any]
        }
        return ["running": true, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
                "agents": browser.prefs.agentsAllowed, "plans": plans, "tasks": AgentSessions.shared.live.count,
                "hidden": NSApp.isHidden, "serving": serving, "world": Store.world ?? ""]
    }

    private func runTask(_ request: [String: Any], browser: Browser, on connection: LineConnection) {
        guard browser.prefs.agentsAllowed else {
            connection.send(["event": "failed", "code": "agents_off", "message": "Agents are off. Turn on Settings › Agents › Let agents use Broadway."])
            return connection.close()
        }
        guard let prompt = request["prompt"] as? String, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            connection.send(["event": "failed", "code": "usage", "message": "A task needs words"])
            return connection.close()
        }
        Task { @MainActor in
            if !Plans.shared.looked { await Plans.shared.refresh() }
            guard let choice = self.choice(request, prefs: browser.prefs) else {
                connection.send(["event": "failed", "code": "no_plan", "message": Plans.shared.trouble(browser.prefs) ?? "That plan or model isn't available"])
                return connection.close()
            }
            AgentSessions.shared.begin(prompt: prompt, choice: choice, prefs: browser.prefs, request: request, on: connection)
        }
    }

    func choice(_ request: [String: Any], prefs: Preferences) -> ModelChoice? {
        var chosen: ModelChoice?
        if let cli = request["cli"] as? String {
            guard let plan = cli == "codex" ? Plan.chatGPT : cli == "claude" ? .claude : nil, Plans.shared.connected(plan) else { return nil }
            chosen = Plans.shared.defaultChoice(plan)
        } else {
            chosen = Plans.shared.choice(.tasks, prefs)
        }
        if let model = request["model"] as? String {
            chosen?.model = model
            chosen?.effort = nil
        }
        if let effort = (request["effort"] as? String).flatMap(Effort.init(rawValue:)) { chosen?.effort = effort }
        return chosen
    }
}
