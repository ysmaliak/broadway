import AppKit

// Links from elsewhere. A click in Mail, in Slack, in a PDF — macOS hands the
// address to whichever app owns http, and this is how that app takes it.
//
// The bundle says it owns http and https (build.sh writes that into the
// plist); this is the other half. Addresses can arrive before the window has
// been built, so they wait here until the browser says it is ready for them.

final class Links: NSObject, NSApplicationDelegate {
    /// Where an address goes once there is somewhere for it to go.
    private static var deliver: ((IncomingLink) -> Void)?
    /// Addresses that arrived first.
    private static var waiting: [IncomingLink] = []
    /// The window in front's, or the first one's, once there is one.
    @MainActor static var window: NSWindow? { Browsers.front?.window ?? Browsers.primary?.window }
    /// Whether the window has been asked for on a link's behalf (summon).
    private static var summoned = false
    /// A first quit waits for an import worker to remove its temporary files.
    /// AppKit calls us again when that cleanup has finished.
    private var terminationPending = false

    @MainActor private static var askingToQuit = false

    @MainActor static func shouldQuit() -> Bool {
        guard !askingToQuit else { return false }
        guard Store.settings.bool(forKey: Preferences.confirmQuitKey) else { return true }
        askingToQuit = true
        defer { askingToQuit = false }
        let alert = NSAlert()
        alert.messageText = "Quit Broadway?"
        alert.informativeText = "Your windows and tabs will close"
        alert.addButton(withTitle: "Quit").keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        // Making Cancel the Return default replaces its Escape equivalent.
        let escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window, event.keyCode == 53 else { return event }
            cancel.performClick(nil)
            return nil
        }
        defer { if let escape { NSEvent.removeMonitor(escape) } }
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quitting closes every window on the way out; that isn't a window
    /// closed for good, whose tabs would go (see Browsers.closing).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { AgentTally.shared.close() }
        if MainActor.assumeIsolated({ LeaveQuit.shouldWait() }) { return .terminateCancel }
        let waiting = MainActor.assumeIsolated {
            Browsers.quitting = true
            return Browser.cancelAllFileImports()
        }
        guard waiting else {
            terminationPending = false
            return .terminateNow
        }
        if !terminationPending {
            terminationPending = true
            Task { @MainActor in
                // Five seconds at most: an import stuck on a slow disk
                // doesn't keep Search from quitting.
                let until = Date().addingTimeInterval(5)
                while Browser.hasActiveFileImports, Date() < until {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                self.terminationPending = false
                sender.terminate(nil)
            }
        }
        // Returning from AppKit's first terminate call lets MainActor finish
        // the worker continuation and remove it from Browser's registry.
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Every window, and windows.json (see Windows.swift).
        Browsers.flush()
        MainActor.assumeIsolated { SignInKeeper.shared.flush() }
        // And the bookmarks or downloads list saved a moment ago, still on
        // their way to the disk.
        Disk.drain()
    }

    /// The nearest thing to a crash reporter a browser with no server can
    /// have: nothing is sent anywhere, but a beta with no record of what
    /// went wrong is a beta nobody can fix. One line, appended, so it
    /// survives the crash that is about to end the process.
    static func watchForTrouble() {
        NSSetUncaughtExceptionHandler { exception in
            let reason = (exception.reason ?? "?").replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9+.-]*://[^\s"'<>]+"#, with: "<address>", options: .regularExpression)
            Links.noteTrouble("\(exception.name.rawValue): \(reason)\n" + exception.callStackSymbols.joined(separator: "\n"))
        }
    }

    nonisolated static func noteTrouble(_ text: String) {
        let line = "\(Date()) — \(text)\n\n"
        let file = Store.file("crash.log")
        if let handle = FileHandle(forWritingAtPath: file.path) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            handle.closeFile()
        } else {
            try? FileManager.default.createDirectory(at: Store.folder, withIntermediateDirectories: true)
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Addresses come in as Apple Events, one each. Taking them straight
    /// from the event manager keeps them out of SwiftUI's hands: left to it,
    /// every address handed at launch had the window presented afresh, and
    /// five of them meant five rebuilds of the content before the window
    /// had shown once.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Links.watchForTrouble()
        LayoutWatch.start()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handle(getURL:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
        if Store.testing, let text = ProcessInfo.processInfo.environment["SEARCH_LINK"], let url = URL(string: text) {
            Links.take(IncomingLink(url: url, source: .unknownApp))
        }
    }

    /// A launch macOS doesn't call a plain one — started hidden, as `open -j`
    /// or anything asking for a hidden launch does — SwiftUI treats like the
    /// launch a link makes below: it leaves its window to whatever the launch
    /// came for, and nothing comes. The app ran with no window at all. The
    /// window is asked for here instead; started hidden, it stays hidden
    /// with the app until the app is shown.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // What an import left in the temporary folder when Search stopped
        // in the middle of it — a Safari export's passwords in the clear
        // among it — goes (Security).
        DispatchQueue.global(qos: .utility).async { ImportFile.sweepScratch() }
        TemporarySweep.atLaunch()
        Trim.start()
        MemoryPages.start()
        MenuIcons.start()
        AgentSetup.shared.launched(agentsOn: Shared.prefs.agentsOn)
        AppIconShown.apply(Shared.prefs.appIcon)
        MainActor.assumeIsolated { HookClock.start() }
        if !Store.unitTests { MainActor.assumeIsolated { Freezes.start() } }
        let plain = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        guard !plain else { return }
        DispatchQueue.main.async {
            guard !NSApp.windows.contains(where: { $0.contentView != nil && !($0 is NSPanel) }) else { return }
            Links.summon()
        }
    }

    @objc private func handle(getURL event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        // A test run takes nothing from outside it: an address from another
        // app would bring a window forward. The bench hands links in itself.
        guard !Store.testing || Links.hearsOthers else { return }
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text), url.scheme?.lowercased().hasPrefix("http") == true
        else { return }
        let source = Links.sender(of: event)
        let chooses = NSEvent.modifierFlags.contains(.option)
        Links.heard(source, event: event)
        Links.take(IncomingLink(url: url, source: source, chooses: chooses))
    }

    static var hearsOthers: Bool { ProcessInfo.processInfo.environment["SEARCH_HEAR_LINKS"] == "1" }

    static func sender(of event: NSAppleEventDescriptor) -> IncomingLink.Source {
        guard let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0,
              let app = NSRunningApplication(processIdentifier: pid) else { return .unknownApp }
        return source(bundleID: app.bundleIdentifier, name: app.localizedName)
    }

    static func source(bundleID: String?, name: String?) -> IncomingLink.Source {
        guard let bundleID, !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier,
              !Links.middlemen.contains(bundleID.lowercased()) else { return .unknownApp }
        return .app(bundleID: bundleID, name: name ?? bundleID)
    }

    static let middlemen: Set<String> = ["com.apple.launchservicesd", "com.apple.coreservices.uiagent", "com.apple.loginwindow"]

    private static func heard(_ source: IncomingLink.Source, event: NSAppleEventDescriptor) {
        if case .app(let bundle, let name) = source {
            MainActor.assumeIsolated { LinkRules.shared.saw(LinkSender(bundleID: bundle, name: name)) }
        }
        guard Store.testing, hearsOthers else { return }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        let app = NSRunningApplication(processIdentifier: pid)
        let line = "\(pid)\t\(app?.bundleIdentifier ?? "-")\t\(app?.localizedName ?? "-")\t\(source)\n"
        let file = Store.file("link-senders.log")
        if let handle = FileHandle(forWritingAtPath: file.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? line.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    /// Files and anything else the system opens with the app: an address, or
    /// a page on this Mac — an .html or .xhtml double-clicked in the Finder
    /// once Search is the Mac's browser (it says it can open them, see
    /// build.sh), which this used to drop without a word.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard !Store.testing || Links.hearsOthers else { return }
        let chooses = NSEvent.modifierFlags.contains(.option)
        for url in urls where url.isFileURL || url.scheme?.lowercased().hasPrefix("http") == true {
            Links.take(IncomingLink(url: url, source: .unknownApp, chooses: chooses))
        }
    }

    /// The Dock icon clicked with the window closed: bring the window back
    /// rather than doing nothing, which is what a hidden-title-bar SwiftUI
    /// window does by default.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // A test run started hidden stays so: another launch of the same app
        // (`open -n` of a second probe) can reach it as a reopen, and nothing
        // is brought back, made or brought forward for it.
        guard !Store.testing else { return false }
        if !flag { Browsers.ensureWindow() }
        return true
    }

    /// Closing the last window leaves the app running, as Safari and Chrome
    /// do (#327): the Dock icon, ⌘N or a link brings a window back, with its
    /// tabs. Its session is written as it closes (see Browsers.closing).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { SceneWindow.untitled() }
        return true
    }

    /// New Window in the Dock icon's menu, as every browser has it.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Window", action: #selector(newWindow), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        let quiet = NSMenuItem(title: "New Private Window", action: #selector(newPrivateWindow), keyEquivalent: "")
        quiet.target = self
        menu.addItem(quiet)
        return menu
    }

    @objc private func newWindow() {
        MainActor.assumeIsolated { Browsers.newWindow() }
    }

    @objc private func newPrivateWindow() {
        MainActor.assumeIsolated { Browsers.newPrivateWindow() }
    }

    /// The browser, once it has a window. Anything that came earlier is
    /// handed over now — but none of it before the window is on screen.
    ///
    /// Five addresses at launch used to mean five web views built before the
    /// first frame, and a window that took a second to appear instead of a
    /// third of one. Now the window comes first; the first page goes into
    /// the blank tab that is already there, and the others fill in behind
    /// it, a few frames apart, in the order they came.
    @MainActor
    static func hand(to browser: Browser) {
        // Only the first window's arrival starts the delivery; the others
        // find it running.
        guard deliver == nil else { return }
        deliver = { link in
            // The window in front's browser, or a window brought back for it:
            // the link lands where you are, not in the first window.
            let landing = Browsers.place(link, from: Browsers.ensureWindow())
            guard landing.forward else { return }
            let browser = landing.browser
            // Put away in the Dock, it stayed there: bringing a window to the
            // front doesn't take it out (#95).
            if let window = browser.window, window.isMiniaturized { window.deminiaturize(nil) }
            if !Store.testing { browser.window?.makeKeyAndOrderFront(nil) }
            comeForward()
        }
        let early = waiting
        waiting = []
        guard let first = early.first else { return }
        onceShown { [weak browser] in
            if let browser { Browsers.place(first, from: browser) }
            comeForward()
            for (n, link) in early.dropFirst().enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(n + 1)) { [weak browser] in
                    guard let browser else { return }
                    Browsers.placeBehind(link, from: browser)
                }
            }
        }
    }

    /// Runs once a window is actually showing, and one turn of the run loop
    /// after that, so the frame is on the screen before the work starts.
    /// Gives up waiting after a second or so and runs anyway — a launch
    /// started hidden has a window nobody can see yet.
    @MainActor
    static func onceShown(_ then: @escaping () -> Void, tries: Int = 0) {
        let shown = NSApp.windows.contains { $0.isVisible && $0.contentView != nil }
        if shown || tries > 40 {
            DispatchQueue.main.async(execute: then)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { onceShown(then, tries: tries + 1) }
        }
    }

    /// In front of the app the link was clicked in, the way a browser comes
    /// forward for Mail. Since macOS 14 an app is let in front when the app
    /// it is asked by hands the front over, and asks with `activate()`.
    /// Not every app hands it over: a link clicked in Notion, and in other
    /// apps built on Electron, left Search behind them. So if Search still
    /// isn't in front a moment later, it asks again the way it did before
    /// macOS 14.
    @MainActor
    private static func comeForward() {
        // Never a test run's: a probe started hidden stays off every screen.
        guard !Store.testing else { return }
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            guard !NSApp.isActive else { return }
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// A link as another app hands one over, for the bench.
    static func arrived(_ url: URL, from source: IncomingLink.Source = .unknownApp, chooses: Bool = false) {
        take(IncomingLink(url: url, source: source, chooses: chooses))
    }

    private static func take(_ link: IncomingLink) {
        if let deliver {
            MainActor.assumeIsolated { HookLinks.consider(link, deliver: deliver) }
        } else {
            waiting.append(link)
            DispatchQueue.main.async { summon() }
        }
    }

    /// A link that launches the app arrives as an Apple Event, taken above,
    /// and SwiftUI — seeing a launch that came to open something rather than
    /// a plain one — leaves its window for that event to open. It never sees
    /// the event, so nothing opened it: every link clicked in another app
    /// while Search was closed launched it with no window and the page
    /// nowhere. SwiftUI's delegate is asked instead for what a plain launch
    /// gets, its window; a single window, so asking twice can't make two.
    @MainActor
    private static func summon() {
        guard deliver == nil, window == nil, !summoned else { return }
        summoned = true
        _ = NSApp.delegate?.applicationOpenUntitledFile?(NSApp)
    }

    // MARK: - being the browser

    private static let probe = URL(string: "https://example.com")!

    /// True when this app is where links from other apps go.
    static var isDefault: Bool {
        guard let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to send http and https here. The system puts up its own
    /// confirmation; the answer arrives through `done`, on the main thread.
    static func becomeDefault(_ done: @escaping (Bool) -> Void) {
        let app = Bundle.main.bundleURL
        let group = DispatchGroup()
        var worked = true
        for scheme in ["http", "https"] {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                if error != nil { worked = false }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(worked) }
    }
}
