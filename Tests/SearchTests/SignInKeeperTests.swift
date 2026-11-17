import AppKit
import Foundation
import Testing
import WebKit
@testable import Search

@Suite("Kept sign-ins", .sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SignInKeeperTests {
    final class Counted: SignInShelf, @unchecked Sendable {
        let inner: FolderShelf
        let pause: TimeInterval
        private let lock = NSLock()
        private var writes = 0

        init(_ inner: FolderShelf, pause: TimeInterval = 0) {
            self.inner = inner
            self.pause = pause
        }

        var written: Int { lock.withLock { writes } }

        func read(_ account: String) -> Data? {
            if pause > 0 { Thread.sleep(forTimeInterval: pause) }
            return inner.read(account)
        }

        func write(_ data: Data, as account: String) -> Bool {
            lock.withLock { writes += 1 }
            return inner.write(data, as: account)
        }

        func remove(_ account: String) { inner.remove(account) }
        func accounts() -> [String] { inner.accounts() }
    }

    private func shelf() -> FolderShelf {
        let folder = Store.file("sign-ins-test-\(UUID().uuidString.prefix(8))")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return FolderShelf(folder: folder)
    }

    private func keeper(_ shelf: SignInShelf, shared: Bool = false) -> SignInKeeper {
        let keeper = SignInKeeper(shelf: shelf)
        keeper.fresh = { false }
        if shared {
            let before = SignInKeeper.shared
            SignInKeeper.shared = keeper
            addTeardownBlock { SignInKeeper.shared = before }
        }
        return keeper
    }

    private func ownStore() -> (WKWebsiteDataStore, UUID) {
        let id = UUID()
        addTeardownBlock { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        return (WKWebsiteDataStore(forIdentifier: id), id)
    }

    private func cookie(_ name: String, _ value: String = "signed-in", domain: String = "shop.example.test",
                        expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: "/"]
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private func names(_ store: WKWebsiteDataStore) async -> Set<String> {
        Set(await store.httpCookieStore.allCookies().map(\.name))
    }

    private func kept(_ shelf: SignInShelf, _ key: UUID) -> [SignInKeeping.Crumb] {
        guard case .putBack(_, let crumbs) = SignInKeeping.reading(shelf.read(key.uuidString), now: Date(), fresh: false) else { return [] }
        return crumbs
    }

    private func until(_ seconds: TimeInterval = 5, _ done: () async -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await done() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await done()
    }

    private func shelve(_ cookies: [HTTPCookie], on shelf: SignInShelf, as key: UUID, written: Date = Date()) {
        let crumbs = Set(cookies.map(SignInKeeper.crumb(of:)))
        _ = shelf.write(SignInKeeping.encode(crumbs, at: written)!, as: key.uuidString)
    }

    @Test func aSessionCookieIsBackAfterTheStoreIsThrownAwayAndMadeAgain() async {
        let shelf = shelf(), key = UUID(), id = UUID()
        addTeardownBlock { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        var store: WKWebsiteDataStore? = WKWebsiteDataStore(forIdentifier: id)
        var first: SignInKeeper? = keeper(shelf)
        first?.watch(store!, as: key)
        await first?.ready(store!)
        await store!.httpCookieStore.setCookie(cookie("session"))
        await first?.cleared(store!)
        #expect(kept(shelf, key).map(\.name) == ["session"])

        first = nil
        for session in await store!.httpCookieStore.allCookies() where session.isSessionOnly {
            await store!.httpCookieStore.deleteCookie(session)
        }
        store = nil
        let again = WKWebsiteDataStore(forIdentifier: id)
        #expect(await !names(again).contains("session"))
        let second = keeper(shelf)
        second.watch(again, as: key)
        await second.ready(again)

        #expect(await names(again).contains("session"))
    }

    @Test func aCookieWithAnExpiryDateIsNeverKept() async {
        let shelf = shelf(), key = UUID()
        let (store, _) = ownStore()
        let keeper = keeper(shelf)
        keeper.watch(store, as: key)
        await keeper.ready(store)

        await store.httpCookieStore.setCookie(cookie("lasting", expires: Date().addingTimeInterval(3600)))
        await store.httpCookieStore.setCookie(cookie("session"))
        await keeper.cleared(store)

        #expect(kept(shelf, key).map(\.name) == ["session"])
    }

    @Test func aPrivateStoreIsNeverKept() async {
        let shelf = shelf(), key = UUID()
        let store = WKWebsiteDataStore.nonPersistent()
        let keeper = keeper(shelf)

        keeper.watch(store, as: key)
        await store.httpCookieStore.setCookie(cookie("session"))
        await keeper.cleared(store)
        keeper.flush()

        #expect(!keeper.watches(store))
        #expect(shelf.accounts().isEmpty)
    }

    @Test func aPrivateWindowsStoreIsNotWatched() throws {
        let browser = Browser(record: WindowRecord(), privateStore: .nonPersistent())
        defer { browser.closeAll() }
        browser.open(URL(string: "https://private.example.test/")!, foreground: true)

        let store = try #require(browser.privateStore)
        #expect(!SignInKeeper.shared.watches(store))
        #expect(browser.tabs.allSatisfy { !SignInKeeper.shared.watches($0.store) })
    }

    @Test func aKeptCookieComesBackWithEveryFlag() async throws {
        let shelf = shelf(), key = UUID()
        let (from, _) = ownStore()
        let (to, _) = ownStore()
        let first = keeper(shelf)
        first.watch(from, as: key)
        await first.ready(from)
        let flagged = try #require(HTTPCookie(properties: [
            .name: "flagged", .value: "v1", .domain: "shop.example.test", .path: "/account",
            .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE", .sameSitePolicy: HTTPCookieStringPolicy.sameSiteStrict.rawValue,
        ]))
        await from.httpCookieStore.setCookie(flagged)
        await first.cleared(from)

        let second = keeper(shelf)
        second.watch(to, as: key)
        await second.ready(to)
        let back = try #require(await to.httpCookieStore.allCookies().first { $0.name == "flagged" })

        #expect(back.value == "v1")
        #expect(back.domain == "shop.example.test")
        #expect(back.path == "/account")
        #expect(back.isSecure)
        #expect(back.isHTTPOnly)
        #expect(back.sameSitePolicy == .sameSiteStrict)
        #expect(back.isSessionOnly)
    }

    @Test func clearingEverySiteRemovesTheKeptCookie() async {
        let shelf = shelf()
        let keeper = keeper(shelf, shared: true)
        let store = Spaces.store(for: Space.firstID)
        await keeper.ready(store)
        let name = "every-\(UUID().uuidString.prefix(6))"
        await store.httpCookieStore.setCookie(cookie(name))
        await keeper.cleared(store)
        #expect(kept(shelf, Space.firstID).contains { $0.name == name })
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        browser.clearSites()

        #expect(await until { !kept(shelf, Space.firstID).contains { $0.name == name } })
        #expect(shelf.read(Space.firstID.uuidString) == nil)
    }

    @Test func clearingOneSiteRemovesOnlyThatSitesKeptCookies() async {
        let shelf = shelf(), key = UUID()
        let keeper = keeper(shelf, shared: true)
        let (store, _) = ownStore()
        keeper.watch(store, as: key)
        await keeper.ready(store)
        await store.httpCookieStore.setCookie(cookie("mine", domain: "shop.example.test"))
        await store.httpCookieStore.setCookie(cookie("theirs", domain: "news.sample.test"))
        await keeper.cleared(store)

        await SiteClearing.clear("example.test", in: store)

        #expect(kept(shelf, key).map(\.name) == ["theirs"])
    }

    @Test func removingASpaceRemovesItsKeptCookies() async {
        let shelf = shelf(), id = UUID()
        let keeper = keeper(shelf, shared: true)
        let store = Spaces.store(for: id)
        #expect(keeper.watches(store))
        await keeper.ready(store)
        await store.httpCookieStore.setCookie(cookie("space"))
        await keeper.cleared(store)
        #expect(kept(shelf, id).map(\.name) == ["space"])

        Spaces.erase(id)

        #expect(await until { shelf.read(id.uuidString) == nil })
        #expect(!keeper.watches(store))
        addTeardownBlock {
            let left = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).filter { $0 != id.uuidString }
            Store.settings.set(left, forKey: "spaces.erasing")
        }
    }

    @Test func anExtensionClearingCookiesRemovesTheKeptCookie() async throws {
        let shelf = shelf()
        let keeper = keeper(shelf, shared: true)
        let store = Spaces.store(for: Space.firstID)
        await keeper.ready(store)
        let site = "k\(UUID().uuidString.prefix(6).lowercased()).test"
        await store.httpCookieStore.setCookie(cookie("extension", domain: "shop.\(site)"))
        await keeper.cleared(store)
        #expect(kept(shelf, Space.firstID).contains { $0.name == "extension" })
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }

        try await ExtensionShims.clear(["cookies": true], options: ["origins": ["https://shop.\(site)"]], browser: browser)

        #expect(!kept(shelf, Space.firstID).contains { $0.name == "extension" })
        #expect(await !names(store).contains("extension"))
    }

    @Test func aCookieTheSiteRemovesLeavesTheKeptCopyWithinTheSettlingTime() async {
        let shelf = shelf(), key = UUID()
        let (store, _) = ownStore()
        let keeper = keeper(shelf)
        keeper.settle = 0.2
        keeper.watch(store, as: key)
        await keeper.ready(store)
        let made = cookie("session")
        await store.httpCookieStore.setCookie(made)
        #expect(await until { kept(shelf, key).map(\.name) == ["session"] })

        await store.httpCookieStore.deleteCookie(made)

        #expect(await until { shelf.read(key.uuidString) == nil })
    }

    @Test func aBurstOfChangesIsLookedAtOnce() async throws {
        let counted = Counted(shelf()), key = UUID()
        let (store, _) = ownStore()
        let keeper = keeper(counted)
        keeper.settle = 1.5
        keeper.watch(store, as: key)
        await keeper.ready(store)

        for index in 0..<5 { await store.httpCookieStore.setCookie(cookie("burst-\(index)")) }
        try await Task.sleep(for: .seconds(3.5))

        #expect(counted.written == 1)
        #expect(kept(counted, key).count == 5)
    }

    @Test func quittingWritesTheKeptCopyBeforeItReturns() async {
        let shelf = shelf(), key = UUID()
        let (store, _) = ownStore()
        let keeper = keeper(shelf)
        keeper.watch(store, as: key)
        await keeper.ready(store)
        await store.httpCookieStore.setCookie(cookie("quit"))

        keeper.flush()

        #expect(kept(shelf, key).map(\.name) == ["quit"])
    }

    @Test func aClearWhileTheRestoreIsUnderWayIsNotUndone() async {
        let counted = Counted(shelf(), pause: 0.5), key = UUID()
        shelve([cookie("ended")], on: counted.inner, as: key)
        let (store, _) = ownStore()
        let keeper = keeper(counted)
        keeper.watch(store, as: key)

        keeper.clearing(store)
        await keeper.cleared(store)
        await keeper.ready(store)
        try? await Task.sleep(for: .milliseconds(700))

        #expect(await !names(store).contains("ended"))
        #expect(counted.read(key.uuidString) == nil)
    }

    @Test func theStoresOwnCookieWinsOverTheKeptOne() async {
        let shelf = shelf(), key = UUID()
        shelve([cookie("session", "kept")], on: shelf, as: key)
        let (store, _) = ownStore()
        await store.httpCookieStore.setCookie(cookie("session", "own"))
        let keeper = keeper(shelf)

        keeper.watch(store, as: key)
        await keeper.ready(store)

        let values = await store.httpCookieStore.allCookies().filter { $0.name == "session" }.map(\.value)
        #expect(values == ["own"])
    }

    @Test func anItemOlderThanAWeekIsRemovedAndNotPutBack() async {
        let shelf = shelf(), key = UUID()
        shelve([cookie("stale")], on: shelf, as: key, written: Date().addingTimeInterval(-8 * 24 * 60 * 60))
        let (store, _) = ownStore()
        let keeper = keeper(shelf)

        keeper.watch(store, as: key)
        await keeper.ready(store)

        #expect(await !names(store).contains("stale"))
        #expect(await until { shelf.read(key.uuidString) == nil })
    }

    @Test func startingWithAFreshWindowPutsNothingBackAndRemovesTheItem() async {
        let shelf = shelf(), key = UUID()
        shelve([cookie("session")], on: shelf, as: key)
        let (store, _) = ownStore()
        let keeper = keeper(shelf)
        keeper.fresh = { true }

        keeper.watch(store, as: key)
        await keeper.ready(store)

        #expect(await !names(store).contains("session"))
        #expect(await until { shelf.read(key.uuidString) == nil })
    }

    @Test func aPageAtLaunchWaitsForTheRestoreAndSendsTheCookie() async throws {
        let server = try LocalPageServer(["/launch": .init(type: "text/html", body: "<!doctype html><title>Launch</title>")])
        defer { server.stop() }
        let counted = Counted(shelf(), pause: 0.6)
        let name = "launch\(UUID().uuidString.prefix(6))"
        shelve([cookie(name, "back", domain: "127.0.0.1")], on: counted.inner, as: Space.firstID)
        keeper(counted, shared: true).deadline = 10
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }

        browser.open(server.url("/launch"), foreground: true)

        #expect(await until(10) { server.cookies(asked: "/launch") != nil })
        #expect(server.cookies(asked: "/launch")?.contains("\(name)=back") == true)
    }

    @Test func aRestoreThatNeverAnswersLetsThePageLoadAfterTheDeadline() async throws {
        let server = try LocalPageServer(["/late": .init(type: "text/html", body: "<!doctype html><title>Late</title>")])
        defer { server.stop() }
        let counted = Counted(shelf(), pause: 20)
        _ = keeper(counted, shared: true)
        let started = ProcessInfo.processInfo.systemUptime
        let browser = Browser(record: WindowRecord())
        browser.leaveFiles()
        defer { browser.closeAll() }

        browser.open(server.url("/late"), foreground: true)

        #expect(await until(10) { server.requests.contains("/late") })
        let waited = ProcessInfo.processInfo.systemUptime - started
        #expect(waited >= 1.8)
        #expect(waited < 6)
    }
}
