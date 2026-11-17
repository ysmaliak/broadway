import AppKit
import WebKit

enum LeaveWords {
    static let title = "Leave this page?"
    static let text = "Changes you made may not be saved"
    static let stay = "Stay"
    static let leave = "Leave"
}

@MainActor
enum LeaveHold {
    private(set) static var held = false

    static func hold(_ on: Bool) {
        guard Store.testing else { return }
        held = on
        guard !on else { return }
        for browser in Browsers.all + MemoryPages.browsers {
            for tab in browser.tabs + browser.parkedTabs where tab.leaveQuestion != nil {
                browser.answerLeave(tab, leave: true)
            }
        }
    }
}

@MainActor
final class LeaveQuestion: Identifiable {
    let id = UUID()
    let asked = Date()
    private var reply: ((Bool) -> Void)?

    init(reply: @escaping (Bool) -> Void) {
        self.reply = reply
    }

    var open: Bool { reply != nil }

    func answer(leave: Bool) {
        let reply = reply
        self.reply = nil
        reply?(leave)
    }

    deinit { reply?(true) }
}

@MainActor
final class LeaveClosing {
    weak var view: WKWebView?
    let since = Date()
    var asked = false
    private var done: ((Bool) -> Void)?

    init(view: WKWebView, done: @escaping (Bool) -> Void) {
        self.view = view
        self.done = done
    }

    var open: Bool { done != nil }

    func finish(_ leave: Bool) {
        let done = done
        self.done = nil
        done?(leave)
    }
}

@MainActor
enum LeaveQuit {
    private static var passed = false
    private static var asking = false

    static func settle() {
        passed = true
    }

    static func shouldWait() -> Bool {
        if passed { return false }
        if asking { return true }
        let pages = Browsers.all.flatMap { browser in browser.leaveOrder().map { (browser, $0) } }
        guard pages.contains(where: { $0.0.leaveAnswer(.quit, for: $0.1) == .ask }) else {
            passed = true
            return false
        }
        asking = true
        Browser.askToLeave(pages, why: .quit) { leave in
            asking = false
            guard leave else { return }
            passed = true
            NSApp.terminate(nil)
        }
        return true
    }
}

@MainActor
final class LeaveWindows: NSObject, NSWindowDelegate {
    static let shared = LeaveWindows()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !Browsers.quitting, let browser = Browsers.browser(for: sender) else { return true }
        return browser.mayLeave(browser.leaveOrder(), why: .closeWindow) { [weak sender] in
            sender?.performClose(nil)
        }
    }
}

extension Browser {
    @objc(_webView:runBeforeUnloadConfirmPanelWithMessage:initiatedByFrame:completionHandler:)
    func webViewAsksBeforeLeaving(_ webView: WKWebView, message: String, frame: WKFrameInfo,
                                  completionHandler: @escaping (Bool) -> Void) {
        guard let tab = anyTab(for: webView), tab.built === webView else { return completionHandler(true) }
        let closing = tab.leaveClosing.flatMap { $0.view === webView && $0.open ? $0 : nil }
        let why: LeaveWhy = closing != nil ? .closeTab : .navigate
        guard leaveAnswer(why, for: tab) == .ask else { return completionHandler(true) }
        guard closing != nil || showsNow(tab) else { return completionHandler(true) }
        if tab.leaveQuestion?.open == true { return completionHandler(false) }
        closing?.asked = true
        StuckRules.committed(&tab.stuck)
        tab.leaveStayedAt = nil
        tab.leaveQuestion = LeaveQuestion(reply: completionHandler)
        bringForward(tab)
    }

    func leavePage(_ tab: Tab) -> LeavePage {
        LeavePage(hasPage: tab.built != nil && tab.page == nil && !tab.asleep,
                  agent: tab.agent,
                  stuck: tab.isStuck,
                  settled: tab.leaveSettled)
    }

    func leaveAnswer(_ why: LeaveWhy, for tab: Tab) -> LeaveAnswer {
        LeaveRules.answer(why, page: leavePage(tab), testing: Store.testing, held: LeaveHold.held)
    }

    func leaveOrder() -> [Tab] {
        let all = tabs + parkedTabs
        let front = all.filter { visibleTabIDs.contains($0.id) }
        return front + all.filter { !visibleTabIDs.contains($0.id) }
    }

    func closeAsking(_ tab: Tab) {
        guard mayLeave([tab], why: .closeTab, again: { [weak self] in self?.close(tab) }) else { return }
        close(tab)
    }

    func closeTabGroupAsking(_ id: UUID) {
        guard mayLeave(folderTabs(id), again: { [weak self] in self?.closeTabGroup(id) }) else { return }
        closeTabGroup(id)
    }

    func mayLeave(_ going: [Tab], why: LeaveWhy = .closeTab, again: @escaping () -> Void) -> Bool {
        let asking = going.filter { !$0.leaveGranted && leaveAnswer(why, for: $0) == .ask }
        guard !asking.isEmpty else {
            for tab in going { tab.leaveGranted = false }
            return true
        }
        if let open = asking.first(where: { $0.leaveQuestion != nil || $0.leaveClosing?.open == true }) {
            if open.leaveQuestion != nil { bringForward(open) }
            return false
        }
        Browser.askToLeave(asking.map { (self, $0) }, why: why) { leave in
            guard leave else { return }
            for tab in going { tab.leaveGranted = true }
            again()
            for tab in going { tab.leaveGranted = false }
        }
        return false
    }

    static func askToLeave(_ pages: [(Browser, Tab)], why: LeaveWhy, then done: @escaping (Bool) -> Void) {
        var run = LeaveRun(count: pages.count)
        func step(_ next: LeaveStep) {
            switch next {
            case .go: done(true)
            case .keep: done(false)
            case .ask(let at):
                let (browser, tab) = pages[at]
                browser.askOne(tab, why: why) { leave in step(run.answered(leave: leave)) }
            }
        }
        step(run.first)
    }

    private func askOne(_ tab: Tab, why: LeaveWhy, then done: @escaping (Bool) -> Void) {
        guard leaveAnswer(why, for: tab) == .ask, let web = tab.built else { return done(true) }
        tab.leaveClosing?.finish(false)
        let closing = LeaveClosing(view: web, done: done)
        tab.leaveClosing = closing
        tab.leaveStayedAt = nil
        tab.leaveTried = web
        guard !tryClose(web) else { return finishClosing(tab, closing, leave: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + LeaveRules.patience) { [weak self, weak tab, weak closing] in
            guard let self, let tab, let closing, tab.leaveClosing === closing, closing.open else { return }
            guard LeaveRules.timedOut(since: closing.since, asked: closing.asked, at: Date()) else { return }
            tab.endPageProcess()
            self.finishClosing(tab, closing, leave: true)
        }
    }

    private func tryClose(_ web: WKWebView) -> Bool {
        let selector = NSSelectorFromString("_tryClose")
        guard web.responds(to: selector) else { return true }
        typealias Call = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(web.method(for: selector), to: Call.self)(web, selector)
    }

    private func finishClosing(_ tab: Tab, _ closing: LeaveClosing, leave: Bool) {
        if tab.leaveClosing === closing { tab.leaveClosing = nil }
        closing.finish(leave)
    }

    func answerLeave(_ tab: Tab, leave: Bool) {
        guard let question = tab.leaveQuestion else { return }
        tab.leaveQuestion = nil
        if !leave { tab.leaveStayedAt = Date() }
        question.answer(leave: leave)
        if let closing = tab.leaveClosing { finishClosing(tab, closing, leave: leave) }
        if !leave, let web = tab.built, web.window != nil { web.window?.makeFirstResponder(web) }
    }

    func leaveHeardClose(_ webView: WKWebView) -> Bool {
        guard let tab = anyTab(for: webView), tab.built === webView else { return false }
        if tab.leaveQuestion != nil { return true }
        guard let closing = tab.leaveClosing, closing.view === webView, closing.open else {
            guard tab.leaveTried === webView else { return false }
            guard let stayed = tab.leaveStayedAt else { return true }
            return LeaveRules.swallows(stayedAt: stayed, at: Date())
        }
        if closing.asked { return true }
        webView.evaluateJavaScript("0") { [weak self, weak tab, weak closing] _, _ in
            MainActor.assumeIsolated {
                guard let self, let tab, let closing, tab.leaveClosing === closing, closing.open, !closing.asked else { return }
                self.finishClosing(tab, closing, leave: true)
            }
        }
        return true
    }

    func leaveHeardStuck(_ tab: Tab) -> Bool {
        if tab.leaveQuestion != nil { return true }
        guard let closing = tab.leaveClosing, closing.open else { return false }
        tab.endPageProcess()
        finishClosing(tab, closing, leave: true)
        return true
    }

    func dropLeave(_ tab: Tab) {
        if let question = tab.leaveQuestion {
            tab.leaveQuestion = nil
            question.answer(leave: true)
        }
        if let closing = tab.leaveClosing { finishClosing(tab, closing, leave: true) }
    }

    private func bringForward(_ tab: Tab) {
        if tabs.contains(where: { $0 === tab }) {
            if !showsNow(tab) { select(tab) }
        } else if let space = parked.first(where: { $0.value.tabs.contains { $0 === tab } })?.key {
            switchSpace(to: space)
            if !showsNow(tab) { select(tab) }
        }
        guard !Store.testing || Store.shownOnScreen, let window else { return }
        if !window.isVisible || !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
    }
}
