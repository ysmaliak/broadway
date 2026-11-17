import AppKit
import Darwin
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class LoadRetryWorldTests {
    private var browser: Browser!
    private var servers: [LocalPageServer] = []

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        NetworkPath.shared.said(true)
    }

    private var processes: [Process] = []
    private var folders: [URL] = []

    private func tearDown() async {
        servers.forEach { $0.stop() }
        for process in processes where process.isRunning { process.terminate() }
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        browser?.closeAll()
        browser = nil
    }

    private let body = "<!doctype html><title>Back again</title><p>Here</p>"

    private func freePort() throws -> UInt16 {
        let probe = try LocalPageServer([:])
        let port = probe.port
        probe.stop()
        return port
    }

    private func serve(on port: UInt16) throws -> LocalPageServer {
        let server = try LocalPageServer(["/page": .init(type: "text/html", body: body)], port: port)
        servers.append(server)
        return server
    }

    private func until(_ seconds: Double = 20, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    private func arrived(_ tab: Tab) -> Bool {
        tab.committed?.path() == "/page" && tab.failure == nil && !tab.loading
    }

    private func run(_ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func listening(_ port: UInt16) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { Darwin.close(socket) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static let secureServer = """
    import ssl, sys
    from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            body = b"<!doctype html><title>Secure</title><p>Here</p>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        def handle(self):
            try:
                super().handle()
            except Exception:
                pass
        def log_message(self, *a):
            pass
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[2], sys.argv[3])
    server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    server.serve_forever()
    """

    private func httpsOnly(on port: UInt16) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-https-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        folders.append(folder)
        try run(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem",
                 "-days", "1", "-subj", "/CN=localhost"], in: folder)
        try Self.secureServer.write(to: folder.appendingPathComponent("serve.py"), atomically: true, encoding: .utf8)
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        server.arguments = ["-I", "serve.py", "\(port)", "cert.pem", "key.pem"]
        server.currentDirectoryURL = folder
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        try server.run()
        processes.append(server)
        #expect(await until(10) { self.listening(port) })
    }

    private func networkReturns() {
        NetworkPath.shared.said(false)
        NetworkPath.shared.said(true)
    }

    @Test func theTabInFrontLoadsWhenTheNetworkComesBack() async throws {
        let port = try freePort()
        let front = browser.open(URL(string: "http://127.0.0.1:\(port)/page")!, foreground: true)
        #expect(await until { front.failure != nil && front.waitingForNetwork })

        let server = try serve(on: port)
        networkReturns()

        #expect(await until { self.arrived(front) })
        #expect(server.requests.contains("/page"))
        #expect(!front.waitingForNetwork)
    }

    @Test func aTabBehindLoadsWhenItComesToTheFront() async throws {
        let port = try freePort()
        let front = browser.open(URL(string: "about:blank")!, foreground: true)
        let behind = browser.open(URL(string: "http://127.0.0.1:\(port)/page")!, foreground: false)
        #expect(browser.activeID == front.id)
        #expect(await until { behind.failure != nil && behind.waitingForNetwork })
        let server = try serve(on: port)

        networkReturns()
        try? await Task.sleep(for: .milliseconds(800))
        let askedBehind = server.requests.contains("/page")
        let owed = behind.retry.network.owed
        browser.select(behind)

        #expect(!askedBehind)
        #expect(owed)
        #expect(await until { self.arrived(behind) })
    }

    @Test func anAgentsTabDoesNotLoadAgain() async throws {
        let port = try freePort()
        let agent = browser.open(URL(string: "http://127.0.0.1:\(port)/page")!, foreground: true)
        agent.agent = true
        #expect(await until { agent.failure != nil && !agent.loading })
        let server = try serve(on: port)

        networkReturns()
        try? await Task.sleep(for: .milliseconds(1200))

        #expect(!agent.waitingForNetwork)
        #expect(!server.requests.contains("/page"))
        #expect(agent.failure != nil)
    }

    @Test func aTypedLocalAddressThatSpeaksOnlyHttpsLandsOnHttps() async throws {
        let port = try freePort()
        try await httpsOnly(on: port)
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        browser.edit()

        browser.typed = "127.0.0.1:\(port)/page"
        browser.submit()

        #expect(await until { tab.committed?.scheme == "https" && tab.failure == nil && !tab.loading })
        #expect(tab.committed?.absoluteString == "https://127.0.0.1:\(port)/page")
    }

    @Test func aLocalAddressWhereNothingAnswersShowsItsHttpFailure() async throws {
        let port = try freePort()
        let http = URL(string: "http://127.0.0.1:\(port)/page")!

        let tab = browser.open(http, foreground: true)

        #expect(await until { tab.failure != nil && !tab.loading && tab.waitingForNetwork })
        #expect(tab.address == http)
        #expect(tab.failure == TroubleKind.refused.message)
        #expect(tab.retry.tryAgainAt == http)
    }

    @Test func tryAgainOnAHeldHttpAddressLoadsItOnce() async throws {
        let port = try freePort()
        let http = URL(string: "http://127.0.0.1:\(port)/page")!
        let tab = browser.open(http, foreground: true)
        #expect(await until { tab.failure != nil && !tab.loading && tab.retry.tryAgainAt == http })
        let server = try serve(on: port)

        tab.reload()

        #expect(await until { self.arrived(tab) })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(server.requests.filter { $0 == "/page" }.count == 1)
        #expect(!tab.waitingForNetwork)
        #expect(tab.retry.tryAgainAt == nil)
    }

    @Test func aLinkToANameThatFailsIsNotRewritten() async throws {
        let target = "https://shop.example.invalid/"
        let server = try LocalPageServer(["/links": .init(type: "text/html",
                                                          body: "<!doctype html><title>Links</title><a id='go' href='\(target)'>Shop</a>")])
        servers.append(server)
        let tab = browser.open(server.url("/links"), foreground: true)
        #expect(await until { tab.committed?.path() == "/links" && !tab.loading })
        var asked: [String] = []
        let watch = kitObserve(initial: false, { tab.address }) { url in
            if let host = url?.host() { asked.append(host) }
        }

        _ = try? await tab.web.evaluateJavaScript("document.getElementById('go').click()")

        #expect(await until { tab.failure != nil && !tab.loading })
        try? await Task.sleep(for: .milliseconds(500))
        #expect(tab.retry.detour == nil)
        #expect(!asked.contains { $0.hasPrefix("www.") })
        #expect(asked.contains("shop.example.invalid"))
        _ = watch
    }

    @Test func aTypedNameThatFailsAtBothNamesShowsTheTypedOne() async throws {
        keepSiteNames()
        let tab = browser.open(URL(string: "about:blank")!, foreground: true)
        browser.edit()
        var asked: [String] = []
        let watch = kitObserve(initial: false, { tab.address }) { url in
            if let host = url?.host() { asked.append(host) }
        }

        browser.typed = "shop.example.invalid"
        browser.submit()

        #expect(await until { tab.failure != nil && !tab.loading && tab.retry.detour == nil && asked.contains("www.shop.example.invalid") })
        _ = watch
        #expect(tab.address?.absoluteString == "https://shop.example.invalid")
        #expect(tab.failure == TroubleKind.notFound.message)
        #expect(tab.retry.tryAgainAt?.absoluteString == "https://shop.example.invalid")
        #expect(SiteNameBook.all.isEmpty)
    }

    private func keepSiteNames() {
        SiteNameBook.forget()
        addTeardownBlock { SiteNameBook.forget() }
    }

    @Test func clearingHistoryForgetsTheRememberedNames() {
        keepSiteNames()
        SiteNameBook.committed(at: "www.example.com",
                               after: Detour(kind: .otherName, from: URL(string: "https://example.com/")!,
                                             to: URL(string: "https://www.example.com/")!, failure: nil, waits: nil),
                               privately: false)
        let before = SiteNameBook.sent(URL(string: "https://example.com/")!)

        browser.clearHistory()

        #expect(before.absoluteString == "https://www.example.com/")
        #expect(SiteNameBook.all.isEmpty)
        #expect(SiteNameBook.sent(URL(string: "https://example.com/")!).absoluteString == "https://example.com/")
    }
}
