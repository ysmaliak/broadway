import Foundation
import JavaScriptCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PopupGestureTests {
    @Test func longLivedMenuPreservesFrameAndOneWindowLimit() {
        var permission = PopupGesture()
        permission.record(origin: "iframe", kind: "menu", now: 10)
        #expect(permission.take(origin: "iframe", now: 20) == false)
        permission.menuClosed(now: 20)
        #expect(permission.take(origin: "sibling", now: 20.1) == false)
        #expect(permission.take(origin: "iframe", now: 20.2) == true)
        permission.menuClosed(now: 21)
        #expect(permission.take(origin: "iframe", now: 21.1) == false)
    }

    @Test func menuCannotCreateOrRearmAGesture() {
        var permission = PopupGesture()
        permission.menuClosed(now: 10)
        #expect(permission.take(origin: "same", now: 10.1) == false)
        permission.record(origin: "same", kind: "input", now: 10)
        permission.menuClosed(now: 20)
        #expect(permission.take(origin: "same", now: 20.1) == false)
        permission.record(origin: "same", kind: "input", now: 11)
        #expect(permission.take(origin: "same", now: 11.1) == true)
        permission.record(origin: "same", kind: "menu", now: 11.2)
        permission.menuClosed(now: 20)
        #expect(permission.take(origin: "same", now: 20.1) == false)
        permission.record(origin: "same", kind: "menu", now: 21)
        permission.clear()
        permission.menuClosed(now: 22)
        #expect(permission.take(origin: "same", now: 22.1) == false)
    }

    @Test func asyncRequestCanOpenOnceWithinActivationWindow() {
        var permission = PopupGesture()
        #expect(permission.take(origin: "https://example.com:443", now: 10) == false)
        permission.record(origin: "https://example.com:443", kind: "input", now: 10)
        #expect(permission.take(origin: "https://example.com:443", now: 12) == true)
        #expect(permission.take(origin: "https://example.com:443", now: 12.1) == false)
    }

    @Test func oneClickOneTabWhicheverOpensFirst() {
        // The page's window.open first (Gmail's handler), then ⌘-click's own tab.
        var permission = PopupGesture()
        let made = UUID()
        permission.record(origin: "same", kind: "input", now: 10)
        permission.record(origin: "same", kind: "click", now: 10.05)
        #expect(permission.take(origin: "same", now: 10.1) == true)
        permission.opened(made)
        #expect(permission.claim(now: 10.2) == made)

        // ⌘-click's own tab first: the page's window.open after it is refused.
        permission.record(origin: "same", kind: "input", now: 20)
        #expect(permission.claim(now: 20.1) == nil)
        #expect(permission.take(origin: "same", now: 20.2) == false)

        // A window from an earlier click is not this click's.
        permission.record(origin: "same", kind: "input", now: 30)
        #expect(permission.take(origin: "same", now: 30.1) == true)
        permission.opened(made)
        permission.record(origin: "same", kind: "input", now: 31)
        #expect(permission.claim(now: 31.1) == nil)
        #expect(permission.take(origin: "same", now: 31.2) == false)

        // Nor one from before the page changed (clear keeps the count going).
        permission.record(origin: "same", kind: "input", now: 40)
        #expect(permission.take(origin: "same", now: 40.1) == true)
        permission.opened(made)
        permission.clear()
        permission.record(origin: "same", kind: "input", now: 41)
        #expect(permission.claim(now: 41.1) == nil)

        // No recent interaction: Search's own tab opens, nothing is spent.
        var idle = PopupGesture()
        #expect(idle.claim(now: 50) == nil)
        idle.record(origin: "same", kind: "input", now: 50)
        #expect(idle.claim(now: 56) == nil)
    }

    @Test func clickDoesNotRearmConsumedMousedown() {
        var permission = PopupGesture()
        permission.record(origin: "same", kind: "input", now: 10)
        #expect(permission.take(origin: "same", now: 10.01) == true)
        permission.record(origin: "same", kind: "click", now: 10.1)
        #expect(permission.take(origin: "same", now: 10.2) == false)
        permission.record(origin: "same", kind: "input", now: 10.3)
        #expect(permission.take(origin: "same", now: 10.4) == true)
    }

    @Test func unrelatedFrameExpiredGestureAndNewDocumentCannotOpen() {
        var permission = PopupGesture()
        permission.record(origin: "first", kind: "input", now: 10)
        #expect(permission.take(origin: "third-party", now: 11) == false)
        #expect(permission.take(origin: "first", now: 15.01) == false)
        permission.record(origin: "first", kind: "input", now: 20)
        permission.clear()
        #expect(permission.take(origin: "first", now: 20.1) == false)
    }

    @Test func assistiveClickCanOpenWithoutMousedown() {
        var permission = PopupGesture()
        permission.record(origin: "same", kind: "click", now: 10)
        #expect(permission.take(origin: "same", now: 10.1) == true)
        permission.record(origin: "same", kind: "click", now: 10.2)
        #expect(permission.take(origin: "same", now: 10.3) == true)
    }

    @Test func iframeInteractionAlsoActivatesItsTopLevelPage() {
        var permission = PopupGesture()
        permission.record(origin: "iframe", kind: "input", now: 10)
        #expect(permission.take(origin: "sibling", now: 10.1) == false)
        #expect(permission.take(origin: "parent", mainFrame: true, now: 10.2) == true)
        #expect(permission.take(origin: "iframe", now: 10.3) == false)
    }

    @Test func opaqueOriginsCannotAuthorizeEachOther() {
        var permission = PopupGesture()
        permission.record(origin: nil, kind: "input", now: 10)
        #expect(permission.take(origin: nil, now: 11) == false, "another opaque frame has no matching origin")
        #expect(permission.take(origin: "https://ads.example:443", now: 11) == false)
        #expect(permission.take(origin: "https://parent.example:443", mainFrame: true, now: 12) == true)
        #expect(permission.take(origin: nil, mainFrame: true, now: 12.1) == false)
    }

    @Test func opaqueMainFrameCanUseItsOwnGestureOnce() {
        var permission = PopupGesture()
        permission.record(origin: nil, kind: "click", now: 10)
        #expect(permission.take(origin: nil, mainFrame: true, now: 12) == true)
        #expect(permission.take(origin: nil, mainFrame: true, now: 12.1) == false)
    }

    @Test func emptyOriginComponentsNeverMakeASharedKey() {
        #expect(PopupGesture.originKey(scheme: "", host: "", port: 0) == nil)
        #expect(PopupGesture.originKey(scheme: "data", host: "", port: 0) == nil)
        #expect(PopupGesture.originKey(scheme: "file", host: "", port: 0) == nil)
        #expect(PopupGesture.originKey(scheme: "https", host: "example.com", port: 443) == "https://example.com:443")
        #expect(PopupGesture.originKey(scheme: "http", host: "example.com", port: 80) != PopupGesture.originKey(scheme: "http", host: "example.com", port: 8080))
    }

    @Test func delayedClickDoesNotRearmConsumedMousedown() {
        for delay in [1.01, 2, 4.99, 5] {
            var permission = PopupGesture()
            permission.record(origin: "same", kind: "input", now: 10)
            #expect(permission.take(origin: "same", now: 10.01) == true)
            permission.record(origin: "same", kind: "click", now: 10 + delay)
            #expect(permission.take(origin: "same", now: 10 + delay) == false)
        }
    }

    @Test func delayedClickDoesNotExtendUnusedMousedown() {
        var permission = PopupGesture()
        permission.record(origin: "same", kind: "input", now: 10)
        permission.record(origin: "same", kind: "click", now: 14.9)
        #expect(permission.take(origin: "same", now: 15.01) == false)
        permission.record(origin: "same", kind: "click", now: 15.1)
        #expect(permission.take(origin: "same", now: 15.2) == true, "a later assistive click is still supported")
    }

    @Test func repeatedAdRequestsCannotStealOrRearmPageGesture() {
        var permission = PopupGesture()
        permission.record(origin: "page", kind: "input", now: 10)
        for offset in 1...20 {
            #expect(permission.take(origin: "ad", now: 10 + Double(offset) / 10) == false)
        }
        #expect(permission.take(origin: "page", mainFrame: true, now: 12) == true)
        #expect(permission.take(origin: "page", mainFrame: true, now: 12.1) == false)
    }

    @Test func navigationRevokesGestureBeforeUnloadAndMenuClose() {
        var permission = PopupGesture()
        permission.record(origin: "same", kind: "menu", now: 10)
        permission.clear() // The main-frame policy clears before answering .allow.
        #expect(permission.take(origin: "same", mainFrame: true, now: 10.1) == false)
        permission.menuClosed(now: 20)
        #expect(permission.take(origin: "same", mainFrame: true, now: 20.1) == false)
    }

    @Test func relayIgnoresRepeatedKeysAndSyntheticEvents() throws {
        let context = try #require(JSContext())
        context.evaluateScript("""
        var sent = [], listeners = {};
        var window = { webkit: { messageHandlers: { officePopupGesture: {
          postMessage: function (message) { sent.push(message.kind); }
        } } } };
        function addEventListener(type, callback) { listeners[type] = callback; }
        function key(name, repeat, trusted) {
          listeners.keydown({ type: 'keydown', key: name, repeat: repeat, isTrusted: trusted });
        }
        """)
        context.evaluateScript(PopupGestureRelay.script)
        context.evaluateScript("""
        key('Enter', false, true); key('Enter', true, true); key('Enter', true, true);
        listeners.click({ type: 'click', isTrusted: true, detail: 0 });
        """)
        #expect(context.evaluateScript("JSON.stringify(sent)")?.toString() == "[\"input\"]")
        context.evaluateScript("""
        key('Escape', false, true); key('Shift', false, true); key('Enter', false, false);
        listeners.click({ type: 'click', isTrusted: false });
        listeners.mousedown({ type: 'mousedown', isTrusted: false });
        listeners.contextmenu({ type: 'contextmenu', isTrusted: false });
        """)
        #expect(context.evaluateScript("sent.length")?.toInt32() == 1)
        context.evaluateScript("""
        listeners.keyup({ type: 'keyup', key: 'Enter', isTrusted: true });
        listeners.click({ type: 'click', isTrusted: true, detail: 0 });
        """)
        #expect(context.evaluateScript("JSON.stringify(sent)")?.toString() == "[\"input\",\"click\"]")
        #expect(context.exception == nil)
    }

}
