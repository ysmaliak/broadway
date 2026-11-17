import AppKit
import Darwin
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .serialized, .timeLimit(.minutes(5)))
@MainActor
final class SiteFilesWorldTests {
    private var browser: Browser!
    private var server: LocalPageServer!
    private var window: NSWindow!
    private var root: URL!
    private var folder: URL!
    private var restore: (() -> Void)?
    private var processes: [Process] = []

    private static let cover = "style=\"position:fixed;inset:0;display:block;background:#eee\""

    private static func file(_ name: String) -> LocalPageServer.Page {
        .init(type: "application/zip", body: String(repeating: "file \(name)\n", count: 32),
              headers: ["Content-Disposition": "attachment; filename=\"\(name)\""])
    }

    private static func page(_ body: String) -> LocalPageServer.Page {
        .init(type: "text/html", body: "<!doctype html><meta charset=utf-8><title>files</title>\(body)")
    }

    init() async throws {
        addTeardownBlock { try await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        server = try LocalPageServer([
            "/link": Self.page("<a id=go href=\"/file/clicked.zip\" \(Self.cover)>Download</a>"),
            "/timer": Self.page("<script>setTimeout(() => { location.href = '/file/timer.zip' }, 300)</script><p>Wait</p>"),
            "/timer-again": Self.page("<script>setTimeout(() => { location.href = '/file/again.zip' }, 300)</script><p>Wait</p>"),
            "/more": Self.page("""
            <a id=go href="/file/first.zip" download \(Self.cover)>Download</a>
            <script>
            const fetch = name => { const a = document.createElement('a'); a.href = '/file/' + name; a.download = name; document.body.appendChild(a); a.click(); };
            document.getElementById('go').addEventListener('click', () => {
              setTimeout(() => fetch('second.zip'), 500);
              setTimeout(() => fetch('third.zip'), 1200);
            });
            </script>
            """),
            "/file/clicked.zip": Self.file("clicked.zip"),
            "/file/timer.zip": Self.file("timer.zip"),
            "/file/again.zip": Self.file("again.zip"),
            "/file/first.zip": Self.file("first.zip"),
            "/file/second.zip": Self.file("second.zip"),
            "/file/third.zip": Self.file("third.zip"),
            "/file/report.zip": Self.file("report.zip"),
            "/file/next.zip": Self.file("next.zip"),
        ])
        SiteFileAsk.shared.forgetAll()
        browser = Browser(record: WindowRecord())
        browser.closeAll()
        let prefs = browser.prefs
        let saved = (prefs.downloads, prefs.asksWhereToSave)
        let folders = Store.settings.object(forKey: SaveAsk.foldersKey)
        restore = {
            (prefs.downloads, prefs.asksWhereToSave) = saved
            Store.settings.set(folders, forKey: SaveAsk.foldersKey)
        }
        browser.loot.forgetAll()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("broadway-site-files-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        prefs.downloads = folder
        prefs.asksWhereToSave = false
        window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 800, height: 600),
                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        window.orderFrontRegardless()
        browser.window = window
    }

    private func tearDown() async throws {
        SiteFileAsk.shared.cancelAll()
        SiteFileAsk.shared.publicHosts = []
        SiteFileAsk.shared.forgetAll()
        SaveAsk.shared.cancelAll()
        if let browser {
            for entry in browser.fetches.entries { browser.cancelDownload(entry) }
            _ = await until(10) { browser.fetches.entries.isEmpty && browser.downloading.isEmpty }
            browser.closeAll()
            browser.loot.forgetAll()
        }
        for process in processes where process.isRunning { process.terminate() }
        server?.stop()
        window?.contentView = nil
        window?.orderOut(nil)
        window?.close()
        if let root { try? FileManager.default.removeItem(at: root) }
        restore?()
        browser = nil
        window = nil
    }

    private func until(_ seconds: Double = 20, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    private func open(_ url: URL) async throws -> Tab {
        let tab = browser.open(url, foreground: true)
        let page = tab.web
        page.frame = window.contentView!.bounds
        window.contentView!.addSubview(page)
        #expect(await until { tab.committed != nil && !tab.loading })
        return tab
    }

    private func click(_ tab: Tab) async throws {
        try await Task.sleep(for: .milliseconds(200))
        let page = tab.web
        let rect = page.convert(page.bounds, to: nil)
        let point = NSPoint(x: rect.midX, y: rect.midY)
        let number = Int.random(in: 1...Int(Int32.max))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0))
            window.sendEvent(event)
        }
    }

    private func landed(_ name: String) -> Bool {
        browser.loot.kept.contains { $0.name == name } && FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    private func card(_ tab: Tab) -> FileCard? { SiteFileAsk.shared.card(for: tab.id) }

    private func gone(_ name: String) -> Bool {
        !FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
            && !browser.loot.kept.contains { $0.name == name } && browser.fetches.entries.isEmpty && browser.downloading.isEmpty
    }

    @Test func aClickedLinkDownloadsWithoutAQuestion() async throws {
        let tab = try await open(server.url("/link"))

        try await click(tab)

        #expect(await until { self.landed("clicked.zip") })
        #expect(SiteFileAsk.shared.cards.isEmpty)
    }

    @Test func aTimerAsksAllowLandsTheFileAndTheSiteIsNotAskedAgain() async throws {
        let tab = try await open(server.url("/timer"))
        #expect(await until { self.card(tab) != nil })
        let asked = card(tab)
        #expect(asked?.title == "\u{201C}127.0.0.1\u{201D} wants to download a file")
        #expect(asked?.text == "timer.zip")
        #expect(browser.fetches.dockLoads.allSatisfy { !$0.underWay })

        browser.answerFileCard(allow: true)

        #expect(await until { self.landed("timer.zip") })
        tab.go(to: server.url("/timer-again"))
        #expect(await until { self.landed("again.zip") })
        #expect(SiteFileAsk.shared.cards.isEmpty)
    }

    @Test func dontAllowLeavesNoFileNoEntryAndNoFailure() async throws {
        let tab = try await open(server.url("/timer"))
        #expect(await until { self.card(tab) != nil })

        browser.answerFileCard(allow: false)

        #expect(await until { self.gone("timer.zip") })
        try await Task.sleep(for: .milliseconds(600))
        #expect(gone("timer.zip"))
        #expect(browser.announcement?.contains("didn't finish") != true)
        #expect(SiteFileAsk.shared.cards.isEmpty)
    }

    @Test func aClickAndTwoMoreFilesAskOnceForTheRest() async throws {
        let tab = try await open(server.url("/more"))

        try await click(tab)

        #expect(await until { self.landed("first.zip") })
        #expect(await until { self.card(tab)?.names.count == 2 })
        #expect(card(tab)?.title == "\u{201C}127.0.0.1\u{201D} wants to download more files")
        #expect(card(tab)?.text == nil)
        #expect(SiteFileAsk.shared.cards[tab.id]?.cards.count == 1)
        browser.answerFileCard(allow: true)
        #expect(await until { self.landed("second.zip") && self.landed("third.zip") })
    }

    @Test func anAgentsDownloadNeverAsks() async throws {
        let tab = browser.open(server.url("/link"), foreground: true)
        tab.agent = true
        #expect(await until { tab.committed != nil && !tab.loading })

        tab.go(to: server.url("/timer"))

        #expect(await until { self.browser.loot.kept.contains { $0.name == "timer.zip" } || self.browser.fetches.entries.contains { $0.name == "timer.zip" } })
        #expect(SiteFileAsk.shared.cards.isEmpty)
    }

    @Test func withAskEachTimeTheSiteQuestionComesBeforeTheSaveQuestion() async throws {
        browser.prefs.asksWhereToSave = true
        let tab = try await open(server.url("/timer"))
        #expect(await until { self.card(tab) != nil })
        #expect(SaveAsk.shared.questions.isEmpty)

        browser.answerFileCard(allow: true)

        #expect(await until { SaveAsk.shared.questions.contains { $0.up } })
        #expect(SaveAsk.shared.questions.first?.name == "timer.zip")
        let target = root.appendingPathComponent("picked.zip")
        #expect(SaveAsk.shared.answer(target))
        #expect(await until { FileManager.default.fileExists(atPath: target.path) && self.browser.loot.kept.contains { $0.path == target.path } })
    }

    @Test func aBackgroundTabKeepsItsQuestionUntilItComesToTheFront() async throws {
        let front = try await open(server.url("/link"))
        let back = browser.open(server.url("/timer"), foreground: false)

        #expect(await until { SiteFileAsk.shared.cards[back.id] != nil })
        #expect(SiteFileAsk.shared.card(for: browser.activeID) == nil)
        #expect(browser.activeID == front.id)
        browser.select(back)

        #expect(SiteFileAsk.shared.card(for: browser.activeID)?.text == "timer.zip")
    }

    private static let secureServer = """
    import ssl, sys
    from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
    page = open(sys.argv[4], "rb").read()
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)
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

    private func freePort() throws -> UInt16 {
        let probe = try LocalPageServer([:])
        let port = probe.port
        probe.stop()
        return port
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

    private func securePage(linking path: String) async throws -> URL {
        let port = try freePort()
        let place = root.appendingPathComponent("https-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let openssl = Process()
        openssl.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        openssl.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "key.pem", "-out", "cert.pem",
                             "-days", "1", "-subj", "/CN=localhost"]
        openssl.currentDirectoryURL = place
        openssl.standardOutput = FileHandle.nullDevice
        openssl.standardError = FileHandle.nullDevice
        try openssl.run()
        openssl.waitUntilExit()
        let html = "<!doctype html><meta charset=utf-8><title>secure</title><a id=go href=\"\(server.url(path).absoluteString)\" \(Self.cover)>Download</a>"
        try html.write(to: place.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        try Self.secureServer.write(to: place.appendingPathComponent("serve.py"), atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "serve.py", "\(port)", "cert.pem", "key.pem", "page.html"]
        process.currentDirectoryURL = place
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        processes.append(process)
        #expect(await until(10) { self.listening(port) })
        return URL(string: "https://127.0.0.1:\(port)/page")!
    }

    @Test func aLocalHttpFileFromAnHttpsPageIsNotAskedAbout() async throws {
        let tab = try await open(try await securePage(linking: "/file/report.zip"))
        #expect(tab.committed?.scheme == "https")

        try await click(tab)

        #expect(await until { self.landed("report.zip") })
        #expect(SiteFileAsk.shared.cards.isEmpty)
    }

    @Test func aClickedHttpFileFromAnHttpsPageAsksAndDownloadAnywayLandsIt() async throws {
        SiteFileAsk.shared.publicHosts = ["127.0.0.1"]
        let tab = try await open(try await securePage(linking: "/file/report.zip"))

        try await click(tab)

        #expect(await until { self.card(tab) != nil })
        let asked = card(tab)
        #expect(asked?.kind == .insecure)
        #expect(asked?.title == "This file is not sent securely")
        #expect(asked?.text == "\u{201C}report.zip\u{201D} from \u{201C}127.0.0.1\u{201D} could be read or changed on the way")
        #expect(asked?.allow == "Download Anyway")
        #expect(asked?.deny == "Don't Download")
        browser.answerFileCard(allow: true)
        #expect(await until { self.landed("report.zip") })
    }

    @Test func dontDownloadLeavesNoFileAndTheNextFileAsksAgain() async throws {
        SiteFileAsk.shared.publicHosts = ["127.0.0.1"]
        let tab = try await open(try await securePage(linking: "/file/report.zip"))

        try await click(tab)
        #expect(await until { self.card(tab)?.kind == .insecure })
        #expect(browser.escapeFileCard())

        #expect(await until { self.gone("report.zip") })
        try await click(tab)
        #expect(await until { self.card(tab)?.kind == .insecure })
        browser.answerFileCard(allow: true)
        #expect(await until { self.landed("report.zip") })
        try await click(tab)
        #expect(await until { self.card(tab)?.kind == .insecure })
    }
}
