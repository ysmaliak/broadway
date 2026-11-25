import AppKit
import Darwin
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class AgentWindowTests {
    private var socket: AgentSocket!
    private var server: LocalPageServer!
    private var made: [Browser] = []
    private var windows: [NSWindow] = []
    private var ends: [Int32] = []
    private var buffered: [Int32: Data] = [:]
    private let before = Front.shared.browser

    init() throws {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        keepSetting(Shared.prefs, \.usesSpaces, "spaces")
        keepSetting(Shared.prefs, \.agentsOn, "agents.on")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Shared.prefs.agentMode = .auto
        Shared.prefs.agentsOn = true
        Shared.prefs.usesSpaces = true
        AgentSites.shared.reset()
        socket = AgentSocket()
        server = try LocalPageServer([
            "/shop": .init(type: "text/html", body: "<!doctype html><title>Shop</title><h1>Shop</h1>"),
        ])
    }

    private func tearDown() {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        for link in AgentLinks.shared.links where link.key == .named("window-test") || link.key == .named("window-other") {
            TaskLedger.shared.close(link.id)
            AgentLinks.shared.forget(link.id)
        }
        for end in ends { Darwin.close(end) }
        for browser in made {
            Browsers.forget(browser)
            browser.closeAll()
        }
        for window in windows { window.orderOut(nil) }
        Front.shared.set(before)
        AgentSites.shared.reset()
        server?.stop()
    }

    private func window(private secret: Bool = false, popup: Bool = false, register: Bool = true) -> Browser {
        let browser = secret ? Browser(record: WindowRecord(), privateStore: .nonPersistent()) : Browser(record: WindowRecord())
        if popup { browser.extensionPopup = "some-extension" }
        let frame = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        frame.isReleasedWhenClosed = false
        windows.append(frame)
        browser.window = frame
        made.append(browser)
        if register { Browsers.register(browser) }
        return browser
    }

    private func pair() throws -> (LineConnection, Int32) {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        ends.append(fds[1])
        return (LineConnection(fd: fds[0]), fds[1])
    }

    private func next(_ fd: Int32) async -> [String: Any]? {
        for _ in 0..<2000 {
            var bytes = buffered[fd] ?? Data()
            var chunk = [UInt8](repeating: 0, count: 65536)
            let read = Darwin.read(fd, &chunk, chunk.count)
            if read > 0 { bytes.append(contentsOf: chunk[0..<read]) }
            if let newline = bytes.firstIndex(of: 0x0A) {
                let line = bytes[bytes.startIndex..<newline]
                buffered[fd] = Data(bytes[bytes.index(after: newline)...])
                return try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            }
            buffered[fd] = bytes
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    private func send(_ request: [String: Any], agent: String = "window-test") async throws -> [String: Any] {
        let (connection, fd) = try pair()
        var request = request
        request["agent"] = ["id": agent]
        socket.handle(request, on: connection)
        return try #require(await next(fd))
    }

    private func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        try await send(["op": "call", "tool": tool, "arguments": arguments])
    }

    private func data(_ reply: [String: Any]) -> [String: Any] { reply["data"] as? [String: Any] ?? [:] }

    private func code(_ reply: [String: Any]) -> String? { (reply["error"] as? [String: Any])?["code"] as? String }

    private var shop: String { "http://127.0.0.1:\(server.port)/shop" }

    @Test func aPrivateWindowInFrontDoesNotTakeAnAgentsTab() async throws {
        let ordinary = window()
        let secret = window(private: true)
        Front.shared.set(secret)

        let opened = try await call("open", ["url": shop])
        let id = try #require(data(opened)["id"] as? String, "\(opened)")
        let listed = try await call("tabs")
        let read = try await call("snapshot", ["tab": id])
        let current = try await call("snapshot")

        #expect(opened["ok"] as? Bool == true)
        #expect(ordinary.tabs.contains { AgentWorkTabs.short($0.id) == id })
        #expect(!secret.tabs.contains { $0.agent })
        #expect((data(listed)["tabs"] as? [[String: Any]] ?? []).contains { $0["id"] as? String == id }, "\(listed)")
        #expect(read["ok"] as? Bool == true, "\(read)")
        #expect(current["ok"] as? Bool == true, "\(current)")
        #expect(Front.shared.browser === secret)
    }

    @Test func spacesAnswerForTheOrdinaryWindowWhenAPrivateOneIsInFront() async throws {
        let ordinary = window()
        let secret = window(private: true)
        Front.shared.set(secret)
        let name = try #require(ordinary.spaces.first?.name)

        let spaces = try await send(["op": "do", "noun": "spaces", "verb": "list", "arguments": [String: Any]()])
        let opened = try await call("open", ["url": shop, "space": name])

        #expect(spaces["ok"] as? Bool == true, "\(spaces)")
        #expect(opened["ok"] as? Bool == true, "\(opened)")
        #expect(code(opened) == nil)
        #expect(!secret.tabs.contains { $0.agent })
    }

    @Test func aPopupInFrontDoesNotTakeAnAgentsTab() async throws {
        let ordinary = window()
        let popup = window(popup: true)
        Front.shared.set(popup)

        let opened = try await call("open", ["url": shop])
        let id = try #require(data(opened)["id"] as? String, "\(opened)")

        #expect(ordinary.tabs.contains { AgentWorkTabs.short($0.id) == id })
        #expect(!popup.tabs.contains { $0.agent })
    }

    @Test func withTwoOrdinaryWindowsTheFrontOneTakesTheTab() async throws {
        let older = window()
        let newer = window()
        Front.shared.set(older)

        let opened = try await call("open", ["url": shop])
        let id = try #require(data(opened)["id"] as? String, "\(opened)")

        #expect(older.tabs.contains { AgentWorkTabs.short($0.id) == id })
        #expect(!newer.tabs.contains { $0.agent })
    }

    @Test func theAgentsWindowIsTheFrontOneWhenItIsOrdinaryAndElseTheNewestOrdinaryOne() {
        let older = window(register: false)
        let newer = window(register: false)
        let secret = window(private: true, register: false)
        let popup = window(popup: true, register: false)
        let shut = window(register: false)
        shut.shut = true

        #expect(Browsers.forAgents(front: older, among: [older, newer, secret]) === older)
        #expect(Browsers.forAgents(front: secret, among: [older, newer, secret]) === newer)
        #expect(Browsers.forAgents(front: popup, among: [older, popup]) === older)
        #expect(Browsers.forAgents(front: nil, among: [older, newer, secret]) === newer)
        #expect(Browsers.forAgents(front: secret, among: [secret]) == nil)
        #expect(Browsers.forAgents(front: secret, among: [shut, secret]) == nil)
        #expect(Browsers.forAgents(front: shut, among: [older, shut]) === older)
        #expect(Browsers.forAgents(front: nil, among: []) == nil)
    }

    @Test func aTabAgentsCannotReachIsNeverAnsweredWithItsID() {
        let secret = window(private: true)
        let tab = secret.benchOpen(URL(string: shop)!)
        tab.agent = true

        let box = BrowserToolbox()
        box.browser = secret
        let refused = box.unreachable(tab)

        #expect(refused?.failed == true)
        #expect(refused?.code == "no_window")
        #expect(refused?.text?.contains(AgentWorkTabs.short(tab.id)) == false)
    }
}
