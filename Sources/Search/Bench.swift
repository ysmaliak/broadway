import AppKit
import Combine
import AuthenticationServices
import WebKit

// A way for a script on this Mac to drive the browser you already have open,
// in tabs of its own, without ever taking the window from you.
//
// Off unless switched on in Settings › General. On, the app listens on a Unix
// socket in its own folder — readable by this user and nobody else, and the
// other end is checked for the same uid before a word is read. One JSON
// object per line in, one per line out, one request per connection. The
// tabs it opens sit at the end of your row with a flask on them, are never
// selected on your behalf, never enter the session or the history, and go
// when the script says so. `./bench` at the root of the repository speaks
// this protocol from the shell.
//
// Pages a script has opened but you are not looking at live in a window of
// their own, off every screen: WebKit lays out and paints a page only when
// it has a size and a window, and a snapshot of a page that has neither is
// a snapshot of nothing.

@MainActor
final class Bench {
    static let shared = Bench()
    private var awake: NSObjectProtocol?

    private weak var browser: Browser?
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var clients: [Int32: Client] = [:]

    /// Where the socket is. Beside the session file, so a test run's bench is
    /// as separate from the real one as everything else it keeps.
    static var socket: URL { Store.file("bench.sock") }

    /// True while something is listening.
    private(set) var running = false

    /// How many times each view that counts itself was built ("hoversweep").
    /// Test runs only; anywhere else counting is one check of a constant.
    private static let counting = Store.testing
    static var bodies: [String: Int] = [:]
    static func count(_ name: String) {
        if counting { bodies[name, default: 0] += 1 }
    }
    /// Each row in the column's own answer to the pointer coming and going,
    /// the very one its onHover gives (SideRow), for "hoversweep". Counted,
    /// since a row built anew can appear before the one it replaces has
    /// gone: the last to appear answers, until the last one goes.
    static var hoverRows: [Tab.ID: (Bool) -> Void] = [:]
    private static var hoverRowsShown: [Tab.ID: Int] = [:]
    static func rowAppeared(_ id: Tab.ID, hover: @escaping (Bool) -> Void) {
        guard counting else { return }
        hoverRows[id] = hover
        hoverRowsShown[id, default: 0] += 1
    }
    static func rowDisappeared(_ id: Tab.ID) {
        guard counting else { return }
        hoverRowsShown[id, default: 1] -= 1
        if hoverRowsShown[id] == 0 { hoverRows[id] = nil; hoverRowsShown[id] = nil }
    }
    static var hoverChips: [Tab.ID: (Bool) -> Void] = [:]
    static func chipAppeared(_ id: Tab.ID, hover: @escaping (Bool) -> Void) {
        guard counting else { return }
        hoverChips[id] = hover
    }
    static func chipDisappeared(_ id: Tab.ID) {
        guard counting else { return }
        hoverChips[id] = nil
    }
    static var rowFrames: [Tab.ID: CGRect] = [:]
    static var checkMarks: [Tab.ID: () -> CGRect?] = [:]
    static var meetingBadge: CGRect?
    static var meetingTile: CGRect?
    static var pressRows: [Tab.ID: (Bool) -> Void] = [:]
    static func rowPress(_ id: Tab.ID, press: @escaping (Bool) -> Void) {
        guard counting else { return }
        pressRows[id] = press
    }
    static var layerRows: [Tab.ID: () -> [String: CALayer]] = [:]
    static func rowLayers(_ id: Tab.ID, layers: @escaping () -> [String: CALayer]) {
        guard counting else { return }
        layerRows[id] = layers
    }
    static func forgetRow(_ id: Tab.ID) {
        guard counting else { return }
        pressRows[id] = nil
        layerRows[id] = nil
        hoverRows[id] = nil
        hoverRowsShown[id] = nil
        rowFrames[id] = nil
    }

    /// The key code of a letter on a US keyboard, which is what WebKit reads
    /// alongside the characters; anything else goes as the space bar's.
    static func keyCode(for character: Character) -> UInt16 {
        let codes: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
            "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        ]
        return codes[Character(character.lowercased())] ?? 49
    }

    /// Where the traffic lights are: each one's left edge and its centre's
    /// height from the top, in the window's points.
    static func lights(of window: NSWindow) -> [[Int]] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { type in
            guard let button = window.standardWindowButton(type) else { return nil }
            let frame = button.convert(button.bounds, to: nil)
            return [Int(frame.minX.rounded()), Int((window.frame.height - frame.midY).rounded())]
        }
    }

    static func glass(in window: NSWindow) -> [[String: Any]] {
        guard let root = window.contentView?.superview?.layer ?? window.contentView?.layer else { return [] }
        var found: [[String: Any]] = []
        func walk(_ layer: CALayer, _ alpha: Swift.Float, _ hidden: Bool) {
            let alpha = alpha * (layer.presentation()?.opacity ?? layer.opacity)
            let hidden = hidden || layer.isHidden
            if String(describing: type(of: layer)) == "CABackdropLayer" {
                let frame = layer.convert(layer.bounds, to: root)
                let top = root.isGeometryFlipped ? frame.minY : root.bounds.height - frame.maxY
                found.append(["frame": [Int(frame.minX.rounded()), Int(top.rounded()), Int(frame.width.rounded()), Int(frame.height.rounded())],
                              "alpha": Double(alpha), "hidden": hidden])
                return
            }
            for sub in layer.sublayers ?? [] { walk(sub, alpha, hidden) }
        }
        walk(root, 1, false)
        return found
    }

    // MARK: - who switched it on

    @MainActor
    enum Consent {
        private static let service = "com.ysmaliak.broadway.bench"

        static var given: Bool { ConsentMark.present("consent", service: service) }

        @discardableResult static func grant() -> Bool { ConsentMark.put("consent", service: service) }

        static func revoke() { ConsentMark.take("consent", service: service) }
    }

    // MARK: - starting and stopping

    func start(for browser: Browser) {
        guard !running else { return }
        self.browser = browser
        if Store.testing, !Store.shownOnScreen { Bench.watchScreens() }
        // Nor App Nap, which a test run behind other windows falls into.
        if Store.testing, !Store.measuring, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Bench")
        }
        let path = Bench.socket.path
        try? FileManager.default.createDirectory(
            at: Bench.socket.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        unlink(path)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { close(fd); return }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { bytes in
                _ = strlcpy(bytes, path, room)
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            unlink(path)
            return
        }
        fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        accepting = source
        listener = fd
        running = true
    }

    func stop() {
        guard running else { return }
        accepting?.cancel()
        accepting = nil
        close(listener)
        listener = -1
        unlink(Bench.socket.path)
        clients.values.forEach { $0.drop() }
        clients = [:]
        running = false
        // The tabs a script left open go with it.
        if let browser {
            for tab in browser.tabs where tab.bench && !tab.agent { browser.close(tab) }
        }
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        // Only this user. The file mode already says so; this says it again,
        // for the day the folder's permissions are not what they were.
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        var room: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &room, socklen_t(MemoryLayout<Int32>.size))
        var quiet: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        let client = Client(fd: fd) { [weak self] request, answer in
            self?.handle(request, answer)
        } gone: { [weak self] fd in
            self?.clients[fd] = nil
        }
        clients[fd] = client
    }

    // MARK: - one connection

    /// Reads until a newline, hands the line up, writes the answer, closes.
    private final class Client {
        let fd: Int32
        private var bytes = Data()
        private let source: DispatchSourceRead
        private let handle: ([String: Any], @escaping ([String: Any]) -> Void) -> Void
        private let gone: (Int32) -> Void
        private var answered = false

        init(
            fd: Int32,
            handle: @escaping ([String: Any], @escaping ([String: Any]) -> Void) -> Void,
            gone: @escaping (Int32) -> Void
        ) {
            self.fd = fd
            self.handle = handle
            self.gone = gone
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
            source.setEventHandler { [weak self] in self?.read() }
            source.resume()
        }

        private func read() {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 {
                if count == 0 || errno != EAGAIN { drop() }
                return
            }
            bytes.append(contentsOf: chunk[0..<count])
            // A line that never ends is not a request.
            if bytes.count > 4_000_000 {
                say(["error": "request too long"])
                return
            }
            guard let newline = bytes.firstIndex(of: 0x0A) else { return }
            let line = bytes[bytes.startIndex..<newline]
            bytes = Data()
            source.cancel()
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                say(["error": "not a JSON object"])
                return
            }
            handle(json) { [weak self] answer in self?.say(answer) }
        }

        private func say(_ answer: [String: Any]) {
            guard !answered else { return }
            answered = true
            var answer = answer
            // The socket's queue is the main one.
            let caught = MainActor.assumeIsolated { Bench.caught }
            if !caught.isEmpty { answer["onScreen"] = caught }
            var out = (try? JSONSerialization.data(withJSONObject: answer)) ?? Data("{\"error\":\"unwritable answer\"}".utf8)
            out.append(0x0A)
            out.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 {
                        if errno == EAGAIN {
                            var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                            _ = poll(&ready, 1, 1000)
                            continue
                        }
                        break
                    }
                    sent += n
                }
            }
            drop()
        }

        func drop() {
            if !source.isCancelled { source.cancel() }
            close(fd)
            gone(fd)
        }
    }

    // MARK: - the commands

    private func handle(_ request: [String: Any], _ given: @escaping ([String: Any]) -> Void) {
        // One answer, and always one: a page that never replies to a script
        // would otherwise hold the bench — every later command waits behind it.
        var answered = false
        let answer: ([String: Any]) -> Void = { reply in
            guard !answered else { return }
            answered = true
            given(reply)
        }
        let patience = (request["do"] as? String) == "wait" ? (request["seconds"] as? Double ?? 30) + 5 :
            (request["do"] as? String) == "import-file" ? (request["timeout"] as? Double ?? 120) :
            (request["do"] as? String) == "aigroups" && (request["args"] as? [String])?.first == "trial" ? 600 : 25
        DispatchQueue.main.asyncAfter(deadline: .now() + patience) { answer(["error": "no answer within \(Int(patience)) s"]) }
        // --window N: the Nth window's browser, oldest first; the first
        // window's otherwise.
        let picked = (request["window"] as? Int).flatMap { n in Browsers.all.indices.contains(n - 1) ? Browsers.all[n - 1] : nil }
        let live = browser.flatMap { b in Browsers.all.contains { $0 === b } ? b : nil }
        let ref = ((request["id"] ?? request["from"]) as? String)?.lowercased() ?? ""
        let owner = ref.count < 4 || live?.tabs.contains(where: { $0.id.uuidString.lowercased().hasPrefix(ref) }) == true ? nil
            : Browsers.all.first { $0.tabs.contains { $0.id.uuidString.lowercased().hasPrefix(ref) } }
        guard let browser = picked ?? owner ?? live ?? Browsers.primary else {
            answer(["error": "no browser"])
            return
        }
        let verb = request["do"] as? String ?? ""

        // With pages shown (`pages on`) the app is no longer hidden: whatever
        // opens or brings back a window would put it on the screen. Refused
        // until `pages off`; listing and closing windows stay.
        if Bench.pagesShown {
            let action = request["action"] as? String ?? "list"
            if verb == "towindow" || (verb == "windows" && !["list", "close"].contains(action)) {
                answer(["error": "pages are on: run `pages off` before opening or bringing back a window"])
                return
            }
        }

        switch verb {
        case _ where BenchPage.verbs.contains(verb):
            BenchPage.run(verb, request, browser: browser, answer)

        case _ where BenchWelcome.verbs.contains(verb):
            BenchWelcome.run(verb, request, browser: browser, answer)

        case _ where BenchSurfaces.verbs.contains(verb):
            BenchSurfaces.run(verb, request, answer)

        case _ where BenchPages.verbs.contains(verb):
            BenchPages.run(request, browser: browser, answer)

        case _ where BenchStuck.verbs.contains(verb):
            BenchStuck.run(request, answer)
        case _ where BenchMemory.verbs.contains(verb):
            BenchMemory.run(request, answer)
        case _ where BenchLeave.verbs.contains(verb):
            BenchLeave.run(request, answer)

        case _ where BenchAddressPill.verbs.contains(verb):
            BenchAddressPill.run(verb, request, answer)

        case _ where BenchLayout.verbs.contains(verb):
            BenchLayout.run(verb, request, answer)

        case _ where BenchNetwork.verbs.contains(verb):
            BenchNetwork.run(request, answer)
        case _ where BenchDock.verbs.contains(verb):
            BenchDock.run(request, answer)
        case _ where BenchSiteFiles.verbs.contains(verb):
            BenchSiteFiles.run(request, browser, answer)

        case _ where BenchHooks.verbs.contains(verb):
            BenchHooks.run(request, browser: browser, answer)

        case "layouts":
            // Test runs only: every frame the pages on screen take, looked at
            // every few milliseconds and after each pass of the run loop, for
            // `seconds`, each change once with when it came. With `immerse`,
            // a page's full screen is faked in or out first, as the page's own
            // word that it is going or back would (Forms.swift); nothing goes
            // full screen. How many times a change of chrome moves the page
            // (Tests/fullscreen_exit.py).
            guard Store.testing else { answer(["error": "layouts is for test runs"]); return }
            let seconds = min(10, request["seconds"] as? Double ?? 1.5)
            let record = LayoutRecord(browser: browser)
            record.look()
            if let on = request["immerse"] as? Bool {
                guard let tab = request["id"] == nil ? browser.active : find(request, in: browser) else { answer(missing(request)); return }
                tab.immersed = on
            }
            record.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                record.stop()
                answer(["layouts": record.seen])
            }

        case "tabs":
            // A private tab is nobody's business but yours: a test run has none
            // of yours, so there every tab is listed.
            let quiet = Store.testing && request["window"] == nil && !browser.isPrivate
                ? Browsers.all.filter(\.isPrivate).flatMap(\.tabs) : []
            answer(["tabs": (browser.tabs.filter { Store.testing || !$0.shy } + quiet).map(describe)])

        case "titles":
            guard Store.testing else { answer(["error": "titles only works on a --test run"]); return }
            if let text = request["history"] as? String, let url = URL(string: text) {
                browser.history.take(url, title: request["named"] as? String ?? "", count: 1, last: Date())
                browser.history.settle()
            }
            if let text = request["mark"] as? String, let url = URL(string: text) {
                _ = browser.bookmarks.add(url, title: request["named"] as? String ?? "")
            }
            let every = Browsers.all.flatMap(\.tabs)
            answer(["tabs": every.map { tab in
                ["id": Bench.short(tab), "url": tab.address?.absoluteString ?? "", "label": tab.label, "title": tab.title,
                 "raw": tab.built?.title ?? "", "settling": !tab.titleSettled,
                 "loading": tab.loading, "asleep": tab.asleep, "active": tab.id == browser.activeID,
                 "failed": tab.failure != nil, "trace": TitleTrace.all[tab.id]?.report ?? []] as [String: Any]
            }])

        case "open":
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "open needs a url"])
                return
            }
            let shy = request["private"] as? Bool == true
            guard !shy || Store.testing else { answer(["error": "open private only works on a --test run"]); return }
            let home = shy ? (browser.isPrivate ? browser : Browsers.all.last { $0.isPrivate } ?? Browsers.newPrivateWindow()) : browser
            let tab = home.benchOpen(url)
            house(tab)
            answer(describe(tab))

        case "go":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else {
                answer(["error": "go needs a url"])
                return
            }
            tab.go(to: url)
            answer(describe(tab))

        case "close":
            if (request["id"] as? String) == "all" {
                let mine = browser.tabs.filter { $0.bench }
                mine.forEach { browser.close($0) }
                answer(["closed": mine.count])
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard tab.bench else {
                answer(["error": "not a bench tab — only tabs the bench opened can be closed from here"])
                return
            }
            browser.close(tab)
            answer(["closed": 1])

        case "wait":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let limit = Date().addingTimeInterval(request["seconds"] as? Double ?? 20)
            wait(for: tab, until: limit, answer)

        case "sleep":
            // Now rather than hours on, but past every other check
            // a tab has to clear — the answer says which one kept it awake.
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            browser.sleep(tab) { said in answer(["said": said, "asleep": tab.asleep]) }

        case "openmark":
            // A bookmark opened as the bar opens one. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "openmark only works on a --test run"]); return }
            guard let text = request["url"] as? String, let url = URL(string: text) else { answer(["error": "openmark needs a url"]); return }
            browser.openBookmark(url)
            answer(["active": browser.active?.id.uuidString ?? ""])

        case "windowbehind":
            guard Store.testing, let window = browser.window else { answer(["error": "windowbehind needs a window on a --test run"]); return }
            window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            window.orderBack(nil)
            NSApp.unhideWithoutActivation()
            window.orderBack(nil)
            answer(["number": window.windowNumber, "level": window.level.rawValue, "key": window.isKeyWindow, "active": NSApp.isActive])

        case "windowpicture":
            guard Store.testing, let path = request["path"] as? String else { answer(["error": "windowpicture needs a path on a --test run"]); return }
            answer(["shot": Browser.picture(of: browser.window?.contentView, to: path) ? path : ""])

        case "pin":
            // Pin a tab, or unpin it with "off". Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "pin only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            var taken: Bool?
            if let at = request["at"] as? Int {
                if request["off"] as? Bool == true {
                    taken = browser.unpinDropped(tab, at: at, group: (request["group"] as? String).flatMap(UUID.init))
                } else {
                    taken = browser.pinDropped(tab, at: at)
                }
            }
            else if request["split"] as? Bool == true, let pair = browser.split(for: tab) {
                if browser.pinnedSplit(of: tab) != nil { browser.unpinSplit(pair) } else { browser.pinSplit(pair) }
            }
            else if request["off"] as? Bool == true { browser.unpin(tab) }
            else if request["home"] as? Bool == true { browser.goHome(tab) }
            // "everywhere": Keep in Every Space (true) or Only in This Space
            // (false), as the pin's menu does.
            else if let everywhere = request["everywhere"] as? Bool, tab.pin != nil {
                if everywhere { browser.shareEverywhere(tab) } else { browser.keepHere(tab) }
            }
            else { browser.pin(tab) }
            answer(["pin": tab.pin ?? "", "everywhere": tab.everywhere, "pinned": browser.pinnedCount, "home": tab.home?.absoluteString ?? "",
                    "address": tab.address?.absoluteString ?? "", "editingLetter": browser.editingPin == tab.id,
                    "pinnedSplit": browser.pinnedSplit(of: tab) != nil,
                    "taken": taken.map { $0 as Any } ?? NSNull()])

        case "select":
            // Picking a tab takes the window over, which the bench never does
            // to someone using it: only on a SEARCH_PROBE run.
            guard Store.testing else {
                answer(["error": "select only works on a --test run — it would take your window over"])
                return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            browser.select(tab)
            answer(describe(tab))

        case "text":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            house(tab)
            tab.web.evaluateJavaScript("document.body ? document.body.innerText : ''") { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    var text = (value as? String) ?? ""
                    var cut = false
                    if text.count > 120_000 { text = String(text.prefix(120_000)); cut = true }
                    answer(["text": text, "truncated": cut, "url": tab.address?.absoluteString ?? "", "title": tab.title])
                }
            }

        case "nowplaying":
            // Whether this app is the Mac's Now Playing app, the one the media
            // keys and AirPods taps go to, as WebKit has it for the tab's
            // page (#512). WebKit's own tests ask the same way; a test run
            // only, since it is WebKit's private side.
            guard Store.testing else { answer(["error": "nowplaying only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let ask = NSSelectorFromString("_requestActiveNowPlayingSessionInfo:")
            guard tab.web.responds(to: ask), let imp = tab.web.method(for: ask) else {
                answer(["error": "this WebKit has no Now Playing info"]); return
            }
            typealias Reply = @convention(block) (ObjCBool, ObjCBool, NSString?, Double, Double, Int) -> Void
            typealias Ask = @convention(c) (AnyObject, Selector, Reply) -> Void
            let reply: Reply = { active, registered, title, _, _, _ in
                MainActor.assumeIsolated {
                    answer(["active": active.boolValue, "registered": registered.boolValue, "title": (title as String?) ?? "",
                            "hushing": tab.hushing])
                }
            }
            unsafeBitCast(imp, to: Ask.self)(tab.web, ask, reply)

        case "eval":
            guard let tab = find(request, in: browser) ?? parked(request, in: browser) else { answer(missing(request)); return }
            guard let js = request["js"] as? String else { answer(["error": "eval needs js"]); return }
            house(tab)
            // Search's own world is where its page scripts live (see Web.world).
            if request["world"] as? String == "search" {
                tab.web.evaluateJavaScript(js, in: nil, in: Web.world) { result in
                    switch result {
                    case .success(let value): answer(["value": Bench.plain(value)])
                    case .failure(let error): answer(["error": error.localizedDescription])
                    }
                }
                return
            }
            tab.web.evaluateJavaScript(js) { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    answer(["value": Bench.plain(value)])
                }
            }

        case "tap":
            // A real click on an element, delivered to the view as mouse
            // events — trusted, as a hand's is — where `click` only runs
            // element.click() in the page, which a password manager, for one,
            // is right to ignore. `text=Sign in` picks a button or link by its
            // words. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "tap only works on a --test run — it would click in your page"]); return }
            guard let tab = find(request, in: browser), let selector = request["selector"] as? String else { answer(missing(request)); return }
            house(tab)
            let view = tab.web
            view.evaluateJavaScript(Bench.locate(selector)) { value, error in
                MainActor.assumeIsolated {
                    guard let point = value as? [Double], point.count == 2, let window = view.window else {
                        answer(["error": error?.localizedDescription ?? "nothing matches \(selector)"])
                        return
                    }
                    let local = NSPoint(x: point[0], y: view.isFlipped ? point[1] : view.bounds.height - point[1])
                    let spot = view.convert(local, to: nil)
                    // Held while clicking: "shift", "cmd", "opt".
                    var held: NSEvent.ModifierFlags = []
                    for name in request["mods"] as? [String] ?? [] {
                        if name == "shift" { held.insert(.shift) }
                        if name == "cmd" { held.insert(.command) }
                        if name == "opt" { held.insert(.option) }
                    }
                    // "button": "middle" clicks with the middle button.
                    let middle = request["button"] as? String == "middle"
                    let types: [NSEvent.EventType] = middle ? [.otherMouseDown, .otherMouseUp] : [.leftMouseDown, .leftMouseUp]
                    for type in types {
                        guard var event = NSEvent.mouseEvent(
                            with: type, location: spot, modifierFlags: held,
                            timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil,
                            eventNumber: 0, clickCount: 1, pressure: type == types[0] ? 1 : 0
                        ) else { continue }
                        if middle, let raw = event.cgEvent {
                            raw.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                            if let again = NSEvent(cgEvent: raw) { event = again }
                        }
                        switch type {
                        case .leftMouseDown: view.mouseDown(with: event)
                        case .otherMouseDown: view.otherMouseDown(with: event)
                        case .otherMouseUp: view.otherMouseUp(with: event)
                        default: view.mouseUp(with: event)
                        }
                    }
                    answer(["ok": true, "at": point.map { Int($0) }])
                }
            }

        case "click", "type", "submit":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            guard let selector = request["selector"] as? String else {
                answer(["error": "\(verb) needs a selector"])
                return
            }
            house(tab)
            let text = request["text"] as? String ?? ""
            tab.web.evaluateJavaScript(Bench.act(verb, selector: selector, text: text)) { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    let said = (value as? String) ?? "?"
                    answer(said == "ok" ? ["ok": true] : ["error": said])
                }
            }

        case "towindow":
            // A tab to another window, as its menu's Move to Window does: to
            // the Nth, or a new one. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "towindow only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            if let at = request["at"] as? [Double], at.count == 2 {
                // Let go at a point of the screen, as a drag out of the row.
                let taken = browser.dragOut(tab, at: NSPoint(x: at[0], y: at[1]))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(["taken": taken, "windows": Browsers.all.count]) }
                return
            }
            let n = request["to"] as? Int
            let target = n.flatMap { Browsers.all.indices.contains($0 - 1) ? Browsers.all[$0 - 1] : nil }
            if n != nil, target == nil { answer(["error": "no window \(n ?? 0)"]); return }
            browser.moveToWindow(tab, target)
            answer(["windows": Browsers.all.count])

        case "tear":
            answer(BenchTear.handle(request))

        case "small":
            answer(BenchSmall.handle(request, browser: browser))

        case "quit":
            // ⌘Q, on a test run: the app ends the way it does for you, the
            // session and windows.json written on the way out.
            guard Store.testing else { answer(["error": "quit only works on a --test run"]); return }
            answer(["quitting": true])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { NSApp.terminate(nil) }

        case "updates":
            guard Store.testing else { answer(["error": "updates only works on a --test run"]); return }
            if let on = request["checks"] as? Bool { Updates.shared.checks = on }
            if let on = request["installs"] as? Bool { Updates.shared.installs = on }
            if request["check"] as? Bool == true { Updates.shared.check() }
            if let version = request["stage"] as? String {
                Updates.shared.pretend(version: version, build: request["build"] as? String ?? version, quits: request["quits"] as? Bool == true)
            }
            if request["unstage"] as? Bool == true { Updates.shared.unpretend() }
            if request["hide"] as? Bool == true { Updates.shared.wait.hide() }
            if request["restart"] as? Bool == true { Updates.shared.restart(over: browser.window) }
            if request["behind"] as? Bool == true { NSApp.hide(nil) }
            var said = Updates.shared.facts
            said["sidebar"] = UpdateCardView.bench(browser)
            said["asked"] = Ask.asked
            if let title = request["press"] as? String { said["pressed"] = UpdateWindows.press(title) }
            said["windows"] = UpdateWindows.read()
            let appMenu = NSApp.mainMenu?.items.first?.submenu
            appMenu?.update()
            let shown = appMenu?.items.filter { !$0.isHidden } ?? []
            said["menu"] = shown.map(\.title)
            said["menuOff"] = shown.filter { !$0.isSeparatorItem && !$0.isEnabled }.map(\.title)
            said["pid"] = ProcessInfo.processInfo.processIdentifier
            said["path"] = Bundle.main.bundlePath
            said["moveOffer"] = Updates.moveOffer?.rawValue ?? ""
            answer(said)

        case "alive":
            // What is still in memory: tabs, their page views, and the web
            // processes those views run in, against what the rows hold. A
            // closed tab or window should leave nothing behind here
            // (Tests/memory_close.py). Read a turn later, once whatever the
            // close let go of has been released. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "alive only works on a --test run"]); return }
            DispatchQueue.main.async {
                let pages = Web.pages.allObjects
                let pids = Set(pages.compactMap { $0.value(forKey: "_webProcessIdentifier") as? Int }.filter { $0 > 0 })
                // The shared helpers too, where this WebKit names them.
                let ask: (NSObject?, String) -> Int = { object, name in
                    guard let object, object.responds(to: NSSelectorFromString(name)) else { return 0 }
                    return object.value(forKey: name) as? Int ?? 0
                }
                answer([
                    "tabs": Tab.live.allObjects.count,
                    "pages": pages.count,
                    "processes": pids.sorted(),
                    "inRows": Browsers.all.reduce(0) { $0 + $1.tabs.count + $1.parkedTabs.count },
                    "built": Browsers.all.reduce(0) { $0 + ($1.tabs + $1.parkedTabs).filter { $0.built != nil }.count },
                    "windows": Browsers.all.count,
                    "urls": pages.map { $0.url?.absoluteString ?? "" },
                    "gpu": pages.map { ask($0, "_gpuProcessIdentifier") }.first { $0 > 0 } ?? 0,
                    "network": pages.map { ask($0.configuration.websiteDataStore, "_networkProcessIdentifier") }.first { $0 > 0 } ?? 0,
                ])
            }

        case "windows":
            // The windows, oldest first, and what the tests do to them. Only
            // on a SEARCH_PROBE run: it opens and closes windows.
            guard Store.testing else { answer(["error": "windows only works on a --test run"]); return }
            let n = (request["n"] as? Int).map { $0 - 1 }
            switch request["action"] as? String {
            case "new": Browsers.newWindow()
            case "private": Browsers.newPrivateWindow()
            case "close":
                guard let n, Browsers.all.indices.contains(n) else { answer(["error": "no window \((n ?? -1) + 1)"]); return }
                Browsers.all[n].window?.close()
            case "reopen": _ = Browsers.reopenWindow()
            case "front":
                // The Nth window as if it had come to the front; a hidden
                // probe's windows never become key on their own.
                guard let n, Browsers.all.indices.contains(n) else { answer(["error": "no window \((n ?? -1) + 1)"]); return }
                Browsers.becameKey(Browsers.all[n])
            case "makekey":
                guard let n, Browsers.all.indices.contains(n) else { answer(["error": "no window \((n ?? -1) + 1)"]); return }
                Browsers.all[n].window?.makeKeyAndOrderFront(nil)
            case "link":
                // A link from another app, the way macOS hands it over.
                guard let text = request["url"] as? String, let url = URL(string: text) else { answer(["error": "link needs a url"]); return }
                Links.arrived(url)
            case "frame":
                guard let n, Browsers.all.indices.contains(n), let f = request["frame"] as? [Double], f.count == 4 else { answer(["error": "frame needs N X Y W H"]); return }
                Browsers.all[n].window?.setFrame(NSRect(x: f[0], y: f[1], width: f[2], height: f[3]), display: false)
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                answer(["windows": Browsers.all.enumerated().map { index, b -> [String: Any] in
                    [
                        "n": index + 1, "front": b === Browsers.front, "scene": b.inScene,
                        "shown": b.window?.isVisible ?? false, "files": b.usesFiles,
                        "space": b.space.name, "tabs": b.tabs.map { $0.address?.absoluteString ?? "" },
                        "spaces": b.spaces.map(\.name),
                        "stores": b.tabs.map { $0.store.identifier?.uuidString ?? "default" },
                        "private": b.isPrivate, "restorable": b.window?.isRestorable ?? false,
                        "shy": b.tabs.map(\.shy), "persistent": b.tabs.map { $0.store.isPersistent },
                        "storeKeys": b.tabs.map { String(UInt(bitPattern: ObjectIdentifier($0.store).hashValue)) },
                        "titles": b.tabs.map(\.title),
                        "pins": b.tabs.filter { $0.pin != nil }.map { $0.pin ?? "" },
                        "frame": b.window.map { NSStringFromRect($0.frame) } ?? "",
                    ]
                }, "closedWindows": Browsers.lastClosedAt != nil])
            }

        case "middle":
            // The middle button pressed and let go at X Y of a tab's page (its
            // own points from the top left), handed to its view as AppKit
            // would: the page sees trusted mousedown, mouseup and auxclick.
            // Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "middle only works on a --test run"]); return }
            guard let tab = find(request, in: browser), let x = request["x"] as? Double, let y = request["y"] as? Double
            else { answer(missing(request)); return }
            house(tab)
            let web = tab.web
            let before = browser.tabs.count
            let inView = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
            let point = web.convert(inView, to: nil)
            for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: web.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .otherMouseDown ? 1 : 0
                ) else { continue }
                // A made event is button 0; the middle is 2, set on its CG form.
                guard let cg = event.cgEvent else { continue }
                cg.setIntegerValueField(.mouseEventButtonNumber, value: 2)
                let middle = NSEvent(cgEvent: cg) ?? event
                if type == .otherMouseDown { web.otherMouseDown(with: middle) } else { web.otherMouseUp(with: middle) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                answer(["tabsBefore": before, "tabsAfter": browser.tabs.count])
            }

        case "linkmenu":
            // A right-click at X Y of a tab's page (its own points from the
            // top left), and the item named "pick" chosen from the menu that
            // comes up. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "linkmenu only works on a --test run"]); return }
            guard let tab = find(request, in: browser), let x = request["x"] as? Double, let y = request["y"] as? Double,
                  let pick = request["pick"] as? String
            else { answer(missing(request)); return }
            house(tab)
            let web = tab.web
            let inView = NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y)
            let point = web.convert(inView, to: nil)
            PageView.picking = pick
            PageView.seen = []
            let hold = request["hold"] as? Double ?? 0
            PageView.pickHold = hold
            for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: web.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .rightMouseDown ? 1 : 0
                ) else { continue }
                if type == .rightMouseDown { web.rightMouseDown(with: event) } else { web.rightMouseUp(with: event) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2 + hold) {
                PageView.picking = nil
                answer([
                    "menu": PageView.seen,
                    "tabs": browser.tabs.map { Bench.short($0) },
                    "urls": browser.tabs.map { $0.address?.absoluteString ?? "" },
                    "active": browser.activeID.flatMap { id in browser.tabs.first { $0.id == id } }.map { Bench.short($0) } ?? "",
                ])
            }

        case "shot":
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            house(tab)
            let path = (request["path"] as? String)
                ?? NSTemporaryDirectory() + "search-bench-\(Bench.short(tab)).png"
            let width = request["width"] as? Double
            shoot(tab, to: URL(fileURLWithPath: path), width: width, answer)

        case "newtabframes":
            guard let window = browser.window, let root = window.contentView else { answer(["error": "no window"]); return }
            func rect(_ view: NSView, _ r: NSRect) -> [Double] {
                let f = view.convert(r, to: nil)
                return [Double(f.minX), Double(window.frame.height - f.maxY),
                        Double(f.width), Double(f.height)].map { ($0 * 2).rounded() / 2 }
            }
            let pages = root.kitSubviews(of: NewTabPageView.self).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            answer(["window": [Double(window.frame.width), Double(window.frame.height)],
                    "content": [Double(root.bounds.width), Double(root.bounds.height)],
                    "pages": pages.map { page in
                        ["view": rect(page, page.bounds), "visible": rect(page, page.visibleRect),
                         "field": page.kitSubviews(of: KitGlass.self).first.map { rect($0, $0.bounds) } ?? [],
                         "lens": page.kitSubviews(of: KitSymbol.self).first.map { rect($0, $0.bounds) } ?? [],
                         "text": (page.kitSubviews(of: AddressTextField.self).first as NSView?
                            ?? page.kitSubviews(of: KitLabel.self).first { !$0.isHiddenOrHasHiddenAncestor && $0.text == NewTabPageView.prompt })
                            .map { rect($0, $0.bounds) } ?? []] as [String: Any]
                    }])
            return

        case "probe":
            // The state of the window itself, for the bug that is not in a
            // page: which panels are up, whether something modal has the
            // app, and every window the app owns.
            var out: [String: Any] = [
                "settings": browser.tuning,
                "passwords": browser.managing,
                // A question hanging from the window (Ask), still unanswered.
                "sheet": browser.window?.attachedSheet != nil,
                // The button of that question that Return presses.
                "sheetReturn": browser.window?.attachedSheet?.defaultButtonCell?.title ?? "",
                "history": browser.recalling,
                "downloads": browser.hoarding,
                "bookmarks": browser.bookmarking,
                // The dropdown off the button, the ⇧⌘B card in it, and how
                // many are kept, for every window alike.
                "bookmarksOpen": browser.bookmarksOpen,
                "downloadsOpen": browser.downloadsOpen,
                "bookmarkCard": browser.bookmarkCard != nil,
                "bookmarkCount": browser.bookmarks.count,
                "import": browser.bringingIn != nil,
                "field": browser.editing,
                "finding": browser.finding,
                "editingLook": browser.editingLook,
                "makingSpace": browser.makingSpace,
                "editingTab": browser.editingTab != nil,
                "peekOpen": browser.peekTab != nil,
                "switcherUp": browser.tabSwitcher.visible,
                "fieldMenu": browser.fieldMenu.showing,
                "settingsDrill": SettingsWindow.shared.benchDetail,
                "suggesting": browser.suggesting != nil,
                "offering": browser.offering != nil,
                "modal": NSApp.modalWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                "look": browser.prefs.look.rawValue,
                "sidePosition": browser.prefs.sidePosition.rawValue,
                "sideWidth": Double(browser.prefs.sideWidth),
                "columnWidth": Double(browser.prefs.columnWidth),
                "appearance": NSApp.appearance?.name.rawValue ?? "system",
                "key": NSApp.keyWindow.map { "\(type(of: $0)) “\($0.title)”" } ?? "",
                // What the keyboard goes to in the key window, or the browser's: a find field,
                // a page, or a button it shouldn't be.
                "responder": (NSApp.keyWindow ?? Links.window)?.firstResponder.map { "\(type(of: $0))" } ?? "",
            ]
            // Whether that is the address field's own editor: a find field or
            // a tab's title being renamed is an NSTextView too.
            if let window = browser.window ?? Links.window, let editor = window.firstResponder as? NSTextView {
                out["responderIsAddress"] = Bench.addressField(in: window.contentView)?.currentEditor() === editor
            } else {
                out["responderIsAddress"] = false
            }
            // What the address field shows, typed and offered ending alike.
            out["fieldText"] = Bench.addressField(in: (browser.window ?? Links.window)?.contentView)?.stringValue ?? ""
            out["windows"] = NSApp.windows.map { window -> [String: Any] in
                [
                    "kind": "\(type(of: window))",
                    "title": window.title,
                    "visible": window.isVisible,
                    "level": window.level.rawValue,
                    "frame": [Int(window.frame.minX), Int(window.frame.minY), Int(window.frame.width), Int(window.frame.height)],
                    "number": window.windowNumber,
                ]
            }
            if let window = browser.window ?? Links.window {
                out["lights"] = Bench.lights(of: window)
                out["glass"] = Bench.glass(in: window)
                out["childGlass"] = (window.childWindows ?? []).flatMap { Bench.glass(in: $0) }
            }
            if let tab = browser.active, let web = tab.built, let window = browser.window ?? Links.window, web.window === window {
                let frame = web.convert(web.bounds, to: nil)
                out["activePageFrame"] = [
                    Int(frame.minX), Int(window.frame.height - frame.maxY),
                    Int(frame.width), Int(frame.height),
                ]
            }
            out["keysQuieted"] = PageView.quieted
            // Settings › General › Web Inspector, as each page's WebKit has it.
            let asked = NSSelectorFromString("_developerExtrasEnabled")
            out["inspector"] = browser.tabs.compactMap { tab -> Bool? in
                guard let preferences = tab.built?.configuration.preferences, preferences.responds(to: asked) else { return nil }
                return preferences.value(forKey: "developerExtrasEnabled") as? Bool
            }
            // Settings › General › Pages at 120 Hz, as each page's WebKit has
            // it: true is held near 60, WebKit's own default.
            out["prefersNear60FPS"] = browser.tabs.compactMap { tab -> Bool? in
                guard let preferences = tab.built?.configuration.preferences else { return nil }
                return FrameRate.prefersNear60(preferences)
            }
            // The column folded away, out for a look, and the lights with it (see Fold.swift).
            out["peek"] = browser.peekTab?.address?.absoluteString ?? ""
            out["peekFrom"] = browser.peekFrom?.uuidString ?? ""
            // The size the peek's page is drawn at (see Tab.applyRememberedZoom).
            out["peekZoom"] = Double(browser.peekTab?.built?.pageZoom ?? 0)
            out["fetching"] = ["showing": browser.fetches.showing, "fraction": browser.fetches.fraction ?? -1, "done": browser.fetches.done]
            // Where the peek's page sits in the window, from its top-left corner, in points.
            if let web = browser.peekTab?.built, let window = web.window {
                let r = web.convert(web.bounds, to: nil)
                out["peekFrame"] = [Int(r.minX), Int(window.frame.height - r.maxY), Int(r.width), Int(r.height)]
            }
            out["folded"] = browser.folded
            out["peeking"] = browser.peeking
            out["sideHides"] = browser.prefs.sideHides
            // The page as a card (see Browser.asCards), and what it is made of.
            out["cards"] = ["switch": browser.prefs.cards, "fullScreen": browser.fullScreen, "on": browser.asCards,
                            "windowFullScreen": (browser.window ?? Links.window)?.styleMask.contains(.fullScreen) ?? false]
            out["lightsHidden"] = Fold.titlebar?.isHidden ?? false
            out["siteCard"] = SiteCardPanel.isShown
            // "Press Esc again to leave full screen", up over a page filling
            // the screen (Settings › General › Press Esc twice to leave full
            // screen).
            out["escapeReminder"] = FullScreenEscape.shared.showing
            if let window = browser.window, let root = window.contentView?.superview {
                func box(_ view: NSView) -> [Int] {
                    let r = view.convert(view.bounds, to: nil)
                    return [Int(r.minX.rounded()), Int((window.frame.height - r.maxY).rounded()), Int(r.width.rounded()), Int(r.height.rounded())]
                }
                func stages(in view: NSView) -> [StageView] {
                    (view as? StageView).map { [$0] } ?? view.subviews.flatMap(stages)
                }
                let found = stages(in: root).filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
                out["stages"] = found.map { stage -> [String: Any] in
                    var entry: [String: Any] = ["frame": box(stage)]
                    if let web = stage.subviews.first(where: { $0 is WKWebView }),
                       let tab = browser.tabs.first(where: { $0.built === web && web.alphaValue > 0 }) {
                        entry["page"] = Bench.short(tab)
                    }
                    return entry
                }
                out["standIns"] = found.flatMap { stage in
                    stage.subviews.filter(StageView.isPlaceholder).map { view -> [String: Any] in
                        var entry: [String: Any] = ["frame": box(view), "hidden": view.isHidden, "stage": box(stage)]
                        if let tab = browser.tabs.first(where: { stage.standIn(for: $0.built) === view }) {
                            entry["tab"] = Bench.short(tab)
                        }
                        return entry
                    }
                }
            }
            out["fullscreenStates"] = browser.tabs.reduce(into: [String: Int]()) { states, tab in
                if let web = tab.built, web.fullscreenState != .notInFullscreen { states[Bench.short(tab)] = web.fullscreenState.rawValue }
            }
            // Whether this Mac lets the browser use its passkeys at all — the
            // one-time permission macOS asks a browser other than Safari for.
            switch ASAuthorizationWebBrowserPublicKeyCredentialManager().authorizationStateForPlatformCredentials {
            case .authorized: out["passkeyAccess"] = "authorized"
            case .denied: out["passkeyAccess"] = "denied"
            default: out["passkeyAccess"] = "notDetermined"
            }
            out["passkeyStatus"] = PasskeyStatus.current.rawValue
            out["dialogs"] = Dialogs.askedInTest
            out["asking"] = browser.asking.map { "\($0.host) \($0.wants)" + ($0.once ? " once" : "") + ($0.keeps ? "" : " unkept") } ?? ""
            out["locationAnswered"] = Browser.locationAnswered ?? ""
            out["passkeyAsks"] = Passkeys.asked
            out["handedOff"] = Browser.handedOff
            out["passkeyLast"] = Passkeys.last
            answer(out)

        case "press":
            // A key pressed on the app as a whole, through its event queue —
            // so its own shortcuts see it first, as they do a real press;
            // `key` goes straight to a page instead. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "press only works on a --test run — it would press keys in your browser"]); return }
            guard let code = request["code"] as? Int, let chars = request["chars"] as? String
            else { answer(["error": "press needs a key code and the characters it types"]); return }
            var flags: NSEvent.ModifierFlags = []
            for name in request["mods"] as? [String] ?? [] {
                switch name {
                case "cmd": flags.insert(.command)
                case "shift": flags.insert(.shift)
                case "ctrl": flags.insert(.control)
                case "opt": flags.insert(.option)
                default: break
                }
            }
            // "repeat": the press a key held down sends again and again.
            let repeats = (request["mods"] as? [String] ?? []).contains("repeat")
            // "sheet": to the question hanging from the window, as a key
            // typed while it is up goes to it.
            if request["toSettings"] as? Bool == true {
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: SettingsWindow.shared.number ?? 0, context: nil,
                    characters: chars, charactersIgnoringModifiers: chars,
                    isARepeat: false, keyCode: UInt16(code)
                ) else { answer(["error": "no such key"]); return }
                let taken = SettingsWindow.shared.press(event)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(["taken": taken]) }
                return
            }
            let number = request["number"] as? Int
                ?? (request["sheet"] as? Bool == true ? browser.window?.attachedSheet : nil)?.windowNumber
                ?? (browser.window ?? Links.window)?.windowNumber ?? 0
            // "letgo": the modifiers let go of, as a flags change with
            // none left, after the press.
            let types: [NSEvent.EventType] = request["letgo"] as? Bool == true
                ? [.keyDown, .keyUp, .flagsChanged] : [.keyDown, .keyUp]
            for type in types {
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: type == .flagsChanged ? [] : flags,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: number, context: nil,
                    characters: chars, charactersIgnoringModifiers: chars,
                    isARepeat: repeats && type == .keyDown, keyCode: UInt16(code)
                ) else { continue }
                NSApp.postEvent(event, atStart: false)
            }
            for letter in request["type"] as? String ?? "" {
                for type: NSEvent.EventType in [.keyDown, .keyUp] {
                    guard let event = NSEvent.keyEvent(
                        with: type, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: number, context: nil,
                        characters: String(letter), charactersIgnoringModifiers: String(letter),
                        isARepeat: false, keyCode: 0
                    ) else { continue }
                    NSApp.postEvent(event, atStart: false)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                answer(["active": browser.active.map { String($0.id.uuidString.prefix(8)).lowercased() } ?? ""])
            }

        case "key":
            // Keys pressed on a tab, as real key events handed to its view —
            // for what the page does with them, and what comes back unused.
            // Only on a SEARCH_PROBE run: it types into a page.
            guard Store.testing else { answer(["error": "key only works on a --test run — it would type into your page"]); return }
            guard let tab = find(request, in: browser), let text = request["text"] as? String else { answer(missing(request)); return }
            house(tab)
            let view = tab.web
            view.window?.makeFirstResponder(view)
            let before = PageView.quieted
            // What WebKit sends back through the app because the page didn't
            // use it: a key press seen here again after it was handed over.
            var pressed: [NSEvent] = []
            var resent = 0
            let watch = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if pressed.contains(where: { PageView.same($0, event) }) { resent += 1 }
                return event
            }
            let code = (request["code"] as? Int).map(UInt16.init)
            let hold = request["hold"] as? Double ?? 0
            func send(_ type: NSEvent.EventType, _ character: Character) {
                let chars = String(character)
                guard let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: view.window?.windowNumber ?? 0, context: nil,
                    characters: chars, charactersIgnoringModifiers: chars,
                    isARepeat: false, keyCode: code ?? Bench.keyCode(for: character)
                ) else { return }
                if type == .keyDown { pressed.append(event); view.keyDown(with: event) } else { view.keyUp(with: event) }
            }
            if hold > 0, let character = text.first {
                send(.keyDown, character)
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) { send(.keyUp, character) }
            } else {
                for character in text {
                    send(.keyDown, character)
                    send(.keyUp, character)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5 + hold) {
                if let watch { NSEvent.removeMonitor(watch) }
                answer(["typed": text, "sentBackUnused": resent, "quieted": PageView.quieted - before])
            }

        case "resize":
            // The window taken to another size in steps, a frame apart, the
            // way a hand drags its corner — for what that does to the title
            // bar. It moves the window, so only on a SEARCH_PROBE run.
            guard Store.testing else {
                answer(["error": "resize only works on a --test run — it would move your window"])
                return
            }
            guard let window = browser.window ?? Links.window,
                  let width = request["width"] as? Double, let height = request["height"] as? Double
            else { answer(["error": "resize needs a width and a height"]); return }
            let steps = max(1, request["steps"] as? Int ?? 12)
            let from = window.frame
            func step(_ n: Int) {
                let t = CGFloat(n) / CGFloat(steps)
                var frame = from
                frame.size.width = from.width + (CGFloat(width) - from.width) * t
                frame.size.height = from.height + (CGFloat(height) - from.height) * t
                frame.origin.y = from.maxY - frame.height
                window.setFrame(frame, display: true)
                if n < steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { step(n + 1) }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        answer(["size": [Int(window.frame.width), Int(window.frame.height)], "lights": Bench.lights(of: window)])
                    }
                }
            }
            step(1)

        case "speakerspot":
            guard Store.testing, let window = browser.window, let content = window.contentView else {
                answer(["error": "speakerspot is for test runs"]); return
            }
            let spots = content.kitSubviews(of: CloseSpotView.self).filter { $0.swaps && !$0.isHiddenOrHasHiddenAncestor }
            if let over = request["over"] as? Bool { for spot in spots { spot.mark.over = over } }
            answer(["spots": spots.map { spot -> [String: Any] in
                let frame = spot.convert(spot.bounds, to: nil)
                let glyph = spot.mark.kitSubviews(of: KitSymbol.self).first
                let layer = spot.layer.map { $0.presentation() ?? $0 }
                return ["x": frame.minX, "y": window.frame.height - frame.maxY, "side": frame.width,
                        "glyph": glyph?.style.size ?? 0, "image": [glyph?.image?.size.width ?? 0, glyph?.image?.size.height ?? 0],
                        "scale": layer?.transform.m11 ?? 0, "alpha": spot.alphaValue, "over": spot.mark.over, "symbol": spot.symbol]
            }])

        case "hoversweep":
            // The pointer taken down the column's rows and back, one row a
            // frame, for what each crossing costs: how many rows were built
            // again, and how long each pass of the main run loop took
            // meanwhile, from waking to going back to sleep (the event,
            // SwiftUI's update, layout, Core Animation's commit). A hidden
            // probe's window gets no pointer, so each step calls the rows'
            // own hover answers, the one left and then the one entered, as
            // AppKit hands them over in one pass. Test runs only.
            guard Store.testing else { answer(["error": "hoversweep is for test runs"]); return }
            guard let window = browser.window ?? Links.window else { return }
            let prefs = browser.prefs
            // The rows on screen, top to bottom.
            let fit = Int((Double(window.frame.height) - Double(Metrics.strip) - 60) / (Double(prefs.sideRow) + 2))
            let order = browser.displayedTabs.map(\.id).filter { Bench.hoverRows[$0] != nil }
            let rows = max(1, min(request["rows"] as? Int ?? fit, fit, order.count))
            let interval = request["interval"] as? Double ?? 1.0 / 60
            let ids = Array(order.prefix(rows))
            let path = ids + ids.reversed().dropFirst()
            var under: Tab.ID?
            func send(_ id: Tab.ID?) {
                if let under, under != id { Bench.hoverRows[under]?(false) }
                if let id, id != under { Bench.hoverRows[id]?(true) }
                under = id
            }
            let clock = LoopClock()
            Bench.bodies = [:]
            clock.start()
            func walk(_ n: Int) {
                guard n < path.count else {
                    send(nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        clock.stop()
                        let crossings = path.count
                        answer([
                            "rows": rows, "crossings": crossings, "tabs": browser.tabs.count,
                            "bodies": Bench.bodies,
                            "crossingMs": LoopClock.summary(clock.marked),
                            "otherMs": LoopClock.summary(clock.unmarked),
                        ])
                    }
                    return
                }
                clock.mark()
                send(path[n])
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { walk(n + 1) }
            }
            walk(0)

        case "pointer":
            // What a page's own tracking areas hand their owners as the
            // pointer goes over it — a move, or the pointer coming in — and a
            // press, at a point of the window from its top-left, straight to
            // the page's view whatever lies over it there (see PageView's
            // covered). The window never sees them, the probe being hidden.
            // Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "pointer only works on a --test run"]); return }
            guard let tab = find(request, in: browser), let web = tab.built, let window = web.window,
                  let x = request["x"] as? Double, let y = request["y"] as? Double
            else { answer(["error": "pointer needs a tab's id, an x and a y"]); return }
            let point = NSPoint(x: x, y: Double(window.frame.height) - y)
            let stamp = ProcessInfo.processInfo.systemUptime
            func mouse(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: stamp,
                                   windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                   clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)
            }
            // A move or an entry goes where AppKit sends it: to the owner of
            // each of the page's tracking areas that asked for it, which for
            // WebKit's own is not the view (see PointerGate).
            func track(_ option: NSTrackingArea.Options, _ selector: Selector, _ event: NSEvent) {
                for area in web.trackingAreas where area.options.contains(option) {
                    if let owner = area.owner as? NSObject, owner.responds(to: selector) { _ = owner.perform(selector, with: event) }
                }
            }
            switch request["what"] as? String ?? "move" {
            case "press":
                if let down = mouse(.leftMouseDown) { web.mouseDown(with: down) }
                if let up = mouse(.leftMouseUp) { web.mouseUp(with: up) }
            case "enter":
                if let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: point, modifierFlags: [], timestamp: stamp,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        trackingNumber: 0, userData: nil) {
                    track(.mouseEnteredAndExited, #selector(NSResponder.mouseEntered(with:)), entered)
                }
            default:
                if let moved = mouse(.mouseMoved) { track(.mouseMoved, #selector(NSResponder.mouseMoved(with:)), moved) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // "covered": the page took it as under cover, and heard nothing.
                answer(["peek": browser.peekTab?.address?.absoluteString ?? "", "peeking": browser.peeking,
                        "covered": web.covered,
                        "ungated": web.trackingAreas.filter { $0.owner !== web && !($0.owner is PointerGate) }.count])
            }

        case "hit":
            // What a press at a point of the window lands on, and whether
            // AppKit would carry the window off on a drag from there — the
            // question behind a tab that moved the window instead of itself.
            // Only looked at, unless asked for a double-click.
            guard let window = browser.window ?? Links.window, let x = request["x"] as? Double, let y = request["y"] as? Double,
                  let frame = window.contentView?.superview
            else { answer(["error": "hit needs an x and a y"]); return }
            let point = NSPoint(x: x, y: Double(window.frame.height) - y)
            let hit = frame.hitTest(frame.convert(point, from: nil))
            if request["middle"] as? Bool == true {
                // The middle button pressed and let go there. A probe's window
                // is hidden and takes no events through the app, so they are
                // handed to the view that catches the middle button over the
                // tabs (MiddleClick in TabBar.swift), the topmost one there.
                guard Store.testing else { answer(["error": "hit … middle only works on a --test run"]); return }
                func catcher(in view: NSView) -> NSView? {
                    for sub in view.subviews.reversed() { if let found = catcher(in: sub) { return found } }
                    guard String(describing: type(of: view)).contains("Catch") else { return nil }
                    return view.convert(view.bounds, to: nil).contains(point) ? view : nil
                }
                guard let target = catcher(in: frame) else { answer(["error": "nothing catches the middle button there"]); return }
                let before = browser.tabs.count
                for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .otherMouseUp ? 0 : 1
                    ) else { continue }
                    if type == .otherMouseDown { target.otherMouseDown(with: event) } else { target.otherMouseUp(with: event) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    answer(["tabsBefore": before, "tabsAfter": browser.tabs.count])
                }
                return
            }
            if request["click"] as? Bool == true {
                guard Store.testing else { answer(["error": "hit … click only works on a --test run"]); return }
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                         pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                    if type == .leftMouseDown { hit?.mouseDown(with: event) } else { hit?.mouseUp(with: event) }
                }
                answer(["view": hit.map { String("\(type(of: $0))".prefix(60)) } ?? ""])
                return
            }
            if request["double"] as? Bool == true {
                // A double-click there, handed to the view under it — through
                // the window it would never arrive, the probe being in the
                // back. On a test run only, and meant for a probe started
                // hidden, where the window changing size shows on no screen.
                guard Store.testing else { answer(["error": "hit … double only works on a --test run"]); return }
                let before = window.frame
                func event(_ type: NSEvent.EventType, _ clicks: Int) -> NSEvent? {
                    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                       pressure: type == .leftMouseUp ? 0 : 1)
                }
                for clicks in [1, 2] {
                    if let down = event(.leftMouseDown, clicks) { hit?.mouseDown(with: down) }
                    if let up = event(.leftMouseUp, clicks) { hit?.mouseUp(with: up) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    let after = window.frame
                    answer(["view": hit.map { String("\(type(of: $0))".prefix(60)) } ?? "",
                            "before": [Int(before.width), Int(before.height)], "after": [Int(after.width), Int(after.height)],
                            "zoomed": window.isZoomed])
                }
                return
            }
            answer([
                "view": hit.map { String("\(type(of: $0))".prefix(60)) } ?? "",
                "standIn": sequence(first: hit, next: { $0?.superview }).contains { $0.map(StageView.isPlaceholder) == true },
                "canMoveWindow": hit?.mouseDownCanMoveWindow ?? false,
                "windowMovable": window.isMovable,
                "titleBar": y <= Double(window.frame.height - window.contentLayoutRect.height),
            ])

        case "field":
            // Text put into the address field the way a paste puts it — the
            // whole of it replacing what is selected — or typed a character
            // at a time, each timed from the moment it goes in to the moment
            // the run loop next rests: the list worked out, SwiftUI's update
            // and Core Animation's commit included. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "field only works on a --test run — it would type into your browser"]); return }
            guard let text = request["text"] as? String, !text.isEmpty else { answer(["error": "field needs some text"]); return }
            let pieces = request["type"] as? Bool == true ? text.map(String.init) : [text]
            if browser.fieldShowing { browser.askFocus() } else { browser.edit() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let field = Bench.addressField(in: (browser.window ?? Links.window)?.contentView),
                      let editor = field.currentEditor() as? NSTextView
                else { answer(["error": "the address field has no editor"]); return }
                var times: [[Double]] = []
                @MainActor func next(_ index: Int) {
                    guard index < pieces.count else {
                        var out: [String: Any] = ["field": field.stringValue, "typed": browser.typed, "offers": browser.offers.map(\.key), "ms": times]
                        guard request["go"] as? Bool == true, let tab = browser.active else { answer(out); return }
                        // Then Return, as the field's own delegate takes it:
                        // how long until WebKit is loading the page.
                        out["viewWasBuilt"] = tab.built != nil
                        let start = CACurrentMediaTime()
                        var loading: Double?
                        let watch = Bench.whenLoading(tab, since: start) { loading = $0 }
                        browser.submit()
                        out["returned"] = (CACurrentMediaTime() - start) * 1000
                        Bench.whenResting(since: start) { rested in
                            out["rested"] = rested
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                watch.cancel()
                                out["loading"] = loading ?? -1
                                answer(out)
                            }
                        }
                        return
                    }
                    let start = CACurrentMediaTime()
                    editor.insertText(pieces[index], replacementRange: NSRange(location: NSNotFound, length: 0))
                    let inserted = (CACurrentMediaTime() - start) * 1000
                    Bench.whenResting(since: start) { rested in
                        guard request["settle"] as? Bool == true else {
                            times.append([inserted, rested])
                            DispatchQueue.main.async { next(index + 1) }
                            return
                        }
                        Bench.whenQuiet(since: start) { settled in
                            times.append([inserted, rested, settled])
                            DispatchQueue.main.async { next(index + 1) }
                        }
                    }
                }
                next(0)
            }

        case "switcher":
            // The ⌃Tab switcher as it stands: up or not, the pick, and where
            // the panel and each card are in the window (top-left points).
            let sw = browser.tabSwitcher
            // "keys": Settings › Tabs › Keys in the tab switcher, on or off.
            if let on = request["keys"] as? Bool { browser.prefs.switcherKeys = on }
            func short(_ id: Tab.ID?) -> String {
                browser.tabs.first { $0.id == id }.map { Bench.short($0) } ?? ""
            }
            func box(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
            answer([
                "visible": sw.visible, "selected": short(sw.selectedID),
                "candidates": sw.candidates.map { short($0) },
                "muted": browser.tabs.filter(\.muted).map { short($0.id) },
                "panel": box(sw.panelFrame),
                "cards": Dictionary(sw.cardFrames.map { (short($0.key), box($0.value)) }, uniquingKeysWith: { a, _ in a }),
                "active": short(browser.activeID),
            ])

        case "recording":
            // The recording pill (RecordingIndicator.swift): lines put up as
            // ExtensionCapture would, a page lent to it, what it shows, and a
            // picture of it drawn off every screen. A test run never puts
            // the pill itself on a screen. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "recording only works on a --test run"]); return }
            let pill = RecordingIndicator.shared
            func state(_ extra: [String: Any] = [:]) -> [String: Any] {
                var out: [String: Any] = [
                    "lines": pill.lines.map { [$0.id, $0.name, $0.what] },
                    "recordingTabs": browser.tabs.filter(\.recording).map { Bench.short($0) },
                    "onScreen": NSApp.windows.contains { $0 is NSPanel && $0.isVisible && $0.contentView?.subviews.contains { $0 is RecordingPillView } == true },
                ]
                out.merge(extra) { _, new in new }
                return out
            }
            switch request["action"] as? String ?? "state" {
            case "show":
                let names = request["names"] as? [String] ?? ["Loom"]
                let what = request["what"] as? String ?? "is recording your screen"
                let page = find(request, in: browser)?.built
                pill.update(names.map { RecordingLine(id: $0.lowercased(), name: $0, what: what) }, pages: page.map { [$0] } ?? [])
                answer(state())
            case "stop":
                var stopped = ""
                pill.onStop = { stopped = $0 }
                pill.stop(request["name"] as? String ?? "")
                answer(state(["stopped": stopped]))
            case "clear": pill.update([]); answer(state())
            case "host", "release":
                guard let tab = find(request, in: browser), let web = tab.built else { answer(missing(request)); return }
                // Where the page was before it was lent, to check it comes back there.
                if request["action"] as? String == "host" {
                    Bench.lentFrom[ObjectIdentifier(web)] = web.superview.map { WeakView($0) } ?? WeakView(nil)
                    pill.host(web)
                } else {
                    pill.release(web)
                }
                let home = Bench.lentFrom[ObjectIdentifier(web)]?.view
                answer(state(["hosted": pill.hosts(web), "backHome": web.superview === home]))
            case "picture":
                guard let path = request["path"] as? String, let rep = pill.picture(dark: request["dark"] as? Bool == true),
                      let data = rep.representation(using: .png, properties: [:]) else { answer(["error": "no picture"]); return }
                try? data.write(to: URL(fileURLWithPath: path))
                answer(state(["saved": path]))
            default: answer(state())
            }

        case "suggest":
            // The engine's suggestions under the field (EngineSuggest.swift):
            // the rows, how many questions went out, were let go of or were
            // too slow, and a row taken as a click takes it. Only on a
            // SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "suggest only works on a --test run"]); return }
            func kind(_ offer: Suggestion) -> String {
                switch offer.kind {
                case .suggested: "suggested"
                case .search: "search"
                case .open: "open"
                case .visited: "visited"
                case .bookmark: "bookmark"
                case .known: "known"
                case .command: "command"
                case .passage: "passage"
                case .action: "action"
                case .answer: "answer"
                case .snippet: "snippet"
                case .placed: "placed"
                }
            }
            func state(_ extra: [String: Any] = [:]) -> [String: Any] {
                var out: [String: Any] = [
                    "typed": browser.typed, "editing": browser.editing,
                    "offers": browser.offers.map { [$0.key, kind($0), $0.url.absoluteString] },
                    // The grey rest of an address the field would finish to.
                    "ending": browser.ending ?? "",
                    "asked": browser.suggester.asked, "cancelled": browser.suggester.cancelled,
                    "tooSlow": browser.suggester.tooSlow,
                    "on": browser.prefs.engineSuggests, "shy": browser.active?.shy ?? false,
                    "address": browser.active?.address?.absoluteString ?? "",
                    "pending": browser.active?.pending?.absoluteString ?? "",
                ]
                out.merge(extra) { _, new in new }
                return out
            }
            if let on = request["on"] as? Bool { browser.prefs.engineSuggests = on }
            switch request["action"] as? String ?? "state" {
            case "take":
                let index = request["index"] as? Int ?? 0
                guard browser.offers.indices.contains(index) else { answer(state(["error": "no row \(index)"])); return }
                browser.take(browser.offers[index])
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(state()) }
            case "walk":
                browser.walk(request["step"] as? Int ?? 1)
                answer(state(["picked": browser.picked ?? -1, "completed": browser.completed]))
            case "go":
                browser.submit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(state()) }
            case "esc": browser.dismiss(); answer(state())
            case "sendable":
                answer(["sendable": EngineSuggest.sendable(request["text"] as? String ?? "")])
            default: answer(state())
            }

        case "sitesearch":
            // Search a site from the address field (SiteSearch.swift): what
            // it offers and holds, Tab, ⌫ in an empty field, Esc, Return,
            // and the sites it has learned. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "sitesearch only works on a --test run"]); return }
            func state(_ extra: [String: Any] = [:]) -> [String: Any] {
                var out: [String: Any] = [
                    "offer": browser.siteOffer?.name ?? "", "chip": browser.siteChip?.name ?? "",
                    "typed": browser.typed, "offers": browser.offers.map { [$0.key, $0.url.absoluteString] },
                    "editing": browser.editing, "learned": SiteSearch.learned.map { [$0.name, $0.host, $0.template] },
                    "address": browser.active?.address?.absoluteString ?? "",
                ]
                out.merge(extra) { _, new in new }
                return out
            }
            switch request["action"] as? String ?? "state" {
            case "tab": answer(state(["took": browser.lockSiteOffer()]))
            case "delete":
                guard let field = Bench.addressField(in: (browser.window ?? Links.window)?.contentView),
                      let editor = field.currentEditor() as? NSTextView else { answer(["error": "no field editor"]); return }
                editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                answer(state())
            case "esc": browser.dismiss(); answer(state())
            case "go":
                browser.submit()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { answer(state(["pending": browser.active?.pending?.absoluteString ?? ""])) }
            case "learn":
                guard let page = (request["page"] as? String).flatMap(URL.init(string:)),
                      let description = (request["description"] as? String).flatMap(URL.init(string:)) else {
                    answer(["error": "sitesearch learn needs page and description"]); return
                }
                SiteSearch.learn(from: page, description: description)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { answer(state()) }
            case "adopt":
                // A learned site kept as learn keeps one, past the fetch: the
                // name a description gives itself is never read.
                SiteSearch.adopt(host: request["host"] as? String ?? "", template: request["template"] as? String ?? "")
                answer(state())
            case "forget": SiteSearch.forget(); answer(state())
            default: answer(state())
            }

        case "bookmark":
            // A bookmark picked from the button's list, through the same
            // call the list makes: how long until WebKit is loading it, and
            // until the run loop rests. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "bookmark only works on a --test run — it would load a page in your tab"]); return }
            guard let url = (request["url"] as? String).flatMap(Address.url(from:)) else { answer(["error": "bookmark needs a url"]); return }
            // "new": into a new tab, whose page has yet to be built.
            if request["new"] as? Bool == true { browser.newTab() }
            guard let tab = browser.active else { answer(["error": "no tab to open it in"]); return }
            browser.bookmarksOpen = true
            let built = tab.built != nil
            var loading: Double?
            let start = CACurrentMediaTime()
            let watch = Bench.whenLoading(tab, since: start) { loading = $0 }
            browser.pickBookmark(url)
            let returned = (CACurrentMediaTime() - start) * 1000
            Bench.whenResting(since: start) { rested in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    watch.cancel()
                    answer(["returned": returned, "loading": loading ?? -1, "rested": rested,
                            "viewWasBuilt": built, "listStillOpen": browser.bookmarksOpen, "sameTab": browser.active?.id == tab.id])
                }
            }

        case "dropdown":
            let dropdown = BookmarksDropdown(browser: browser, bookmarks: browser.bookmarks)
            dropdown.fillAll()
            answer(["items": BenchMenus.describe(dropdown.menu),
                    "lone": BookmarksDropdown.lone(browser.bookmarks.roots)?.title ?? ""])

        case "marks":
            // Each bookmark wherever it is shown, nothing drawn on a screen:
            // the bar's buttons laid out off every screen, with their size;
            // each of the bar's folders as the menu it opens, and the menu
            // bar's Bookmarks menu, every folder in them opened; and the
            // button's list, row by row — each with what it reads and
            // whether it wears the site's icon or a letter in its place.
            guard Store.testing else { answer(["error": "marks only works on a --test run"]); return }
            // "rename": [url, name] — typed into the ⇧⌘B card's Name field.
            if let pair = request["rename"] as? [String], pair.count == 2,
               let url = URL(string: pair[0]), let kept = browser.bookmarks.bookmark(for: url) {
                BookmarkCardView.rename(kept.id, pair[1], in: browser.bookmarks)
            }
            func line(_ depth: Int, _ item: NSMenuItem) -> [String: Any] {
                ["depth": depth, "title": item.title, "folder": item.submenu != nil, "image": item.image != nil]
            }
            let bar = browser.bookmarks.roots.map { node -> [String: Any] in
                let size = BookmarksBarItem(node: node, icon: nil).fitting
                return ["label": node.label, "title": node.title, "unnamed": node.unnamed,
                        "width": Double(size.width), "height": Double(size.height)]
            }
            let folders = browser.bookmarks.roots.filter(\.isFolder).map { folder -> [String: Any] in
                ["folder": folder.title, "items": BookmarkMenu.shared.walk(folder).map { line($0.depth, $0.item) }]
            }
            var menu: [[String: Any]] = []
            if let main = NSApp.mainMenu?.items.first(where: { $0.title == "Bookmarks" })?.submenu {
                main.delegate?.menuNeedsUpdate?(main)
                func down(_ items: [NSMenuItem], _ depth: Int) {
                    for item in items where item.tag == 0x5EAC && !item.isSeparatorItem {
                        menu.append(line(depth, item))
                        if let sub = item.submenu {
                            sub.delegate?.menuNeedsUpdate?(sub)
                            down(sub.items, depth + 1)
                        }
                    }
                }
                down(main.items, 0)
            }
            func rows(_ nodes: [Bookmark], _ depth: Int) -> [[String: Any]] {
                nodes.flatMap { node -> [[String: Any]] in
                    [["depth": depth, "label": node.label, "folder": node.isFolder,
                      "icon": !node.isFolder && Favicons.shared.cached(for: node.address) != nil]] + rows(node.children ?? [], depth + 1)
                }
            }
            // "path": the button's list drawn there, every folder open, in
            // the light, off every screen.
            if let path = request["path"] as? String {
                let all = Set(Bookmarks.folders(browser.bookmarks.roots).map(\.node.id))
                let outline = BookmarkOutlineView(bookmarks: browser.bookmarks, expanded: all, shown: nil, open: { _ in }, openInNewTab: { _ in })
                let host = KitBox(fill: Palette.NS.ground)
                host.addSubview(outline)
                outline.frame = NSRect(x: 6, y: 6, width: 268, height: outline.fittingHeight())
                host.frame = NSRect(x: 0, y: 0, width: 280, height: outline.fittingHeight() + 12)
                host.appearance = NSAppearance(named: .aqua)
                host.layoutSubtreeIfNeeded()
                if let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: picture)
                    try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
            }
            answer(["bar": bar, "folders": folders, "menu": menu, "list": rows(browser.bookmarks.roots, 0),
                    "shown": BookmarksBar.seen(in: browser.window?.contentView)])

        case "import":
            guard Store.testing else { answer(["error": "import only works on a --test run"]); return }
            let found = ImportSource.installed()
            guard let source = found.first(where: { $0.name == request["from"] as? String }) else {
                answer(["found": found.map(\.name)])
                return
            }
            // The profile used most recently unless another is named, by its
            // folder or the name the browser gives it; "all" for every one.
            let profile: String?
            switch request["profile"] as? String {
            case nil: profile = source.usual
            case "all": profile = nil
            case let name?:
                guard let match = source.profiles.first(where: { $0.id == name || $0.name == name }) else {
                    answer(["error": "no profile “\(name)” in \(source.name)", "profiles": source.profiles.map(\.id)])
                    return
                }
                profile = match.id
            }
            let what = request["what"] as? [String] ?? []
            var out: [String: Any] = ["found": found.map(\.name), "profiles": source.profiles.map(\.id),
                                      "profile": profile ?? "all"]
            if what.contains("bookmarks") {
                let (added, already, kept) = browser.takeBookmarks(from: source, profile: profile, replacing: request["replace"] as? Bool == true)
                out["bookmarks"] = ["added": added, "already": already, "kept": kept, "total": browser.bookmarks.count,
                                    "top": browser.bookmarks.roots.map(\.title)]
            }
            if what.contains("history") {
                let places = source.places(profile: profile)
                for place in places { browser.history.take(place.url, title: place.title, count: place.count, last: place.last) }
                browser.history.settle()
                out["places"] = places.count
                ImportRecords.note(source.name, places: places.count)
            }
            if what.contains("passwords") {
                let outcome = Result { try source.read(profile: profile) }
                switch outcome {
                case .success(let read): out["read"] = read.logins.count; out["skipped"] = read.skipped
                    out["undecrypted"] = read.undecrypted
                case .failure(let error): out["error"] = "\(error)"
                }
                browser.took(outcome, from: source.name)
                out["saved"] = browser.saved.count
            }
            if what.contains("spaces") {
                if let sidebar = source.arcSidebar(profile: profile) {
                    let (spaces, pins, tabs) = browser.takeArc(sidebar, from: source, profile: profile)
                    ImportRecords.note(source.name, spaces: spaces, pinned: pins + tabs)
                    out["arc"] = ["spaces": spaces, "pins": pins, "tabs": tabs,
                                  "names": browser.spaces.map(\.name), "usesSpaces": browser.prefs.usesSpaces]
                } else {
                    out["arc"] = "no Arc sidebar"
                }
            }
            // What is now recorded from it, as the sheet shows it.
            if let record = ImportRecords.of(source.name) {
                out["record"] = ["bookmarks": record.bookmarks, "places": record.places, "passwords": record.passwords,
                                 "ids": record.bookmarkIDs.count]
            }
            answer(out)

        case "import-preview":
            // What the sheet counts as it opens, for every browser found:
            // its profiles, the one used most recently, and what that one
            // and all of them hold — through the same call the sheet makes,
            // which never asks for a key. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "import-preview only works on a --test run"]); return }
            let asked = Chromium.keyAsks
            func counts(_ preview: ImportSource.Preview) -> [String: Any] {
                ["bookmarks": preview.bookmarks, "places": preview.places, "passwords": preview.passwords,
                 "extensions": preview.extensions]
            }
            let found = ImportSource.installed().map { source -> [String: Any] in
                let usual = source.usual
                return ["name": source.name,
                        "profiles": source.profiles.map { ["id": $0.id, "name": $0.name] },
                        "default": usual ?? "",
                        "counts": counts(source.preview(profile: usual)),
                        "all": counts(source.preview(profile: nil))]
            }
            // keyAsked: by this count; keyAskedEver: by anything since launch,
            // the sheet opening included.
            answer(["browsers": found, "safari": ImportSource.safari, "keyAsked": Chromium.keyAsks - asked,
                    "keyAskedEver": Chromium.keyAsks])

        case "import-file":
            // A file another browser exported, through the same call the
            // File… buttons make after their chooser. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "import-file only works on a --test run"]); return }
            guard let path = request["path"] as? String else { answer(["error": "import-file needs a path"]); return }
            Task { @MainActor in
                let took = await browser.takeFile(URL(fileURLWithPath: path))
                answer(["said": took.said, "bookmarks": took.bookmarks, "already": took.already, "places": took.places,
                        "kept": took.kept, "skipped": took.skipped, "cancelled": took.cancelled,
                        "total": browser.bookmarks.count, "top": browser.bookmarks.roots.map(\.title), "saved": browser.saved.count])
            }

        case "remove-folder":
            // The bookmarks list's Remove on a top-level folder, question and
            // all: the real sheet, which `press` with "sheet" answers. Only on
            // a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "remove-folder only works on a --test run"]); return }
            guard let title = request["title"] as? String,
                  let folder = browser.bookmarks.roots.first(where: { $0.isFolder && $0.title == title })
            else { answer(["error": "no top-level folder by that title"]); return }
            browser.bookmarks.askRemove(folder)
            answer(["asked": title])
        case "passwords":
            // The passwords panel's list, narrowed as its search box would
            // narrow it, and with "remove" its Remove All… / Remove N…, which
            // `ui confirm` answers. Only on a SEARCH_PROBE run: it takes
            // passwords out of the keychain (the test world's own, by label).
            guard Store.testing else { answer(["error": "passwords only works on a --test run"]); return }
            if let filter = request["filter"] as? String { browser.hunting = filter }
            // "shown": the list as the page holds it now, not read again,
            // so a route to the page that never read it shows as empty.
            if request["shown"] as? Bool != true { browser.relist() }
            if request["remove"] as? Bool == true { browser.forgetShown() }
            // Answered once the removals, off the main thread, are done.
            func settled() {
                guard !browser.forgetting else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { settled() }
                    return
                }
                answer(["count": browser.saved.count, "shown": browser.shownSites.reduce(0) { $0 + $1.logins.count },
                        "announced": browser.announcement ?? ""])
            }
            settled()

        case "history":
            // History on a --test run: "take" puts an address in as an import
            // would, since a bench tab's visits never enter it; "forget" drops
            // one as the panel's cross does. Answers with every address kept.
            guard Store.testing else { answer(["error": "history only works on a --test run"]); return }
            if let text = request["take"] as? String, let url = Address.url(from: text) {
                browser.history.take(url, title: text, count: request["count"] as? Int ?? 1, last: Date())
                browser.history.settle()
            }
            if let text = request["forget"] as? String, let url = Address.url(from: text) {
                browser.history.forget(History.identity(for: url))
            }
            answer(["history": browser.history.everything().map(\.url.absoluteString)])

        case "import-panel":
            guard Store.testing else { answer(["error": "import-panel only works on a --test run"]); return }
            if let path = request["file"] as? String { ImportModel.benchFile = URL(fileURLWithPath: path) }
            let page = NSApp.windows.compactMap { $0.contentView?.kitSubviews(of: ImportPageView.self).first }.first
            guard let page else { answer(["open": false, "bringing": browser.bringingIn ?? ""]); return }
            page.layoutSubtreeIfNeeded()
            let model = page.model
            let rows = page.kitSubviews(of: ImportSourceRow.self)
            let shown = Set(page.kitSubviews(of: NSView.self).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { $0.identifier?.rawValue })
            let lead = page.kitSubviews(of: PagePill.self).first { $0.identifier?.rawValue == "import.bring" }
            answer(["open": true, "looking": model.looking, "safari": model.safari, "onSafari": model.onSafari,
                    "pick": model.onSafari ? ImportSource.safariName : model.pick?.name ?? "",
                    "rows": rows.map { $0.accessibilityLabel() ?? "" }, "chosen": rows.filter { $0.chosen }.map { $0.accessibilityLabel() ?? "" },
                    "shown": shown.filter { $0.hasPrefix("import.") || $0.hasPrefix("settings.row.import.") }.sorted(),
                    "lead": lead.map { $0.isHiddenOrHasHiddenAncestor ? "" : $0.title } ?? "",
                    "openedSafari": model.openedSafari, "busy": model.bringing,
                    "brought": (model.brought ?? []).map(\.text), "total": browser.bookmarks.count,
                    "top": browser.bookmarks.roots.map(\.title)])

        case "import-file-start":
            guard Store.testing else { answer(["error": "import-file only works on a --test run"]); return }
            guard let path = request["path"] as? String else { answer(["error": "import-file needs a path"]); return }
            guard browser.fileImport == nil else { answer(["error": "import already running"]); return }
            Task { @MainActor in _ = await browser.takeFile(URL(fileURLWithPath: path)) }
            answer(["started": true])

        case "import-file-status":
            guard Store.testing else { answer(["error": "import-file only works on a --test run"]); return }
            if let job = browser.fileImport {
                answer(["running": true, "filename": job.filename, "message": job.message,
                        "completed": job.completed, "total": job.total ?? -1, "cancelling": job.cancelling])
            } else { answer(["running": false]) }

        case "import-file-cancel":
            guard Store.testing else { answer(["error": "import-file only works on a --test run"]); return }
            browser.cancelFileImport()
            answer(["cancelling": browser.fileImport?.cancelling ?? false])

        case "tab-type":
            // The field in the tab, on the tab in front: the edit begun as a
            // click on it does, what is given typed into it key by key as the
            // keyboard would, then "keys" (down, up, return, delete) pressed.
            // What the field and its list are left showing. Test runs only.
            guard Store.testing else { answer(["error": "tab-type only works on a --test run"]); return }
            guard let tab = browser.active else { answer(["error": "no tab"]); return }
            if browser.editingTab != tab.id { browser.beginTabEdit(tab) }
            let text = request["text"] as? String ?? ""
            let keys = request["keys"] as? [String] ?? []
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let editor = browser.window?.firstResponder as? NSTextView,
                      let field = editor.delegate as? NSTextField else { answer(["error": "the field isn't focused"]); return }
                if request["clear"] as? Bool == true { editor.selectAll(nil); editor.deleteBackward(nil) }
                for ch in text { editor.insertText(String(ch), replacementRange: editor.selectedRange()) }
                for key in keys {
                    switch key {
                    case "down": editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
                    case "up": editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
                    case "return": editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                    case "delete": editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
                    default: break
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    let selected = editor.selectedRange()
                    var shot = ""
                    if let path = request["picture"] as? String, TabOffersPanel.picture(to: path) { shot = path }
                    answer(["field": field.stringValue, "selected": [selected.location, selected.length],
                            "offers": browser.tabOffers.map { "\($0.key) | \($0.url.absoluteString)" },
                            "picked": browser.tabPicked ?? -1, "listShown": TabOffersPanel.isShown,
                            "editing": browser.editingTab != nil, "draft": browser.tabDraft,
                            "active": browser.active?.address?.absoluteString ?? "", "picture": shot])
                }
            }

        case "settings":
            // Settings as SettingsIndex has it (Tests/settings_layout.py):
            // every row with its section, group and keys; what Find a
            // setting finds for some words; a merged control moved as its
            // row moves it; the merged values read back. Test runs only.
            guard Store.testing else { answer(["error": "settings only works on a --test run"]); return }
            if let id = request["set"] as? String {
                guard let value = request["value"], SettingsIndex.apply(id, value, to: browser.prefs) else {
                    answer(["error": "settings set ID VALUE: unknown id or value"]); return
                }
            }
            if request["forget"] as? Bool == true { browser.forgetCaptureChoices() }
            var reply: [String: Any] = ["values": SettingsIndex.values(browser.prefs),
                                        "settingsPage": browser.settingsPage.rawValue,
                                        "speeds": Dictionary(uniqueKeysWithValues: VideoSpeed.sites().map { ($0.site, $0.rate) }),
                                        "lastQuality": VideoQuality.last() ?? 0]
            if let words = request["find"] as? String {
                reply["found"] = SettingsIndex.find(words).map(SettingsIndex.describe)
            } else {
                reply["items"] = SettingsIndex.items.map(SettingsIndex.describe)
                reply["pages"] = SettingsPage.blocks.flatMap { $0 }.map(\.rawValue)
            }
            if let y = request["scroll"] as? Double { reply["scrolled"] = SettingsWindow.shared.benchScroll(to: y) }
            if let wheel = request["wheel"] as? [Double], wheel.count == 3 {
                reply["wheeled"] = SettingsWindow.shared.benchWheel(by: wheel[0], at: NSPoint(x: wheel[1], y: wheel[2]))
            }
            if let id = request["row"] as? String {
                let rows = browser.window?.contentView?.kitSubviews(of: SettingsRowView.self).filter { !$0.isHiddenOrHasHiddenAncestor } ?? []
                reply["rows"] = rows.map(\.rowID)
                if let row = rows.first(where: { $0.rowID == id }) {
                    let toggle = row.kitSubviews(of: KitSwitch.self).first
                    let lineHeight = NSLayoutManager().defaultLineHeight(for: row.detail.font ?? SettingsMetrics.detailFont)
                    reply["row"] = ["detail": row.detail.stringValue, "alpha": Double(row.alphaValue), "on": toggle?.isOn ?? false,
                                    "detailWidth": Double(row.detail.frame.width), "detailLines": Int((row.detail.frame.height / lineHeight).rounded()),
                                    "enabled": toggle?.isEnabled ?? false, "more": row.kitSubviews(of: NSButton.self).contains { $0.accessibilityLabel()?.hasPrefix("More about") == true }] as [String: Any]
                }
            }
            let setup = AgentSetup.shared
            reply["agentSetup"] = ["runs": setup.runs, "open": setup.open(), "marked": setup.marked, "on": browser.prefs.agentsOn] as [String: Any]
            if request["chrome"] as? Bool == true { reply["chrome"] = SettingsWindow.shared.benchChrome() }
            if request["stage"] as? Bool == true { reply["stage"] = SettingsWindow.shared.benchStage() }
            answer(reply)

        case "floataway":
            guard Store.testing else { answer(["error": "floataway only works on a --test run"]); return }
            Float.benchAway = NSPoint(x: -30000, y: -30000)
            browser.toggleFloat()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                answer(["floating": browser.floater.showing, "tab": browser.floating.map { $0.uuidString } ?? ""])
            }

        case "lingering":
            guard Store.testing else { answer(["error": "lingering only works on a --test run"]); return }
            let playing = NSSelectorFromString("_isPlayingAudio")
            answer(["floating": browser.floating?.uuidString ?? "", "showing": browser.floater.showing,
                    "announced": browser.announcement ?? "",
                    "views": Tab.letGo.allObjects.map { web -> [String: Any] in
                ["url": web.url?.absoluteString ?? "", "address": "\(Unmanaged.passUnretained(web).toOpaque())", "superview": web.superview.map { "\(type(of: $0))" } ?? "",
                 "window": web.window.map { "\(type(of: $0))" } ?? "",
                 "playing": web.responds(to: playing) && (web.value(forKey: "_isPlayingAudio") as? Bool ?? false),
                 "process": web.responds(to: NSSelectorFromString("_webProcessIdentifier")) ? (web.value(forKey: "_webProcessIdentifier") as? Int ?? 0) : -1]
            }])

        case "player":
            guard Store.testing else { answer(["error": "player only works on a --test run"]); return }
            Float.benchAway = NSPoint(x: -30000, y: -30000)
            if let host = (request["url"] as? String).flatMap(URL.init(string:))?.host() { Players.benchHosts.insert(host) }
            answer(["players": Array(Players.benchHosts)])

        case "closebelow":
            guard Store.testing else { answer(["error": "closebelow only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            browser.closeTabsBelow(tab)
            answer(["tabs": browser.tabs.count])

        case "undoclose":
            guard Store.testing else { answer(["error": "undoclose only works on a --test run"]); return }
            guard let undo = browser.window?.undoManager else { answer(["error": "no undo manager"]); return }
            let title = undo.undoMenuItemTitle
            let could = undo.canUndo
            let undoing = NSSelectorFromString("undo:")
            func items(_ menu: NSMenu?) -> [NSMenuItem] { (menu?.items ?? []).flatMap { [$0] + items($0.submenu) } }
            let item = items(NSApp.mainMenu).first { $0.action == undoing }
            if let page = browser.active?.built { browser.window?.makeFirstResponder(page) }
            let responder = browser.window?.firstResponder
            if let item, let target = responder?.supplementalTarget(forAction: undoing, sender: item) as? NSResponder ?? sequence(first: responder, next: { $0?.nextResponder }).compactMap({ $0 }).first(where: { $0.responds(to: undoing) }) {
                _ = (target as? NSMenuItemValidation)?.validateMenuItem(item)
            }
            let menuTitle = item?.title ?? ""
            let sent = responder?.tryToPerform(undoing, with: nil) ?? false
            answer(["title": title, "could": could, "sent": sent, "responder": responder.map { "\(type(of: $0))" } ?? "",
                    "menuKey": item?.keyEquivalent ?? "", "menuTitle": menuTitle, "tabs": browser.tabs.count])

        case "closekey":
            guard Store.testing else { answer(["error": "closekey only works on a --test run"]); return }
            let key = request["settings"] as? Bool == true ? NSApp.window(withWindowNumber: SettingsWindow.shared.number ?? -1) : browser.window
            NSApp.activate(ignoringOtherApps: true)
            key?.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let before = browser.tabs.count
                let wasKey = NSApp.keyWindow === key
                let taken = Browsers.pressClose(shift: request["shift"] as? Bool == true, in: key)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    answer(["taken": taken, "tabs": [before, browser.tabs.count], "settingsOpen": SettingsWindow.shared.isOpen,
                            "browserOpen": browser.window?.isVisible == true, "wasKey": wasKey,
                            "menuBrowserKey": Front.shared.browserKey])
                }
            }

        case "menus":
            // Every menu of the menu bar, by title, after SwiftUI has filled
            // it — and whether the AI add-on counts as on. Reads only.
            guard Store.testing else { answer(["error": "menus only works on a --test run"]); return }
            var menus: [String: [String]] = [:]
            var keys: [[String: Any]] = []
            var shown: [String: [String: Bool]] = [:]
            func walk(_ menu: NSMenu, path: String) {
                for entry in menu.items where !entry.isSeparatorItem && !entry.isHidden {
                    if !entry.keyEquivalent.isEmpty {
                        let flags = entry.keyEquivalentModifierMask
                        keys.append(["path": "\(path) › \(entry.title)", "key": entry.keyEquivalent.lowercased(),
                                     "command": flags.contains(.command), "shift": flags.contains(.shift) || entry.keyEquivalent != entry.keyEquivalent.lowercased(),
                                     "option": flags.contains(.option), "control": flags.contains(.control), "enabled": entry.isEnabled])
                    }
                    if let sub = entry.submenu { walk(sub, path: "\(path) › \(entry.title)") }
                }
            }
            for item in NSApp.mainMenu?.items ?? [] {
                guard let menu = item.submenu else { continue }
                menu.delegate?.menuNeedsUpdate?(menu)
                menus[item.title] = menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
                shown[item.title] = Dictionary(menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map { ($0.title, $0.isEnabled) },
                                               uniquingKeysWith: { first, _ in first })
                walk(menu, path: item.title)
            }
            answer(["menus": menus, "keys": keys, "enabled": shown, "ai": browser.prefs.ai, "textActions": browser.prefs.textActions,
                    "settingsPages": SettingsPage.allCases.map(\.rawValue),
                    "settingsPage": browser.settingsPage.rawValue])

        case "textcheck":
            // Text replacement, smart quotes and smart dashes: what the Mac
            // says, what the page's view says, and Edit › Substitutions as it
            // would open, with its ticks. toggle NAME: the menu's own action,
            // which writes WebKit's default in the app's standard domain —
            // the real Search's, for a probe of the real app — so only in a
            // copy under a bundle id of its own (Tests/text_replacement.py).
            guard Store.testing else { answer(["error": "textcheck only works on a --test run"]); return }
            let web = find(request, in: browser)?.built ?? browser.active?.built
            if let name = request["toggle"] as? String {
                guard Store.ownContainer else {
                    answer(["error": "textcheck toggle only works in a copy under its own bundle id — it would switch the real Broadway's setting"])
                    return
                }
                guard let kind = Substitution(rawValue: name) else { answer(["error": "toggle quotes|dashes|replacement"]); return }
                browser.toggleSubstitution(kind, in: web)
            }
            // The menu bar is drawn again a moment after the browser changes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                var mac: [String: Bool] = [:], page: [String: Bool] = [:], kept: [String: Any] = [:]
                let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
                for kind in Substitution.allCases {
                    mac[kind.rawValue] = kind.mac
                    page[kind.rawValue] = kind.isOn(in: web)
                    kept[kind.rawValue] = domain[kind.key] ?? NSNull()
                }
                var items: [[String: Any]] = []
                if let edit = NSApp.mainMenu?.items.first(where: { $0.title == "Edit" })?.submenu {
                    edit.delegate?.menuNeedsUpdate?(edit)
                    if let sub = edit.items.first(where: { $0.title == "Substitutions" })?.submenu {
                        sub.delegate?.menuNeedsUpdate?(sub)
                        items = sub.items.filter { !$0.isSeparatorItem && !$0.isHidden }
                            .map { ["title": $0.title, "on": $0.state == .on] }
                    }
                }
                answer(["mac": mac, "page": page, "kept": kept, "menu": items, "web": web != nil])
            }

        case "menu":
            // The Bookmarks menu as it is about to open: the menu bar
            // told it is being tracked, SwiftUI's own update run on it, its
            // first folder opened — then what each holds. Only on a
            // SEARCH_PROBE run; nothing is drawn.
            guard Store.testing else { answer(["error": "menu only works on a --test run"]); return }
            guard let main = NSApp.mainMenu, let menu = main.items.first(where: { $0.title == "Bookmarks" })?.submenu
            else { answer(["error": "no Bookmarks menu"]); return }
            // "peek": only what is in it now, nothing opened or filled — to
            // see what an update while it is open left of the bookmarks.
            // "shown"/"hidden": the menu told it opened or closed, as tracking would.
            if request["shown"] as? Bool == true {
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
                menu.delegate?.menuWillOpen?(menu)
            }
            if request["swiftui"] as? Bool == true { BookmarkMenu.shared.swiftUIUpdate() }
            if request["hidden"] as? Bool == true {
                menu.delegate?.menuDidClose?(menu)
                NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: main)
            }
            if request["peek"] as? Bool == true {
                answer(["ours": BookmarkMenu.shared.count, "items": menu.items.count])
                return
            }
            let before = menu.items.count
            let wrapped = menu.delegate.map { "\(type(of: $0))" } ?? "none"
            let start = CACurrentMediaTime()
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: main)
            let filled = (CACurrentMediaTime() - start) * 1000
            menu.delegate?.menuNeedsUpdate?(menu)
            let folder = menu.items.first { $0.submenu != nil && $0.tag != 0 }?.submenu
            if let folder { folder.delegate?.menuNeedsUpdate?(folder) }
            // "open": the first bookmark in that folder picked, as a click would.
            if request["open"] as? Bool == true, let folder,
               let index = folder.items.firstIndex(where: { $0.representedObject is URL }) {
                folder.performActionForItem(at: index)
            }
            answer(["delegate": wrapped, "before": before, "after": menu.items.count, "ours": BookmarkMenu.shared.count, "fillMs": filled,
                    "titles": menu.items.prefix(8).map { $0.isSeparatorItem ? "—" : $0.title },
                    "firstFolder": folder?.items.prefix(4).map(\.title) ?? [],
                    "firstFolderImages": folder?.items.prefix(4).map { $0.image != nil } ?? [],
                    "active": browser.active?.address?.absoluteString ?? ""])

        case "keyeq":
            // A ⌘ shortcut pressed while the page has the keyboard, put
            // through the app's key handling and then to the page's view, as
            // AppKit does with a key window — which a hidden probe hasn't.
            // Reports what Search did and what the page saw. Only on a
            // SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "keyeq only works on a --test run"]); return }
            guard let tab = browser.active, let web = tab.built, let window = web.window,
                  let chars = request["chars"] as? String, let code = request["code"] as? Int
            else { answer(["error": "keyeq needs a loaded tab, the characters and the key code"]); return }
            var flags: NSEvent.ModifierFlags = [.command]
            if (request["mods"] as? [String] ?? []).contains("shift") { flags.insert(.shift) }
            window.makeFirstResponder(web)
            guard let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: UInt16(code)
            ) else { answer(["error": "no event"]); return }
            let before = (finding: browser.finding, summoning: browser.editing, folded: browser.folded)
            var firstPass = "search"
            if ContentView.keyHooks[ObjectIdentifier(browser)]?(event) != nil {
                firstPass = "page"
                _ = web.performKeyEquivalent(with: event)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                web.evaluateJavaScript("JSON.stringify(window.__keys || [])") { seen, _ in
                    MainActor.assumeIsolated {
                        answer(["firstPass": firstPass, "pageSaw": seen as? String ?? "",
                                "finding": [before.finding, browser.finding], "fieldUp": [before.summoning, browser.editing],
                                "folded": [before.folded, browser.folded]])
                    }
                }
            }

        case "image-text":
            guard Store.testing else { answer(["error": "image-text only works on a --test run"]); return }
            guard let id = request["id"] as? String,
                  let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }),
                  let text = request["url"] as? String, let url = URL(string: text)
            else { answer(["error": "image-text needs a tab and url"]); return }
            if request["state"] as? Bool == true {
                answer(["text": ImageText.board.string(forType: .string) ?? "",
                        "announcement": browser.announcement ?? "",
                        "running": tab.imageTextTask != nil])
                return
            }
            let menu = browser.imageMenu(for: tab, at: url)
            guard let index = menu.items.firstIndex(where: { $0.title == "Copy Text" }) else {
                answer(["error": "no Copy Text item"]); return
            }
            if request["clear"] as? Bool == true { ImageText.board.clearContents() }
            menu.performActionForItem(at: index)
            let work = tab.imageTextTask
            if request["start"] as? Bool == true {
                answer(["started": true, "menu": menu.items.map(\.title)])
                return
            }
            if request["close"] as? Bool == true { browser.closeTab(tab) }
            Task {
                await work?.value
                answer(["text": ImageText.board.string(forType: .string) ?? "",
                        "announcement": browser.announcement ?? "",
                        "cancelled": work?.isCancelled ?? false,
                        "menu": menu.items.map(\.title)])
            }

        case "image-data":
            // What Copy Image would put on the pasteboard, without putting it
            // there: the picture at an address, read as the menu reads it.
            guard Store.testing else { answer(["error": "image-data only works on a --test run"]); return }
            guard let tab = (request["id"] as? String).flatMap({ id in browser.tabs.first { $0.id.uuidString.lowercased().hasPrefix(id) } }) ?? browser.active,
                  let text = request["url"] as? String, let url = URL(string: text)
            else { answer(["error": "image-data needs a url"]); return }
            Task {
                let data = await browser.imageData(at: url, in: tab)
                let image = data.flatMap { NSImage(data: $0) }
                answer(["bytes": data?.count ?? 0, "image": image.map { [Int($0.size.width), Int($0.size.height)] } ?? []])
            }

        case "find":
            // Find on Page as typed into its bar, then Next or Previous
            // pressed, and what the bar says once the page has answered.
            guard Store.testing else { answer(["error": "find only works on a --test run"]); return }
            if request["close"] as? Bool == true {
                browser.closeFind()
                answer(["finding": browser.finding])
                return
            }
            let start = Date()
            browser.finding = true
            browser.matchCase = request["case"] as? Bool ?? false
            browser.wholeWords = request["words"] as? Bool ?? false
            // The same words again would count as Next, as they do in the bar.
            let text = request["text"] as? String ?? ""
            if browser.needle != text { browser.needle = text }
            for _ in 0..<(request["next"] as? Int ?? 0) { browser.look(forward: true) }
            for _ in 0..<(request["back"] as? Int ?? 0) { browser.look(forward: false) }
            func settled(_ tries: Int) {
                let status = browser.findStatus
                if (status != nil && !browser.findBusy) || tries > 200 {
                    answer(["status": status ?? "", "ms": Int(Date().timeIntervalSince(start) * 1000)])
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { settled(tries + 1) }
            }
            settled(0)
        case "translate":
            // Translate Page on a tab, as its menu does, answered once the
            // first pass is in (what it measured); original puts it back;
            // state is the tab's sign, its frames, the last page menu and
            // the languages always translated; always/never LANG are the
            // sign's Always Translate. Changing anything: test runs only.
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let action = request["action"] as? String ?? "start"
            guard Store.testing || ["state", "start", "original"].contains(action) else {
                answer(["error": "translate \(action) only works on a --test run"]); return
            }
            let state: () -> [String: Any] = {
                var mark: [String: Any] = [:]
                if let m = tab.translation {
                    mark = ["from": m.from ?? "", "to": m.to]
                    switch m.phase {
                    case .working: mark["phase"] = "working"
                    case .done: mark["phase"] = "done"
                    case .failed(let message): mark["phase"] = "failed"; mark["message"] = message
                    }
                }
                return [
                    "enabled": PageTranslator.enabled, "available": PageTranslator.available,
                    "mark": mark, "running": tab.translator != nil, "frames": tab.translateFrames.count,
                    "report": tab.translator?.report ?? [:], "menu": tab.built?.translateItem()?.title ?? "",
                    "always": browser.prefs.translateAlways.sorted(), "tabAlways": tab.translateLanguages.sorted(),
                    "wake": tab.translateOnWake?.to ?? "", "shy": tab.shy,
                ]
            }
            switch action {
            case "original":
                tab.translator?.end(restore: true)
                answer(state())
            case "state":
                answer(state())
            case "toggle":
                // What choosing the page menu's item does.
                guard let item = tab.built?.translateItem() else { answer(["error": "no Translate Page item"]); return }
                tab.built?.perform(item.action, with: item)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { answer(state()) }
            case "always", "never":
                guard let code = request["lang"] as? String else { answer(["error": "translate always|never LANG"]); return }
                tab.setAlwaysTranslates(code, action == "always")
                answer(state())
            default:
                let target = (request["lang"] as? String).map(Locale.Language.init(identifier:)) ?? PageTranslator.reader(for: tab)
                if PageTranslator.start(tab, to: target, done: { report in
                    var reply = state()
                    reply["report"] = report
                    answer(reply)
                }) == nil { return }
            }

        case "parked":
            guard Store.testing else { answer(["error": "parked only works on a --test run"]); return }
            answer(["pages": SpaceStageView.parkedPages(browser).map { space, tab -> [String: Any] in
                let web = tab.built
                let picture = browser.spacePictures.image(for: tab, in: space)?.size
                return ["space": space.uuidString, "inWindow": web?.window != nil,
                        "size": web.map { [Double($0.frame.width), Double($0.frame.height)] } ?? [],
                        "picture": picture.map { [Double($0.width), Double($0.height)] } ?? []]
            }])

        case "overhang":
            guard let content = browser.window?.contentView else { answer(["error": "overhang needs a window"]); return }
            var found: [[String: Any]] = []
            for web in content.kitSubviews(of: PageView.self) where !web.isHiddenOrHasHiddenAncestor {
                guard let root = web.layer else { continue }
                let bounds = root.bounds
                func walk(_ layer: CALayer, _ clip: CGRect, _ path: String) {
                    guard !layer.isHidden, layer.opacity > 0 else { return }
                    let name = "\(path)/\(type(of: layer))"
                    let frame = layer.convert(layer.bounds, to: root)
                    let seen = frame.intersection(clip)
                    if !seen.isNull, seen.width > 0.01, seen.height > 0.01,
                       seen.minX < bounds.minX - 0.01 || seen.maxX > bounds.maxX + 0.01 || seen.minY < bounds.minY - 0.01 || seen.maxY > bounds.maxY + 0.01 {
                        found.append(["layer": String(name.suffix(160)), "left": Double(bounds.minX - seen.minX), "right": Double(seen.maxX - bounds.maxX),
                                      "top": Double(bounds.minY - seen.minY), "bottom": Double(seen.maxY - bounds.maxY)])
                    }
                    let inner = layer.masksToBounds || layer.mask != nil ? clip.intersection(frame) : clip
                    for sub in layer.sublayers ?? [] { walk(sub, inner, name) }
                }
                let open = CGRect(x: -1e6, y: -1e6, width: 2e6, height: 2e6)
                walk(root, root.masksToBounds ? bounds : open, "")
            }
            answer(["layers": found])

        case "layersAt":
            guard let window = browser.window, let frameView = window.contentView?.superview, let root = frameView.layer else {
                answer(["error": "layersAt needs a window"]); return
            }
            let x = request["x"] as? Double ?? 0
            let top = request["y"] as? Double ?? 0
            let reach = request["reach"] as? Double ?? 0.5
            let point = CGPoint(x: x, y: root.isGeometryFlipped ? top : Double(root.bounds.height) - top)
            var found: [[String: Any]] = []
            func walk(_ layer: CALayer, _ path: String) {
                guard !layer.isHidden else { return }
                let name = "\(path)/\(type(of: layer))" + (layer.delegate.map { "(\(type(of: $0)))" } ?? "")
                let frame = layer.convert(layer.bounds, to: root)
                if frame.insetBy(dx: -reach, dy: 0).contains(point) {
                    var row: [String: Any] = ["layer": String(name.suffix(220)), "frame": [frame.minX, Double(root.bounds.height) - frame.maxY, frame.width, frame.height].map { Double($0) },
                                              "opacity": Double(layer.opacity), "contents": layer.contents != nil, "mask": layer.mask != nil, "clips": layer.masksToBounds,
                                              "corner": Double(layer.cornerRadius), "border": Double(layer.borderWidth)]
                    if let bg = layer.backgroundColor { row["bg"] = NSColor(cgColor: bg)?.description ?? "?" }
                    if let border = layer.borderColor, layer.borderWidth > 0 { row["borderColor"] = NSColor(cgColor: border)?.description ?? "?" }
                    if let shape = layer as? CAShapeLayer, let fill = shape.fillColor { row["fill"] = NSColor(cgColor: fill)?.description ?? "?" }
                    if layer.filters?.isEmpty == false || layer.compositingFilter != nil || layer.backgroundFilters?.isEmpty == false { row["filters"] = true }
                    found.append(row)
                }
                for sub in layer.sublayers ?? [] { walk(sub, name) }
            }
            walk(root, "")
            answer(["layers": found])

        case "visible":
            // Refused: it lent the tab to a window of its own, off every
            // screen, so that WebKit would count the page as seen. No bench
            // verb makes a window for now, off screen or not, after windows
            // reached a screen during test runs; what needs a page to be
            // seen is checked on a release candidate instead.
            answer(["error": "visible is switched off: it made a window, and no bench verb makes one for now — check this on a release candidate"])

        case "ai":
            // The AI add-on's requests against a stand-in on this Mac: "mock"
            // points every provider at it, "key" keeps a made-up key for the
            // run (in memory), "ask" sends one question and gives back the
            // whole answer or the error. Only on a SEARCH_PROBE run, and only
            // ever to the loopback address.
            guard Store.testing else { answer(["error": "ai only works on a --test run"]); return }
            switch request["action"] as? String {
            case "fake":
                let plan = (request["plan"] as? String).flatMap(Plan.init(rawValue:)) ?? .claude
                if request["hang"] as? Bool == true {
                    Plans.shared.standIn(FakeProvider(plan: plan, script: [.emit(.started(model: nil)), .emit(.text("Working ")),
                                                                           .emit(.toolStarted(id: "1", name: "snapshot", summary: "Reading")),
                                                                           .emit(.toolFinished(id: "1", failed: false)), .hang]), for: plan)
                } else if let words = request["answer"] as? String {
                    Plans.shared.standIn(FakeProvider(plan: plan, script: [.emit(.started(model: nil)), .emit(.text(words)),
                                                                           .emit(.finished(ProviderUsage()))]), for: plan)
                } else {
                    Plans.shared.standIn(FakeProvider(plan: plan, echoes: true), for: plan)
                }
                Plans.shared.standIn(FakeProvider(plan: plan.other, echoes: true), for: plan.other)
                if let mac = request["mac"] as? Bool {
                    let fake = FakeProvider(plan: .thisMac, echoes: true)
                    if !mac { fake.fakeStatus = PlanStatus() }
                    Plans.shared.standIn(fake, for: .thisMac)
                }
                Task { @MainActor in
                    await Plans.shared.refresh()
                    answer(["plan": plan.rawValue, "choice": Plans.shared.choice(.tasks, browser.prefs)?.label ?? ""])
                }
            case "task-ask":
                guard let id = AgentSessions.shared.live.keys.first else { answer(["error": "no task is running"]); return }
                let asked = AgentSessions.Waiting(question: request["text"] as? String ?? "", inBroadway: request["person"] as? Bool ?? false)
                answer(["said": AgentSessions.shared.raise(id, asked).text ?? ""])
            case "task-clear":
                guard let id = AgentSessions.shared.live.keys.first else { answer(["error": "no task is running"]); return }
                AgentSessions.shared.clear(id)
                answer(["ok": true])
            case "line", "question":
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                browser.select(tab)
                Task { @MainActor in
                    if browser.ai.line == nil { await browser.openLine(tab) }
                    if let text = request["text"] as? String {
                        browser.ai.line?.draft = text
                        browser.ai.line?.run()
                    }
                    answer(browser.aiState())
                }
            case "escape":
                answer(["used": browser.benchEscape()])
            case "frames":
                answer(["frames": browser.lineFrames()])
            case "state":
                answer(browser.aiState())
            case "sent":
                var out: [String: Any] = [:]
                for plan in Plan.allCases {
                    guard let fake = Plans.shared.provider(plan) as? FakeProvider else { continue }
                    out[plan.rawValue] = ["count": fake.requests.count, "tools": fake.requests.map { $0.tools == .none ? "none" : "some" },
                                          "prompts": fake.requests.map(\.prompt)]
                }
                answer(["sent": out, "announced": browser.announcement ?? ""])
            case "select":
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                browser.select(tab)
                let js = request["js"] as? String ?? ""
                tab.web.evaluateJavaScript(js) { _, _ in
                    MainActor.assumeIsolated {
                        browser.moreCommands()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(browser.aiState()) }
                    }
                }
            case "take":
                browser.ai.commands?.index = request["index"] as? Int ?? 0
                if let commands = browser.ai.commands { commands.take(browser) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(browser.aiState()) }
            case "primary":
                if let result = browser.ai.result { browser.primary(result) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(browser.aiState()) }
            case "picture":
                guard let path = request["path"] as? String else { answer(["error": "ai picture PATH"]); return }
                var made: [String] = []
                if let tab = browser.active, let doing = tab.agentActing, !tab.driving {
                    let badge = AgentActingBadgeView(doing: doing)
                    let size = badge.fittingSize
                    let ground = KitBox(fill: Palette.NS.wash)
                    ground.appearance = browser.window?.effectiveAppearance
                    ground.frame = NSRect(x: 0, y: 0, width: size.width + 40, height: size.height + 40)
                    badge.frame = NSRect(x: 20, y: 20, width: size.width, height: size.height)
                    ground.addSubview(badge)
                    ground.layoutSubtreeIfNeeded()
                    let url = URL(fileURLWithPath: path).appendingPathComponent("ai-acting.png")
                    if let picture = ground.bitmapImageRepForCachingDisplay(in: ground.bounds) {
                        ground.cacheDisplay(in: ground.bounds, to: picture)
                        if (try? picture.representation(using: .png, properties: [:])?.write(to: url)) != nil { made.append(url.path) }
                    }
                }
                answer(["made": made])
            case "read":
                // What of the page would go to the model, and nothing sent.
                guard let tab = find(request, in: browser) else { answer(missing(request)); return }
                Task { @MainActor in
                    guard let read = await AIPage.read(tab) else { answer(["error": "nothing to read"]); return }
                    Bench.aiRead = read
                    answer(["title": read.title, "text": read.text, "links": read.links.count, "cut": read.cut])
                }
            case "check":
                // The last page read, and an answer checked against it.
                guard let read = Bench.aiRead, let text = request["text"] as? String else {
                    answer(["error": "ai read a page first, then ai check TEXT"]); return
                }
                answer(["strays": AIPage.strays(in: text, from: read)])
            default:
                answer(["error": "ai fake [PLAN] | read ID | check TEXT"])
            }

        case "notifications":
            // What a test run would have posted, and every site's answer.
            guard Store.testing else { answer(["error": "notifications only works on a --test run"]); return }
            answer(["recorded": SiteNotifications.shared.recorded, "choices": SiteNotifications.choices,
                    "asking": browser.asking.map { "\($0.host) \($0.wants)" } ?? ""])

        case "localnetwork":
            guard Store.testing else { answer(["error": "localnetwork only works on a --test run"]); return }
            if let site = request["forget"] as? String { LocalNetworkGuard.shared.forget(site) }
            let tab = find(request, in: browser) ?? browser.active
            let controller = tab?.built?.configuration.userContentController
            answer(["attached": controller.map { LocalNetworkGuard.shared.isAttached($0) } ?? false,
                    "compiled": LocalNetworkGuard.shared.list != nil,
                    "blocked": LocalNetworkGuard.shared.blocked,
                    "asking": browser.asking.map { "\($0.host) \($0.wants) \($0.reach)" } ?? "",
                    "sites": LocalNetworkGuard.sites.map { ["site": $0.origin, "allowed": $0.allowed] }])

        case "answer":
            guard Store.testing else { answer(["error": "answer only works on a --test run"]); return }
            switch request["with"] as? String {
            case "once": browser.allowCaptureOnce()
            case "always": browser.allowCapture()
            case "no": browser.denyCapture()
            case "screen": browser.shareScreen()
            case "window": browser.shareWindow()
            case "noscreen": browser.denyShare()
            default: answer(["error": "answer once|always|no|screen|window|noscreen"]); return
            }
            answer(["asking": browser.asking.map { "\($0.host) \($0.wants)" } ?? "", "locationAnswered": Browser.locationAnswered ?? "",
                    "displayAnswered": Browser.displayAnswered as Any? ?? NSNull()])

        case "accounts":
            // The list under the sign-in box the caret is in — passkeys, then
            // passwords — and, with "pick", a click on its row by number,
            // counted from 0. Only on a SEARCH_PROBE run: it would sign in.
            // Also the name the save question would keep ("offer"), and,
            // with "forget", every login this test world kept — its own
            // label's, never another world's or the real one's. "keep" is
            // the save question's Save.
            guard Store.testing else { answer(["error": "accounts only works on a --test run"]); return }
            if request["keep"] as? Bool == true { browser.keepOffer() }
            if request["forget"] as? Bool == true {
                Vault.all().forEach { Vault.forget(host: $0.host, user: $0.user) }
                browser.dropOffer()
            } else if let user = request["forget"] as? String {
                // One account's, as Settings › Passwords forgets it: "" is
                // the login kept under no name.
                Vault.all().filter { $0.user == user }.forEach { Vault.forget(host: $0.host, user: $0.user) }
            }
            let offer: [String: Any] = browser.offering.map { ["user": $0.login.user, "host": $0.login.host, "changed": $0.changed] } ?? [:]
            var holds: [String: Any] = [:]
            if let check = request["check"] as? [String: String], let user = check["user"], let password = check["password"] {
                holds["holds"] = Vault.all().contains { $0.user == user && Vault.secret(of: $0) == password }
            }
            // Every account this world keeps, by name, without a secret.
            let all = Vault.all()
            let users = all.map(\.user)
            let used = all.map { ["host": $0.host, "user": $0.user, "used": $0.used?.timeIntervalSince1970 ?? 0] as [String: Any] }
            guard let list = browser.suggesting else {
                answer(["shown": false, "offer": offer, "kept": users.count, "users": users, "used": used].merging(holds) { $1 }); return
            }
            let strong: [[String: Any]] = list.strong == nil ? [] : [["strong": true]]
            let rows: [[String: Any]] = strong + list.passkeys.map { ["passkey": $0.name] } + list.logins.map { ["login": $0.user] }
            if let press = request["press"] as? [Double], press.count == 2 {
                // A press and a release at a point of the window, from its
                // top-left, handed to whatever the window says is there — the
                // way a click on a row reaches the list, without the pointer.
                guard let window = browser.window, let frame = window.contentView?.superview else {
                    answer(["error": "no window"]); return
                }
                let point = NSPoint(x: press[0], y: Double(window.frame.height) - press[1])
                guard let target = frame.hitTest(frame.convert(point, from: nil)) else { answer(["error": "nothing there"]); return }
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                    else { continue }
                    if type == .leftMouseDown { target.mouseDown(with: event) } else { target.mouseUp(with: event) }
                }
                // What it reached and who has the keys after: a hidden
                // probe's SwiftUI button never fires, so the pick itself is
                // `pick`'s to check.
                answer(["pressed": "\(type(of: target))", "responder": window.firstResponder.map { "\(type(of: $0))" } ?? ""])
                return
            }
            if let pick = request["pick"] as? Int {
                guard rows.indices.contains(pick) else { answer(["error": "no row \(pick)"]); return }
                let at = pick - strong.count
                if at < 0 { browser.chooseStrongPassword() } else if at < list.passkeys.count { browser.choose(list.passkeys[at]) } else { browser.choose(list.logins[at - list.passkeys.count]) }
            }
            var out: [String: Any] = ["shown": true, "rows": rows, "nameOnly": list.nameOnly, "wide": list.wide, "offer": offer, "kept": users.count,
                                      "users": users, "used": used, "spot": [list.spot.minX, list.spot.minY, list.spot.width, list.spot.height]]
            out.merge(holds) { $1 }
            // With Split View's stage, the card as drawn, in the window from
            // its top-left, and the page-sized box it hangs in.
            if let drawn = PaneStage.accountCard() {
                func box(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map { Double($0) } }
                out["card"] = box(drawn.card)
                out["host"] = box(drawn.host)
            }
            if let path = request["picture"] as? String, let host = AccountHost.shown, host.window != nil {
                let area = host.card.insetBy(dx: -16, dy: -16).intersection(host.bounds)
                host.layoutSubtreeIfNeeded()
                if let picture = host.bitmapImageRepForCachingDisplay(in: area) {
                    host.cacheDisplay(in: area, to: picture)
                    out["picture"] = (try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil ? path : ""
                    out["window"] = host.window?.windowNumber ?? 0
                }
            }
            answer(out)

        case "appleoffer":
            // "Use your Apple passwords?" under a sign-in box (ApplePasswordsOffer),
            // which a test run never shows unless asked here. "asks": offer as a
            // person would see it, with a stand-in for Apple's helper that
            // only counts its starts (Apple's own is never run from a test).
            // "helper": false, as on a Mac without it. "show"/"drop": the row
            // up under the tab in front, or the list taken down. "use",
            // "never": its row or its ✕ clicked. "forget": never offered.
            guard Store.testing else { answer(["error": "appleoffer only works on a --test run"]); return }
            if let on = request["asks"] as? Bool {
                ApplePasswordsOffer.benchAsks = on
                if on, browser.applePasswords.standIn == nil {
                    let link = StandInLink()
                    browser.applePasswords = ApplePasswords(makeLink: { link })
                    browser.applePasswords.standIn = link
                }
            }
            if let on = request["helper"] as? Bool { ApplePasswordsOffer.benchHelper = on }
            if request["forget"] as? Bool == true { browser.applePasswordsOffer.forget(); browser.prefs.applePasswords = false }
            if let site = request["show"] as? String, let tab = browser.activeID {
                browser.testOffer(on: tab, site: site, age: request["age"] as? Double ?? 1)
            }
            if request["drop"] as? Bool == true { browser.testOffer(on: nil) }
            if request["use"] as? Bool == true { browser.useApplePasswords() }
            if request["never"] as? Bool == true { browser.neverOfferApplePasswords() }
            let offer = browser.applePasswordsOffer
            answer([
                "asks": ApplePasswordsOffer.benchAsks,
                "offered": offer.offered.sorted(),
                "unanswered": offer.store.integer(forKey: ApplePasswordsOffer.unansweredKey),
                "never": offer.store.bool(forKey: ApplePasswordsOffer.neverKey),
                "retired": offer.retired,
                "row": browser.suggesting?.appleOffer ?? "",
                "shown": browser.suggesting != nil,
                "on": browser.prefs.applePasswords,
                "pairing": browser.applePairing != nil,
                "state": "\(browser.applePasswords.state)",
                "standInStarts": (browser.applePasswords.standIn as? StandInLink)?.starts ?? 0,
            ])

        case "peek":
            // A link's page in the peek panel over the tab in front, as a
            // shift-click on it would open it (see Peek.swift); "close" puts
            // it away. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "peek only works on a --test run"]); return }
            if request["url"] as? String == "close" {
                browser.closePeek()
                answer(["peek": ""])
                return
            }
            guard let tab = browser.active, let text = request["url"] as? String, let url = URL(string: text)
            else { answer(["error": "peek needs a tab in front and an address"]); return }
            browser.peek(url, from: tab)
            answer(["peek": url.absoluteString])

        case "pull":
            // Two fingers sideways over the page: DX points in STEPS scroll
            // events spread over MS milliseconds, with a trackpad's phases,
            // handed to the page's view — for the swipe back and forward.
            // Reports where the tab is after. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "pull only works on a --test run"]); return }
            guard let tab = browser.active, let web = tab.built, let dx = request["dx"] as? Double
            else { answer(["error": "pull needs a loaded tab and a distance"]); return }
            let steps = max(2, request["steps"] as? Int ?? 10)
            let ms = max(1, request["ms"] as? Double ?? 200)
            let before = tab.address?.absoluteString ?? ""
            // Over the middle of the page. An event made here has no window,
            // so AppKit hands WebKit its screen point as the point in the
            // window: left where it starts, the pointer's, the page saw the
            // scroll only while the pointer happened to be over it. Put where
            // the page's middle is in its window, measured the way AppKit
            // measures a screen point (from the top of the main screen).
            let middle = web.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), to: nil)
            let over = CGPoint(x: middle.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - middle.y)
            func send(_ phase: Int64, _ delta: Double) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: Int32(delta), wheel3: 0) else { return }
                cg.location = over
                cg.setIntegerValueField(CGEventField(rawValue: 88)!, value: 1) // kCGScrollWheelEventIsContinuous
                cg.setIntegerValueField(CGEventField(rawValue: 99)!, value: phase) // kCGScrollWheelEventScrollPhase
                cg.setIntegerValueField(CGEventField(rawValue: 97)!, value: Int64(delta)) // kCGScrollWheelEventPointDeltaAxis2
                if let event = NSEvent(cgEvent: cg) { web.scrollWheel(with: event) }
            }
            send(1, 0)
            for n in 1...steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000 * Double(n) / Double(steps)) {
                    send(2, dx / Double(steps))
                    if n == steps { send(request["cancel"] as? Bool == true ? 8 : 4, 0) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000 + 1.2) {
                answer(["before": before, "after": tab.address?.absoluteString ?? ""])
            }

        case "magnify":
            // The trackpad's pinch, as WebKit ends it: the page's scale set
            // around a point (in the view, from its top left), or read back
            // with no scale given. Only on a SEARCH_PROBE run.
            guard Store.testing else { answer(["error": "magnify only works on a --test run"]); return }
            guard let tab = find(request, in: browser), let web = tab.built else { answer(missing(request)); return }
            // ⌘+ and ⌘−'s kind: the page's own zoom, as View › Zoom In sets it.
            if let zoom = request["zoom"] as? Double { tab.magnify(to: CGFloat(zoom)) }
            if let scale = request["scale"] as? Double {
                let x = request["x"] as? Double ?? Double(web.bounds.midX)
                let y = request["y"] as? Double ?? Double(web.bounds.midY)
                web.setMagnification(CGFloat(scale), centeredAt: NSPoint(x: x, y: web.isFlipped ? y : Double(web.bounds.height) - y))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(["magnification": Double(web.magnification), "zoom": Double(web.pageZoom),
                        "size": [Double(web.bounds.width), Double(web.bounds.height)]])
            }

        case "wheel":
            // Two fingers on the trackpad over the page, any way: DX, DY
            // points in STEPS events over MS milliseconds, with a trackpad's
            // phases and, if asked, a glide after. Only on a SEARCH_PROBE run.
            // The page is told eight times the points asked for, as a line
            // of a wheel is eight points; "exact" tells it the points
            // themselves. "x", "y": where over the page, from its top left.
            // "legs": more [DX, DY] strokes before the fingers lift. "hold":
            // milliseconds they rest before lifting. "cancel": the Mac calls
            // the gesture off. "plain": a mouse wheel, with no phases at all.
            // "peek": over the peek's page.
            guard Store.testing else { answer(["error": "wheel only works on a --test run"]); return }
            guard let tab = request["peek"] as? Bool == true ? browser.peekTab : find(request, in: browser), let web = tab.built
            else { answer(missing(request)); return }
            let legs = [[request["dx"] as? Double ?? 0, request["dy"] as? Double ?? 0]] + (request["legs"] as? [[Double]] ?? []).filter { $0.count == 2 }
            let steps = max(2, request["steps"] as? Int ?? 10)
            let ms = max(1, request["ms"] as? Double ?? 200)
            let glide = request["glide"] as? Int ?? 0
            let hold = max(0, request["hold"] as? Double ?? 0) / 1000
            let plain = request["plain"] as? Bool ?? false
            let exact = !plain && request["exact"] as? Bool ?? false
            let x = request["x"] as? Double ?? Double(web.bounds.midX)
            let y = request["y"] as? Double ?? Double(web.bounds.midY)
            let aim = web.convert(NSPoint(x: x, y: web.isFlipped ? y : Double(web.bounds.height) - y), to: nil)
            let over = CGPoint(x: aim.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - aim.y)
            func send(_ phase: Int64, _ momentum: Int64, _ x: Double, _ y: Double) {
                guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: plain ? .line : .pixel, wheelCount: 2, wheel1: Int32(y), wheel2: Int32(x), wheel3: 0) else { return }
                cg.location = over
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: plain ? 0 : 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: momentum)
                if !plain {
                    cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
                    cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
                }
                cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(y))
                cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(x))
                if exact {
                    cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: y)
                    cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: x)
                }
                if let event = NSEvent(cgEvent: cg) { web.scrollWheel(with: event) }
            }
            if !plain {
                send(128, 0, 0, 0)
                send(1, 0, 0, 0)
            }
            let each = ms / 1000 / Double(steps)
            let moving = ms / 1000 * Double(legs.count)
            for (index, leg) in legs.enumerated() {
                for n in 1...steps {
                    DispatchQueue.main.asyncAfter(deadline: .now() + ms / 1000 * Double(index) + each * Double(n)) {
                        send(plain ? 0 : 2, 0, leg[0] / Double(steps), leg[1] / Double(steps))
                    }
                }
            }
            if !plain {
                DispatchQueue.main.asyncAfter(deadline: .now() + moving + hold + 0.001) {
                    send(request["cancel"] as? Bool == true ? 8 : 4, 0, 0, 0)
                }
            }
            let last = legs[legs.count - 1]
            for n in 0..<glide {
                DispatchQueue.main.asyncAfter(deadline: .now() + moving + hold + 0.016 * Double(n + 1)) {
                    let k = pow(0.85, Double(n + 1))
                    send(0, n == 0 ? 1 : (n == glide - 1 ? 3 : 2), last[0] / Double(steps) * k, last[1] / Double(steps) * k)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + moving + hold + 0.016 * Double(glide) + 0.5) {
                answer(["ok": true])
            }

        case "refresh":
            guard Store.testing else { answer(["error": "refresh only works on a --test run"]); return }
            if let on = request["continues"] as? Bool { PullRefresh.continues = on }
            guard let tab = request["peek"] as? Bool == true ? browser.peekTab : find(request, in: browser), let web = tab.built
            else { answer(missing(request)); return }
            if request["clear"] as? Bool == true { web.refresh.forget() }
            if let count = request["sample"] as? Int {
                BenchPull.sample(web, count: count, every: request["every"] as? Double ?? 0.016, answer: answer)
            } else {
                answer(BenchPull.state(web))
            }

        case "discs":
            guard Store.testing else { answer(["error": "discs only works on a --test run"]); return }
            guard let tab = find(request, in: browser) ?? browser.active, let web = tab.built
            else { answer(missing(request)); return }
            if let count = request["sample"] as? Int {
                BenchDisc.sample(in: { [weak web] in web?.window }, count: count, every: request["every"] as? Double ?? 0.008, answer: answer)
            } else {
                answer(["discs": BenchDisc.look(in: web.window)])
            }

        case "columnscroll":
            // The column's rows and their scroll (Side.swift, idea 443): the
            // room under the pins, what the rows add up to and measure,
            // whether they scroll, and where. "wheel": DY points of a mouse
            // wheel, handed to whatever lies under the middle of the column
            // ("y" from the window's top) as AppKit would hand it, so a row
            // that swallowed the wheel would show. Positive goes down the
            // list. Nothing is shown or brought forward. Test runs only.
            guard Store.testing else { answer(["error": "columnscroll only works on a --test run"]); return }
            guard let window = browser.window ?? Links.window, let frame = window.contentView?.superview
            else { answer(["error": "columnscroll needs a window"]); return }
            let width = Double(browser.prefs.columnWidth), whole = Double(window.frame.width)
            let onRight = browser.prefs.sidePosition == .right
            func scrolls(in view: NSView) -> [NSScrollView] {
                (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
            }
            func shown(_ view: NSView) -> Bool {
                var rect = view.convert(view.bounds, to: nil)
                var up = view.superview
                while let at = up { rect = rect.intersection(at.convert(at.bounds, to: nil)); up = at.superview }
                return !view.isHiddenOrHasHiddenAncestor && !rect.isEmpty
            }
            func column() -> NSScrollView? {
                let reach = width + 1 + (browser.folded ? 2 * Double(Metrics.floatGap) : 0)
                return scrolls(in: frame).filter { view in
                    let rect = view.convert(view.bounds, to: nil)
                    return rect.height > 60 && Double(rect.width) <= width + 1 && shown(view)
                        && (onRight ? Double(rect.minX) >= whole - reach : Double(rect.maxX) <= reach)
                }.max { $0.frame.height < $1.frame.height }
            }
            func report() {
                var out: [String: Any] = ["measured": SideColumnView.measured.mapValues { $0.isFinite ? Double($0) : -1 },
                                          "edges": ColumnEdges.seen.mapValues(Double.init),
                                          "marks": ColumnEdges.marks.mapValues { $0.map(Double.init) },
                                          "height": Double(window.frame.height), "scrolls": false]
                out["positions"] = ["list": browser.columnMemory.saved[browser.spaceID]?.list ?? -1,
                                    "landingList": browser.columnMemory.landing.list,
                                    "nativeList": browser.columnMemory.offset(.list) ?? -1,
                                    "restoring": browser.columnMemory.restoring ? 1 : 0]
                out["all"] = scrolls(in: frame).filter(shown).map { view in
                    let rect = view.convert(view.bounds, to: nil)
                    return [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
                }
                if let scroll = column(), let scroller = scroll.verticalScroller {
                    func box(_ rect: NSRect) -> [Double] {
                        let r = scroller.convert(rect, to: nil)
                        return [Double(r.minX), Double(window.frame.height) - Double(r.maxY), Double(r.width), Double(r.height)]
                    }
                    let view = scroll.convert(scroll.bounds, to: nil)
                    out["scroller"] = ["frame": box(scroller.bounds), "knob": box(scroller.rect(for: .knob)),
                                       "shown": !scroller.isHidden && scroller.alphaValue > 0 ? 1 : 0,
                                       "legacy": scroll.scrollerStyle == .legacy ? 1 : 0,
                                       "view": [Double(view.minX), Double(view.maxX)]]
                }
                if let scroll = column(), let document = scroll.documentView {
                    out["scrolls"] = SideColumnView.measured["fits"] == 0
                    out["offset"] = Double(scroll.contentView.bounds.minY)
                    out["visible"] = Double(scroll.contentView.bounds.height)
                    out["content"] = Double(document.frame.height)
                }
                answer(out)
            }
            // "peek": the column folded away (⌘S) and out over the page, as
            // the pointer at the edge brings it, or back in and unfolded.
            if let out = request["peek"] as? Bool {
                if out != browser.folded { browser.toggleFold() }
                browser.peek(out)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { report() }
                return
            }
            if request["flash"] as? Bool == true {
                column()?.flashScrollers()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { report() }
                return
            }
            guard let dy = request["wheel"] as? Double else { report(); return }
            let x = onRight ? whole - width / 2 : width / 2
            let y = request["y"] as? Double ?? Double(window.frame.height) / 2
            let point = NSPoint(x: x, y: Double(window.frame.height) - y)
            guard let under = frame.hitTest(frame.convert(point, from: nil)) else { answer(["error": "nothing under the column there"]); return }
            // Notches of 10 points, as a wheel sends them: down the list is
            // the wheel turned towards you, a negative delta.
            var left = dy
            func turn() {
                guard abs(left) > 0.5 else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { report() }
                    return
                }
                let step = left > 0 ? min(left, 10) : max(left, -10)
                left -= step
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-step), wheel2: 0, wheel3: 0) {
                    cg.location = CGPoint(x: window.frame.minX + point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.minY + point.y))
                    if let event = NSEvent(cgEvent: cg) {
                        let scroll = column()
                        let before = scroll?.contentView.bounds.origin
                        under.scrollWheel(with: event)
                        if let scroll, let before, scroll.documentView != nil, under.isDescendant(of: scroll),
                           scroll.contentView.bounds.origin == before {
                            let proposed = NSRect(origin: NSPoint(x: before.x, y: before.y + step), size: scroll.contentView.bounds.size)
                            let constrained = scroll.contentView.constrainBoundsRect(proposed)
                            scroll.contentView.scroll(to: constrained.origin)
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { turn() }
            }
            turn()

        case "place":
            // A tab put at another place in the row, as a drag would.
            guard let id = request["id"] as? String, let to = request["to"] as? Int,
                  let tab = browser.tabs.first(where: { Bench.short($0) == id && (Store.testing || $0.bench) })
            else { answer(["error": "place needs a tab id and an index"]); return }
            browser.move(tab, to: to)
            answer(["at": browser.tabs.firstIndex { $0.id == tab.id } ?? -1])

        case "adopt":
            guard Store.testing else { answer(["error": "adopt only works on a --test run"]); return }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            tab.bench = false
            answer(describe(tab))

        case "group":
            // Tab groups, as their menus make and change them (TabGroups.swift):
            // a tab into a new group or an existing one, or out; a group
            // folded or opened. Test runs only: it rearranges your tabs.
            guard Store.testing else { answer(["error": "group only works on a --test run"]); return }
            let named = request["name"] as? String ?? ""
            let group = browser.tabGroups.first { $0.name == named || $0.id.uuidString.lowercased().hasPrefix(named.lowercased()) && !named.isEmpty }
            if let id = request["id"] as? String {
                guard let tab = browser.tabs.first(where: { Bench.short($0) == id }) else { answer(["error": "no tab “\(id)” — see tabs"]); return }
                if request["new"] as? Bool == true {
                    let made = browser.addTabGroup(containing: tab)
                    if !named.isEmpty { browser.renameTabGroup(made, to: named) }
                    browser.editingGroupID = nil
                } else if named == "none" {
                    browser.move(tab, toGroup: nil)
                } else if let group {
                    browser.move(tab, toGroup: group.id)
                } else {
                    answer(["error": "no group “\(named)”"]); return
                }
            } else if request["fold"] as? Bool == true {
                guard let group else { answer(["error": "no group “\(named)”"]); return }
                browser.toggleTabGroup(group.id)
                var at = 0.0
                for wait in request["again"] as? [Double] ?? [] {
                    at += wait
                    let id = group.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak browser] in browser?.toggleTabGroup(id) }
                }
            } else if request["close"] as? Bool == true {
                guard let group else { answer(["error": "no group “\(named)”"]); return }
                browser.closeTabGroup(group.id)
            } else if let pinned = request["pinned"] as? Bool {
                guard let group else { answer(["error": "no group “\(named)”"]); return }
                KitChange.eased { browser.setFolderPinned(group.id, pinned) }
            } else if let look = request["look"] as? String {
                guard let group else { answer(["error": "no group “\(named)”"]); return }
                if look == "edit" { browser.editingGroupID = group.id } else if look == "clear" { browser.editingGroupID = nil }
                for page in browser.window?.contentView?.kitSubviews(of: SidePageView.self) ?? [] { page.benchFolder(group.id, look: look) }
            } else if request["ungroup"] as? Bool == true {
                guard let group else { answer(["error": "no group “\(named)”"]); return }
                browser.removeTabGroup(group.id)
            } else if let all = request["all"] as? String {
                // Fold All Groups / Unfold All Groups, from the View menu's
                // item or the space's menu ("via": "view" or "space"), or
                // straight; nothing is shown.
                let title = all == "fold" ? "Shut All Folders" : "Open All Folders"
                switch request["via"] as? String {
                case "view":
                    guard let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu else {
                        answer(["error": "no View menu"]); return
                    }
                    view.delegate?.menuNeedsUpdate?(view)
                    view.update()
                    guard let at = view.items.firstIndex(where: { $0.title == title }) else { answer(["error": "no “\(title)” in View"]); return }
                    view.performActionForItem(at: at)
                case "space":
                    let menu = SpaceMenu.menu(for: browser)
                    guard let at = menu.items.firstIndex(where: { $0.title == title }) else { answer(["error": "no “\(title)” in the space's menu"]); return }
                    menu.performActionForItem(at: at)
                default:
                    browser.foldAllGroups(all == "fold")
                }
            }
            func items(_ menu: NSMenu?) -> [[String: Any]] {
                (menu?.items ?? []).filter { $0.title.hasSuffix("All Folders") }.map {
                    ["title": $0.title, "enabled": $0.isEnabled, "key": $0.keyEquivalent,
                     "option": $0.keyEquivalentModifierMask.contains(.option),
                     "command": $0.keyEquivalentModifierMask.contains(.command)] as [String: Any]
                }
            }
            let view = NSApp.mainMenu?.items.first(where: { $0.title == "View" })?.submenu
            view?.delegate?.menuNeedsUpdate?(view!)
            view?.update()
            // ⌘[ and ⌘] as this keyboard types them, beside which the two sit.
            let tabsMenu = NSApp.mainMenu?.items.first(where: { $0.title == "Tabs" })?.submenu
            let brackets = ["Back", "Forward"].map { title in tabsMenu?.items.first { $0.title == title }?.keyEquivalent ?? "" }
            answer(["viewItems": items(view), "spaceItems": items(SpaceMenu.menu(for: browser)), "brackets": brackets,
                    "on": browser.prefs.usesTabGroups, "groups": browser.tabGroups.map { group in
                ["id": String(group.id.uuidString.prefix(8)).lowercased(), "name": group.name, "collapsed": group.collapsed,
                 "tabs": browser.tabs(in: group.id).map(Bench.short)] as [String: Any]
            }])

        case "tospace":
            // Move to Space from a tab's menu, to the Nth space. Test runs only.
            guard Store.testing else { answer(["error": "tospace only works on a --test run"]); return }
            // "group": a group by name, as its menu's Move Folder to Space.
            if let name = request["group"] as? String, let index = request["index"] as? Int,
               browser.spaces.indices.contains(index - 1) {
                guard let group = browser.tabGroups.first(where: { $0.name == name }) else {
                    answer(["error": "no group “\(name)”"]); return
                }
                browser.move(group: group.id, toSpace: browser.spaces[index - 1].id)
                answer(["space": browser.spaces[index - 1].name, "tabs": browser.tabs.map(Bench.short),
                        "groups": browser.tabGroups.map(\.name)])
                return
            }
            guard let id = request["id"] as? String, let index = request["index"] as? Int,
                  let tab = browser.tabs.first(where: { Bench.short($0) == id }),
                  browser.spaces.indices.contains(index - 1)
            else { answer(["error": "tospace needs a tab id and a space number"]); return }
            browser.move(tab, toSpace: browser.spaces[index - 1].id)
            answer(["space": browser.spaces[index - 1].name, "tabs": browser.tabs.map(Bench.short)])

        case "window":
            // The browser's window, when a probe started hidden came up
            // without one: the Window menu's own item for it.
            guard Store.testing else { answer(["error": "window only works on a --test run"]); return }
            if (browser.window ?? Links.window)?.contentView != nil, NSApp.windows.contains(where: { $0 === (browser.window ?? Links.window) }) {
                answer(["window": "there"])
                return
            }
            let items = NSApp.mainMenu?.items.first { $0.submenu?.title == "Window" }?.submenu?.items ?? []
            guard let item = items.first(where: { $0.title == "Broadway" }), let action = item.action else {
                answer(["error": "no Broadway item in the Window menu", "items": items.map(\.title)])
                return
            }
            NSApp.sendAction(action, to: item.target, from: item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                answer(["window": NSApp.windows.map { "\(type(of: $0))" }, "hidden": NSApp.isHidden])
            }

        case "pages":
            // Pages that WebKit will paint, for `picture`, from a probe started
            // hidden: the app shown again without coming forward, but only
            // once its windows are all off the screen — the browser's own put
            // away, the bench's room far off every screen. Anything of the
            // app's that would show on a screen and the app is hidden again.
            guard Store.testing, let window = browser.window ?? Links.window else { answer(["error": "pages only works on a --test run"]); return }
            func onScreen(_ w: NSWindow) -> Bool { NSScreen.screens.contains { $0.frame.intersects(w.frame) } }
            if request["on"] as? Bool == true {
                _ = room ?? makeRoom()
                window.orderOut(nil)
                for other in NSApp.windows where other !== room && onScreen(other) { other.orderOut(nil) }
                Bench.pagesShown = true
                NSApp.unhideWithoutActivation()
                let showing = NSApp.windows.filter { $0.isVisible && onScreen($0) }
                if !showing.isEmpty {
                    NSApp.hide(nil)
                    answer(["error": "a window would have shown: \(showing.map { "\(type(of: $0))" })"])
                    return
                }
                answer(["pages": true])
            } else {
                NSApp.hide(nil)
                Bench.pagesShown = false
                window.orderFront(nil)
                answer(["pages": false])
            }

        case "picture":
            // The whole window as a picture — the app's own drawing, with each
            // page on screen put in as WebKit pictures it — from a probe
            // started hidden, so nothing shows on anybody's screen. For the
            // images on the site.
            guard Store.testing else { answer(["error": "picture only works on a --test run"]); return }
            guard let window = browser.window ?? Links.window, let frame = window.contentView?.superview,
                  let path = request["path"] as? String, !path.isEmpty
            else { answer(["error": "picture needs a path"]); return }
            func pages(in view: NSView) -> [WKWebView] {
                if let web = view as? WKWebView { return [web] }
                return view.subviews.flatMap(pages)
            }
            // The page, when WebKit paints (see `pages`): the tab's address
            // loaded afresh in a view of its own in the bench's room, sized
            // as the page is, and pictured there.
            if !NSApp.isHidden, request["page"] as? Bool != false, let tab = browser.active, let address = tab.address,
               let live = tab.built, live.window === window {
                let rect = live.convert(live.bounds, to: nil)
                guard let chrome = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { answer(["error": "nothing drawn"]); return }
                frame.cacheDisplay(in: frame.bounds, to: chrome)
                let stand = room ?? makeRoom()
                // The tab's own page by default — as it is, reader view or
                // things hidden included — lent to the room for the picture
                // and handed back; or, with `fresh`, the address loaded anew.
                let fresh = request["fresh"] as? Bool == true
                let home = live.superview
                let homeFrame = live.frame
                let page = fresh ? WKWebView(frame: NSRect(origin: .zero, size: rect.size), configuration: Web.configuration()) : live
                if !fresh {
                    live.removeFromSuperview()
                    live.frame = NSRect(origin: .zero, size: rect.size)
                    live.alphaValue = 1
                }
                func giveBack() {
                    guard !fresh else { page.removeFromSuperview(); return }
                    live.removeFromSuperview()
                    live.frame = homeFrame
                    home?.addSubview(live)
                }
                // A window off every screen counts as covered, and WebKit
                // paints nothing it thinks nobody sees; this one is told to
                // paint regardless.
                let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
                if page.responds(to: occlusion) {
                    typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                    unsafeBitCast(page.method(for: occlusion), to: Setter.self)(page, occlusion, false)
                }
                stand.contentView?.addSubview(page)
                if fresh { page.load(URLRequest(url: address)) }
                let settle = request["settle"] as? Double ?? 3
                func whenLoaded(_ tries: Int) {
                    guard page.isLoading, tries > 0 else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                            page.takeSnapshot(with: nil) { image, _ in
                                MainActor.assumeIsolated {
                                    giveBack()
                                    let drawn = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: chrome.pixelsWide, pixelsHigh: chrome.pixelsHigh,
                                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                                    guard let drawn else { answer(["error": "nothing drawn"]); return }
                                    drawn.size = frame.bounds.size
                                    NSGraphicsContext.saveGraphicsState()
                                    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: drawn)
                                    chrome.draw(in: frame.bounds)
                                    image?.draw(in: rect)
                                    NSGraphicsContext.restoreGraphicsState()
                                    do {
                                        try drawn.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                                        answer(["saved": path, "pixels": [drawn.pixelsWide, drawn.pixelsHigh], "page": [Int(rect.minX), Int(frame.bounds.height - rect.maxY), Int(rect.width), Int(rect.height)],
                                                "points": [Int(frame.bounds.width), Int(frame.bounds.height)], "lights": Bench.lights(of: window)])
                                    } catch { answer(["error": error.localizedDescription]) }
                                }
                            }
                        }
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { whenLoaded(tries - 1) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { whenLoaded(80) }
                return
            }
            let shown = pages(in: frame).filter { !$0.isHidden && $0.alphaValue > 0 && !$0.frame.isEmpty }
            var taken: [(WKWebView, NSImage)] = []
            var left = shown.count
            func draw() {
                // Each page's picture where the page is, the page itself put
                // aside for the one drawing.
                var covers: [NSImageView] = []
                for (web, image) in taken {
                    let cover = NSImageView(frame: web.frame)
                    cover.image = image
                    cover.imageScaling = .scaleAxesIndependently
                    cover.autoresizingMask = web.autoresizingMask
                    web.superview?.addSubview(cover, positioned: .above, relativeTo: web)
                    web.isHidden = true
                    covers.append(cover)
                }
                let glass = request["glass"] as? Bool == false ? frame.kitSubviews(of: KitGlass.self).filter { !$0.isHidden } : []
                glass.forEach { $0.isHidden = true }
                frame.layoutSubtreeIfNeeded()
                defer {
                    covers.forEach { $0.removeFromSuperview() }
                    taken.forEach { $0.0.isHidden = false }
                    glass.forEach { $0.isHidden = false }
                }
                guard let picture = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else {
                    answer(["error": "nothing drawn"])
                    return
                }
                frame.cacheDisplay(in: frame.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path, "pixels": [picture.pixelsWide, picture.pixelsHigh],
                            "points": [Int(frame.bounds.width), Int(frame.bounds.height)], "lights": Bench.lights(of: window)])
                } catch { answer(["error": error.localizedDescription]) }
            }
            guard left > 0 else { draw(); return }
            for web in shown {
                web.takeSnapshot(with: nil) { image, _ in
                    MainActor.assumeIsolated {
                        if let image { taken.append((web, image)) }
                        left -= 1
                        if left == 0 { draw() }
                    }
                }
            }

        case "float":
            // The floating window's gestures, handed to it as a trackpad, a
            // wheel or a click would, on screens made up far off the real
            // ones: where a flick, a pull at a side, a dock and a click on
            // the sliver leave it. Test runs only, with the window off every
            // screen (after `film float`), and nothing shown.
            guard Store.testing else { answer(["error": "float only works on a --test run"]); return }
            if let action = request["action"] as? String, ["sight", "cover", "look", "left", "back"].contains(action) {
                answer(benchSight(action, request["value"] as? String, browser: browser))
                return
            }
            if let action = request["action"] as? String, ["hover", "press", "scrub", "chrome", "toggle", "pace", "rate", "key", "captions"].contains(action) {
                if action == "toggle" { browser.toggleFloat() }
                if action == "pace" { FloatMotion.pace = max(1, Double(request["value"] as? String ?? "") ?? 1) }
                var out = browser.floater.bench(action, request["value"] as? String)
                let top = NSScreen.screens.first?.frame.height ?? 0
                if let panel = NSApp.windows.first(where: { "\(type(of: $0))" == "Panel" && $0.isVisible }) {
                    let f = panel.frame
                    out["frame"] = [f.minX, top - f.maxY, f.width, f.height]
                }
                if let visible = NSScreen.main?.visibleFrame {
                    out["visible"] = [visible.minX, top - visible.maxY, visible.width, visible.height]
                }
                out["top"] = top
                out["ghosts"] = FloatMotion.ghosts.map { [Double($0.windowNumber), $0.frame.minX, top - $0.frame.maxY, $0.frame.width, $0.frame.height, $0.alphaValue] }
                answer(out)
                return
            }
            if request["action"] as? String == "awake" {
                let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
                guard let web = browser.active?.web, web.responds(to: occlusion) else { answer(["error": "float awake needs a tab"]); return }
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(web.method(for: occlusion), to: Setter.self)(web, occlusion, false)
                web.isHidden = true
                web.isHidden = false
                answer(["awake": true])
                return
            }
            if request["action"] as? String == "size" {
                guard let args = request["args"] as? [Double], args.count == 2,
                      let panel = NSApp.windows.first(where: { "\(type(of: $0))" == "Panel" && $0.isVisible })
                else { answer(["error": "float size W H, with the floating window up"]); return }
                let f = panel.frame
                panel.setFrame(NSRect(x: f.maxX - args[0], y: f.minY, width: args[0], height: args[1]), display: true)
                answer(["width": panel.frame.width, "height": panel.frame.height, "window": panel.windowNumber])
                return
            }
            guard Float.benchAway != nil,
                  let panel = NSApp.windows.first(where: { "\(type(of: $0))" == "Panel" && $0.isVisible }),
                  let controls = (panel.contentView?.subviews ?? []).flatMap({ [$0] + $0.subviews }).first(where: { "\(type(of: $0))" == "Controls" })
            else { answer(["error": "float needs the floating window up, off screen (film float first)"]); return }
            let screen = NSRect(x: -30000, y: -30000, width: 1440, height: 900)
            if Float.benchScreens == nil { Float.benchScreens = [screen] }
            func state() -> [String: Any] {
                let f = panel.frame
                let first = Float.benchScreens?.first ?? screen
                let made: [[Int]] = (Float.benchScreens ?? []).map { made in
                    [Int(made.minX - first.minX), Int(made.minY - first.minY), Int(made.width), Int(made.height)]
                }
                let x = Int((f.minX - first.minX).rounded()), y = Int((f.minY - first.minY).rounded())
                let shown = Int((f.intersection(first).width / f.width * 100).rounded())
                return ["x": x, "y": y, "width": Int(f.width), "height": Int(f.height), "screens": made, "shown": shown]
            }
            // Where it goes on its way, every few milliseconds for a second
            // and a bit: how far out it swings, and where it comes to rest.
            func follow(_ done: @escaping ([String: Any]) -> Void) {
                let first = Float.benchScreens?.first ?? screen
                var xs: [Int] = []
                func look(_ left: Int) {
                    xs.append(Int((panel.frame.minX - first.minX).rounded()))
                    guard left > 0 else {
                        var out = state()
                        out["path"] = xs.enumerated().filter { $0.offset % 4 == 0 }.map(\.element)
                        out["least"] = xs.min() ?? 0
                        out["most"] = xs.max() ?? 0
                        done(out)
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { look(left - 1) }
                }
                look(130)
            }
            // A scroll event whose fingers went `way` on screen, as the
            // window reads it, whatever the Mac's scrolling direction.
            func scroll(_ way: CGVector, phase: Int64, continuous: Bool) -> NSEvent? {
                func make(_ dx: Double, _ dy: Double) -> NSEvent? {
                    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: continuous ? .pixel : .line, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)
                    else { return nil }
                    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: continuous ? 1 : 0)
                    if continuous {
                        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
                        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
                    } else {
                        cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(dy))
                        cg.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(dx))
                    }
                    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                    return NSEvent(cgEvent: cg)
                }
                guard let probe = make(1, 1) else { return nil }
                let sign: CGFloat = probe.isDirectionInvertedFromDevice ? 1 : -1
                let perX = sign * probe.scrollingDeltaX, perY = -sign * probe.scrollingDeltaY
                guard perX != 0, perY != 0 else { return nil }
                return make(Double(way.dx / perX), Double(way.dy / perY))
            }
            let args = request["args"] as? [Double] ?? []
            switch request["action"] as? String {
            case "screens":
                // One made-up screen, or two side by side.
                Float.benchScreens = request["two"] as? Bool == true
                    ? [screen, screen.offsetBy(dx: screen.width, dy: 0)] : [screen]
                answer(state())
            case "place":
                guard args.count == 2 else { answer(["error": "float place X Y"]); return }
                let first = Float.benchScreens?.first ?? screen
                panel.setFrameOrigin(NSPoint(x: first.minX + args[0], y: first.minY + args[1]))
                answer(state())
            case "swipe":
                // Fingers down, DX, DY on screen in STEPS moves MS apart, up.
                guard args.count >= 2 else { answer(["error": "float swipe DX DY [STEPS] [MS]"]); return }
                let steps = max(1, Int(args.count > 2 ? args[2] : 10))
                let gap = (args.count > 3 ? args[3] : 16) / 1000
                let step = CGVector(dx: args[0] / Double(steps), dy: args[1] / Double(steps))
                if let down = scroll(.zero, phase: 1, continuous: true) { controls.scrollWheel(with: down) }
                func move(_ n: Int) {
                    guard n < steps else {
                        if let up = scroll(.zero, phase: 4, continuous: true) { controls.scrollWheel(with: up) }
                        follow { answer($0) }
                        return
                    }
                    if let e = scroll(step, phase: 2, continuous: true) { controls.scrollWheel(with: e) }
                    DispatchQueue.main.asyncAfter(deadline: .now() + gap) { move(n + 1) }
                }
                move(0)
            case "wheel":
                guard args.count == 2, let e = scroll(CGVector(dx: args[0], dy: args[1]), phase: 0, continuous: false)
                else { answer(["error": "float wheel DX DY"]); return }
                controls.scrollWheel(with: e)
                follow { answer($0) }
            case "click":
                let middle = NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let e = NSEvent.mouseEvent(with: type, location: middle, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: type == .leftMouseUp ? 0 : 1) else { continue }
                    if type == .leftMouseDown { controls.mouseDown(with: e) } else { controls.mouseUp(with: e) }
                }
                follow { answer($0) }
            default:
                answer(state())
            }

        case "film" where ["float", "land"].contains(request["action"] as? String ?? ""):
            // The video going out into its floating window, or back into its
            // tab (#257), recorded by the page itself on every frame it
            // draws: the size it is laid out at, the video's box in it, and
            // whether everything else is out of the way. Beside it, how much
            // of the view it is in the video fills.
            //
            // Only from a probe started hidden, and it stays hidden. The
            // little window opens off every screen, and the tab's stage is
            // lent to a borderless window off every screen for the filming;
            // those two are left out of the hiding, so WebKit draws the page
            // in them as it would for a person. (Showing the app instead,
            // with the browser's window moved off the screens, put that
            // window back on one: a titled window is put on a screen as it
            // is shown.)
            guard Store.testing else { answer(["error": "film only works on a --test run"]); return }
            guard NSApp.isHidden else { answer(["error": "film float needs a probe started hidden"]); return }
            guard let window = Links.window, let path = request["path"] as? String, !path.isEmpty
            else { answer(["error": "film float needs the browser's window (bench window) and a path"]); return }
            let out = request["action"] as? String == "float"
            let floated = browser.floatingTab
            guard let tab = out ? browser.active : floated, out != browser.floater.showing
            else { answer(["error": out ? "already floating, or no tab" : "nothing is floating"]); return }
            // How it goes: ⇧⌘P (the default), going to another tab and back
            // ("switch", Settings › Float the video when you switch tabs), or
            // another app coming forward and Search again ("app"). A page the
            // bench serves itself is taken for a player's, for those two.
            let via = request["via"] as? String ?? "key"
            let other = browser.tabs.first { $0.id != tab.id && !$0.isBlank && !$0.asleep }
            if via == "switch", out, other == nil { answer(["error": "film float via switch needs another tab"]); return }
            if via != "key", request["player"] as? Bool ?? true, let host = tab.address?.host() { Players.benchHosts.insert(host) }
            func stages(in view: NSView) -> [StageView] {
                (view as? StageView).map { [$0] } ?? view.subviews.flatMap(stages)
            }
            guard let root = window.contentView,
                  let stage = stages(in: root).filter({ !$0.isHiddenOrHasHiddenAncestor })
                      .max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }),
                  let home = stage.superview
            else { answer(["error": "no stage in the window"]); return }
            let seconds = min(4, max(0.1, request["seconds"] as? Double ?? 1))
            Float.benchAway = NSPoint(x: -20000, y: -20000)
            let hall = self.hall ?? {
                let hall = NSWindow(contentRect: NSRect(x: -20000, y: -22000, width: 100, height: 100),
                                    styleMask: [.borderless], backing: .buffered, defer: false)
                hall.isReleasedWhenClosed = false
                hall.isExcludedFromWindowsMenu = true
                hall.collectionBehavior = [.transient, .ignoresCycle, .stationary]
                hall.hasShadow = false
                // Left out of the hiding. It also keeps AppKit from taking
                // the little window, closing, for the last one and quitting.
                hall.canHide = false
                self.hall = hall
                return hall
            }()
            hall.setFrame(NSRect(x: -20000, y: -22000, width: stage.frame.width, height: stage.frame.height), display: false)
            hall.orderBack(nil)
            let place = stage.frame
            let after = home.subviews.firstIndex(of: stage).flatMap { home.subviews.indices.contains($0 + 1) ? home.subviews[$0 + 1] : nil }
            stage.removeFromSuperview()
            stage.frame = NSRect(origin: .zero, size: place.size)
            hall.contentView?.addSubview(stage)
            func giveBack() {
                stage.removeFromSuperview()
                stage.frame = place
                if let after, after.superview === home {
                    home.addSubview(stage, positioned: .below, relativeTo: after)
                } else {
                    home.addSubview(stage)
                }
            }
            // A window off every screen counts as covered, and WebKit draws
            // nothing it thinks nobody sees.
            let web = tab.web
            let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
            if web.responds(to: occlusion) {
                typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
                unsafeBitCast(web.method(for: occlusion), to: Setter.self)(web, occlusion, false)
            }
            let record = """
            (function () {
              var log = window.__benchFilm = [], t0 = performance.now();
              window.__benchWall = Date.now();
              function look() {
                var v = document.querySelector('[data-office-float]');
                if (!v) {
                  var all = document.querySelectorAll('video'), most = -1;
                  for (var i = 0; i < all.length; i++) {
                    var b = all[i].getBoundingClientRect();
                    if (b.width * b.height > most) { most = b.width * b.height; v = all[i]; }
                  }
                }
                var on = document.documentElement.classList.contains('office-floating') ? 1 : 0;
                var r = v ? v.getBoundingClientRect() : { left: 0, top: 0, width: 0, height: 0 };
                log.push([Math.round(performance.now() - t0), innerWidth, innerHeight, r.left, r.top, r.width, r.height,
                          v ? v.videoWidth : 0, v ? v.videoHeight : 0, on,
                          v && !v.paused ? 1 : 0, document.visibilityState === 'visible' ? 1 : 0]);
              }
              // And each time the float's class comes or goes, the size the
              // page had then.
              var turns = window.__benchTurns = [];
              new MutationObserver(function () {
                var on = document.documentElement.classList.contains('office-floating') ? 1 : 0;
                if (!turns.length || turns[turns.length - 1][3] !== on)
                  turns.push([Math.round(performance.now() - t0), innerWidth, innerHeight, on]);
              }).observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });
              // Looked at just after each frame is drawn, whatever order the
              // frame's own callbacks — a landing's among them — ran in.
              var drawn = new MessageChannel();
              drawn.port1.onmessage = function () {
                look();
                if (performance.now() - t0 < \(Int(seconds * 1000))) requestAnimationFrame(frame);
              };
              function frame() { drawn.port2.postMessage(0); }
              requestAnimationFrame(frame);
              return true;
            })();
            """
            // Where the page is, from this side, every few hundredths, and
            // what covers it meanwhile: the still over the little window,
            // the picture of the page over its tab.
            var hosts: [[String: Any]] = []
            var started = CACurrentMediaTime()
            var startedWall = Date().timeIntervalSince1970
            // Every size the web view is given on the way, however briefly:
            // each one is a layout WebKit is asked for.
            var sizes: [[Int]] = []
            web.postsFrameChangedNotifications = true
            let resized = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: web, queue: nil) { _ in
                MainActor.assumeIsolated {
                    let size = web.frame.size
                    if sizes.last.map({ $0[1] != Int(size.width) || $0[2] != Int(size.height) }) ?? true {
                        sizes.append([Int((CACurrentMediaTime() - started) * 1000), Int(size.width), Int(size.height)])
                    }
                }
            }
            // What WebKit has handed this side to show, as against what the
            // page has laid out: the size of the page's frame in the layers
            // it last sent, and of the video's own layer in them. And the
            // picture itself: drawn by another of WebKit's processes into a
            // layer of its own (`host`, its size, and whether it is shown at
            // that size or stretched to another) inside the one it has been
            // given room in (`room`). The two disagree while that process has
            // still to draw at the new size.
            func drawn() -> [String: Any] {
                var frame: CGSize?, video: CGSize?, host: [Int] = [], room: [Int] = []
                func walk(_ layer: CALayer) {
                    let name = layer.name ?? ""
                    if frame == nil, name == "frame clipping" { frame = layer.bounds.size }
                    if host.isEmpty, "\(type(of: layer))" == "CALayerHost", let player = layer.superlayer,
                       "\(type(of: player))" == "WebAVPlayerLayer" {
                        host = [Int(layer.bounds.width), Int(layer.bounds.height), CATransform3DIsIdentity(layer.transform) ? 1 : 0]
                        room = [Int(player.bounds.width), Int(player.bounds.height)]
                    }
                    if name.contains(" VIDEO "), layer.bounds.width * layer.bounds.height > (video.map { $0.width * $0.height } ?? -1) {
                        video = layer.bounds.size
                    }
                    layer.sublayers?.forEach(walk)
                }
                if let root = web.layer { walk(root) }
                return ["page": frame.map { [Int($0.width), Int($0.height)] } ?? [], "video": video.map { [Int($0.width), Int($0.height)] } ?? [],
                        "host": host, "room": room]
            }
            // Each time round the run loop that the page is in no window at
            // all: too brief, some of them, for the samples to catch.
            var unwindowed: [Int] = []
            let looking = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.allActivities.rawValue, true, 0) { _, _ in
                MainActor.assumeIsolated {
                    let now = Int((CACurrentMediaTime() - started) * 1000)
                    if web.window == nil, unwindowed.last != now { unwindowed.append(now) }
                }
            }
            CFRunLoopAddObserver(CFRunLoopGetMain(), looking, .commonModes)
            func watch() {
                let showing = NSApp.windows.filter { w in w.isVisible && NSScreen.screens.contains { $0.frame.intersects(w.frame) } }
                if !showing.isEmpty { NSApp.hide(nil) }
                let view = web.bounds.size
                hosts.append(["t": Int((CACurrentMediaTime() - started) * 1000),
                              // "held": kept unseen by its stage on the way out (see StageView.keep).
                              "in": web.window === hall ? (web.alphaValue == 0 ? "held" : "tab") : web.window == nil ? "none" : "float",
                              "view": [Int(view.width), Int(view.height)], "showing": showing.map { "\(type(of: $0))" },
                              "still": browser.floater.covered ? (browser.floater.coveredByStill ? "frame" : "black") : "none",
                              "cover": tab.cover != nil, "drawn": drawn()])
                guard CACurrentMediaTime() - started < seconds else { return finish(view) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { watch() }
            }
            func finish(_ view: NSSize) {
                NotificationCenter.default.removeObserver(resized)
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), looking, .commonModes)
                web.evaluateInSearch("[window.__benchFilm, window.__benchTurns, window.__benchWall]") { found in
                    MainActor.assumeIsolated {
                        giveBack()
                        let both = found as? [Any] ?? []
                        let rows = (both.first as? [[Any]] ?? []).map { $0.map { ($0 as? NSNumber)?.doubleValue ?? 0 } }
                        // Added to a frame's or a turn's time, puts it on the
                        // hosts' clock, which starts as the float is asked for.
                        let shift = both.count > 2 ? Int(((both[2] as? NSNumber)?.doubleValue ?? 0) - startedWall * 1000) : 0
                        let turns = (both.count > 1 ? both[1] as? [[Any]] ?? [] : []).map { $0.map { ($0 as? NSNumber)?.intValue ?? 0 } }
                        let fill = { (part: CGFloat, whole: CGFloat) in whole > 0 ? (part / whole * 1000).rounded() / 1000 : 0 }
                        let frames: [[String: Any]] = rows.filter { $0.count == 12 }.map { n in
                            // The picture inside the video's box, fitted as
                            // `contain` fits it, cut to what both the page
                            // and the view it ends up in show.
                            var picture = NSRect(x: n[3], y: n[4], width: n[5], height: n[6])
                            if n[7] > 0, n[8] > 0, n[5] > 0, n[6] > 0 {
                                let scale = min(n[5] / n[7], n[6] / n[8])
                                picture = NSRect(x: n[3] + (n[5] - n[7] * scale) / 2, y: n[4] + (n[6] - n[8] * scale) / 2,
                                                 width: n[7] * scale, height: n[8] * scale)
                            }
                            let seen = picture.intersection(NSRect(x: 0, y: 0, width: min(n[1], view.width), height: min(n[2], view.height)))
                            return ["t": Int(n[0]), "page": [Int(n[1]), Int(n[2])], "video": [Int(n[5].rounded()), Int(n[6].rounded())],
                                    "isolated": n[9] == 1, "playing": n[10] == 1, "seen": n[11] == 1,
                                    "fill": seen.isNull ? [0, 0] : [fill(seen.width, view.width), fill(seen.height, view.height)]]
                        }
                        let result: [String: Any] = ["view": [Int(view.width), Int(view.height)], "frames": frames, "hosts": hosts,
                                                     "sizes": sizes, "turns": turns, "shift": shift,
                                                     "unwindowed": unwindowed]
                        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]) {
                            try? data.write(to: URL(fileURLWithPath: path + ".json"))
                        }
                        answer(["frames": frames.count, "saved": path + ".json"])
                    }
                }
            }
            // A video paused while its page was out of sight — WebKit stops
            // a muted one nobody can see — started again, now that it can
            // be seen: in the page's own world, through its player where it
            // has one (YouTube's pauses a video started behind its back).
            // Then the page draws a few frames where it is, and moves.
            let start = """
            (function () {
              var v = document.querySelector('video'), p = document.getElementById('movie_player');
              if (!\(out) || !v || !v.paused) return 0;
              v.muted = true;
              if (p && p.playVideo) { if (p.mute) p.mute(); p.playVideo(); } else v.play();
              return 1;
            })();
            """
            web.evaluateJavaScript(start) { restarted, _ in
                MainActor.assumeIsolated {
                    DispatchQueue.main.asyncAfter(deadline: .now() + ((restarted as? Int) == 1 ? 1 : 0)) {
                        web.evaluateInSearch(record) { _ in
                            MainActor.assumeIsolated {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    started = CACurrentMediaTime()
                                    startedWall = Date().timeIntervalSince1970
                                    watch()
                                    switch via {
                                    case "switch": browser.select(out ? other! : tab)
                                    case "app":
                                        let away = browser.prefs.floatsAway
                                        browser.prefs.floatsAway = true
                                        if out { browser.appLeft() } else { browser.appBack() }
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            browser.prefs.floatsAway = away
                                        }
                                    case "sight":
                                        let away = browser.prefs.floatsAway
                                        browser.prefs.floatsAway = true
                                        browser.sightForBench = !out
                                        browser.judgeSight()
                                        browser.prefs.floatsAway = away
                                    default: browser.toggleFloat()
                                    }
                                }
                            }
                        }
                    }
                }
            }

        case "film":
            // The whole window, title bar and lights included, drawn every few
            // hundredths of a second while something animates — what a person
            // would see of it, from a probe started hidden that nobody sees.
            // The lights' own slide is a Core Animation one, which a drawing
            // doesn't show: where they are is reported beside each frame.
            guard Store.testing else { answer(["error": "film only works on a --test run"]); return }
            let card = request["target"] as? String == "card" ? KitPopup.current(in: browser.window) : nil
            guard let window = browser.window ?? Links.window,
                  let frame = card?.panel?.contentView ?? window.contentView?.superview,
                  let path = request["path"] as? String, !path.isEmpty
            else { answer(["error": "film needs something to do and a path"]); return }
            if ["select", "pindrag"].contains(request["action"] as? String ?? ""), find(request, in: browser) == nil {
                answer(missing(request)); return
            }
            let count = min(60, max(1, request["frames"] as? Int ?? 14))
            let every = min(0.5, max(0.01, request["every"] as? Double ?? 0.03))
            // The column's corner — the lights, the pins, the first rows — is
            // what moves; the whole window would take longer to draw than a
            // frame lasts. Written out once the filming is over.
            let band = (request["region"] as? String)?.split(separator: ",").compactMap { Double($0) }
            let corner = request["region"] as? String == "full" ? frame.bounds
                : band?.count == 4 ? NSRect(x: band![0], y: frame.bounds.height - band![1] - band![3], width: band![2], height: band![3])
                : card != nil ? frame.bounds
                : NSRect(x: 0, y: frame.bounds.height - 460, width: min(380, frame.bounds.width), height: 460)
            // The pages under it take a third of a second each to draw into a
            // picture, longer than the whole animation: they sit the filming
            // out, and come back after.
            func pages(in view: NSView) -> [NSView] { view is WKWebView ? [view] : view.subviews.flatMap(pages) }
            let resting = pages(in: frame).filter { !$0.isHidden }
            resting.forEach { $0.isHidden = true }
            var shots: [[String: Any]] = []
            var pictures: [NSBitmapImageRep] = []
            let started = CACurrentMediaTime()
            func take(_ index: Int) {
                guard index < count else {
                    resting.forEach { $0.isHidden = false }
                    for (index, picture) in pictures.enumerated() {
                        let file = path + String(format: "-%02d.png", index)
                        if let data = picture.representation(using: .png, properties: [:]),
                           (try? data.write(to: URL(fileURLWithPath: file))) != nil { shots[index]["file"] = file }
                    }
                    answer(["frames": shots, "probe": PinDragProbe.shared.log])
                    PinDragProbe.shared.log = []
                    return
                }
                var shot: [String: Any] = ["t": Int((CACurrentMediaTime() - started) * 1000)]
                let area = card != nil ? frame.bounds : corner
                shot["size"] = [Int(frame.bounds.width), Int(frame.bounds.height)]
                if let picture = frame.bitmapImageRepForCachingDisplay(in: area) {
                    frame.cacheDisplay(in: area, to: picture)
                    pictures.append(picture)
                }
                if let bar = Fold.titlebar {
                    let moved = bar.layer?.presentation()?.value(forKeyPath: "transform.translation.x") as? CGFloat ?? 0
                    let lifted = bar.layer?.presentation()?.value(forKeyPath: "transform.translation.y") as? CGFloat ?? 0
                    shot["lights"] = ["hidden": bar.isHidden, "x": Int(moved.rounded()), "y": Int(lifted.rounded()),
                                      "flipped": bar.superview?.isFlipped ?? false]
                }
                shot["cards"] = PaneStage.cards(in: frame)
                shot["rides"] = SpaceStagePreviewView.edges(in: frame)
                shot["riders"] = RideView.report(in: frame)
                shot["pictures"] = StagePicture.report(in: frame)
                shots.append(shot)
                DispatchQueue.main.asyncAfter(deadline: .now() + every) { take(index + 1) }
            }
            take(0)
            switch request["action"] as? String {
            case "peek": browser.peek(true)
            case "unpeek": browser.peek(false)
            case "lookmore", "lookless": (card?.content as? SpaceLookEditorView)?.setMore(request["action"] as? String == "lookmore")
            case "lookone", "lookboth": (card?.content as? SpaceLookEditorView)?.pickMode(oneColour: request["action"] as? String == "lookone")
            case "dark", "light": browser.prefs.look = Look(rawValue: request["action"] as? String ?? "") ?? browser.prefs.look
            case "fold": browser.toggleFold()
            case "select": if let tab = find(request, in: browser) { browser.select(tab) }
            case "step": browser.step(request["direction"] as? Int ?? 1)
            case "back": browser.back()
            case "newtab": browser.newTab()
            case "forward": browser.forward()
            case "go": if let url = (request["url"] as? String).flatMap(URL.init(string:)) { browser.active?.go(to: url) }
            case "space": if let index = request["index"] as? Int, browser.spaces.indices.contains(index) { browser.goToSpace(browser.spaces[index].id) }
            case "headerdrag":
                let index = (request["space"] as? Int ?? 1) - 1
                let dys = request["dys"] as? [Double] ?? []
                let step = request["step"] as? Double ?? every
                let cancel = request["cancel"] as? Bool == true
                if browser.spaces.indices.contains(index), let lift = StackedProbe.lift {
                    lift.scripted = true
                    StackedProbe.begin?(browser.spaces[index].id)
                    let start = lift.start
                    for (at, dy) in dys.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(at + 1)) {
                            lift.move(to: start + dy)
                            if at == dys.count - 1 {
                                if cancel { lift.cancel() }
                                lift.end()
                            }
                        }
                    }
                }
            case "pindrag":
                let points = (request["points"] as? [[Double]] ?? []).filter { $0.count == 2 }
                let step = request["step"] as? Double ?? every
                let cancel = request["cancel"] as? Bool == true
                if let tab = find(request, in: browser) {
                    for (index, coordinates) in points.enumerated() {
                        DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(index)) {
                            let page = PinDragProbe.shared.page
                            let point = CGPoint(x: coordinates[0] - page.minX, y: coordinates[1] - page.minY)
                            let last = index == points.count - 1
                            let crossed = PinDragProbe.shared.drive?(tab.id, last && cancel ? nil : point, last)
                            PinDragProbe.shared.log.append("\(Int(point.x)),\(Int(point.y)) \(crossed.map(String.init) ?? "-")")
                        }
                    }
                }
            case "drag":
                let points = (request["points"] as? [[Double]] ?? []).filter { $0.count == 2 }
                let step = request["step"] as? Double ?? every
                if request["activate"] as? Bool == true {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
                let root = window.contentView?.superview
                for (index, coordinates) in points.enumerated() {
                    let type: NSEvent.EventType = index == 0 ? .leftMouseDown : index == points.count - 1 ? .leftMouseUp : .leftMouseDragged
                    let point = NSPoint(x: coordinates[0], y: Double(window.frame.height) - coordinates[1])
                    DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(index)) {
                        guard let event = NSEvent.mouseEvent(
                            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: 1,
                            pressure: type == .leftMouseUp ? 0 : 1
                        ) else { return }
                        if request["to"] as? String == "post" { NSApp.postEvent(event, atStart: false); return }
                        guard request["to"] as? String == "view" else { window.sendEvent(event); return }
                        if type == .leftMouseDown { self.pressed = root.flatMap { $0.hitTest($0.convert(point, from: nil)) } }
                        switch type {
                        case .leftMouseDown: self.pressed?.mouseDown(with: event)
                        case .leftMouseDragged: self.pressed?.mouseDragged(with: event)
                        default: self.pressed?.mouseUp(with: event)
                        }
                    }
                }
            case "swipe":
                // Two fingers along the column, a step every frame for the
                // first eight, then let go: the next space coming in, as a
                // hand brings it (dx, default -160).
                let dx = request["dx"] as? Double ?? -160
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                for step in 0..<8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + every * Double(step)) {
                        SpaceSwipe.shared.moved(dx: dx / 8, dy: 0)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + every * 8) { SpaceSwipe.shared.ended() }
            default: break
            }

        case "fold":
            guard Store.testing else { answer(["error": "fold only works on a --test run"]); return }
            guard let path = request["path"] as? String else { answer(["error": "fold needs a path"]); return }
            guard browser.folded, browser.peeking else { answer(["error": "fold and peek first: ui folded on, ui peek on"]); return }
            let width = request["width"] as? Double ?? 1100
            let size = NSSize(width: width, height: 500)
            let host = KitBox(fill: .red)
            host.frame = NSRect(origin: .zero, size: size)
            host.addSubview({ let fold = Fold(browser: browser); fold.frame = host.bounds; return fold }())
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { answer(["error": "nothing drawn"]); return }
                host.cacheDisplay(in: host.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path])
                } catch { answer(["error": error.localizedDescription]) }
                window.contentView = nil
            }

        case "site":
            guard Store.testing else { answer(["error": "site only works on a --test run — it would describe your tab"]); return }
            guard let tab = browser.active, !tab.isBlank else { answer(["error": "no page on screen"]); return }
            let step: SiteCard.Step = request["security"] as? Bool == true ? .security : SiteControlsBench.step(request["step"] as? String)
            let items = BenchMenus.describe(SiteCard(browser: browser, tab: tab, step: step).menu)
            if let path = request["path"] as? String,
               let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            answer(["items": items])

        case "column":
            // The column of tabs, drawn off screen at its width, with what the
            // browser has now — the rows, the card for a new space, the dots.
            guard Store.testing else { answer(["error": "column only works on a --test run — it would picture your tabs"]); return }
            guard let path = request["path"] as? String else { answer(["error": "column needs a path"]); return }
            let height = request["height"] as? Double ?? 600
            let width = Double(browser.prefs.columnWidth)
            let host = SideColumnView(browser: browser)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { answer(["error": "nothing drawn"]); return }
                host.cacheDisplay(in: host.bounds, to: picture)
                do {
                    try picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                    answer(["saved": path])
                } catch { answer(["error": error.localizedDescription]) }
                window.contentView = nil
            }

        case "columnfilm":
            guard Store.testing else { answer(["error": "columnfilm only works on a --test run — it would picture your tabs"]); return }
            guard let path = request["path"] as? String else { answer(["error": "columnfilm needs a path"]); return }
            let height = request["height"] as? Double ?? 300
            let width = Double(browser.prefs.columnWidth)
            let count = min(90, max(1, request["frames"] as? Int ?? 30))
            let every = min(0.5, max(0.01, request["every"] as? Double ?? 1.0 / 60))
            let host = SideColumnView(browser: browser)
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = (request["dark"] as? Bool).map { NSAppearance(named: $0 ? .darkAqua : .aqua) } ?? NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            if let y = request["scroll"] as? Double {
                func scrolls(in view: NSView) -> [NSScrollView] {
                    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrolls)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard let scroll = scrolls(in: host).max(by: { $0.frame.height < $1.frame.height }),
                          let document = scroll.documentView else { return }
                    let end = max(0, document.frame.height - scroll.contentView.bounds.height + scroll.contentInsets.bottom)
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: y < 0 ? end : min(y, end)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
            var shots: [[String: Any]] = []
            var started = CACurrentMediaTime()
            func take(_ index: Int) {
                guard index < count else {
                    window.contentView = nil
                    answer(["frames": shots])
                    return
                }
                host.layoutSubtreeIfNeeded()
                if let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: picture)
                    let file = path + String(format: "-%02d.png", index)
                    if let data = picture.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: file))) != nil {
                        shots.append(["t": Int((CACurrentMediaTime() - started) * 1000), "file": file,
                                      "offset": Double(browser.spaceMotion.offset)])
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + every) { take(index + 1) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                started = CACurrentMediaTime()
                take(0)
                switch request["action"] as? String {
                case "space":
                    if let index = request["index"] as? Int, browser.spaces.indices.contains(index) { browser.goToSpace(browser.spaces[index].id) }
                case "swipe":
                    let dx = request["dx"] as? Double ?? -160
                    SpaceSwipe.shared.start(for: browser)
                    SpaceSwipe.shared.began()
                    for step in 0..<8 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + every * 2 * Double(step)) {
                            SpaceSwipe.shared.moved(dx: dx / 8, dy: 0)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + every * 16) { SpaceSwipe.shared.ended() }
                case "ask": browser.askForSpace()
                case "leave": browser.leaveSpaceCreation()
                case "addressBar":
                    browser.prefs.addressBar.toggle()
                default: break
                }
            }

        case "gallery":
            BenchControls.render(request, answer: answer)

        case "glasskeys":
            guard Store.testing else { answer(["error": "glasskeys only works on a --test run"]); return }
            BenchGlassKeys.run(request, answer: answer)

        case "axpress":
            guard Store.testing else { answer(["error": "axpress is for test runs"]); return }
            guard let identifier = request["identifier"] as? String, let window = browser.window
            else { answer(["error": "axpress needs an identifier and a test window"]); return }
            if let error = Bench.axPress(identifier, in: window) { answer(["error": identifier + " " + error]); return }
            answer(["pressed": identifier])

        case "keyloop":
            guard Store.testing else { answer(["error": "keyloop is for test runs"]); return }
            if let on = request["fka"] as? Bool { KitFocus.keyboardAccess = { on } }
            let settings = request["settings"] as? Bool == true
            guard let window = settings ? NSApp.window(withWindowNumber: SettingsWindow.shared.number ?? -1) : browser.window
            else { answer(["error": "no such window"]); return }
            func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
            if window.autorecalculatesKeyViewLoop { window.recalculateKeyViewLoop() }
            let views = (window.contentView?.superview ?? window.contentView).map(all) ?? []
            let start = request["start"] as? String ?? ""
            var cursor = views.first { !$0.isHiddenOrHasHiddenAncestor && (start.isEmpty ? $0.canBecomeKeyView : String(describing: type(of: $0)) == start) }
            var steps: [String] = [cursor.map { String(describing: type(of: $0)) } ?? ""]
            for _ in 0..<(request["steps"] as? Int ?? 12) {
                cursor = cursor?.nextValidKeyView
                steps.append(cursor.map { String(describing: type(of: $0)) } ?? "")
            }
            answer(["steps": steps, "autorecalculates": window.autorecalculatesKeyViewLoop])

        case "axaudit":
            guard Store.testing else { answer(["error": "axaudit is for test runs"]); return }
            var windows: [[String: Any]] = []
            for window in NSApp.windows where window.isVisible || window === browser.window || window.windowNumber == SettingsWindow.shared.number {
                let gaps = AccessAudit.gaps(in: window)
                windows.append(["title": window.title, "type": String(describing: type(of: window)),
                                "visible": window.isVisible, "gaps": gaps.map(\.report)])
            }
            answer(["windows": windows])

        case "pintrace":
            guard Store.testing else { answer(["error": "pintrace is for test runs"]); return }
            if request["action"] as? String == "start" {
                PinFlightTrace.log = []
                PinFlightTrace.events = []
                PinFlightTrace.started = CACurrentMediaTime()
                PinFlightTrace.on = true
                answer(["ok": true])
            } else {
                PinFlightTrace.on = false
                answer(["frames": PinFlightTrace.log, "events": PinFlightTrace.events])
            }

        case "rowframes":
            guard Store.testing else { answer(["error": "rowframes is for test runs"]); return }
            var rows: [String: [Double]] = [:]
            for tab in browser.tabs {
                guard let frame = Bench.rowFrames[tab.id] else { continue }
                rows[Bench.short(tab)] = [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) }
            }
            var checks: [String: [Double]] = [:]
            for tab in browser.tabs {
                guard let frame = Bench.checkMarks[tab.id]?() else { continue }
                checks[Bench.short(tab)] = [frame.minX, frame.minY, frame.width, frame.height].map { Double($0) }
            }
            var icons: [String: [Double]] = [:]
            var chevrons: [[Double]] = []
            var headings: [String: [Double]] = [:]
            if let content = browser.window?.contentView {
                func placed(_ view: NSView) -> [Double] {
                    let rect = view.convert(view.bounds, to: content)
                    let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
                    return [rect.minX, top, rect.width, rect.height].map { Double($0) }
                }
                func walk(_ view: NSView) {
                    for sub in view.subviews where !sub.isHidden {
                        if let row = sub as? TabRowView, let tab = row.tab,
                           let mark = row.subviews.flatMap(\.subviews).first(where: { $0 is RowMarkView && !$0.isHidden }) {
                            icons[Bench.short(tab)] = placed(mark)
                        } else if sub is StackFoldButton {
                            chevrons.append(placed(sub))
                        } else if let heading = sub as? GroupHeadingView, let group = heading.group {
                            headings[group.name] = placed(heading)
                            walk(sub)
                        } else {
                            walk(sub)
                        }
                    }
                }
                walk(content)
            }
            answer(["rows": rows, "checks": checks, "icons": icons, "chevrons": chevrons, "headings": headings, "blocks": SidePageView.benchBlocks,
                    "line": SidePageView.benchLine ?? [:], "active": browser.active.map(Bench.short) ?? ""])

        case "rowtitles":
            guard Store.testing else { answer(["error": "rowtitles is for test runs"]); return }
            guard let content = browser.window?.contentView else { answer(["error": "no window"]); return }
            let rows = content.kitSubviews(of: TabRowView.self).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            answer(["rows": rows.compactMap(\.benchTitle)])

        case "unseenmarks":
            guard Store.testing else { answer(["error": "unseenmarks is for test runs"]); return }
            guard let content = browser.window?.contentView else { answer(["error": "no window"]); return }
            let dots = content.kitSubviews(of: UnseenDotView.self).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            answer(["marks": dots.map { dot -> [String: Any] in
                let rect = dot.convert(dot.bounds, to: content)
                let top = content.isFlipped ? rect.minY : content.bounds.height - rect.maxY
                var host: NSView? = dot.superview
                var heading = ""
                while let view = host {
                    if let found = view as? GroupHeadingView { heading = found.group?.name ?? ""; break }
                    host = view.superview
                }
                let layer = dot.layer?.presentation() ?? dot.layer
                return ["frame": [rect.minX, top, rect.width, rect.height].map { Double($0) },
                        "radius": Double(layer?.cornerRadius ?? -1), "model": Double(dot.layer?.cornerRadius ?? -1),
                        "opacity": Double(layer?.opacity ?? -1), "host": String(describing: type(of: dot.superview ?? dot)),
                        "heading": heading]
            }])

        case "rowpress":
            guard Store.testing else { answer(["error": "rowpress is for test runs"]); return }
            guard let tab = find(request, in: browser), let press = Bench.pressRows[tab.id] else { answer(missing(request)); return }
            press(request["down"] as? Bool ?? true)
            answer(["active": browser.active.map(Bench.short) ?? ""])

        case "presssample":
            guard Store.testing else { answer(["error": "presssample is for test runs"]); return }
            guard let tab = find(request, in: browser), let layers = Bench.layerRows[tab.id] else { answer(missing(request)); return }
            let seconds = request["seconds"] as? Double ?? 0.8
            let start = CACurrentMediaTime()
            var frames: [[String: Any]] = []
            let timer = Timer(timeInterval: 1.0 / 240, repeats: true) { timer in
                let now = CACurrentMediaTime() - start
                var frame: [String: Any] = ["t": now * 1000]
                for (name, layer) in layers() {
                    let shown = layer.presentation() ?? layer
                    frame[name] = ["scale": Double(shown.transform.m11), "opacity": Double(shown.opacity), "hidden": layer.isHidden,
                                   "anchor": [Double(layer.anchorPoint.x), Double(layer.anchorPoint.y)],
                                   "keys": layer.animationKeys() ?? []] as [String: Any]
                }
                frames.append(frame)
                if now > seconds {
                    timer.invalidate()
                    answer(["frames": frames])
                }
            }
            RunLoop.main.add(timer, forMode: .common)

        case "addresshover":
            guard Store.testing, let address = browser.window?.contentView?.kitSubviews(of: SideAddressView.self).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else {
                answer(["error": "no address pill"]); return
            }
            address.benchPillHover(request["on"] as? Bool ?? true)
            if let down = request["press"] as? Bool { address.benchPress(down) }
            if let full = request["fullAddress"] as? Bool { browser.prefs.fullAddress = full }
            answer(["frame": address.window.map { _ in let f = address.convert(address.bounds, to: nil); return [f.minX, f.minY, f.width, f.height] } ?? []])

        case "rowhover":
            guard Store.testing else { answer(["error": "rowhover is for test runs"]); return }
            let order = browser.displayedTabs.map(\.id).filter { Bench.hoverRows[$0] != nil }
            let at = request["index"] as? Int ?? 0
            let picked = request["id"] != nil ? find(request, in: browser)?.id : order.indices.contains(at) ? order[at] : nil
            let chip = request["id"] != nil ? picked.flatMap { Bench.hoverChips[$0] } : nil
            guard let picked, let row = Bench.hoverRows[picked] ?? chip else { answer(["error": "no row \(at)", "rows": order.count]); return }
            row(request["on"] as? Bool ?? true)
            answer(["rows": order.count])

        case "stacked":
            guard Store.testing else { answer(["error": "stacked only works on a --test run"]); return }
            let tab: Tab? = (request["id"] as? String).flatMap { ref in
                browser.spaces.lazy.flatMap { browser.stackedRow($0.id).tabs }.first { $0.id.uuidString.lowercased().hasPrefix(ref.lowercased()) }
            }
            let target = (request["space"] as? Int).flatMap { browser.spaces.indices.contains($0 - 1) ? browser.spaces[$0 - 1].id : nil }
            switch request["action"] as? String ?? "" {
            case "load": browser.loadStackedRows()
            case "select":
                guard let tab, let space = browser.spaces.first(where: { browser.stackedRow($0.id).tabs.contains { $0.id == tab.id } })
                else { answer(missing(request)); return }
                browser.stackedSelect(tab, in: space.id)
            case "fold":
                guard let target else { answer(["error": "stacked fold needs space"]); return }
                if let on = request["on"] as? Bool { StackedFolds.shared.set(target, folded: on) } else { StackedFolds.shared.toggle(target) }
            case "jump":
                guard let target else { answer(["error": "stacked jump needs space"]); return }
                browser.stackedJump(to: target)
            case "drop":
                guard let tab, let target else { answer(["error": "stacked drop needs id and space"]); return }
                browser.stackedDrop(tab, onto: target)
            case "newtab":
                guard let target else { answer(["error": "stacked newtab needs space"]); return }
                browser.stackedNewTab(in: target)
            case "lift":
                guard let target else { answer(["error": "stacked lift needs space"]); return }
                StackedProbe.lift?.scripted = true
                StackedProbe.begin?(target)
            case "carry":
                guard let lift = StackedProbe.lift, let dy = request["dy"] as? Double else { answer(["error": "stacked carry needs dy and a lift"]); return }
                lift.move(to: lift.start + dy)
            case "letgo":
                StackedProbe.lift?.end()
            case "scroll":
                StackedProbe.scroll?(CGFloat(request["y"] as? Double ?? 0))
            case "run":
                StackedProbe.run?(CGFloat(request["from"] as? Double ?? 0), CGFloat(request["to"] as? Double ?? 0),
                                  CGFloat(request["step"] as? Double ?? 2))
            case "wheel":
                StackedProbe.route = request["route"] as? String ?? "direct"
                StackedProbe.wheel?(request["dy"] as? Double ?? 0, max(2, request["steps"] as? Int ?? 10), max(1, request["ms"] as? Double ?? 200),
                                    request["glide"] as? Int ?? 0, CGFloat(request["y"] as? Double ?? 200))
            default: break
            }
            answer(browser.stackedReport())

        case "space":
            // The spaces, and switching between them, for a test of what a
            // space keeps apart. Test runs only: it moves your tabs about.
            guard Store.testing else { answer(["error": "space only works on a --test run"]); return }
            switch request["action"] as? String ?? "" {
            case "new": browser.addSpace(named: request["name"] as? String ?? "Test", sharesSignIns: request["fresh"] as? Bool != true)
            case "go": browser.switchSpace(index: (request["index"] as? Int ?? 1) - 1)
            case "delete": browser.deleteSpace(browser.spaceID)
            case "icon": browser.setSpaceIcon(browser.spaceID, to: (request["icon"] as? String).map { TabIcon(saved: $0) })
            case "rename":
                if let name = request["name"] as? String { browser.renameSpace(browser.spaceID, to: name) }
                if let icon = request["icon"] as? String { browser.setSpaceIcon(browser.spaceID, to: TabIcon(saved: icon)) }
            case "swipe":
                // Two fingers sideways over the column, as the swipe reads
                // them — the trackpad's own events can't reach a probe in the back.
                let dx = request["dx"] as? Double ?? -120
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                for _ in 0..<12 { SpaceSwipe.shared.moved(dx: dx / 12, dy: 0) }
                SpaceSwipe.shared.ended()
            case "hold":
                // The fingers down and DX along, not yet let go — for a look
                // at the column mid-swipe.
                let dx = request["dx"] as? Double ?? -120
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                for _ in 0..<12 { SpaceSwipe.shared.moved(dx: dx / 12, dy: 0) }
            case "release":
                SpaceSwipe.shared.ended()
            case "held":
                SpaceSwipe.shared.held = request["on"] as? Bool ?? true
            case "trackpad":
                SpaceSwipe.shared.start(for: browser)
                BenchTrackpad.play(browser, request)
            case "trace":
                if request["report"] as? Bool == true { answer(SwipeTrace.shared.report()); return }
                SwipeTrace.shared.start(browser)
            case "goto":
                browser.goToSpace(index: (request["index"] as? Int ?? 1) - 1)
            case "foot":
                let index = (request["index"] as? Int ?? 1) - 1
                guard browser.spaces.indices.contains(index), let window = browser.window else {
                    answer(["error": "space foot needs a space and its test window"]); return
                }
                if let error = Bench.axPress("space-" + browser.spaces[index].id.uuidString, in: window) {
                    answer(["error": "the space's foot button " + error]); return
                }
            case "point":
                if let door = request["door"] as? String, let window = browser.window, let root = window.contentView {
                    let wanted = root.kitSubviews(of: KitHoverView.self).filter { view in
                        guard !view.isHiddenOrHasHiddenAncestor else { return false }
                        switch door {
                        case "plus": return view is DoorView && view.superview is SpaceFootView
                        case "downloads": return view is FetchDoorView
                        default: return view is DoorView || view is FetchDoorView
                        }
                    }
                    let on = request["on"] as? Bool ?? true
                    wanted.forEach { $0.benchPillHover(on) }
                    answer(["doors": wanted.map { view -> [String: Any] in
                        let side = (view as? DoorView)?.box ?? view.bounds.width
                        let plate = NSRect(x: (view.bounds.width - side) / 2, y: (view.bounds.height - side) / 2, width: side, height: side)
                        let rect = view.convert(plate, to: nil)
                        return ["icon": (view as? DoorView)?.icon ?? "downloads",
                                "plate": [rect.minX, window.frame.height - rect.maxY, rect.width, rect.height].map { Double($0) }]
                    }])
                    return
                }
                let index = (request["index"] as? Int ?? 1) - 1
                guard browser.spaces.indices.contains(index), let content = browser.window?.contentView else {
                    answer(["error": "space point needs a space and its test window"]); return
                }
                let wanted = "space-" + browser.spaces[index].id.uuidString
                content.kitSubviews(of: SpaceSpotView.self).first { $0.accessibilityIdentifier() == wanted }?
                    .benchPillHover(request["on"] as? Bool ?? true)
            case "key":
                Command.all.first { $0.id == "spaces.\(request["index"] as? Int ?? 1)" }?.run(browser)
            case "menu":
                let menu = SpaceMenu.menu(for: browser)
                let at = (request["index"] as? Int ?? 1) - 1
                if menu.items.indices.contains(at) { menu.performActionForItem(at: at) }
            case "ask":
                browser.askForSpace()
            case "leave":
                browser.leaveSpaceCreation()
            case "card":
                if let name = request["name"] as? String { browser.spaceAsk.draft?.name = name }
                if let look = request["look"] as? String { browser.spaceAsk.draft?.look = look }
                if let shared = request["shared"] as? Bool { browser.spaceAsk.accounts = SpaceAccounts(shares: shared) }
                if let icon = request["icon"] as? String { browser.spaceDraftIcon = TabIcon(saved: icon) }
                if request["create"] as? Bool == true { browser.createAskedSpace() }
            case "wheel":
                SpaceSwipe.shared.start(for: browser)
                _ = SpaceSwipe.shared.take(SpaceSwipe.Scroll(precise: false, dx: request["dx"] as? Double ?? -1), over: true)
            case "sweep":
                let stops = request["stops"] as? [Double] ?? []
                SpaceSwipe.shared.start(for: browser)
                SpaceSwipe.shared.began()
                var path: [Double] = []
                var at = 0.0
                for stop in stops {
                    for step in 1...18 { path.append(at + (stop - at) * Double(step) / 18) }
                    at = stop
                }
                var last = 0.0
                for (index, point) in path.enumerated() {
                    let move = point - last
                    last = point
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) / 60) {
                        SpaceSwipe.shared.moved(dx: move, dy: 0)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(path.count) / 60 + 0.01) {
                    SpaceSwipe.shared.ended()
                }
            case "look":
                var look = browser.space.look ?? SpaceLook()
                if ["colour", "custom", "colours"].contains(where: { request[$0] != nil }) {
                    look.mode = nil
                    look.fixed = nil
                    look.darkTone = nil
                    look.lightTone = nil
                }
                look.colour = request["colour"] as? String ?? look.colour
                if let custom = request["custom"] as? String {
                    look.colour = "custom"
                    look.custom = custom.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
                    look.colours = nil
                }
                if let colours = request["colours"] as? [String], !colours.isEmpty {
                    let clean = colours.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased() }
                    look = SpaceLook(colours: clean, intensity: look.intensity ?? SpaceLook.bold, transparency: look.transparency,
                                     grain: look.grain, glass: look.glass)
                }
                if let intensity = request["intensity"] as? Double { look.intensity = intensity }
                look.glass = request["glass"] as? Bool ?? look.glass
                look.transparency = request["transparency"] as? Double ?? look.transparency
                look.grain = request["grain"] as? Double ?? look.grain
                func tone(_ key: String) -> SpaceLook.Tone? {
                    guard let given = request[key] as? [String: Any] else { return nil }
                    if let colours = given["colours"] as? [String], !colours.isEmpty {
                        return SpaceLook.Tone(colours: colours.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased() },
                                              intensity: given["intensity"] as? Double ?? SpaceLook.bold)
                    }
                    if let id = given["swatch"] as? String { return SpaceLook.swatches.first { $0.id == id }?.tone }
                    return SpaceLook.Tone(colour: given["colour"] as? String ?? "gray", intensity: given["intensity"] as? Double)
                }
                if let mode = request["mode"] as? String {
                    let dark = request["shade"] as? String == "dark" || (request["shade"] == nil && browser.window?.contentView?.kitDark == true)
                    look.choose(oneColour: mode == "one", dark: dark)
                    if mode == "one", let shade = request["shade"] as? String { look.fixed = SpaceLook.Side(rawValue: shade) }
                }
                if let made = tone("dark") { look.paint(made, dark: true) }
                if let made = tone("light") { look.paint(made, dark: false) }
                if let side = request["follow"] as? String { look.follow(dark: side == "dark") }
                browser.setSpaceLook(browser.spaceID, to: look)
            case "bare":
                SpaceGroundView.bare = request["on"] as? Bool ?? true
                var views = browser.window?.contentView.map { [$0] } ?? []
                while let view = views.popLast() {
                    (view as? SpaceGroundView)?.render()
                    views += view.subviews
                }
            case "slide":
                let here = browser.spaces.firstIndex { $0.id == browser.spaceID } ?? 0
                SpaceSwipe.shared.slide(browser, to: (request["index"] as? Int ?? 1) - 1, from: here)
            case "move":
                if let index = request["index"] as? Int { browser.moveSpace(browser.spaceID, to: index - 1) }
            case "menuitems":
                answer(["items": SpaceMenu.menu(for: browser).items.map { item -> [String: Any] in
                    ["title": item.title, "key": item.keyEquivalent, "separator": item.isSeparatorItem, "checked": item.state == .on]
                }])
                return
            case "step":
                browser.stepSpace(request["by"] as? Int ?? 1)
            case "footwheel":
                guard let window = browser.window, let foot = browser.spaceFeet.allObjects.first(where: { $0.window === window }) else {
                    answer(["error": "space footwheel needs the window's foot"]); return
                }
                let point = foot.convert(NSPoint(x: foot.bounds.midX, y: foot.bounds.midY), to: nil)
                let scroll = SpaceSwipe.Scroll(precise: request["precise"] as? Bool ?? true, dx: -(request["dx"] as? Double ?? 0),
                                               dy: -(request["dy"] as? Double ?? 0))
                SpaceSwipe.shared.start(for: browser)
                let panned = SpaceSwipe.shared.pan(scroll, at: point, in: browser, window: window)
                if !panned, request["through"] as? Bool == true { _ = SpaceSwipe.shared.take(scroll, over: true) }
                answer(["panned": panned, "foot": foot.benchState])
                return
            case "footpage":
                guard let window = browser.window, let foot = browser.spaceFeet.allObjects.first(where: { $0.window === window }) else {
                    answer(["error": "space footpage needs the window's foot"]); return
                }
                foot.page(CGFloat(request["by"] as? Double ?? 1))
            case "footback":
                browser.spaceFeet.allObjects.first { $0.window === browser.window }?.comeBack(after: request["after"] as? Double ?? 0)
            case "foottrace":
                if request["on"] as? Bool == true {
                    SpaceFootView.trace = []
                    SpaceFootView.fades = 0
                } else {
                    let frames = SpaceFootView.trace ?? []
                    SpaceFootView.trace = nil
                    answer(["foottrace": ["frames": frames, "fades": SpaceFootView.fades] as [String: Any]])
                    return
                }
            default: break
            }
            var said: [String: Any] = [
                "on": browser.prefs.usesSpaces,
                "current": browser.space.name,
                "spaces": browser.spaces.map { ["name": $0.name, "id": $0.id.uuidString, "downloads": $0.downloads ?? "", "shared": $0.sharesSignIns == true] },
                "parked": browser.parked.map { [$0.key.uuidString: $0.value.tabs.count] },
                "tabs": browser.tabs.count,
                "making": browser.makingSpace,
                "asking": browser.spaceAsk.up,
                "card": ["name": browser.spaceAsk.draft?.name ?? "", "look": browser.spaceAsk.draft?.look ?? "",
                         "accounts": browser.spaceAsk.accounts.rawValue, "icon": browser.draftIcon.saved] as [String: Any],
                "looks": SpaceLook.offered,
                "swipe": Double(browser.spaceMotion.offset),
                "next": browser.spaceNext ?? -1,
                "trackpad": BenchTrackpad.taken,
                // Each space off screen as a swipe draws it passing by
                // (Parked.drawn): its groups, folded or not, and their tabs.
                "drawn": Dictionary(browser.parked.map { id, row in
                    let (groups, loose) = row.drawn(groupsOn: browser.prefs.usesTabGroups, splitView: browser.prefs.splitView)
                    return (browser.spaces.first { $0.id == id }?.name ?? id.uuidString, [
                        "groups": groups.map { ["name": $0.group.name, "collapsed": $0.group.collapsed,
                                                "tabs": $0.tabs.map(Bench.short)] as [String: Any] },
                        "loose": loose.map(Bench.short),
                        "active": row.active.map { id in row.tabs.first { $0.id == id }.map(Bench.short) ?? "" } ?? "",
                    ] as [String: Any])
                }, uniquingKeysWith: { first, _ in first }),
                "pages": Web.pages.allObjects.map { $0.configuration.websiteDataStore.identifier?.uuidString ?? "default" },
            ]
            if let foot = browser.spaceFeet.allObjects.first(where: { $0.window != nil && $0.window === browser.window }) {
                said["foot"] = foot.benchState
            }
            said["loads"] = ["rows": SpaceLoads.rows, "longestMs": SpaceLoads.longest * 1000,
                             "parkedTabs": browser.parkedTabs.count] as [String: Any]
            let out = said
            // And the stores WebKit keeps by identifier, a moment later —
            // what a deleted space should have taken with it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { ids in
                    MainActor.assumeIsolated {
                        // What is still in the stores of deleted spaces — none, if deleting emptied them.
                        let erasing = (Store.settings.stringArray(forKey: "spaces.erasing") ?? []).compactMap(UUID.init)
                        guard request["records"] as? Bool == true, !erasing.isEmpty else {
                            answer(out.merging(["stores": ids.map(\.uuidString)]) { a, _ in a })
                            return
                        }
                        Task { @MainActor in
                            var left: [String: [String]] = [:]
                            for id in erasing where ids.contains(id) {
                                let records = await WKWebsiteDataStore(forIdentifier: id)
                                    .dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
                                left[id.uuidString] = records.map { "\($0.displayName): \($0.dataTypes.sorted().joined(separator: ","))" }
                            }
                            answer(out.merging(["stores": ids.map(\.uuidString), "erasingRecords": left]) { a, _ in a })
                        }
                    }
                }
            }

        case "split":
            splitCommand(request, browser: browser, answer)

        case "fieldrows":
            fieldCommand(request, browser: browser, answer)

        case "snippets":
            snippetCommand(request, browser: browser, answer)

        case "quick":
            quickCommand(request, browser: browser, answer)

        case "meetalert":
            meetingAlertCommand(request, browser: browser, answer)

        case "meetfolder":
            meetingFolderCommand(request, browser: browser, answer)

        case "idle":
            BenchIdle.run(request, browser: browser, answer)

        case "signins":
            BenchSignIns.run(request, answer)

        case "lights":
            BenchLights.run(request, answer)

        case "ui":
            if request["toggleFold"] as? Bool == true, Store.testing { browser.toggleFold() }
            if Store.testing, let width = request["sideWidth"] as? Double { browser.prefs.sideWidth = CGFloat(width) }
            // Open or close the app's own panels, to reproduce what a person
            // did without a person.
            if let on = request["settings"] as? Bool { browser.tuning = on }
            if Store.testing, request["settingsClose"] as? Bool == true { SettingsWindow.shared.close() }
            if let on = request["passwords"] as? Bool, Store.testing { browser.managing = on }
            if let name = request["settingspage"] as? String { browser.show(InternalPage(.settings, name)) }
            if Store.testing, let page = (request["settingsPage"] as? String).flatMap(SettingsPage.named) {
                browser.settingsPage = page
                browser.settingsAsked = page
            }
            if Store.testing, let words = request["settingsFind"] as? String { browser.settingsTyped = words }
            if Store.testing, let text = request["linkChooser"] as? String, let url = URL(string: text) {
                LinkChooser.ask(IncomingLink(url: url, source: .unknownApp), url: url, in: browser, world: Browsers.linkWorld(from: browser))
            }
            if Store.testing, let on = request["linkNotice"] as? Bool {
                browser.showLinkNotice(on ? LinkNotice("Opened in Work by a rule", choices: [
                    .init("Undo", id: "link.notice.undo") {}, .init("Edit Rule", id: "link.notice.edit") {},
                ]) : nil, for: 60)
            }
            if Store.testing, let name = request["settingsDetail"] as? String, name == "linkrule", let rule = LinkRules.shared.rules.first {
                browser.settingsRule = rule.id
            } else if Store.testing, let name = request["settingsDetail"] as? String {
                if let detail = SettingsDetail.named(name) {
                    browser.settingsDrill = detail
                } else if let page = SettingsPage.named(name) {
                    browser.settingsPage = page
                    browser.settingsAsked = page
                } else {
                    browser.settingsDrill = nil
                }
            }
            if Store.testing, let at = request["settingsClick"] as? [Double], at.count == 2 {
                SettingsWindow.shared.benchClick(x: at[0], y: at[1])
            }
            if Store.testing, let on = request["settingsKey"] as? Bool { SettingsWindow.shared.benchKey(on) }
            if Store.testing, let size = request["settingsSize"] as? [Double], size.count == 2 {
                SettingsWindow.shared.benchResize(width: size[0], height: size[1])
            }
            if Store.testing, let id = request["settingsPress"] as? String, !SettingsWindow.shared.benchPress(id) {
                answer(["error": "nothing to press in Settings called \(id)"])
                return
            }
            if Store.testing, let row = request["settingsPoint"] as? String, !SettingsWindow.shared.benchPoint(row) {
                answer(["error": "no row in Settings to point at called \(row)"])
                return
            }
            if Store.testing, let row = request["settingsFocus"] as? String, !SettingsWindow.shared.benchFocus(row) {
                answer(["error": "nothing in the Settings row \(row) takes the keyboard"])
                return
            }
            if Store.testing, let at = request["settingsSpace"] as? Int {
                SettingsWindow.shared.benchSpace(browser.spaces.indices.contains(at - 1) ? browser.spaces[at - 1].id : nil)
            }
            let phases: [String: NSEvent.EventType] = ["down": .leftMouseDown, "up": .leftMouseUp, "move": .mouseMoved, "drag": .leftMouseDragged]
            let phase = phases[request["pointerPhase"] as? String ?? "move"] ?? .mouseMoved
            if Store.testing, let at = request["settingsPointer"] as? [Double], at.count == 2 {
                SettingsWindow.shared.benchClick(x: at[0], y: at[1], types: [phase])
            }
            if Store.testing, let at = request["windowPointer"] as? [Double], at.count == 2,
               let window = (request["pointerWindow"] as? Int).flatMap(NSApp.window(withWindowNumber:)) ?? browser.window {
                SettingsWindow.benchClick(in: window, x: at[0], y: at[1], types: [phase])
            }
            if Store.testing, let key = request["settingsKey"] as? String {
                let keys: [String: (UInt16, String)] = ["tab": (48, "\t"), "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "space": (49, " ")]
                if let (code, characters) = keys[key.replacingOccurrences(of: "shift-", with: "")] {
                    SettingsWindow.shared.benchKey(code, characters: characters, shift: key.hasPrefix("shift-"))
                }
            }
            if let on = request["history"] as? Bool { browser.recalling = on }
            if let on = request["downloads"] as? Bool { browser.hoarding = on }
            if Store.testing, let place = request["windowAt"] as? String, let window = browser.window,
               let screen = window.screen?.visibleFrame {
                var origin = NSPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2)
                if place == "bottom" || place == "corner" { origin.y = screen.minY }
                if place == "left" || place == "corner" { origin.x = screen.minX }
                if place == "right" || place == "rightcorner" { origin.x = screen.maxX - window.frame.width }
                if place == "rightcorner" { origin.y = screen.minY }
                window.setFrameOrigin(origin)
            }
            if Store.testing, let stage = request["downloadsStage"] as? String {
                guard Fetches.benchStages.contains(stage) else {
                    answer(["error": "downloadsStage is one of \(Fetches.benchStages.joined(separator: ", "))"])
                    return
                }
                browser.fetches.benchStage(stage, loot: browser.loot)
            }
            if let on = request["recentdownloads"] as? Bool { browser.downloadsOpen = on }
            if Store.testing, let link = request["link"] as? String {
                if !browser.prefs.showsLinks { browser.prefs.showsLinks = true }
                browser.linkStatus.show(link == "off" ? nil : link, over: browser.active?.built, space: browser.spaceID, privateTab: browser.active?.shy == true)
            }
            if Store.testing, let text = request["announce"] as? String { browser.announce(text) }
            if Store.testing, let on = request["downloadsbutton"] as? Bool { browser.prefs.alwaysShowsDownloads = on }
            if Store.testing, let on = request["plus"] as? Bool { browser.plusOpen = on }
            if Store.testing, let bars = request["glassBars"] as? [String] { BenchGlass.show(bars, browser) }
            if Store.testing, let dark = request["glassDark"] as? Bool { BenchGlass.dark(dark) }
            if Store.testing, let on = request["finding"] as? Bool { if on { browser.finding = true } else { browser.closeFind() } }
            if let on = request["bookmarks"] as? Bool { browser.bookmarking = on }
            if Store.testing, request["bookmarkCard"] as? Bool == true { browser.bookmarkCurrent() }
            if Store.testing, let on = request["bookmarksList"] as? Bool {
                if on { browser.bookmarkCard = nil }
                browser.bookmarksOpen = on
            }
            // The Bring things over sheet: on, off, on at a browser by name,
            // or on for the extensions alone, as Settings › Extensions opens it.
            if let text = request["import"] as? String {
                browser.bringingExtensions = text == "extensions"
                browser.bringingIn = ["off", "false", "0", "no"].contains(text) ? nil
                    : ["on", "true", "1", "yes", "extensions"].contains(text) ? "" : text
            }
            // Search's own pages (InternalPages.swift): one shown by its
            // address as a link would open it, one reached from the page in
            // front as its own buttons do, and an address typed on the tab
            // in front.
            if let text = request["show"] as? String, let url = URL(string: text) { _ = browser.open(url, foreground: true) }
            if let text = request["lead"] as? String, let kind = InternalPage.Kind(rawValue: text) { browser.lead(to: InternalPage(kind)) }
            if let text = request["go"] as? String, let url = URL(string: text) { browser.active?.go(to: url) }
            if let on = request["hidden"] as? Bool { browser.reviewing = on }
            if let look = (request["look"] as? String).flatMap(Look.init) { browser.prefs.look = look }
            if let side = request["side"] as? String {
                guard let position = SidebarPosition(rawValue: side) else {
                    answer(["error": "side needs left or right"])
                    return
                }
                browser.prefs.sidePosition = position
            }
            if let mode = (request["pages120"] as? String).flatMap(FastPages.init) { browser.prefs.fastPages = mode }
            if let on = request["dusk"] as? Bool { browser.prefs.darkensPages = on }
            // Swipe between pages, standing in for the Mac's own setting.
            if let on = request["swipepages"] as? Bool, Store.testing { Swipe.testing = on }
            // Ask.sure answered without a sheet: yes or no to every question
            // from now on, until "ask".
            if let yes = request["confirm"] as? Bool, Store.testing { Ask.testing = yes }
            // "ask": the real question again, as a person gets it.
            if request["confirm"] as? String == "ask" { Ask.testing = nil }
            if Store.testing, let title = request["sheetPress"] as? String {
                guard let button = browser.window?.attachedSheet?.contentView?.kitSubviews(of: NSButton.self).first(where: { $0.title == title })
                else { answer(["error": "no button called \(title) on a sheet"]); return }
                button.performClick(nil)
            }
            if let on = request["spaces"] as? Bool { browser.prefs.usesSpaces = on }
            if let on = request["groups"] as? Bool, Store.testing { browser.prefs.usesTabGroups = on }
            if let on = request["sharedpins"] as? Bool { browser.prefs.sharesPins = on }
            if let on = request["hides"] as? Bool { browser.prefs.sideHides = on }
            if let on = request["cards"] as? Bool { browser.prefs.cards = on }
            if Store.testing, let on = request["unclip"] as? Bool, let root = browser.window?.contentView?.superview {
                SelectedLook.unclip(on, in: root)
            }
            if let on = request["bookmarksBar"] as? Bool, Store.testing { browser.prefs.bookmarksBar = on }
            if let on = request["address"] as? Bool { browser.prefs.showsAddress = on }
            if Store.testing, let bar = request["addressBar"] as? String {
                browser.prefs.addressBar = bar != "hidden"
                browser.prefs.fullAddress = bar == "full"
            }
            // Settings › Videos wait for a click, moved as its switch moves it.
            if let on = request["waits"] as? Bool, Store.testing { browser.prefs.waitsForPlay = on }
            // Settings › Privacy's two switches (see Privacy.swift).
            if let on = request["gpc"] as? Bool, Store.testing { browser.prefs.sendsPrivacySignal = on }
            if let on = request["clickids"] as? Bool, Store.testing { browser.prefs.removesClickIDs = on }
            if let on = request["folded"] as? Bool { browser.folded = on }
            // The window's own full screen as the chrome sees it, without
            // the window going there: a test run never takes the screen.
            if let on = request["fullscreen"] as? Bool, Store.testing { browser.fullScreen = on }
            if let on = request["peek"] as? Bool { browser.peek(on) }
            if Store.testing, let card = request["hovercard"] as? [String: Any],
               let id = card["id"] as? String, let at = card["frame"] as? [Double], at.count == 4,
               let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }) {
                browser.hoverCards.enter(.tab(tab.id), frame: CGRect(x: at[0], y: at[1], width: at[2], height: at[3]))
            }
            if Store.testing, request["hovercard"] as? String == "off" { browser.hoverCards.dismiss() }
            if let on = request["noisy"] as? Bool { browser.active?.noisy = on }
            if Store.testing, let id = request["unread"] as? String,
               let tab = browser.tabs.first(where: { Bench.short($0) == String(id.prefix(8)).lowercased() }) {
                tab.unread = true
            }
            if let on = request["lookMore"] as? Bool, request["editlook"] as? Bool == true { Store.settings.set(on, forKey: SpaceLookEditorView.moreKey) }
            if let on = request["editlook"] as? Bool { browser.editingLook = on }
            if let card = KitPopup.current(in: browser.window)?.content as? SpaceLookEditorView {
                if let on = request["lookMore"] as? Bool, request["editlook"] == nil { card.setMore(on) }
                if let mode = request["lookMode"] as? String { card.pickMode(oneColour: mode == "one") }
                if let side = request["lookSide"] as? String { card.pickSide(dark: side == "dark") }
                if let id = request["lookSwatch"] as? String { card.pickSwatch(id) }
            }
            if request["lookHeights"] as? Bool == true {
                answer(["heights": SpaceLookEditorView.heights])
                SpaceLookEditorView.heights = []
                return
            }
            if request["pickicon"] as? Bool == true { browser.iconPicker.pick(.space(browser.spaceID)) }
            if Store.testing, request["popup"] as? String == "close" { KitPopup.closeAll(in: browser.window) }
            // A peek at a link (Peek.swift): its two buttons.
            if let what = request["peeklink"] as? String {
                if what == "keep" { browser.keepPeek() }
                else if what == "beside" { browser.keepPeek(beside: true) }
                else { browser.closePeek() }
            }
            // The address of the tab on screen being edited in the tab, with
            // this typed, and that edit let go of by a click elsewhere.
            if let text = request["edittab"] as? String, let tab = browser.active {
                browser.beginTabEdit(tab)
                browser.tabDraft = text
            }
            if request["finishedit"] as? Bool == true { browser.finishTabEdit() }
            if let on = request["extensions"] as? Bool { Extensions.shared.menuOpen = on }
            if Store.testing, let ask = request["tabKeys"] as? [String: Any] { return BenchTabKeys.run(ask, browser: browser, answer) }
            if Store.testing, let ask = request["foldtrace"] as? [String: Any] { return FoldTrace.run(ask, browser: browser, answer) }
            if Store.testing, let ask = request["stagetrace"] as? [String: Any] { return StageTrace.run(ask, browser: browser, answer) }
            if Store.testing, let ask = request["peektrace"] as? [String: Any] { return PeekTrace.run(ask, browser: browser, answer) }
            if Store.testing, let ask = request["endtrace"] as? [String: Any] { return EndTrace.run(ask, browser: browser, answer) }
            if Store.testing, let on = request["pointerless"] as? Bool { Fold.pointerIgnored = on }
            if Store.testing, let on = request["covered"] as? Bool { ContentView.seenWhenCovered = on }
            answer(["ok": true])

        case "sidepanel":
            // The side panel (SidePanel.swift): what is in it, and, in a test
            // run, JavaScript in its extension page, or closing it.
            let web = SidePanelPages.shared.web(in: browser)
            var content: [String: Any] = ["kind": "none"]
            switch browser.sidePanel {
            case .page(let id, let url, let tab): content = ["kind": "page", "extension": id, "url": url.absoluteString, "tab": tab.map { $0.uuidString } ?? ""]
            case .site(let url, let space): content = ["kind": "site", "url": url.absoluteString, "space": space.uuidString,
                                                       "store": web.map { $0.configuration.websiteDataStore.isPersistent } ?? false,
                                                       "sameStore": web.map { $0.configuration.websiteDataStore === Spaces.store(for: browser.spaceID) } ?? false,
                                                       "profileStore": web.map { page in Spaces.spaceStores().contains { $0 === page.configuration.websiteDataStore } } ?? false,
                                                       "inspectable": web.map { return $0.isInspectable } ?? false,
                                                       "developerExtras": web.flatMap { $0.configuration.preferences.value(forKey: "developerExtrasEnabled") as? Bool } ?? false]
                .merging(SidePanelPages.shared.siteReport(in: browser)) { a, _ in a }
            case nil: break
            }
            // Where the panel's page and every page sit in the window, from
            // its top-left corner, in points: [x, y, width, height].
            func spot(_ view: NSView?) -> [Int] {
                guard let view, let window = view.window else { return [] }
                let r = view.convert(view.bounds, to: nil)
                return [Int(r.minX), Int(window.frame.height - r.maxY), Int(r.width), Int(r.height)]
            }
            func webs(in view: NSView?) -> [WKWebView] {
                guard let view else { return [] }
                if let web = view as? WKWebView { return [web] }
                return view.subviews.flatMap(webs)
            }
            let all = webs(in: (browser.window ?? Links.window)?.contentView)
            var state: [String: Any] = ["shown": browser.sidePanelShown, "held": browser.sidePanelHeld,
                                        "content": content, "width": Double(browser.prefs.sidePanelWidth),
                                        "page": web?.url?.absoluteString ?? "", "title": web?.title ?? "", "loading": web?.isLoading ?? false,
                                        "opensWindows": web?.configuration.preferences.javaScriptCanOpenWindowsAutomatically ?? false]
            state["frame"] = spot(web)
            state["pages"] = all.filter { $0 !== web }.map(spot)
            state["cards"] = browser.asCards
            state["windowWidth"] = Int((browser.window ?? Links.window)?.frame.width ?? 0)
            state["tabs"] = browser.tabs.count
            switch request["action"] as? String ?? "state" {
            case "eval":
                guard Store.testing else { answer(["error": "sidepanel eval only works on a --test run"]); return }
                guard let web, let js = request["js"] as? String else { answer(["error": "no panel page"]); return }
                web.evaluateJavaScript(js) { value, error in
                    if let error { answer(["error": error.localizedDescription]) } else { answer(["value": Bench.plain(value)]) }
                }
            case "touch":
                // A real click in the panel's page, as the event watcher
                // records one (Extensions.touched). Test runs only.
                guard Store.testing else { answer(["error": "sidepanel touch only works on a --test run"]); return }
                if case .page(let id, _, _) = browser.sidePanel { Extensions.touched[id] = Date() }
                answer(state)
            case "close":
                guard Store.testing else { answer(["error": "sidepanel close only works on a --test run"]); return }
                browser.closeSidePanel()
                answer(["shown": browser.sidePanelShown])
            case "site":
                // A website into the panel, as View › Side Panel puts one
                // there (or the tab's menu, with "tab"). Test runs only.
                guard Store.testing else { answer(["error": "sidepanel site only works on a --test run"]); return }
                if let id = request["tab"] as? String, let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }) {
                    browser.openInSidePanel(tab)
                } else if let url = (request["url"] as? String).flatMap(URL.init(string:)) {
                    browser.showSiteInPanel(url)
                }
                answer(["shown": browser.sidePanelShown])
            case "crash":
                // The panel's website told its process is gone, as WebKit
                // tells a crash. Test runs only.
                guard Store.testing else { answer(["error": "sidepanel crash only works on a --test run"]); return }
                SidePanelPages.shared.siteCrashed(in: browser)
                answer(SidePanelPages.shared.siteReport(in: browser))
            case "totab":
                guard Store.testing else { answer(["error": "sidepanel totab only works on a --test run"]); return }
                browser.sitePanelToTab()
                answer(["shown": browser.sidePanelShown, "tabs": browser.tabs.count])
            default:
                answer(state)
            }

        case "popups":
            // The windows a tab's page was refused, as its sign offers them
            // (BlockedPopups.swift), and the sites allowed. open (newest is
            // 0), allow and remove do what the sign and Settings › Privacy
            // do: test runs only, they open tabs and change settings.
            let action = request["action"] as? String ?? "state"
            guard Store.testing || ["state", "sites"].contains(action) else {
                answer(["error": "popups \(action) only works on a --test run"]); return
            }
            let sites: () -> [String: Any] = { ["allowed": browser.prefs.popupSites.sorted()] }
            if action == "sites" { answer(sites()); return }
            if action == "forgive" { PopupGuard.strikes.removeAll(); answer(sites()); return }
            if action == "remove" {
                guard let site = request["site"] as? String else { answer(["error": "popups remove needs a site"]); return }
                browser.prefs.popupSites.remove(site)
                answer(sites()); return
            }
            guard let tab = find(request, in: browser) else { answer(missing(request)); return }
            let state: () -> [String: Any] = {
                [
                    "blocked": tab.blockedPopups.map { $0.url?.absoluteString ?? "" },
                    "openable": tab.blockedPopups.map { BlockedPopups.openable($0.url) != nil },
                    "reasons": tab.blockedPopups.map { $0.reason?.rawValue ?? "" },
                    "hits": tab.popupGesture.hits.count,
                    "trace": tab.popupTrace,
                    "wary": PopupGuard.wary(tab.pageAddress),
                    "sign": !tab.blockedPopups.isEmpty,
                    "site": BlockedPopups.site(of: tab.pageAddress) ?? "",
                    "allowed": browser.prefs.popupSites.sorted(),
                    "tabAllowed": tab.popupSites.sorted(),
                ]
            }
            switch action {
            case "state": answer(state())
            case "open":
                let index = request["index"] as? Int ?? 0
                let newest = Array(tab.blockedPopups.reversed())
                guard newest.indices.contains(index) else { answer(["error": "no blocked pop-up \(index)"]); return }
                let opened = browser.openBlocked(newest[index], from: tab)
                var reply = state()
                if let opened {
                    reply["opened"] = describe(opened)
                    reply["openedOpener"] = opened.opener?.uuidString ?? ""
                }
                answer(reply)
            case "allow":
                browser.allowPopups(from: tab)
                answer(state())
            default:
                answer(["error": "popups state|open|allow|remove|sites"])
            }

        case "agent", "agents":
            guard Store.testing else { answer(["error": "agent only works on a --test run"]); return }
            agent(request, browser: browser, answer)

        case "autofill":
            guard Store.testing else { answer(["error": "autofill only works on a --test run"]); return }
            autofill(request, browser: browser, answer)

        case "codes":
            guard Store.testing else { answer(["error": "codes only works on a --test run"]); return }
            codes(request, browser: browser, answer)
        case "folders", "searchfolder", "live", "route", "card", "icon":
            TabsBench.run(verb, request, browser: browser, answer)
        case "foldergrid":
            FolderGridBench.run(request, browser: browser, answer)

        case "aigroups":
            AIGroupsBench.run(request, browser: browser, answer)

        case "ctxmenu":
            BenchMenus.run(request, browser: browser, answer)

        case "downloadtrace":
            guard Store.testing else { answer(["error": "downloadtrace is for test runs"]); return }
            if request["clear"] as? Bool == true { DownloadTrace.clear() }
            if let name = request["cancel"] as? String, let entry = browser.fetches.entries.first(where: { $0.name == name }) {
                browser.cancelDownload(entry)
            }
            let entries = browser.fetches.entries.map { entry -> [String: Any] in
                ["name": entry.name, "state": "\(entry.state)", "error": entry.errorDescription ?? "",
                 "destination": entry.destination?.path ?? ""]
            }
            let kept = browser.loot.kept.map { ["name": $0.name, "path": $0.path, "from": $0.from] }
            let quiet = Browsers.all.flatMap { $0.privateFileDownloads }.map { ["name": $0.name, "path": $0.path] }
            answer(["events": DownloadTrace.events, "entries": entries, "kept": kept, "private": quiet,
                    "folder": browser.downloadsFolder.path, "announcement": browser.announcement ?? "",
                    "shieldLists": Shield.shared.downloaded.count])

        case "downloadslist":
            guard Store.testing else { answer(["error": "downloadslist is for test runs"]); return }
            if request["action"] as? String == "click" {
                func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .leftMouseDown ? 1 : 0
                    )
                }
                if let row = request["row"] as? Int {
                    guard let list = RecentDownloadsView.front, let window = list.window, browser.downloadsOpen,
                          let point = list.benchSpot(row, verb: request["verb"] as? String),
                          let down = event(.leftMouseDown, at: point, in: window),
                          let up = event(.leftMouseUp, at: point, in: window) else {
                        answer(["error": "nothing to click on that row"])
                        return
                    }
                    let hit = window.contentView?.superview.flatMap { $0.hitTest($0.convert(point, from: nil)) }
                    NSApp.postEvent(down, atStart: false)
                    NSApp.postEvent(up, atStart: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        let rows = browser.downloadsOpen && list.window != nil ? list.benchRows() : []
                        answer(["open": browser.downloadsOpen, "rows": rows, "hit": hit.map { "\(type(of: $0))" } ?? "",
                                "asked": Loot.benchAsked])
                    }
                    return
                }
                guard let door = browser.downloadsAnchor, let window = door.window else { answer(["error": "no downloads button"]); return }
                let rect = door.convert(door.bounds, to: nil)
                var point = NSPoint(x: rect.maxX - 2, y: rect.midY)
                if let at = request["at"] as? [Double], at.count == 2 { point = NSPoint(x: at[0], y: Double(window.frame.height) - at[1]) }
                let via = request["via"] as? String ?? "window"
                func send(_ type: NSEvent.EventType) {
                    guard let made = event(type, at: point, in: window) else { return }
                    switch via {
                    case "app": NSApp.sendEvent(made)
                    case "post": NSApp.postEvent(made, atStart: false)
                    default: window.sendEvent(made)
                    }
                }
                send(.leftMouseDown)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    let between = browser.downloadsOpen
                    send(.leftMouseUp)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                        answer(["open": browser.downloadsOpen, "between": between])
                    }
                }
                return
            }
            guard let list = RecentDownloadsView.front, list.window != nil, browser.downloadsOpen else {
                answer(["error": "the downloads list is not open"])
                return
            }
            switch request["action"] as? String ?? "rows" {
            case "select": list.benchSelect(request["row"] as? Int)
            case "press":
                guard let row = request["row"] as? Int, list.benchPress(row, verb: request["verb"] as? String) else {
                    answer(["error": "nothing to press on that row"])
                    return
                }
            case "key":
                guard let code = request["code"] as? Int else { answer(["error": "downloadslist key CODE"]); return }
                list.benchKey(UInt16(code))
            case "axpress":
                guard let row = request["row"] as? Int else { answer(["error": "downloadslist axpress ROW"]); return }
                let pressed = list.benchAccessPress(row)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    answer(["pressed": pressed, "open": browser.downloadsOpen, "asked": Loot.benchAsked])
                }
                return
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                guard browser.downloadsOpen, list.window != nil else { answer(["open": false, "rows": []]); return }
                answer(["open": true, "rows": list.benchRows(), "key": list.window?.isKeyWindow == true,
                        "responder": list.window?.firstResponder.map { "\(type(of: $0))" } ?? ""])
            }

        case "pageclick":
            BenchPageClick.run(request, browser: browser, answer)

        case "plans":
            PlansBench.run(request, browser: browser, answer)

        case "hints":
            BenchHints.run(request, browser: browser, answer)

        case "knowing":
            guard Store.testing else { answer(["error": "knowing only works on a --test run"]); return }
            knowing(request, browser: browser, answer)

        case "extensions", "ext-add", "ext-folder", "ext-press", "ext-remove", "ext-reload", "ext-page", "ext-popup", "ext-menu", "ext-pin", "ext-shot", "ext-answer", "ext-enable", "ext-private", "capture", "capture-stop":
            extensionCommand(verb, request, browser: browser, answer)

        default:
            answer(["error": "unknown command “\(verb)”", "commands": [
                "tabs", "network", "dock", "sitefiles", "quick", "open", "adopt", "go", "openmark", "close", "wait", "sleep", "select", "text", "nowplaying", "eval", "click", "type", "submit", "shot", "probe", "key", "textcheck", "resize", "hit", "pointer", "film", "float", "window", "pages", "picture", "pdf", "place", "group", "tospace", "field", "bookmark", "marks", "menu", "keyeq", "fill", "pin", "middle", "windows", "alive", "updates", "quit", "towindow", "pull", "magnify", "wheel", "refresh", "discs", "space", "split", "column", "fold", "consent", "site", "ui", "import", "import-preview", "import-file", "import-panel", "import-file-start", "import-file-status", "import-file-cancel", "remove-folder", "passwords", "accounts", "find", "answer", "visible", "ai", "notifications", "popups", "suggest", "translate", "settings", "fieldrows", "autofill", "agent", "agents", "codes", "folders", "searchfolder", "live", "route", "card", "icon", "aigroups", "ctxmenu", "downloadslist", "pageclick", "hints",
            ]])
        }
    }

    /// A small model bridge for offline split regressions. The browser model is
    /// the system under test; this command is deliberately unavailable in the
    /// browser somebody is using because its actions move and close tabs.
    /// Where a page lent to the recording pill was before, for `recording`.
    static var lentFrom: [ObjectIdentifier: WeakView] = [:]
    final class WeakView {
        weak var view: NSView?
        init(_ view: NSView?) { self.view = view }
    }

    /// The view a `split mouse … to: view` press landed on, for the rest of it.
    private weak var pressed: NSView?

    private func splitCommand(
        _ request: [String: Any],
        browser: Browser,
        _ answer: @escaping ([String: Any]) -> Void
    ) {
        guard Store.testing else {
            answer(["error": "split only works on a --test run"])
            return
        }

        func reply(_ extra: [String: Any] = [:]) {
            answer(splitState(browser).merging(extra) { _, new in new })
        }
        func tab(_ field: String = "id") -> Tab? {
            guard let id = request[field] as? String else { return nil }
            return find(["id": id], in: browser)
        }

        switch request["action"] as? String ?? "state" {
        case "state":
            reply()

        case "divider":
            func dividers(in view: NSView?) -> [PaneDivider] {
                guard let view else { return [] }
                return (view as? PaneDivider).map { [$0] } ?? view.subviews.flatMap { dividers(in: $0) }
            }
            guard let content = browser.window?.contentView,
                  let divider = dividers(in: content).first(where: { !$0.isHidden && $0.window != nil }) else {
                answer(["error": "no divider on screen"])
                return
            }
            if let on = request["hover"] as? Bool { divider.benchHover(on) }
            if let on = request["hold"] as? Bool { divider.benchHold(on) }
            let frame = divider.convert(divider.bounds, to: nil)
            let height = content.bounds.height
            DispatchQueue.main.asyncAfter(deadline: .now() + (request["wait"] as? Double ?? 0)) {
                answer(["frame": [frame.minX, height - frame.maxY, frame.width, frame.height], "pill": divider.benchPill])
            }

        case "pill":
            func pills(in view: NSView?) -> [SideAddressView] {
                guard let view else { return [] }
                return (view as? SideAddressView).map { [$0] } ?? view.subviews.flatMap { pills(in: $0) }
            }
            guard let content = browser.window?.contentView, let pill = pills(in: content).first else {
                answer(["error": "no address pill"])
                return
            }
            let frame = pill.convert(pill.bounds, to: nil)
            answer(["frame": [frame.minX, content.bounds.height - frame.maxY, frame.width, frame.height],
                    "shown": !pill.isHidden && pill.window != nil, "says": pill.accessibilityLabel() ?? ""])

        case "enabled":
            guard let on = request["on"] as? Bool else { answer(["error": "split enabled needs on"]); return }
            browser.prefs.splitView = on
            DispatchQueue.main.async { reply() }

        case "group":
            guard let page = tab() else { answer(["error": "split group needs id"]); return }
            if let id = (request["group"] as? String).flatMap(UUID.init) {
                browser.move(page, toGroup: id)
            } else if request["group"] as? String == "none" {
                browser.move(page, toGroup: nil)
            } else {
                _ = browser.addTabGroup(containing: page)
            }
            reply()

        case "collapse":
            guard let id = (request["group"] as? String).flatMap(UUID.init) else {
                answer(["error": "split collapse needs group UUID"]); return
            }
            browser.toggleTabGroup(id)
            reply()

        case "step":
            browser.step(request["direction"] as? Int ?? 1)
            reply()

        case "moveSpace":
            guard let page = tab(), let id = (request["spaceID"] as? String).flatMap(UUID.init) else {
                answer(["error": "split moveSpace needs id and spaceID"]); return
            }
            browser.move(page, toSpace: id) { reply() }

        case "moveWindow":
            guard let page = tab() else { answer(["error": "split moveWindow needs id"]); return }
            let target = (request["targetWindow"] as? Int).flatMap { n in
                Browsers.all.indices.contains(n - 1) ? Browsers.all[n - 1] : nil
            }
            browser.moveToWindow(page, target)
            reply(["windows": Browsers.all.count])

        case "rows":
            reply(["rows": browser.allRows().mapValues { row in
                ["tabs": row.tabs.count, "splits": row.splits.count, "active": row.active] as [String: Any]
            }])

        case "mouse":
            guard let window = browser.window,
                  let points = request["points"] as? [[Double]], !points.isEmpty,
                  points.allSatisfy({ $0.count == 2 }) else {
                answer(["error": "split mouse needs two or more [x,y] window points"]); return
            }
            // "hold": the button stays down after the last point; "resume":
            // it was already down, so the first point is a drag — a drag in
            // two calls, looked at in between. "clicks": 2 for a double-click.
            let hold = request["hold"] as? Bool == true
            let resume = request["resume"] as? Bool == true
            let clicks = request["clicks"] as? Int ?? 1
            let direct = request["to"] as? String == "view"
            let named: [String: NSEvent.ModifierFlags] = ["command": .command, "shift": .shift, "option": .option, "control": .control]
            let mods = (request["modifiers"] as? [String] ?? []).reduce(into: NSEvent.ModifierFlags()) { $0.formUnion(named[$1] ?? []) }
            for (index, coordinates) in points.enumerated() {
                let type: NSEvent.EventType = index == 0 && !resume ? .leftMouseDown
                    : index == points.count - 1 && !hold ? .leftMouseUp : .leftMouseDragged
                let point = NSPoint(x: coordinates[0], y: Double(window.frame.height) - coordinates[1])
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: index, clickCount: clicks,
                    pressure: type == .leftMouseUp ? 0 : 1
                ) else { continue }
                // Through the app, as a hand's arrive, one turn of the run
                // loop apart: its monitors see them, though a hidden window
                // hands them to no view. "view": straight to the view under
                // the press instead, as `tap` does, for what the view itself
                // does with them.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(index)) {
                    guard direct else { NSApp.sendEvent(event); return }
                    if type == .leftMouseDown {
                        let root = window.contentView?.superview
                        self.pressed = root.flatMap { $0.hitTest($0.convert(point, from: nil)) }
                    }
                    switch type {
                    case .leftMouseDown: self.pressed?.mouseDown(with: event)
                    case .leftMouseDragged: self.pressed?.mouseDragged(with: event)
                    default: self.pressed?.mouseUp(with: event)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 * Double(points.count) + 0.4) { reply() }

        case "escape":
            guard let window = browser.window, let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                isARepeat: false, keyCode: 53
            ) else { answer(["error": "split escape needs a window"]); return }
            let caught = PaneGrip.Grip.escape(event)
            if !caught { NSApp.sendEvent(event) }
            reply(["caught": caught])

        case "open":
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else {
                answer(["error": "split open needs a URL"])
                return
            }
            let source = request["from"] == nil ? browser.active : tab("from")
            let page = browser.open(url, foreground: request["foreground"] as? Bool ?? true,
                                    atEnd: request["atEnd"] as? Bool ?? false, from: source)
            reply(["resultID": Bench.short(page)])

        case "private":
            let quiet = browser.isPrivate ? browser : Browsers.all.last { $0.isPrivate } ?? Browsers.newPrivateWindow()
            if quiet === browser { quiet.newTab() }
            answer(splitState(quiet).merging(["window": (Browsers.all.firstIndex { $0 === quiet } ?? 0) + 1]) { _, new in new })

        case "bench":
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)) else {
                answer(["error": "split bench needs a URL"])
                return
            }
            let page = browser.benchOpen(url)
            house(page)
            reply(["resultID": Bench.short(page)])

        case "start":
            browser.startSplit()
            reply()

        case "pair":
            guard let dragged = tab(), let target = tab("with") else {
                answer(["error": "split pair needs id and with"])
                return
            }
            let side = request["side"] as? String ?? "left"
            guard side == "left" || side == "right" else {
                answer(["error": "split pair side must be left or right"])
                return
            }
            browser.pair(dragged, with: target, onLeft: side == "left")
            reply()

        case "aim":
            guard let dragged = tab() else { answer(["error": "split aim needs id"]); return }
            let side: TabDrag.Side = switch request["side"] as? String {
            case "left": .left
            case "right": .right
            default: .centre
            }
            TabDrag.shared.aim(browser: browser, source: dragged, target: tab("with"), side: side)
            reply()

        case "focus", "select":
            guard let page = tab() else { answer(["error": "split focus needs id"]); return }
            if request["action"] as? String == "select" { browser.select(page) }
            else { browser.focusPane(page) }
            reply()

        case "detach":
            guard let page = tab() else { answer(["error": "split detach needs id"]); return }
            browser.detachSplit(page)
            reply()

        case "fraction":
            guard let pair = request["split"] as? String,
                  let id = UUID(uuidString: pair),
                  let fraction = request["fraction"] as? Double
            else { answer(["error": "split fraction needs split UUID and fraction"]); return }
            browser.setSplitFraction(id, fraction: fraction)
            reply()

        case "close":
            guard let page = tab() else { answer(["error": "split close needs id"]); return }
            browser.close(page)
            reply()

        case "closeTab":
            // Close Tab as a hand asks for it — ⌘W, the row's cross, its
            // menu — where a tab in a group is put away (Browser.closeTab).
            guard let page = tab() else { answer(["error": "split closeTab needs id"]); return }
            browser.closeTab(page)
            reply()

        case "newTab":
            browser.newTab()
            reply()

        case "reopen":
            browser.reopen()
            reply()

        case "insert":
            guard let url = (request["url"] as? String).flatMap(URL.init(string:)),
                  let index = request["index"] as? Int
            else { answer(["error": "split insert needs URL and index"]); return }
            let page = Tab()
            browser.prepare(page)
            browser.insert(page, at: index)
            page.go(to: url)
            reply(["resultID": Bench.short(page)])

        case "move":
            guard let page = tab(), let index = request["to"] as? Int else {
                answer(["error": "split move needs id and to"])
                return
            }
            browser.move(page, to: index)
            reply()

        case "drop":
            guard let page = tab() else { answer(["error": "split drop needs id"]); return }
            browser.dropTabIntoStrip(page, before: tab("before"))
            reply()

        case "space":
            switch request["spaceAction"] as? String {
            case "new": browser.addSpace(named: request["name"] as? String ?? "Split test")
            case "go":
                guard let id = (request["spaceID"] as? String).flatMap(UUID.init) else {
                    answer(["error": "split space go needs a UUID"])
                    return
                }
                browser.switchSpace(to: id)
            default:
                answer(["error": "split space action must be new or go"])
                return
            }
            reply()

        case "sleep":
            guard let page = tab() else { answer(["error": "split sleep needs id"]); return }
            browser.sleep(page) { result in reply(["sleepResult": result]) }

        case "age":
            // As if the tab had been left `seconds` ago (see Closing.swift).
            guard let page = tab() ?? browser.parkedTabs.first(where: { Bench.short($0) == request["id"] as? String }),
                  let seconds = request["seconds"] as? Double else {
                answer(["error": "split age needs id and seconds"])
                return
            }
            page.touch(at: Date().addingTimeInterval(-seconds))
            page.letGo = nil
            reply()

        case "name":
            // Named, or its name taken away with none.
            guard let page = tab() else { answer(["error": "split name needs id"]); return }
            page.name = request["name"] as? String
            reply()

        case "tidy":
            browser.closeLeftAlone()
            // Each close waits for the page to say it holds nothing typed.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reply() }

        case "save":
            browser.writeSession(now: true)
            // And pins.json, which goes by the Disk queue: a test reads it
            // the moment this answers, and a busy machine can leave it behind.
            Disk.drain()
            reply()

        case "closeOthers":
            guard let page = tab() else { answer(["error": "split closeOthers needs id"]); return }
            browser.closeOthers(but: page)
            reply()
        case "keys":
            // The keys handed to a page's view, as the key-view loop would.
            guard let page = tab(), let web = page.built, let window = web.window else {
                answer(["error": "split keys needs the id of a page on screen"]); return
            }
            window.makeFirstResponder(web)
            reply()
        case "motion":
            // The pictures moving on the stage now (see PaneStage.animate).
            func stage(in view: NSView) -> PaneStage? {
                if let stage = view as? PaneStage { return stage }
                for sub in view.subviews { if let found = stage(in: sub) { return found } }
                return nil
            }
            guard let root = browser.window?.contentView?.superview, let found = stage(in: root) else {
                answer(["error": "no split stage in this window"]); return
            }
            reply(["motion": found.motionNow])
        case "pose":
            // A card as a page's question would put up, with no page waiting
            // on it: a page that asks is held by WebKit until it is answered,
            // and a picture of the window would wait on it too.
            guard let page = tab() else { answer(["error": "split pose needs id"]); return }
            browser.paneQuestions.append(PaneQuestion(
                tab: page.id, host: request["host"] as? String ?? "example.com",
                message: request["message"] as? String ?? "", kind: .confirm, reply: { _, _ in }
            ))
            reply()
        case "answer":
            // The first question the page asked, answered as its card would.
            guard let page = tab(), let question = browser.paneQuestions.first(where: { $0.tab == page.id }) else {
                answer(["error": "split answer needs the id of a page with a question"]); return
            }
            browser.answer(question, ok: request["ok"] as? Bool ?? true, text: request["text"] as? String)
            reply()
        case "swap": browser.swapSplit(); reply()
        case "even": browser.evenSplit(); reply()
        case "closeBoth": browser.closeSplit(); reply()
        case "dismiss": browser.dismiss(); reply()
        case "side":
            browser.focusPane(onLeft: request["left"] as? Bool ?? true)
            reply()
        case "openIn":
            guard let page = tab() else { answer(["error": "split openIn needs id"]); return }
            browser.openInSplit(page)
            reply()
        case "pick":
            // ⌘-clicks in the column on exactly these tabs, from no selection.
            guard let ids = request["ids"] as? [String] else { answer(["error": "split pick needs ids"]); return }
            let picked = ids.compactMap { find(["id": $0], in: browser) }
            browser.clearTabSelection()
            for page in picked { browser.extendTabSelection(to: page, modifiers: .command) }
            // The first ⌘-click picks the page in front too, as in the column.
            if let front = browser.active, !picked.contains(where: { $0 === front }),
               browser.selectedTabIDs.contains(front.id) {
                browser.extendTabSelection(to: front, modifiers: .command)
            }
            reply()
        case "pairPicked":
            // The tab menu's Open 2 Tabs in Split View, right-clicked on id.
            browser.pairPickedTabs(focus: tab())
            reply()
        case "closePicked":
            // The tab menu's Close Tabs, right-clicked among the picked.
            browser.closePickedTabs()
            reply()
        case "fill":
            guard let blank = tab(), let page = tab("with") else { answer(["error": "split fill needs id and with"]); return }
            browser.fill(blank, with: page)
            reply()

        default:
            answer(["error": "unknown split action"])
        }
    }

    private func splitState(_ browser: Browser) -> [String: Any] {
        func short(_ id: UUID?) -> Any {
            guard let id, let tab = browser.tabs.first(where: { $0.id == id }) else { return NSNull() }
            return Bench.short(tab)
        }
        return [
            "tabs": browser.tabs.map { tab in
                [
                    "id": Bench.short(tab),
                    "title": tab.title,
                    "url": tab.address?.absoluteString ?? "",
                    "blank": tab.isBlank,
                    // One of Search's own pages (InternalPages.swift), by its address.
                    "internal": tab.page?.url.absoluteString ?? "",
                    "canBack": tab.canGoBack,
                    "canForward": tab.canGoForward,
                    "built": tab.built != nil,
                    "shy": tab.shy,
                    "bench": tab.bench,
                    "asleep": tab.asleep,
                    "awakeReason": browser.awake(because: tab) ?? "",
                    "staysReason": browser.stays(because: tab) ?? "",
                    // How long it counts as left (Closing.swift), and when
                    // you last looked, for ⌃Tab: letting go moves only the first.
                    "idle": Date().timeIntervalSince(tab.leftSince),
                    "looked": Date().timeIntervalSince(tab.touched),
                    // Which web view holds its page, while it has one: the
                    // same after a pin or an unpin, as nothing was loaded again.
                    "web": tab.built.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue), radix: 16) } ?? "",
                    // Whether its page is in a window, and kept there unseen
                    // for a call (StageView.calls); whether it is on one; and
                    // whether the keys would go to it.
                    "inWindow": tab.built?.window != nil,
                    "heldForCall": tab.built.map { web in (web.superview as? StageView)?.holdsCall(web) == true } ?? false,
                    "onCall": tab.built.map { StageView.onCall($0) } ?? false,
                    "hasKeys": tab.built.map { web in
                        (web.window?.firstResponder as? NSView).map { $0 === web || $0.isDescendant(of: web) } ?? false
                    } ?? false,
                ] as [String: Any]
            },
            "splits": browser.splits.map { pair in
                [
                    "id": pair.id.uuidString,
                    "left": short(pair.left),
                    "right": short(pair.right),
                    "fraction": pair.fraction,
                    "tabs": pair.tabs.map { short($0) },
                    "sizes": pair.sizes,
                    "axis": pair.axis.rawValue,
                    "focused": short(pair.focused),
                ] as [String: Any]
            },
            "activeID": short(browser.activeID),
            "displayedIDs": browser.displayedTabs.map { Bench.short($0) },
            "visibleIDs": browser.tabs.filter { browser.visibleTabIDs.contains($0.id) }.map { Bench.short($0) },
            "shownIDs": browser.shownTabs.map { Bench.short($0) },
            "groups": browser.tabGroups.map { ["id": $0.id.uuidString, "collapsed": $0.collapsed] as [String: Any] },
            "groupIDs": browser.tabs.map { $0.groupID?.uuidString ?? "" },
            "enabled": browser.prefs.splitView,
            "finding": browser.finding,
            "linkShown": browser.linkStatus.destination ?? "",
            "linkPreview": browser.linkStatus.preview.map { ["title": $0.title, "reference": $0.reference, "state": $0.state ?? "", "checks": $0.checks?.rawValue ?? "", "review": $0.review ?? "", "author": $0.author ?? "", "updated": $0.updated?.timeIntervalSince1970 ?? 0] as [String: Any] } ?? [:],
            "linkOnRight": browser.linkStatus.onRight,
            "downloadsOpen": browser.downloadsOpen,
            "needle": browser.needle,
            "findStatus": browser.findStatus ?? "",
            "pins": browser.tabs.filter { $0.pin != nil }.map { Bench.short($0) },
            // What ⇧⌘T would bring back, as its menu item says it.
            "reopenTitle": browser.reopenTitle,
            "ghosts": browser.ghosts.count,
            // The pins every space shows (Pins.shared), and which cookie
            // store each pin's tab signs in with.
            "everywhere": browser.tabs.filter { $0.pin != nil && $0.everywhere }.map { Bench.short($0) },
            "pinStores": Dictionary(uniqueKeysWithValues: browser.tabs.filter { $0.pin != nil }
                .map { (Bench.short($0), $0.store.identifier?.uuidString ?? "default") }),
            // What pages of the pair asked, oldest first (see PaneQuestion).
            "questions": browser.paneQuestions.map { question in
                ["tab": short(question.tab), "host": question.host, "message": question.message,
                 "kind": { switch question.kind { case .alert: "alert"; case .confirm: "confirm"; case .prompt: "prompt" } }()]
            },
            "held": browser.heldDialogs.mapValues(\.count).reduce(into: [String: Int]()) { out, entry in
                if let tab = browser.tabs.first(where: { $0.id == entry.key }) { out[Bench.short(tab)] = entry.value }
            },
            "stage": browser.window?.contentView.map { PaneStage.cards(in: $0) } ?? [:],
            "paneFrames": browser.tabs.compactMap { tab -> [String: Any]? in
                guard let web = tab.built, let window = browser.window, web.window === window else { return nil }
                let frame = web.convert(web.bounds, to: nil)
                return ["id": Bench.short(tab), "x": Double(frame.minX),
                        "y": Double(window.frame.height - frame.maxY),
                        "width": Double(frame.width), "height": Double(frame.height)]
            },
            "spaceID": browser.spaceID.uuidString,
            "spaceIDs": browser.spaces.map { $0.id.uuidString },
            // Tabs picked in the column (⌘- or ⇧-click), and what Open 2 Tabs
            // in Split View would pair: off while the menu's item is off.
            "selected": browser.tabs.filter { browser.selectedTabIDs.contains($0.id) }.map { Bench.short($0) },
            "pickedPair": browser.pickedPair.map { [Bench.short($0.left), Bench.short($0.right)] } ?? [],
            "pickedPaired": browser.pickedTabsArePaired,
        ]
    }

    /// Extensions, from the shell. Installing asks as it always does, except
    /// in a test run given `yes` — a real browser can't be made to skip it.
    private func extensionCommand(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let extensions = Extensions.shared
        let skip = Store.testing && (request["yes"] as? Bool ?? false)
        switch verb {
        case "extensions":
            answer(["started": extensions.started, "busy": extensions.busy ?? "", "extensions": extensions.installed.map { item -> [String: Any] in
                let context = extensions.contexts[item.id]
                let action = context.flatMap { $0.action(for: extensions.activeAdapter(for: $0)) }
                return [
                    "id": item.id, "name": item.name, "version": item.version, "enabled": item.enabled,
                    "loaded": context != nil, "private": context?.hasAccessToPrivateData ?? false,
                    "base": context?.baseURL.absoluteString ?? "",
                    "errors": (context.map(Extensions.errors(of:)) ?? []).map { e in
                        let under = Extensions.errors(in: [e.userInfo[NSUnderlyingErrorKey]].compactMap { $0 } as NSArray).first.map { " ← \($0.text) \($0.userInfo)" } ?? ""
                        return e.text + under + (e.userInfo.isEmpty ? "" : " \(e.userInfo.filter { $0.key != NSLocalizedDescriptionKey && $0.key != NSUnderlyingErrorKey })")
                    },
                    "reported": extensions.errors[item.id] ?? [],
                    "action": action?.label ?? "", "badge": action?.badgeText ?? "",
                    "popup": action?.presentsPopup ?? false,
                    "pinned": item.pinned ?? false, "source": item.source ?? "",
                ]
            }])
        case "ext-add":
            guard let text = request["id"] as? String else { answer(["error": "ext-add needs an id or link"]); return }
            extensions.install(from: text, confirm: !skip)
            answer(["started": true])
        case "ext-folder":
            guard let path = request["path"] as? String else { answer(["error": "ext-folder needs a path"]); return }
            extensions.installFolder(at: URL(fileURLWithPath: path), confirm: !skip)
            answer(["started": true])
        case "ext-press":
            guard let id = request["id"] as? String else { answer(["error": "ext-press needs an id"]); return }
            extensions.press(id)
            answer(["pressed": true])
        case "ext-enable":
            guard let id = request["id"] as? String else { answer(["error": "ext-enable needs an id"]); return }
            extensions.setEnabled(id, request["on"] as? Bool ?? true)
            answer(["enabled": request["on"] as? Bool ?? true])
        case "ext-private":
            guard Store.testing else { answer(["error": "only in a test run"]); return }
            guard let id = request["id"] as? String, let context = extensions.contexts[id] else {
                answer(["error": "ext-private needs a loaded extension's id"]); return
            }
            extensions.setPrivate(id, request["on"] as? Bool ?? true)
            answer(["private": context.hasAccessToPrivateData])
        case "capture":
            // Extensions' screen recording: ids given, what is recording, who
            // may, and the last request with its answer.
            answer(ExtensionCapture.shared.state)
        case "capture-stop":
            guard let id = request["id"] as? String else { answer(["error": "capture-stop needs an id"]); return }
            ExtensionCapture.shared.stop(id)
            answer(["stopping": id])
        case "ext-answer":
            // In a test run: answer every extension's question yes or no
            // without asking, or go back to asking.
            guard Store.testing else { answer(["error": "only in a test run"]); return }
            switch request["answer"] as? String {
            case "yes": extensions.answerForTests = true
            case "no": extensions.answerForTests = false
            default: extensions.answerForTests = nil
            }
            answer(["answer": request["answer"] as? String ?? "ask", "asked": extensions.asked])
        case "ext-shot":
            // A picture of the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view, let path = request["path"] as? String
            else { answer(["error": "no popup open for that extension"]); return }
            shoot(web, to: URL(fileURLWithPath: path), width: nil, answer)
        case "ext-menu":
            let items = BenchMenus.describe(ExtensionsMenu.menu(for: extensions))
            if let path = request["path"] as? String,
               let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted]) {
                try? data.write(to: URL(fileURLWithPath: path))
            }
            answer(["items": items])
        case "ext-pin":
            guard let id = request["id"] as? String else { answer(["error": "ext-pin needs an id"]); return }
            extensions.setPinned(id, request["on"] as? Bool ?? true)
            answer(["pinned": request["on"] as? Bool ?? true])
        case "ext-reload":
            guard let id = request["id"] as? String else { answer(["error": "ext-reload needs an id"]); return }
            extensions.reload(id)
            answer(["reloading": true])
        case "ext-remove":
            guard let id = request["id"] as? String else { answer(["error": "ext-remove needs an id"]); return }
            extensions.remove(id)
            answer(["removed": true])
        case "ext-popup":
            // JavaScript in the extension's popup, while it is open.
            guard let id = request["id"] as? String, ExtensionPopup.shared.extensionID == id,
                  let web = ExtensionPopup.shared.view
            else { answer(["error": "no popup open for that extension"]); return }
            web.evaluateJavaScript(request["js"] as? String ?? "document.title") { value, error in
                MainActor.assumeIsolated {
                    if let error { answer(["error": error.localizedDescription]); return }
                    answer(["value": Bench.plain(value)])
                }
            }
        case "ext-page":
            // One of the extension's own pages in a bench tab, where `eval`
            // runs with the extension's APIs.
            guard let id = request["id"] as? String, let context = extensions.contexts[id] else {
                answer(["error": "no such extension loaded"])
                return
            }
            let path = (request["path"] as? String ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let tab = browser.benchOpen(context.baseURL.appendingPathComponent(path))
            house(tab)
            answer(describe(tab))
        default:
            answer(["error": "unknown"])
        }
    }

    /// The tab a request names, among the ones the bench opened itself. The
    /// bench is how this browser is driven while somebody is using it, and
    /// reading, clicking or sleeping in one of their tabs is not part of
    /// that: a script here is meant for tabs marked with the flask. A
    /// SEARCH_PROBE run has nobody's tabs in it, so there any tab answers,
    /// as for `tap` and `select`: a popup a bench page opened with
    /// `window.open` carries no flask and would be out of reach otherwise.
    private func find(_ request: [String: Any], in browser: Browser) -> Tab? {
        guard let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty else { return nil }
        return browser.tabs.first { (Store.testing || $0.bench) && $0.id.uuidString.lowercased().hasPrefix(ref) }
    }

    private func parked(_ request: [String: Any], in browser: Browser) -> Tab? {
        guard Store.testing, let ref = (request["id"] as? String)?.lowercased(), !ref.isEmpty else { return nil }
        return browser.parkedTabs.first { $0.id.uuidString.lowercased().hasPrefix(ref) }
    }

    private func missing(_ request: [String: Any]) -> [String: Any] {
        ["error": "no tab “\(request["id"] as? String ?? "")” — see tabs"]
    }

    private func describe(_ tab: Tab) -> [String: Any] {
        let browser = Browsers.all.first { $0.tabs.contains { $0 === tab } } ?? self.browser
        return [
            "id": Bench.short(tab),
            "url": tab.address?.absoluteString ?? "",
            "page": tab.pageAddress?.absoluteString ?? "",
            "internal": tab.page?.url.absoluteString ?? "",
            "title": tab.title,
            "name": tab.name ?? "",
            // The group it is in, by name, whether or not groups are on.
            "group": browser?.group(of: tab).flatMap { id in browser?.tabGroups.first { $0.id == id }?.name } ?? "",
            "loading": tab.loading,
            "hollow": tab.hollow,
            "view": tab.built?.url?.absoluteString ?? "",
            "bench": tab.bench,
            "active": tab.id == browser?.activeID,
            // Where the page is, as its tab would say it at rest, and whether
            // it says it now: the setting on, the tab you're on, not edited
            // (see AtRest.swift).
            "atRest": AtRest.of(tab.restAddress)?.text ?? "",
            "atRestShown": browser.map { tab.id == $0.activeID && $0.editingTab != tab.id && AtRest.said(tab.restAddress, always: $0.prefs.showsAddress) != nil } ?? false,
            "asleep": tab.asleep,
            "shy": tab.shy,
            "noisy": tab.noisy,
            "muted": tab.muted,
            // Darkened by Search, as the page last said, and what the page
            // was seen to be: dark by itself, light, or not looked at (see
            // Dusk.swift).
            "dusked": tab.dusked,
            "duskNative": tab.duskNative.map { $0 ? "dark" : "light" } ?? "",
            "extensions": { return tab.carriesExtensions }(),
            // The page's WebKit process, for measuring what it holds.
            "process": tab.built.flatMap { $0.value(forKey: "_webProcessIdentifier") as? Int } ?? 0,
            // The icon it wears, as one averaged colour: enough to tell a
            // test's plain squares apart. "" for none.
            "icon": tab.icon.map(Bench.colour) ?? "",
        ]
    }

    private static func colour(_ image: NSImage) -> String {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: 1, height: 1))
        NSGraphicsContext.restoreGraphicsState()
        guard let c = rep.colorAt(x: 0, y: 0) else { return "" }
        return String(format: "%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    static func short(_ tab: Tab) -> String {
        String(tab.id.uuidString.prefix(8)).lowercased()
    }

    /// The address field, wherever it is in the window.
    static func addressField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.delegate is AddressFieldKeys { return field }
        for sub in view.subviews { if let found = addressField(in: sub) { return found } }
        return nil
    }

    /// Milliseconds from `start` to the run loop's next rest — after every
    /// observer that runs before it sleeps, Core Animation's commit included.
    private final class QuietWatch {
        var wake = CACurrentMediaTime()
        var rest = CACurrentMediaTime()
        var timer: Timer?
        var observer: CFRunLoopObserver?
    }

    static func whenQuiet(since start: CFTimeInterval, gap: CFTimeInterval = 0.02, _ then: @escaping @MainActor (Double) -> Void) {
        let watch = QuietWatch()
        func arm() {
            watch.timer?.invalidate()
            let timer = Timer(fire: Date(timeIntervalSinceNow: max(0.001, watch.rest + gap - CACurrentMediaTime())), interval: 0, repeats: false) { _ in
                MainActor.assumeIsolated {
                    guard CACurrentMediaTime() - watch.rest >= gap * 0.98 else { return }
                    if let observer = watch.observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
                    watch.observer = nil
                    watch.timer = nil
                    then((watch.rest - start) * 1000)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            watch.timer = timer
        }
        let activities = CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue
        watch.observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, CFIndex.max) { _, activity in
            MainActor.assumeIsolated {
                let now = CACurrentMediaTime()
                if activity == .afterWaiting {
                    watch.wake = now
                    return
                }
                if now - watch.wake > 0.0005 { watch.rest = now }
                arm()
            }
        }
        if let observer = watch.observer { CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }

    static func whenLoading(_ tab: Tab, since start: CFTimeInterval, _ got: @escaping @MainActor (Double) -> Void) -> AnyCancellable {
        let reads = KitReads(now: true)
        reads.changed = { [weak reads, weak tab] in
            let at = CACurrentMediaTime()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let reads, let tab else { return }
                    if tab.loading { got((at - start) * 1000) } else if reads.track({ tab.loading }) { got((CACurrentMediaTime() - start) * 1000) }
                }
            }
        }
        if reads.track({ tab.loading }) { got((CACurrentMediaTime() - start) * 1000) }
        return AnyCancellable { reads.stop() }
    }

    static func whenResting(since start: CFTimeInterval, _ then: @escaping @MainActor (Double) -> Void) {
        var observer: CFRunLoopObserver?
        observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            let rested = (CACurrentMediaTime() - start) * 1000
            MainActor.assumeIsolated { then(rested) }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
    }

    /// Once the page has stopped loading, or the time is up.
    private func wait(for tab: Tab, until limit: Date, _ answer: @escaping ([String: Any]) -> Void) {
        if !tab.loading, tab.address != nil, tab.failure == nil || true {
            // A beat for the document's own scripts to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self else { return }
                var out = describe(tab)
                if let failure = tab.failure { out["failure"] = failure }
                answer(out)
            }
            return
        }
        guard Date() < limit else {
            var out = describe(tab)
            out["timeout"] = true
            answer(out)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.wait(for: tab, until: limit, answer)
        }
    }

    // MARK: - the room off screen

    private var room: NSWindow?

    // MARK: - nothing on a screen

    /// Set once `pages on` has shown a hidden probe again, so WebKit paints
    /// its pages: from then on the app is no longer hidden, and a window
    /// ordered in would come onto the screen.
    static var pagesShown = false
    static var frontAsked = false
    /// Windows a test run let onto a screen. Every answer names them from
    /// then on, and ./bench fails: a test must never show a window there.
    private(set) static var caught: [String] = []
    private static var watching: [NSObjectProtocol] = []

    static func onScreen(_ window: NSWindow) -> Bool {
        guard window.level.rawValue >= Int(CGWindowLevelForKey(.desktopWindow)) else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(window.frame) }
    }

    /// A window about to be ordered in during a test run with pages shown
    /// (Windows.open, Windows.show): the app hidden again first, so it
    /// waits unseen. Moving it off the screen isn't enough — AppKit pulls a
    /// titled window back onto one as it comes in. `pages on` again puts
    /// every window away before it shows the app.
    static func keepOff(_ window: NSWindow) {
        guard Store.testing, pagesShown else { return }
        NSApp.hide(nil)
        pagesShown = false
    }

    /// Any other window that comes onto a screen in a test run — a sheet, a
    /// panel, one made by a path nobody thought of: taken off at once and
    /// named in every answer.
    static func watchScreens() {
        guard watching.isEmpty else { return }
        // The app itself shown or brought forward by anything but `pages on`
        // (which never activates it): hidden again at once.
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didUnhideNotification] {
            watching.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    if note.name == NSApplication.didUnhideNotification, pagesShown { return }
                    if frontAsked { return }
                    caught.append("the app \(note.name == NSApplication.didUnhideNotification ? "shown" : "brought forward")")
                    NSApp.hide(nil)
                    pagesShown = false
                }
            })
        }
        watching.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow, window.isVisible,
                      window.occlusionState.contains(.visible), onScreen(window) else { return }
                caught.append("\(type(of: window)) “\(window.title)” at \(NSStringFromRect(window.frame))")
                NSApp.hide(nil)
                pagesShown = false
            }
        })
    }
    /// Where `film float` lends the tab's stage, off every screen.
    private var hall: NSWindow?

    func house(_ tab: Tab) {
        guard tab.bench, tab.web.window == nil else { return }
        let window = room ?? makeRoom()
        tab.web.frame = window.contentView?.bounds ?? NSRect(origin: .zero, size: AgentPageRoom.size)
        tab.web.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(tab.web)
    }

    func closeEmptyRoom() {
        guard let room, room.contentView?.subviews.isEmpty != false else { return }
        room.close()
        self.room = nil
    }

    /// The last page `ai read` read, for `ai check`.
    static var aiRead: AIPage.Read?

    private func makeRoom() -> NSWindow {
        let window = AgentPageRoom.make()
        room = window
        return window
    }

    private func shoot(_ tab: Tab, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        shoot(tab.web, to: file, width: width, answer)
    }

    private func shoot(_ web: WKWebView, to file: URL, width: Double?, _ answer: @escaping ([String: Any]) -> Void) {
        let shot = WKSnapshotConfiguration()
        shot.afterScreenUpdates = true
        if let width { shot.snapshotWidth = NSNumber(value: width) }
        web.takeSnapshot(with: shot) { image, error in
            MainActor.assumeIsolated {
                guard let image, let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let png = rep.representation(using: .png, properties: [:])
                else {
                    answer(["error": error?.localizedDescription ?? "no picture"])
                    return
                }
                do {
                    try png.write(to: file)
                    answer(["path": file.path, "width": rep.pixelsWide, "height": rep.pixelsHigh])
                } catch {
                    answer(["error": error.localizedDescription])
                }
            }
        }
    }

    // MARK: - page-side helpers

    /// A JavaScript value the way JSON can carry it.
    private static func plain(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if JSONSerialization.isValidJSONObject(["v": value]) { return value }
        return String(describing: value)
    }

    /// Where an element's middle is, in the page's own points, scrolled
    /// into view first. A selector, or `text=…` for a button or link by its
    /// words.
    private static func locate(_ selector: String) -> String {
        let sel = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var s = \(sel), el = null;
          if (s.indexOf('text=') === 0) {
            var want = s.slice(5).trim().toLowerCase();
            el = Array.prototype.find.call(document.querySelectorAll('button, a, [role=button], input[type=submit]'), function (e) {
              return ((e.innerText || e.value || '').trim().toLowerCase()) === want;
            }) || null;
          } else {
            el = document.querySelector(s);
          }
          if (!el) return null;
          el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var r = el.getBoundingClientRect();
          return [r.left + r.width / 2, r.top + r.height / 2];
        })()
        """
    }

    /// Click, type into, or submit the element a selector names. Typing goes
    /// through the field's own setter and fires the events a keystroke
    /// would, the same as the password filler, so frameworks notice.
    private static func act(_ verb: String, selector: String, text: String) -> String {
        let sel = (try? JSONSerialization.data(withJSONObject: [selector])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        let txt = (try? JSONSerialization.data(withJSONObject: [text])).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return """
        (function () {
          var el = document.querySelector(\(sel));
          if (!el) return 'nothing matches ' + \(sel);
          if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
          var verb = '\(verb)';
          if (verb === 'click') { el.focus && el.focus(); el.click(); return 'ok'; }
          if (verb === 'submit') {
            var form = el.tagName === 'FORM' ? el : el.form || el.closest('form');
            if (!form) return 'no form around ' + \(sel);
            if (form.requestSubmit) form.requestSubmit(); else form.submit();
            return 'ok';
          }
          el.focus && el.focus();
          var value = \(txt);
          if (el.isContentEditable) {
            el.textContent = value;
            el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
            return 'ok';
          }
          var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setter && setter.set) setter.set.call(el, value); else el.value = value;
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok';
        })();
        """
    }
}

/// The pages' frames as they change, for the bench's `layouts`: one entry per
/// change, the first being where they were.
@MainActor
private final class LayoutRecord {
    weak var browser: Browser?
    private(set) var seen: [[String: Any]] = []
    private var last: [String: [Int]]?
    private let began = CACurrentMediaTime()
    private var timer: Timer?
    private var observer: CFRunLoopObserver?

    init(browser: Browser) { self.browser = browser }

    func look() {
        guard let browser, let window = browser.window else { return }
        var now: [String: [Int]] = [:]
        for tab in browser.tabs {
            guard let web = tab.built, web.window === window, !web.isHiddenOrHasHiddenAncestor else { continue }
            let r = web.convert(web.bounds, to: nil)
            now[Bench.short(tab)] = [Int(r.minX.rounded()), Int((window.frame.height - r.maxY).rounded()),
                                     Int(r.width.rounded()), Int(r.height.rounded())]
        }
        guard now != last else { return }
        last = now
        seen.append(["ms": Int((CACurrentMediaTime() - began) * 1000), "pages": now])
    }

    func start() {
        let timer = Timer(timeInterval: 0.004, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        // After everything else in the turn, Core Animation's commit included.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.look() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop() {
        look()
        timer?.invalidate()
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
    }
}

/// Each pass of the main run loop, from waking to going back to sleep, in
/// milliseconds: the ones that carried a pointer move ("hoversweep") apart
/// from the rest (timers, animation, anything else).
private final class LoopClock: @unchecked Sendable {
    private(set) var marked: [Double] = []
    private(set) var unmarked: [Double] = []
    private var woke: CFAbsoluteTime = 0
    private var carrying = false
    private var observers: [CFRunLoopObserver] = []

    func mark() { carrying = true }

    func start() {
        // First to hear the loop wake, last to hear it sleep: after Core
        // Animation's commit, which is where SwiftUI's update lands.
        let wake = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [unowned self] _, _ in
            woke = CFAbsoluteTimeGetCurrent()
        }
        let sleep = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [unowned self] _, _ in
            guard woke > 0 else { return }
            let ms = (CFAbsoluteTimeGetCurrent() - woke) * 1000
            if carrying { marked.append(ms) } else { unmarked.append(ms) }
            carrying = false
            woke = 0
        }
        for observer in [wake, sleep].compactMap({ $0 }) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            observers.append(observer)
        }
    }

    func stop() {
        for observer in observers { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observers = []
    }

    static func summary(_ values: [Double]) -> [String: Double] {
        guard !values.isEmpty else { return ["count": 0] }
        let sorted = values.sorted()
        func at(_ q: Double) -> Double { sorted[min(sorted.count - 1, Int(q * Double(sorted.count)))] }
        return ["count": Double(sorted.count), "p50": at(0.5), "p95": at(0.95), "max": sorted.last!,
                "total": sorted.reduce(0, +)]
    }
}


/// Apple's helper, stood in for in a test run (bench `appleoffer`): it starts,
/// counts that it did, and never answers, so a pairing begun from the offer
/// waits for a code that never comes. Apple's own is never run from a test.
final class StandInLink: AppleLink {
    var onMessage: (([String: Any]) -> Void)?
    var onEnd: (() -> Void)?
    private(set) var starts = 0
    func start() throws { starts += 1 }
    func send(_ message: [String: Any]) throws {}
    func stop() {}
}
