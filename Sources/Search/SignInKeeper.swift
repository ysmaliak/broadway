import Foundation
import WebKit

@MainActor
final class SignInKeeper {
    static var shared = SignInKeeper(shelf: SignInKeeper.ownShelf())

    nonisolated static func ownShelf() -> SignInShelf {
        Store.testing ? FolderShelf(folder: Store.file("Sign-ins")) : KeychainShelf()
    }

    private final class Watched {
        let key: UUID
        let store: WKWebsiteDataStore
        var observer: Observer?
        var ready = false
        var released = false
        var cleared = 0
        var looking = false
        var turn = 0
        var lookWhenReady = false
        var waiters: [() -> Void] = []

        init(key: UUID, store: WKWebsiteDataStore) {
            self.key = key
            self.store = store
        }
    }

    private final class Observer: NSObject, WKHTTPCookieStoreObserver {
        let changed: @MainActor () -> Void

        init(_ changed: @escaping @MainActor () -> Void) {
            self.changed = changed
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            MainActor.assumeIsolated { changed() }
        }
    }

    private final class Book: @unchecked Sendable {
        var last: [UUID: Set<SignInKeeping.Crumb>] = [:]
        var written: [UUID: Date] = [:]
    }

    private final class Left: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int

        init(_ value: Int) {
            self.value = value
        }

        var count: Int { lock.withLock { value } }

        func take() {
            lock.withLock { value -= 1 }
        }
    }

    private struct Cookies: @unchecked Sendable {
        let all: [HTTPCookie]
    }

    let shelf: SignInShelf
    var settle = SignInKeeping.settle
    var deadline = SignInKeeping.deadline
    var now: @Sendable () -> Date = { Date() }
    var fresh: @Sendable () -> Bool = { Store.settings.bool(forKey: Preferences.freshKey) }

    private var watched: [UUID: Watched] = [:]
    private var byStore: [ObjectIdentifier: UUID] = [:]
    private let book = Book()
    private let queue = DispatchQueue(label: "com.ysmaliak.broadway.sign-ins", qos: .userInitiated)

    init(shelf: SignInShelf) {
        self.shelf = shelf
    }

    func launch(keeping spaces: [Space]) {
        watch(Store.websites, as: Space.firstID)
        let keys = Set([Space.firstID] + spaces.filter { !$0.isFirst && $0.sharesSignIns != true }.map(\.id))
        let shelf = shelf
        queue.async {
            for account in shelf.accounts() where !keys.contains(where: { $0.uuidString == account }) {
                shelf.remove(account)
            }
        }
    }

    func watch(_ store: WKWebsiteDataStore, as key: UUID) {
        guard store.isPersistent, byStore[ObjectIdentifier(store)] == nil, watched[key] == nil else { return }
        let entry = Watched(key: key, store: store)
        watched[key] = entry
        byStore[ObjectIdentifier(store)] = key
        let observer = Observer { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.changed(entry)
        }
        entry.observer = observer
        store.httpCookieStore.add(observer)
        restore(entry)
    }

    var watching: [UUID] { Array(watched.keys) }

    func watches(_ store: WKWebsiteDataStore) -> Bool {
        byStore[ObjectIdentifier(store)] != nil
    }

    func ready(_ store: WKWebsiteDataStore, _ go: @escaping () -> Void) {
        guard let key = byStore[ObjectIdentifier(store)], let entry = watched[key], !entry.ready, !entry.released else {
            go()
            return
        }
        entry.waiters.append(go)
    }

    func ready(_ store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            ready(store) { done.resume() }
        }
    }

    func clearing(_ store: WKWebsiteDataStore) {
        guard let key = byStore[ObjectIdentifier(store)], let entry = watched[key] else { return }
        entry.cleared += 1
    }

    func cleared(_ store: WKWebsiteDataStore, done: (() -> Void)? = nil) {
        guard let key = byStore[ObjectIdentifier(store)], let entry = watched[key] else {
            done?()
            return
        }
        look(entry, force: false) {
            guard let done else { return }
            DispatchQueue.main.async { done() }
        }
    }

    func cleared(_ store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            cleared(store) { done.resume() }
        }
    }

    func forget(_ key: UUID) {
        if let entry = watched.removeValue(forKey: key) {
            byStore[ObjectIdentifier(entry.store)] = nil
            entry.cleared += 1
            if let observer = entry.observer { entry.store.httpCookieStore.remove(observer) }
            entry.observer = nil
            release(entry)
        }
        let shelf = shelf, book = book
        queue.async {
            shelf.remove(key.uuidString)
            book.last[key] = nil
            book.written[key] = nil
        }
    }

    func flush(within limit: TimeInterval = SignInKeeping.deadline) {
        let until = Date().addingTimeInterval(limit)
        let entries = watched.values.filter { $0.ready || $0.cleared > 0 }
        let left = Left(entries.count)
        for entry in entries {
            look(entry, force: true) { left.take() }
        }
        while left.count > 0, Date() < until {
            RunLoop.current.run(mode: .default, before: min(until, Date().addingTimeInterval(0.02)))
        }
    }

    private func restore(_ entry: Watched) {
        let generation = entry.cleared
        let shelf = shelf, book = book, key = entry.key
        let now = now(), fresh = fresh()
        queue.async {
            let reading = SignInKeeping.reading(shelf.read(key.uuidString), now: now, fresh: fresh)
            var crumbs: [SignInKeeping.Crumb] = []
            switch reading {
            case .nothing:
                book.written[key] = nil
                book.last[key] = []
            case .discard:
                shelf.remove(key.uuidString)
                book.written[key] = nil
                book.last[key] = []
            case .putBack(let written, let kept):
                book.written[key] = written
                book.last[key] = Set(kept)
                crumbs = kept
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.putBack(crumbs, into: entry, generation: generation) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + deadline) { [weak self, weak entry] in
            guard let self, let entry else { return }
            self.release(entry)
        }
    }

    private func putBack(_ crumbs: [SignInKeeping.Crumb], into entry: Watched, generation: Int) {
        guard watched[entry.key] === entry else { return }
        guard !crumbs.isEmpty, entry.cleared == generation else {
            finish(entry)
            return
        }
        let jar = entry.store.httpCookieStore
        jar.getAllCookies { [weak self] present in
            guard let self, self.watched[entry.key] === entry else { return }
            guard entry.cleared == generation else {
                self.finish(entry)
                return
            }
            let places = Set(present.map { Self.crumb(of: $0).place })
            let cookies = SignInKeeping.toPutBack(crumbs, present: places).compactMap(Self.cookie(of:))
            guard !cookies.isEmpty else {
                self.finish(entry)
                return
            }
            var left = cookies.count
            for cookie in cookies {
                jar.setCookie(cookie) {
                    left -= 1
                    if left == 0 { self.finish(entry) }
                }
            }
        }
    }

    private func finish(_ entry: Watched) {
        entry.ready = true
        release(entry)
        if entry.lookWhenReady {
            entry.lookWhenReady = false
            look(entry, force: false)
        }
    }

    private func release(_ entry: Watched) {
        entry.released = true
        let waiting = entry.waiters
        entry.waiters = []
        waiting.forEach { $0() }
    }

    func resettle(_ seconds: TimeInterval) {
        settle = seconds
        for entry in watched.values where entry.looking { schedule(entry) }
    }

    private func changed(_ entry: Watched) {
        guard watched[entry.key] === entry, !entry.looking else { return }
        schedule(entry)
    }

    private func schedule(_ entry: Watched) {
        entry.looking = true
        entry.turn += 1
        let turn = entry.turn
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self, weak entry] in
            guard let self, let entry, entry.turn == turn else { return }
            entry.looking = false
            self.look(entry, force: false)
        }
    }

    private func look(_ entry: Watched, force: Bool, done: (@Sendable () -> Void)? = nil) {
        guard watched[entry.key] === entry else {
            done?()
            return
        }
        guard entry.ready || entry.cleared > 0 else {
            entry.lookWhenReady = true
            done?()
            return
        }
        let generation = entry.cleared
        entry.store.httpCookieStore.getAllCookies { [weak self] all in
            guard let self, self.watched[entry.key] === entry, entry.cleared == generation else {
                done?()
                return
            }
            let cookies = Cookies(all: all)
            let shelf = self.shelf, book = self.book, key = entry.key
            let now = self.now(), fresh = self.fresh()
            self.queue.async {
                Self.write(cookies, for: key, force: force, now: now, fresh: fresh, shelf: shelf, book: book)
                done?()
            }
        }
    }

    private nonisolated static func write(_ cookies: Cookies, for key: UUID, force: Bool, now: Date, fresh: Bool,
                                          shelf: SignInShelf, book: Book) {
        let kept = SignInKeeping.keepable(cookies.all.map { SignInKeeping.Seen(crumb: crumb(of: $0), sessionOnly: $0.isSessionOnly) })
        let step = SignInKeeping.step(kept: kept, last: book.last[key] ?? [], written: book.written[key],
                                      now: now, force: force, fresh: fresh)
        switch step {
        case .nothing:
            break
        case .remove:
            shelf.remove(key.uuidString)
            book.written[key] = nil
            book.last[key] = []
        case .write:
            guard let data = SignInKeeping.encode(kept, at: now), shelf.write(data, as: key.uuidString) else { return }
            book.written[key] = now
            book.last[key] = kept
        }
    }

    nonisolated static func crumb(of cookie: HTTPCookie) -> SignInKeeping.Crumb {
        SignInKeeping.Crumb(name: cookie.name, value: cookie.value, domain: cookie.domain, path: cookie.path,
                            secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, sameSite: cookie.sameSitePolicy?.rawValue)
    }

    nonisolated static func cookie(of crumb: SignInKeeping.Crumb) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: crumb.name,
            .value: crumb.value,
            .domain: crumb.domain,
            .path: crumb.path,
        ]
        if crumb.secure { properties[.secure] = "TRUE" }
        if crumb.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite = crumb.sameSite { properties[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: properties)
    }
}
