import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class SessionStatesTests {
    private var servers: [LocalPageServer] = []
    private var browsers: [Browser] = []

    init() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NetworkPath.shared.said(true)
        addTeardownBlock { await self.tearDown() }
    }

    private func tearDown() async {
        servers.forEach { $0.stop() }
        browsers.forEach { $0.closeAll() }
        browsers = []
    }

    private func serve() throws -> UInt16 {
        let page = { (name: String) in LocalPageServer.Page(type: "text/html", body: "<!doctype html><title>\(name)</title><p>\(name)</p><div style=\"height: 6000px\"></div>") }
        let server = try LocalPageServer(["/one": page("One"), "/two": page("Two")])
        servers.append(server)
        return server.port
    }

    private func browser(privately: Bool = false) -> Browser {
        let browser = Browser(record: WindowRecord(), privateStore: privately ? .nonPersistent() : nil)
        browsers.append(browser)
        return browser
    }

    private func until(_ seconds: Double = 20, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return done()
    }

    private func shows(_ path: String, _ tab: Tab) -> Bool {
        tab.committed?.path() == path && !tab.loading && tab.failure == nil && tab.built?.isLoading == false
    }

    private func onDisk(_ space: UUID = Space.firstID) -> [String: SessionStates.Kept] {
        let name = space == Space.firstID ? "session-states.plist" : "session-states-\(space.uuidString).plist"
        guard let data = try? Data(contentsOf: Store.file(name)) else { return [:] }
        return (try? PropertyListDecoder().decode([String: SessionStates.Kept].self, from: data)) ?? [:]
    }

    private func scrollY(_ tab: Tab) async -> Double? {
        guard let web = tab.built else { return nil }
        return try? await web.evaluateJavaScript("window.scrollY") as? Double
    }

    private func relaunch(after before: Browser) -> Browser {
        before.flushSession()
        Disk.drain()
        Browser.nextEra()
        SessionStates.unload()
        return browser()
    }

    private func walk(_ browser: Browser, port: UInt16) async throws -> Tab {
        let tab = browser.open(URL(string: "http://127.0.0.1:\(port)/one")!, foreground: true)
        #expect(await until { self.shows("/one", tab) })
        tab.go(to: URL(string: "http://127.0.0.1:\(port)/two")!)
        #expect(await until { self.shows("/two", tab) && tab.built?.canGoBack == true })
        return tab
    }

    @Test func aTabRestoredAfterARelaunchCanGoBack() async throws {
        let port = try serve()
        let before = browser()
        _ = try await walk(before, port: port)
        before.flushSession()
        Disk.drain()
        Browser.nextEra()
        SessionStates.unload()

        let after = browser()
        let restored = try #require(after.tabs.first { $0.address?.path() == "/two" })
        after.select(restored)

        #expect(await until { self.shows("/two", restored) && restored.built?.canGoBack == true })
        #expect(restored.built?.backForwardList.backItem?.url.path() == "/one")
    }

    @Test func aTabAsleepAtQuitCanGoBackAfterARelaunch() async throws {
        let port = try serve()
        let before = browser()
        let tab = try await walk(before, port: port)
        before.newTab()
        tab.sleep(picture: nil)
        #expect(tab.asleep)

        let after = relaunch(after: before)
        let restored = try #require(after.tabs.first { $0.address?.path() == "/two" })
        after.select(restored)

        #expect(await until { self.shows("/two", restored) && restored.built?.canGoBack == true })
        #expect(restored.built?.backForwardList.backItem?.url.path() == "/one")
    }

    @Test func aRestoredTabComesBackWhereItWasScrolled() async throws {
        let port = try serve()
        let before = browser()
        let tab = try await walk(before, port: port)
        tab.built?.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        _ = try? await tab.built?.evaluateJavaScript("window.scrollTo(0, 1200)")
        var scrolled: Double?
        for _ in 0..<100 where scrolled != 1200 {
            scrolled = await scrollY(tab)
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(scrolled == 1200)
        try? await Task.sleep(for: .milliseconds(1500))

        let after = relaunch(after: before)
        let restored = try #require(after.tabs.first { $0.address?.path() == "/two" })
        after.select(restored)
        #expect(await until { self.shows("/two", restored) })
        restored.built?.frame = NSRect(x: 0, y: 0, width: 800, height: 600)

        var landed: Double?
        let end = Date().addingTimeInterval(10)
        while Date() < end, landed != 1200 {
            landed = await scrollY(restored)
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(landed == 1200)
    }

    @Test func aPageBehindARestoredTabComesBackWhereItWasScrolled() async throws {
        let port = try serve()
        let before = browser()
        let tab = before.open(URL(string: "http://127.0.0.1:\(port)/one")!, foreground: true)
        #expect(await until { self.shows("/one", tab) })
        tab.built?.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        _ = try? await tab.built?.evaluateJavaScript("window.scrollTo(0, 1200)")
        var scrolled: Double?
        for _ in 0..<100 where scrolled != 1200 {
            scrolled = await scrollY(tab)
            try? await Task.sleep(for: .milliseconds(20))
        }
        tab.go(to: URL(string: "http://127.0.0.1:\(port)/two")!)
        #expect(await until { self.shows("/two", tab) && tab.built?.canGoBack == true })

        let after = relaunch(after: before)
        let restored = try #require(after.tabs.first { $0.address?.path() == "/two" })
        after.select(restored)
        #expect(await until { self.shows("/two", restored) && restored.built?.canGoBack == true })
        restored.built?.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        restored.built?.goBack()
        #expect(await until { self.shows("/one", restored) })

        var landed: Double?
        let end = Date().addingTimeInterval(10)
        while Date() < end, landed != 1200 {
            landed = await scrollY(restored)
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(landed == 1200)
    }

    @Test func aRestoredTabWhosePageFailsKeepsItsHistory() async throws {
        let port = try serve()
        let before = browser()
        _ = try await walk(before, port: port)
        servers.forEach { $0.stop() }

        let after = relaunch(after: before)
        let restored = try #require(after.tabs.first { $0.address?.path() == "/two" })
        let key = restored.stateKey
        #expect(onDisk()[key] != nil)
        after.select(restored)
        #expect(await until { restored.failure != nil || !restored.asleep && restored.built?.isLoading == false })
        after.writeSession(now: true)
        Disk.drain()

        #expect(onDisk()[key] != nil)
    }

    @Test func aPrivateWindowWritesNoPageHistory() async throws {
        let port = try serve()
        let shy = browser(privately: true)
        _ = try await walk(shy, port: port)
        shy.flushSession()
        Disk.drain()

        #expect(onDisk().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: Store.file("session-states.plist").path))
    }

    @Test func aClosedTabsPageHistoryLeavesTheFile() async throws {
        let port = try serve()
        let window = browser()
        let kept = try await walk(window, port: port)
        let closed = try await walk(window, port: port)
        window.writeSession(now: true)
        Disk.drain()
        let written = onDisk(window.spaceID)
        #expect(written[kept.stateKey] != nil)
        #expect(written[closed.stateKey] != nil)

        window.close(closed)
        window.writeSession(now: true)
        Disk.drain()

        let left = onDisk(window.spaceID)
        #expect(left[kept.stateKey] != nil)
        #expect(left[closed.stateKey] == nil)
    }

    @Test func anUnreadableSavedHistoryStillOpensThePage() async throws {
        let port = try serve()
        let url = "http://127.0.0.1:\(port)/two"
        let junk = ["junk": SessionStates.Kept(url: url, state: Data("not a history".utf8))]
        try PropertyListEncoder().encode(junk).write(to: Store.file("session-states.plist"))
        Session.write(now: true, Session.Shape(tabs: [Session.Entry(url: url, title: "Two", state: "junk")], active: 0))
        SessionStates.unload()

        let window = browser()
        let restored = try #require(window.tabs.first { $0.address?.path() == "/two" })
        window.select(restored)

        #expect(await until { self.shows("/two", restored) })
    }
}
