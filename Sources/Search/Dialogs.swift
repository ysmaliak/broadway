import AppKit
import WebKit

// The questions a page is allowed to ask, and the answers it gets.
//
// WebKit does nothing with alert(), confirm(), prompt(), a file input or a
// password-protected site unless somebody answers for them — and "nothing"
// means confirm() is always false, so "leave without saving?" leaves, and a
// file picker that never opens. Each one here is the system's own sheet on the
// window the page is in, which is what every other browser on this Mac shows.

/// A question held for a tab in the background. WebKit wants every one of
/// them answered; one let go without being shown answers as dismissed.
@MainActor
final class HeldQuestion {
    private let show: () -> Void
    private var drop: (() -> Void)?

    init(show: @escaping () -> Void, drop: @escaping () -> Void) {
        self.show = show
        self.drop = drop
    }

    func present() {
        drop = nil
        show()
    }

    func dismiss() {
        let drop = drop
        self.drop = nil
        drop?()
    }

    deinit { drop?() }
}

/// A question from a page of the pair on screen, drawn over that page alone
/// (see PaneQuestionCard), so the other page goes on working. Answered
/// exactly once, whatever happens to it: WebKit wants every one answered,
/// and answering twice would crash the page. Let go unanswered — the page
/// closed, gone elsewhere, Split View turned off — it answers as dismissed.
@MainActor
final class PaneQuestion: Identifiable {
    enum Kind: Equatable { case alert, confirm, prompt(String) }

    let id = UUID()
    let tab: Tab.ID
    /// The site asking: the frame's own origin, never the page's address,
    /// so a frame from another site is named as itself.
    let host: String
    let message: String
    let kind: Kind
    let asked = Date()
    let offersSilence: Bool
    private(set) weak var page: WKWebView?
    private var reply: ((Bool, String?) -> Void)?

    init(tab: Tab.ID, host: String, message: String, kind: Kind, page: WKWebView? = nil, offersSilence: Bool = false,
         reply: @escaping (Bool, String?) -> Void) {
        self.tab = tab
        self.host = host
        self.message = message
        self.kind = kind
        self.page = page
        self.offersSilence = offersSilence
        self.reply = reply
    }

    var open: Bool { reply != nil }

    func answered(ok: Bool, text: String? = nil, silence: Bool = false) {
        if open, let page { DialogRuns.answered(page, silence: offersSilence && silence) }
        answer(ok: ok, text: text)
    }

    func answer(ok: Bool, text: String? = nil) {
        let reply = reply
        self.reply = nil
        reply?(ok, text)
    }

    deinit { reply?(false, nil) }
}

extension Browser {
    // MARK: - asked over one page of a pair

    /// The tab asking, when it is a page of the pair on screen: its question
    /// goes over it, not over the window.
    private func paneAsking(_ webView: WKWebView) -> Tab? {
        guard let pair = activeSplit,
              let tab = tabs.first(where: { $0.built === webView }), pair.contains(tab.id) else { return nil }
        return tab
    }

    private func askInPane(_ tab: Tab, _ webView: WKWebView, frame: WKFrameInfo, message: String, kind: PaneQuestion.Kind,
                           reply: @escaping (Bool, String?) -> Void) {
        let host = frame.securityOrigin.host
        paneQuestions.append(PaneQuestion(tab: tab.id, host: host, message: message, kind: kind, page: webView,
                                          offersSilence: DialogRuns.offersSilence(webView), reply: reply))
    }

    /// The card's buttons, and the bench.
    func answer(_ question: PaneQuestion, ok: Bool, text: String? = nil, silence: Bool = false) {
        question.answered(ok: ok, text: text, silence: silence)
        paneQuestions.removeAll { $0.id == question.id }
    }

    /// A page closed, gone to another address, or out of Split View: what it
    /// asked is answered as dismissed.
    func dropQuestions(for tab: Tab.ID? = nil) {
        for page in tabs + parkedTabs where tab == nil || page.id == tab {
            page.agentDialog?.answer(ok: false)
            page.agentDialog = nil
        }
        if tab == nil || fileChoice?.tabID == tab { fileChoice?.cancel() }
        let dropping = paneQuestions.filter { tab == nil || $0.tab == tab }
        guard !dropping.isEmpty else { return }
        paneQuestions.removeAll { question in dropping.contains { $0.id == question.id } }
        for question in dropping { question.answer(ok: false) }
    }

    // MARK: - alert, confirm, prompt

    /// A page's question goes over its own page only. One from a tab in the
    /// background — or in another space — waits until you go to that tab, as
    /// in Safari and Chrome: over the tab in front, a prompt() asking for a
    /// password would pass for that page's. A tab closed first gets the
    /// answer a dismissed dialog gives.
    @discardableResult
    func ask(from webView: WKWebView, show: @escaping () -> Void, drop: @escaping () -> Void) -> HeldQuestion? {
        let known = tabs + parkedTabs
        // Questions from tabs that have gone some other way than close(_:).
        for id in heldDialogs.keys where !known.contains(where: { $0.id == id }) {
            heldDialogs.removeValue(forKey: id)?.forEach { $0.dismiss() }
        }
        guard let tab = known.first(where: { $0.built === webView }), tab.id != activeID else {
            show()
            return nil
        }
        let question = HeldQuestion(show: show, drop: drop)
        heldDialogs[tab.id, default: []].append(question)
        return question
    }

    private func askAgent(_ webView: WKWebView, frame: WKFrameInfo, message: String, kind: PaneQuestion.Kind,
                          reply: @escaping (Bool, String?) -> Void) -> Bool {
        guard let tab = anyTab(for: webView), tab.agent, tab.agentTask != nil, !tab.shy, !tab.driving, tab.agentFinished == nil else { return false }
        tab.agentDialog?.answer(ok: false)
        tab.agentDialog = PaneQuestion(tab: tab.id, host: frame.securityOrigin.host, message: message, kind: kind, page: webView,
                                       offersSilence: DialogRuns.offersSilence(webView), reply: reply)
        return true
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        if DialogRuns.silenced(webView) { return completionHandler() }
        if askAgent(webView, frame: frame, message: message, kind: .alert, reply: { _, _ in completionHandler() }) { return }
        if let tab = paneAsking(webView) {
            return askInPane(tab, webView, frame: frame, message: message, kind: .alert) { _, _ in completionHandler() }
        }
        ask(from: webView, show: {
            let alert = Dialogs.alert(from: frame, saying: message)
            alert.addButton(withTitle: "OK")
            Dialogs.showFromPage(alert, over: webView) { _ in completionHandler() }
        }, drop: completionHandler)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        if DialogRuns.silenced(webView) { return completionHandler(false) }
        if askAgent(webView, frame: frame, message: message, kind: .confirm, reply: { ok, _ in completionHandler(ok) }) { return }
        if let tab = paneAsking(webView) {
            return askInPane(tab, webView, frame: frame, message: message, kind: .confirm) { ok, _ in completionHandler(ok) }
        }
        ask(from: webView, show: {
            let alert = Dialogs.alert(from: frame, saying: message)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            Dialogs.showFromPage(alert, over: webView) { answer in
                completionHandler(answer == .alertFirstButtonReturn)
            }
        }, drop: { completionHandler(false) })
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        if DialogRuns.silenced(webView) { return completionHandler(nil) }
        if askAgent(webView, frame: frame, message: prompt, kind: .prompt(""), reply: { ok, text in completionHandler(ok ? (text ?? "") : nil) }) { return }
        if let tab = paneAsking(webView) {
            return askInPane(tab, webView, frame: frame, message: prompt, kind: .prompt(defaultText ?? "")) { ok, text in
                completionHandler(ok ? (text ?? "") : nil)
            }
        }
        ask(from: webView, show: {
            let alert = Dialogs.alert(from: frame, saying: prompt)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            Dialogs.showFromPage(alert, over: webView) { answer in
                completionHandler(answer == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }, drop: { completionHandler(nil) })
    }

    // MARK: - choosing a file

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        if let given = AgentUploadArm.take(webView, frame: frame, multiple: parameters.allowsMultipleSelection) {
            return completionHandler(given.isEmpty ? nil : given)
        }
        if anyTab(for: webView)?.agentTask != nil { AgentFilePicker.note(webView) }
        let reply = FileChoiceReply(completionHandler)
        if Store.testing && !FileChoice.probing {
            Dialogs.askedInTest.append("Choose a file (\(frame.securityOrigin.host))")
            return reply.finish(nil)
        }
        ask(from: webView, show: { [weak self, weak webView] in
            guard let self, let webView else { return reply.finish(nil) }
            let page = self.anyTab(for: webView) ?? (self.peekTab?.built === webView ? self.peekTab : nil)
            guard let tab = page, self.activeID == tab.id || self.peekTab === tab else { return reply.finish(nil) }
            self.fileChoice?.cancel()
            let choice = FileChoice(browser: self, tab: tab, webView: webView, host: frame.securityOrigin.host,
                                    rules: FileChoiceRules(accept: "", multiple: parameters.allowsMultipleSelection,
                                                           directories: parameters.allowsDirectories), reply: reply)
            self.fileChoice = choice
            webView.evaluateJavaScript("window.__broadwayFileInput?.() ?? null", in: frame, in: Web.world) { [weak self, weak choice] result in
                guard let self, let choice, self.fileChoice === choice, !reply.finished else { return }
                var rect: NSRect?
                if case .success(let value) = result, let input = value as? [String: Any] {
                    choice.setAccept(input["accept"] as? String ?? "")
                    if frame.isMainFrame, let x = input["x"] as? Double, let y = input["y"] as? Double,
                       let width = input["width"] as? Double, let height = input["height"] as? Double,
                       width > 0, height > 0 {
                        rect = NSRect(x: x, y: webView.isFlipped ? y : webView.bounds.height - y - height, width: width, height: height)
                    }
                    choice.show(at: rect)
                } else {
                    choice.showInFinder()
                }
            }
        }, drop: { reply.finish(nil) })
    }

    // MARK: - a site that asks who you are, or can't prove who it is

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            trust(webView, challenge, completionHandler)
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodNTLM:
            signIn(webView, challenge, completionHandler)
        case NSURLAuthenticationMethodClientCertificate:
            ClientCertificateAsk.handle(self, webView, challenge, completionHandler)
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }

    private func trust(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard let trust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var problem: CFError?
        let trusted = SecTrustEvaluateWithError(trust, &problem)
        let host = space.host.lowercased()
        let pageTab = tab(for: webView).flatMap { ($0.address?.host() ?? $0.pending?.host())?.lowercased() == host ? $0 : nil }
        let page = pageTab != nil
        let otherName = OtherName.countsTrust(problem.map { CFErrorGetCode($0) }) && pageTab?.retry.otherNameDue(for: host) == true
        CertificateTrust.answer(
            store: webView.configuration.websiteDataStore,
            host: host,
            port: space.port,
            chain: trusted ? [] : CertificateTrust.chain(of: trust),
            trusted: trusted,
            isPage: page,
            otherNameDue: otherName,
            ask: { [weak self] reply in
                guard let self else {
                    reply(false)
                    return
                }
                self.ask(from: webView, show: {
                    let alert = NSAlert()
                    alert.messageText = "This connection isn't private"
                    alert.informativeText = "Broadway couldn't confirm \u{201C}\(host)\u{201D} is who it says it is, so someone could see what you send. Only continue if you know why."
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "Go Back")
                    alert.addButton(withTitle: "Continue Anyway")
                    Dialogs.show(alert, over: webView) { answer in
                        reply(answer == .alertSecondButtonReturn || (Store.testing && Dialogs.continuesInTest))
                    }
                }, drop: { reply(false) })
            },
            done: { outcome in
                switch outcome {
                case .system: completionHandler(.performDefaultHandling, nil)
                case .pass: completionHandler(.useCredential, URLCredential(trust: trust))
                case .refuse: completionHandler(.cancelAuthenticationChallenge, nil)
                }
            }
        )
    }

    /// A site behind a name and a password — a staging server, a router. One
    /// wrong answer gets another go; the second is taken as "not for me".
    private func signIn(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.previousFailureCount < 2 else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        let asking = tab(for: webView).flatMap { $0.agent ? $0.id : nil }
        if let asking { AgentSignInBox.hosts[asking] = challenge.protectionSpace.host }
        let answered = completionHandler
        let completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, credential in
            if let asking { AgentSignInBox.hosts[asking] = nil }
            answered(disposition, credential)
        }
        // A tab behind yours asking for a name and a password would put the
        // question over the page you are looking at, where it would pass for
        // that page's. It waits for its own tab, as a page's questions do.
        ask(from: webView, show: { [weak self] in
            self?.askSignIn(webView, challenge, completionHandler)
        }, drop: { completionHandler(.cancelAuthenticationChallenge, nil) })
    }

    private func askSignIn(
        _ webView: WKWebView,
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let alert = NSAlert()
        alert.messageText = "\(space.host) asks you to sign in"
        alert.informativeText = space.realm.map { "“\($0)”" } ?? "The site wants a name and a password"
        if challenge.previousFailureCount > 0 {
            alert.informativeText += "\nThat wasn't accepted, so try again"
        }
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let name = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        name.placeholderString = "Name"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        pass.placeholderString = "Password"
        name.nextKeyView = pass
        box.addSubview(name)
        box.addSubview(pass)
        alert.accessoryView = box
        alert.window.initialFirstResponder = name

        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(
                .useCredential,
                URLCredential(user: name.stringValue, password: pass.stringValue, persistence: .forSession)
            )
        }
    }

    // MARK: - a page whose process went away

    /// WebKit runs each page in a process of its own, and the system kills
    /// those under memory pressure — background tabs first. Left alone, the
    /// tab shows white until somebody thinks to reload. Saying so, with the
    /// one thing worth offering, is what the failure view is for.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        cancelDisplay(for: webView)
        guard let tab = tab(for: webView) else {
            _ = anyTab(for: webView)?.endedOnPurpose(webView)
            return
        }
        dropQuestions(for: tab.id)
        if tab.endedOnPurpose(webView) { return }
        // In front of you: straight back, a reload beats a white page with a
        // button on it. Behind another tab: the moment you come back to it.
        if visibleTabIDs.contains(tab.id), !tab.isBlank {
            tab.recoverFromCrash()
        } else {
            tab.stale = true
        }
    }
}

struct DialogRun {
    static let span: TimeInterval = 10

    private(set) var answered: Date?
    private(set) var silenced = false

    func offersSilence(at now: Date) -> Bool {
        guard let answered else { return false }
        return now.timeIntervalSince(answered) < Self.span
    }

    mutating func answer(at now: Date, silence: Bool) {
        answered = now
        if silence { silenced = true }
    }
}

@MainActor
enum DialogRuns {
    private final class Held {
        var run = DialogRun()
    }

    private static let runs = NSMapTable<WKWebView, Held>.weakToStrongObjects()

    static func silenced(_ page: WKWebView) -> Bool {
        runs.object(forKey: page)?.run.silenced == true
    }

    static func offersSilence(_ page: WKWebView, at now: Date = Date()) -> Bool {
        runs.object(forKey: page)?.run.offersSilence(at: now) == true
    }

    static func answered(_ page: WKWebView, silence: Bool, at now: Date = Date()) {
        let held = runs.object(forKey: page) ?? Held()
        held.run.answer(at: now, silence: silence)
        runs.setObject(held, forKey: page)
    }

    static func reset(_ page: WKWebView) {
        runs.removeObject(forKey: page)
    }
}

@MainActor
final class DialogSilence: Equatable {
    private(set) weak var page: WKWebView?
    var ticked = false

    init(_ page: WKWebView?) {
        self.page = page
    }

    nonisolated static func == (one: DialogSilence, other: DialogSilence) -> Bool { one === other }

    func taken() {
        guard ticked, let page else { return }
        DialogRuns.answered(page, silence: true)
    }
}

final class DialogSilenceBox: KitHoverView {
    static let side: CGFloat = 14
    static let gap: CGFloat = 7

    var isOn = false {
        didSet {
            guard isOn != oldValue else { return }
            paint()
            setAccessibilityValue(isOn ? "on" : "off")
        }
    }
    var changed: ((Bool) -> Void)?

    private let square = KitBox(fill: nil, corners: .radius(4))
    private let mark = KitSymbol("checkmark", style: KitSymbol.Style(size: 9, weight: .bold), tint: .white)
    private let words: KitLabel

    init(isOn: Bool, font: NSFont, color: NSColor) {
        self.isOn = isOn
        words = KitLabel(Dialogs.silenceWords, font: font, color: color)
        super.init(frame: .zero)
        wantsLayer = true
        words.setAccessibilityElement(false)
        mark.setAccessibilityElement(false)
        addSubview(square)
        square.addSubview(mark)
        addSubview(words)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(Dialogs.silenceWords)
        setAccessibilityValue(isOn ? "on" : "off")
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        let text = words.measure(width: .greatestFiniteMagnitude)
        return NSSize(width: Self.side + Self.gap + ceil(text.width), height: max(Self.side, ceil(text.height)))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        flip()
    }

    override func accessibilityPerformPress() -> Bool {
        flip()
        return true
    }

    func flip() {
        isOn.toggle()
        changed?(isOn)
    }

    override func hoverChanged() { paint() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    private func paint() {
        let dark = kitDark
        let (fill, knob) = KitSwitch.colors(on: true, dark: dark, lit: hovering)
        square.fill = isOn ? fill : KitWash.track.color(dark: dark, plus: hovering ? 0.03 : 0)
        square.stroke = isOn ? nil : KitColor.hairline
        mark.tint = knob
        mark.isHidden = !isOn
    }

    override func layout() {
        super.layout()
        let box = NSRect(x: 0, y: (bounds.height - Self.side) / 2, width: Self.side, height: Self.side)
        square.frame = kitSnap(box)
        mark.centre(in: square.bounds)
        let text = words.measure(width: .greatestFiniteMagnitude)
        let x = Self.side + Self.gap
        words.frame = kitSnap(NSRect(x: x, y: (bounds.height - ceil(text.height)) / 2, width: max(0, bounds.width - x), height: ceil(text.height)))
    }
}

enum Dialogs {
    static let silenceWords = "Don't let this page show more dialogs"

    static func alert(from frame: WKFrameInfo, saying message: String) -> NSAlert {
        let alert = NSAlert()
        // The site's name as the title, so a page can't dress its message up
        // as one from the system or from the browser.
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says" : host
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    /// The window the page is in, or the browser's window for a tab that
    /// isn't on stage right now.
    static func window(for webView: WKWebView) -> NSWindow? {
        webView.window ?? NSApp.mainWindow ?? NSApp.windows.first { $0.contentView != nil && $0.isVisible }
    }

    @MainActor
    static func showFromPage(_ alert: NSAlert, over webView: WKWebView,
                             then finish: @escaping (NSApplication.ModalResponse) -> Void) {
        if DialogRuns.silenced(webView) { return finish(.cancel) }
        if DialogRuns.offersSilence(webView) {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = Dialogs.silenceWords
        }
        show(alert, over: webView) { [weak webView] answer in
            if let webView {
                DialogRuns.answered(webView, silence: alert.showsSuppressionButton && alert.suppressionButton?.state == .on)
            }
            finish(answer)
        }
    }

    /// A test run's questions, in the order they would have been shown.
    static var askedInTest: [String] = []

    static var continuesInTest = false

    static var shownInTest = false

    static func show(
        _ alert: NSAlert,
        over webView: WKWebView,
        then finish: @escaping (NSApplication.ModalResponse) -> Void
    ) {
        // A test run never shows one — a sheet, or a window of its own for a
        // page without one, would be on the screen of whoever is working
        // beside it. What it would have asked is written down (bench probe),
        // and it is answered as if cancelled.
        if Store.testing, !shownInTest {
            askedInTest.append(alert.messageText)
            finish(.cancel)
            return
        }
        if let window = window(for: webView) {
            alert.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(alert.runModal())
        }
    }
}
