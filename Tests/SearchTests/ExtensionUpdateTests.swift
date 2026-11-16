import AppKit
import Foundation
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionUpdateTests {
    @Test func updatePermissionDefersWithoutWindowAndReturnCancelsRetry() async throws {
        _ = NSApplication.shared
        let extensions = Extensions.shared
        #expect(extensions.answerForTests == nil)
        #expect(!NSApp.windows.contains { $0.isVisible && $0.canBecomeMain })
        let deferred = await extensions.ask(install: "Synthetic update", wants: ["Read history"], icon: nil, updating: true)
        #expect(!deferred)

        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 600, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        defer { window.close() }
        let retry = Task { await extensions.ask(install: "Synthetic update", wants: ["Read history"], icon: nil, updating: true) }
        for _ in 0..<100 {
            if window.attachedSheet != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try #require(window.attachedSheet)
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        let controls = buttons(in: try #require(sheet.contentView))
        let cancel = try #require(controls.first { $0.title == "Cancel" })
        let confirm = try #require(controls.first { $0.title == "Add Extension" })
        #expect(sheet.defaultButtonCell === cancel.cell, "Return must cancel the update")
        #expect(confirm.keyEquivalent == "")
        cancel.performClick(nil)
        let accepted = await retry.value
        #expect(!accepted)
    }

    @Test func recentStartupStillSchedulesLaterChecks() throws {
        _ = NSApplication.shared
        let extensions = Extensions.shared
        #expect(extensions.installed.isEmpty, "This test must never update real extensions")
        guard extensions.installed.isEmpty else { return }
        let key = "extensions.checked"
        let previous = Store.settings.object(forKey: key)
        defer {
            if let previous { Store.settings.set(previous, forKey: key) }
            else { Store.settings.removeObject(forKey: key) }
        }
        let recent = Date()
        Store.settings.set(recent, forKey: key)
        extensions.checkForUpdates()
        let timer = try #require(extensions.updateClock)
        #expect(timer.isValid)
        #expect(timer.timeInterval == 3600)
        #expect((Store.settings.object(forKey: key) as? Date) == recent)
        extensions.checkForUpdates()
        #expect(extensions.updateClock === timer)

        // Fire the real timer after a simulated day asleep, without waiting a day.
        Store.settings.set(Date().addingTimeInterval(-86400), forKey: key)
        timer.fire()
        let checked = try #require(Store.settings.object(forKey: key) as? Date)
        #expect(abs(checked.timeIntervalSinceNow) < 2)
        timer.fire()
        #expect((Store.settings.object(forKey: key) as? Date) == checked)
        #expect(timer.isValid)
    }

    @Test func pendingUpdateIsNotStartedTwiceAndFailureAllowsRetry() async {
        _ = NSApplication.shared
        let extensions = Extensions.shared
        let item = Installed(id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", name: "Synthetic update",
                             version: "1", enabled: false, fromStore: true, permissions: [])
        let started = Expectation(description: "First update requested")
        let response = UpdateResponse()
        URLProtocol.registerClass(UpdateProtocol.self)
        UpdateProtocol.response = response
        defer {
            URLProtocol.unregisterClass(UpdateProtocol.self)
            UpdateProtocol.response = nil
        }
        response.started = started
        let first = Task { await extensions.update(item) }
        await fulfillment(of: [started], timeout: 5)
        await extensions.update(item)
        #expect(response.count == 1, "A pending request must not be duplicated")
        response.fail()
        await first.value

        let retried = Expectation(description: "Failed update can be retried")
        response.started = retried
        let retry = Task { await extensions.update(item) }
        await fulfillment(of: [retried], timeout: 5)
        #expect(response.count == 2)
        await retry.value
    }
}

private final class UpdateResponse {
    private let lock = NSLock()
    private var requests: [URLProtocol] = []
    private var nextStart: Expectation?
    var started: Expectation? {
        get { lock.withLock { nextStart } }
        set { lock.withLock { nextStart = newValue } }
    }
    var count: Int { lock.withLock { requests.count } }
    func receive(_ request: URLProtocol) {
        let (count, signal) = lock.withLock {
            requests.append(request)
            let signal = nextStart
            nextStart = nil
            return (requests.count, signal)
        }
        if count > 1 {
            request.client?.urlProtocol(request, didFailWithError: URLError(.notConnectedToInternet))
        }
        signal?.fulfill()
    }
    func fail() {
        let request = lock.withLock { requests.first }
        if let request { request.client?.urlProtocol(request, didFailWithError: URLError(.notConnectedToInternet)) }
    }
}

private final class UpdateProtocol: URLProtocol {
    static var response: UpdateResponse?
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "clients2.google.com"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.response?.receive(self) }
    override func stopLoading() {}
}
