import AppKit
import Darwin
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class TaskDoorTests {
    private static let removed = ["sign_in", "autofill", "helper_start", "helper_wait", "mac_read", "mac_run", "remember", "profile_found", "address_found", "suggest", "brief", "memory_search", "memory_read"]

    private var browser: Browser!
    private var socket: AgentSocket!
    private var made: [UUID] = []
    private var ends: [Int32] = []

    init() throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        let mine = Tab(configuration: Web.configuration(space: browser.spaceID))
        mine.restore(url: URL(string: "https://example.com/mine")!, title: "Mine")
        browser.showRow([mine], active: mine.id)
        Browsers.register(browser)
        socket = AgentSocket()
        socket.box.browser = browser
        browser.prefs.agentMode = .bypass
        browser.prefs.agentsOn = true
    }

    private func tearDown() {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for id in made {
            TaskLedger.shared.close(id)
            AgentLinks.shared.forget(id)
        }
        for end in ends { Darwin.close(end) }
        if let browser { Browsers.forget(browser) }
        browser?.closeAll()
        browser = nil
    }

    private func pair() throws -> (LineConnection, Int32) {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        ends.append(fds[1])
        return (LineConnection(fd: fds[0]), fds[1])
    }

    private var buffered: [Int32: Data] = [:]

    private func next(_ fd: Int32, where wanted: ([String: Any]) -> Bool = { _ in true }) async -> [String: Any]? {
        for _ in 0..<2000 {
            var bytes = buffered[fd] ?? Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            let read = Darwin.read(fd, &chunk, chunk.count)
            if read > 0 { bytes.append(contentsOf: chunk[0..<read]) }
            while let newline = bytes.firstIndex(of: 0x0A) {
                let line = bytes[bytes.startIndex..<newline]
                bytes = Data(bytes[bytes.index(after: newline)...])
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any], wanted(object) {
                    buffered[fd] = bytes
                    return object
                }
            }
            buffered[fd] = bytes
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func hello(_ request: [String: Any]) async throws -> (connection: LineConnection, fd: Int32, greeting: [String: Any]) {
        let (connection, fd) = try pair()
        socket.handle(request, on: connection)
        let greeting = try #require(await next(fd))
        if let link = (greeting["link"] as? String).flatMap(UUID.init(uuidString:)) { made.append(link) }
        return (connection, fd, greeting)
    }

    private func rpc(_ connection: LineConnection, _ fd: Int32, id: Int, _ method: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        connection.onLine?(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        if let answer = await next(fd, where: { ($0["id"] as? Int) == id }) { return answer }
        Issue.record("no answer to \(method)")
        return [:]
    }

    private func names(_ listed: [String: Any]) -> Set<String> {
        Set(((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
    }

    @Test func anMCPHelloThatNamesATaskIsAFreshOutsideAgent() async throws {
        let named = UUID()
        let plain = try await hello(["op": "mcp", "agent": [String: Any]()])
        let tasked = try await hello(["op": "mcp", "agent": [String: Any](), "task": named.uuidString])
        defer { plain.connection.close(); tasked.connection.close() }

        let link = try #require((tasked.greeting["link"] as? String).flatMap(UUID.init(uuidString:)))
        let plainList = try await rpc(plain.connection, plain.fd, id: 1, "tools/list")
        let taskedList = try await rpc(tasked.connection, tasked.fd, id: 1, "tools/list")
        let run = try await rpc(tasked.connection, tasked.fd, id: 2, "tools/call", ["name": "mac_run", "arguments": ["command": "true", "reason": "x"]])

        #expect(tasked.greeting["mcp"] as? Bool == true)
        #expect(link != named)
        #expect(TaskLedger.shared.entry(link) != nil)
        #expect(TaskLedger.shared.entry(named) == nil)
        #expect(AgentLinks.shared.link(named) == nil)
        #expect(!names(taskedList).isEmpty)
        #expect(names(taskedList) == names(plainList))
        #expect((run["error"] as? [String: Any])?["code"] as? Int == -32602)
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func aTaskWithAgentsOffIsNobody() async throws {
        browser.prefs.agentsOn = false
        let tasked = try await hello(["op": "mcp", "agent": [String: Any](), "task": UUID().uuidString])
        defer { tasked.connection.close() }

        let listed = try await rpc(tasked.connection, tasked.fd, id: 1, "tools/list")
        let run = try await rpc(tasked.connection, tasked.fd, id: 2, "tools/call", ["name": "tabs", "arguments": [String: Any]()])

        #expect(tasked.greeting["link"] == nil)
        #expect(names(listed).isEmpty)
        #expect(((run["result"] as? [String: Any])?["isError"] as? Bool) == true)
    }

    @Test func anMCPConnectionMadeWithAgentsOffTakesASessionAtItsFirstCallOnceTheyAreOn() async throws {
        browser.prefs.agentsOn = false
        let connected = try await hello(["op": "mcp", "agent": [String: Any]()])
        defer { connected.connection.close() }
        browser.prefs.agentsOn = true
        let before = Set(AgentLinks.shared.live.map(\.id))

        connected.connection.onLine?(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": "tabs", "arguments": [String: Any]()]])
        let changed = await next(connected.fd) { $0["method"] as? String != nil }
        let answer = try #require(await next(connected.fd) { ($0["id"] as? Int) == 1 })
        let joined = AgentLinks.shared.live.map(\.id).filter { !before.contains($0) }
        made += joined

        #expect(connected.greeting["link"] == nil)
        #expect(changed?["method"] as? String == "notifications/tools/list_changed")
        #expect(((answer["result"] as? [String: Any])?["isError"] as? Bool) != true)
        #expect(joined.count == 1)
        #expect(joined.first.map { TaskLedger.shared.entry($0) != nil } == true)
    }

    @Test func aRunningWatchEndsWithOneLineWhenThePersonSwitchesToAsk() async throws {
        browser.prefs.agentMode = .auto
        let (connection, fd) = try pair()
        var closed = false
        connection.onClose = { closed = true }
        socket.handle(["op": "watch", "only": ["spaces"]], on: connection)
        let started = try #require(await next(fd))

        browser.prefs.agentMode = .ask
        let last = try #require(await next(fd) { $0["error"] != nil })
        for _ in 0..<200 where !closed { try? await Task.sleep(for: .milliseconds(5)) }

        #expect((started["data"] as? [String: Any])?["watching"] as? Bool == true)
        #expect((last["error"] as? [String: Any])?["message"] as? String == "Agents are set to Ask now, so watching stopped")
        #expect(closed)
    }

    @Test func aRemovedToolIsAnUnknownToolForAnOutsideAgentAndForAMadeUpTask() async throws {
        let link = AgentLinks.shared.join(.named(UUID().uuidString), name: "Claude Code")
        TaskLedger.shared.open(link.id, title: "Claude Code")
        made.append(link.id)
        var answers: [String: [String: Any]] = [:]
        for (caller, task) in [("outside", link.id), ("made up", UUID())] {
            var sent: [[String: Any]] = []
            let server = MCPServer(box: AgentSessionBox(socket: socket, browser: browser), task: task) { sent.append($0) }
            for (index, name) in (Self.removed + ["no_such_tool"]).enumerated() {
                server.handle(["jsonrpc": "2.0", "id": index, "method": "tools/call", "params": ["name": name, "arguments": ["tab": "x"]] as [String: Any]])
                for _ in 0..<200 where !sent.contains(where: { ($0["id"] as? Int) == index }) { try? await Task.sleep(for: .milliseconds(5)) }
                answers["\(caller) \(name)"] = sent.first { ($0["id"] as? Int) == index }
            }
        }

        for caller in ["outside", "made up"] {
            let unknown = try #require(answers["\(caller) no_such_tool"]?["error"] as? [String: Any])
            for name in Self.removed {
                let said = try #require(answers["\(caller) \(name)"]?["error"] as? [String: Any], "\(caller) \(name)")
                #expect(said["code"] as? Int == unknown["code"] as? Int, "\(caller) \(name)")
                #expect((said["message"] as? String)?.replacingOccurrences(of: name, with: "no_such_tool") == unknown["message"] as? String, "\(caller) \(name)")
            }
        }
        #expect(AgentDesk.shared.pending.isEmpty)
    }

    @Test func aRemovedToolOnTheSocketIsAnUnknownTool() async throws {
        var answers: [String: [String: Any]] = [:]
        for name in Self.removed + ["no_such_tool"] {
            let (connection, fd) = try pair()
            socket.handle(["op": "call", "tool": name, "arguments": ["tab": "x"], "agent": ["id": "door"]], on: connection)
            answers[name] = try #require(await next(fd), "\(name)")
        }
        let unknown = try #require(answers["no_such_tool"]?["error"] as? [String: Any])

        for name in Self.removed {
            let said = try #require(answers[name]?["error"] as? [String: Any], "\(name)")
            #expect(said["code"] as? String == unknown["code"] as? String, "\(name)")
            #expect((said["message"] as? String)?.replacingOccurrences(of: name, with: "no_such_tool") == unknown["message"] as? String, "\(name)")
        }
        #expect(BrowserToolbox().tools.allSatisfy { !Self.removed.contains($0.name) })
        #expect(AgentCatalog.shapes.keys.allSatisfy { !Self.removed.contains($0) })
        #expect(AgentDesk.shared.pending.isEmpty)
    }
}
