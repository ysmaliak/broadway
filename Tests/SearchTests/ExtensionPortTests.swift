import Foundation
import JavaScriptCore
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct ExtensionPortTests {
    @Test func contentMessagesStayPlainAndOwnPageMessagesStayNumbered() throws {
        let script = ExtensionShims.script
        let start = try #require(script.range(of: "if (runtime && typeof runtime.connect === \"function\" && runtime.onConnect) {"))
        let end = try #require(script.range(of: "// Members of namespaces WebKit has.", range: start.upperBound..<script.endIndex))
        let ports = String(script[start.lowerBound..<end.lowerBound])
        for content in [true, false] {
            let js = try #require(JSContext())
            js.evaluateScript(#"""
            const inContent = \#(content), own = "webkit-extension://test/";
            const put = (target, key, value) => { target[key] = value; };
            const untabbed = (sender) => sender;
            const makeEvent = () => {
              const listeners = new Set();
              return { addListener: f => listeners.add(f), removeListener: f => listeners.delete(f),
                       hasListener: f => listeners.has(f), fire: m => [...listeners].forEach(f => f(m)) };
            };
            let sent;
            const runtime = { id: "test", getURL: () => own,
                              connect: () => ({ postMessage: m => { sent = m; }, onMessage: makeEvent() }),
                              onConnect: makeEvent() };
            \#(ports)
            runtime.connect().postMessage({ question: "hello" });
            """#)
            #expect(js.exception?.toString() == nil)
            #expect(js.evaluateScript("sent.question === 'hello'")?.toBool() == content)
            #expect(js.evaluateScript("Array.isArray(sent.__searchPort)")?.toBool() == (!content))
            js.evaluateScript(#"""
            let received = [];
            runtime.onConnect.addListener(p => p.onMessage.addListener(m => received.push(m)));
            const incoming = { sender: { url: inContent ? "https://example.com/" : "webkit-extension://test" },
                               postMessage: () => {}, onMessage: makeEvent() };
            runtime.onConnect.fire(incoming);
            incoming.onMessage.fire(sent);
            incoming.onMessage.fire(sent);
            """#)
            #expect(js.exception?.toString() == nil)
            #expect(js.evaluateScript("received[0].question")?.toString() == "hello")
            #expect(js.evaluateScript("received.length")?.toInt32() == (content ? 2 : 1))
            js.evaluateScript("runtime.connect('another-extension').postMessage({ external: true });")
            #expect(js.evaluateScript("sent.external")?.toBool() == true)
        }
    }
}
