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

    static let extraAgents: Set<String> = ["cursor", "opencode", "gemini"]

    static func optional(_ check: [String: Any]) -> Bool {
        extraAgents.contains(check["name"] as? String ?? "") && check["ok"] as? Bool == false && check["absent"] as? Bool == true
    }

    static func tilde(_ text: String, home: String) -> String {
        let trimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !trimmed.isEmpty, let pattern = try? NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: trimmed) + "(?=/|\\s|$)") else { return text }
        return pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "~")
    }

    static func summary(_ checks: [[String: Any]], home: String = AgentCommand.home(ProcessInfo.processInfo.environment)) -> String {
        guard !checks.isEmpty else { return "Snapshot pages, click and more, from Terminal" }
        let agents = [("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor"), ("opencode", "opencode"), ("gemini", "Gemini CLI")]
        let named = [("fish", "fish"), ("zsh", "zsh"), ("bash", "bash")] + agents
        let good = named.filter { name, _ in
            checks.first { $0["name"] as? String == name }.map { $0["ok"] as? Bool == true && $0["detail"] as? String != "not used here" } == true
        }.map(\.1)
        guard isSetUp(checks) else {
            let skilled = good.filter { name in agents.contains { $0.1 == name } }
            guard !skilled.isEmpty else { return "Puts broadway on your PATH, with shell completions and skills for Claude Code, Codex, Cursor, opencode and Gemini CLI" }
            let listed = skilled.count == 1 ? skilled[0] : skilled.dropLast().joined(separator: ", ") + " and " + skilled[skilled.count - 1]
            return "\(listed) \(skilled.count == 1 ? "has" : "have") Broadway's skill. Set Up also puts broadway on your PATH."
        }
        let hooks: Set<String> = ["claude hooks", "codex hooks"]
        let quiet: Set<String> = ["running", "agents", "plan"]
        let broken = checks.first { $0["ok"] as? Bool == false && !quiet.union(hooks).contains($0["name"] as? String ?? "") && !optional($0) }
        if let broken { return "On your PATH, but \((broken["detail"] as? String).map { tilde($0, home: home) } ?? "something is off"). Run broadway doctor." }
        if checks.contains(where: { $0["ok"] as? Bool == false && hooks.contains($0["name"] as? String ?? "") }) {
            return "Run broadway setup again to let Broadway see when an agent has finished"
        }
        return good.isEmpty ? "On your PATH. Try broadway status." : "On your PATH, set up for \(good.joined(separator: ", ")). Try broadway doctor."
    }

    static func mcpConfig(path: String) -> String {
        let config: [String: Any] = ["mcpServers": ["broadway-browser": ["command": path, "args": ["mcp"]]]]
        let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

@MainActor
final class AgentSocket {
    static let shared = AgentSocket()

    private var server: UnixLineServer?
    private weak var browser: Browser?
    let box = BrowserToolbox()
    var serving = false
    var nobodyHome = false
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
        if AgentIdle.shouldQuit(woken: woken, hidden: NSApp.isHidden, serving: serving, quiet: quiet) {
            LeaveQuit.settle()
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

    func handle(_ request: [String: Any], on connection: LineConnection) {
        guard let browser = Browsers.front ?? browser else {
            connection.send(["error": "Broadway has no window open"])
            return connection.close()
        }
        lastUsed = Date()
        switch request["op"] as? String {
        case "status":
            connection.send(status(browser))
            connection.close()
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
        case "mcp":
            var task: UUID?
            if browser.prefs.agentsAllowed {
                let held = UUID()
                let shared = ((request["agent"] as? [String: Any])?["session"] as? String).map { !$0.isEmpty } == true
                task = link(for: request, create: true, connection: shared ? nil : held, name: AgentLinks.mcpName(request["client"] as? String))?.id
                let gone = connection.onClose
                if !shared {
                    connection.onClose = {
                        gone?()
                        MainActor.assumeIsolated { AgentLinks.shared.endConnection(held) }
                    }
                } else if let task {
                    connection.onClose = {
                        gone?()
                        MainActor.assumeIsolated { AgentLinks.shared.closedShared(task) }
                    }
                }
            }
            let server = MCPServer(box: AgentSessionBox(socket: self, browser: browser), task: task) { [weak connection] message in connection?.send(message) }
            server.named = { client in
                guard let task, let name = AgentLinks.mcpName(client) else { return }
                AgentLinks.shared.rename(task, name)
            }
            if let wait = request["wait_person"] as? String { server.environment["BROADWAY_WAIT_PERSON"] = wait }
            if task != nil {
                server.person = { [weak self, weak browser] tool, arguments in
                    guard let self, let browser = browser ?? Browsers.front else { return .failure("Broadway has no window open", code: .noWindow) }
                    return await PersonTools.call(tool, arguments, link: task, browser: browser, socket: self)
                }
            }
            box.browser = browser
            connection.onLine = { line in MainActor.assumeIsolated { server.handle(line) } }
            var greeting: [String: Any] = ["mcp": true]
            if let task { greeting["link"] = task.uuidString.lowercased() }
            connection.send(greeting)
        default:
            guard !command(request, browser: browser, on: connection) else { return }
            connection.send(["error": "broadway status, open, every, mcp, tools, call, quit or serve"])
            connection.close()
        }
    }

    private func status(_ browser: Browser) -> [String: Any] {
        ["running": true, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
         "agents": browser.prefs.agentsAllowed, "hidden": NSApp.isHidden, "serving": serving, "world": Store.world ?? ""]
    }
}
