import JavaScriptCore
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
struct ExtensionWorkerPortTests {
    @Test @MainActor func realShimEntryCoversContentScriptsAndExtensionPages() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExtensionWorkerRecovery/shim-harness.js")
        let harness = try String(contentsOf: fixture, encoding: .utf8)
        for content in [true, false] {
            let js = try #require(JSContext())
            js.evaluateScript("const console = { log() {}, error() {} };\n" + harness)
            js.evaluateScript("const fixture = recoveryFixture(\(content)); Object.assign(globalThis, fixture.root); window = globalThis; top = globalThis;")
            // Execute the whole shim: slicing after the content-script return
            // would falsely claim that the content path is covered (#506).
            js.evaluateScript(ExtensionShims.script.replacingOccurrences(of: "__SEARCH_WORKER_GENERATION__", with: "0"))
            #expect(js.exception?.toString() == nil)
            js.evaluateScript("const port = chrome.runtime.connect(); let count = 0; port.onDisconnect.addListener(() => count++); port.postMessage({ question: 'hello' });")
            drain(js)
            #expect(js.evaluateScript("fixture.subscriptions.length")?.toInt32() == 1)
            #expect(js.evaluateScript("count")?.toInt32() == 0)
            js.evaluateScript("fixture.subscriptions[0].resolve(1);")
            drain(js)
            #expect(js.evaluateScript("count")?.toInt32() == 1, "content: \(content)")
            js.evaluateScript("port.nativeDisconnect.fire(port);")
            #expect(js.evaluateScript("count")?.toInt32() == 1)
            #expect(js.evaluateScript("fixture.nativePorts.length")?.toInt32() == 1, "No automatic reconnect")
            #expect(js.evaluateScript("port.posts.length")?.toInt32() == 1, "No replay")
            #expect(js.exception?.toString() == nil)
        }
    }

    @Test @MainActor func contentScriptsGetChromeReasonAndPlatformEnums() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExtensionWorkerRecovery/shim-harness.js")
        let harness = try String(contentsOf: fixture, encoding: .utf8)
        let js = try #require(JSContext())
        js.evaluateScript("const console = { log() {}, error() {} };\n" + harness)
        js.evaluateScript("const fixture = recoveryFixture(true); Object.assign(globalThis, fixture.root); window = globalThis; top = globalThis;")
        js.evaluateScript(ExtensionShims.script.replacingOccurrences(of: "__SEARCH_WORKER_GENERATION__", with: "0"))
        #expect(js.exception?.toString() == nil)
        // A content script's own code runs after the early return, so read the
        // constants then, not merely once the whole shim has finished.
        js.evaluateScript("globalThis.reasonAtStartup = chrome.runtime.OnInstalledReason.INSTALL;")
        #expect(js.evaluateScript("reasonAtStartup")?.toString() == "install")
        #expect(js.evaluateScript("chrome.runtime.OnInstalledReason.INSTALL")?.toString() == "install")
        #expect(js.evaluateScript("chrome.runtime.OnRestartRequiredReason.OS_UPDATE")?.toString() == "os_update")
        #expect(js.evaluateScript("chrome.runtime.PlatformArch.ARM64")?.toString() == "arm64")
        #expect(js.evaluateScript("chrome.runtime.PlatformOs.MAC")?.toString() == "mac")
        #expect(js.evaluateScript("chrome.runtime.RequestUpdateCheckStatus.NO_UPDATE")?.toString() == "no_update")
    }

    @Test @MainActor func cookieChangesWithoutACookieAreNotGivenToListeners() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExtensionWorkerRecovery/shim-harness.js")
        let harness = try String(contentsOf: fixture, encoding: .utf8)
        let js = try #require(JSContext())
        js.evaluateScript("const console = { log() {}, error() {} };\n" + harness)
        js.evaluateScript("""
        const fixture = recoveryFixture(false);
        Object.assign(globalThis, fixture.root);
        window = globalThis; top = globalThis;
        const listeners = [];
        chrome.cookies = { onChanged: { addListener: (f) => listeners.push(f), removeListener: (f) => { const i = listeners.indexOf(f); if (i >= 0) listeners.splice(i, 1); },
                                   hasListener: (f) => listeners.includes(f), fire: (...args) => listeners.forEach((f) => f(...args)) } };
        """)
        js.evaluateScript(ExtensionShims.script.replacingOccurrences(of: "__SEARCH_WORKER_GENERATION__", with: "0"))
        #expect(js.exception?.toString() == nil)
        js.evaluateScript("""
        globalThis.seen = [];
        const listener = (change) => seen.push(change.cookie.name);
        chrome.cookies.onChanged.addListener(listener);
        chrome.cookies.onChanged.addListener(listener);
        chrome.cookies.onChanged.fire(undefined);
        chrome.cookies.onChanged.fire({});
        chrome.cookies.onChanged.fire({ cookie: { name: "session" }, cause: "explicit" });
        """)
        #expect(js.exception?.toString() == nil)
        #expect(js.evaluateScript("seen.length")?.toInt32() == 1)
        #expect(js.evaluateScript("seen[0]")?.toString() == "session")
        #expect(js.evaluateScript("chrome.cookies.onChanged.hasListener(listener)")?.toBool() == true)
        js.evaluateScript("chrome.cookies.onChanged.removeListener(listener)")
        #expect(!(js.evaluateScript("chrome.cookies.onChanged.hasListener(listener)")?.toBool() ?? true))
        js.evaluateScript("chrome.cookies.onChanged.fire({ cookie: { name: 'after' }, cause: 'explicit' });")
        #expect(js.evaluateScript("seen.length")?.toInt32() == 1)
    }

    @MainActor
    @Test func nativeGenerationCatchesLateSubscribersAndIsolatesExtensions() async {
        let recovery = ExtensionWorkerRecovery()
        #expect(recovery.generation(for: "first") == 0)
        recovery.restarted("first")
        let late = await recovery.observe("first", generation: 0, token: "old-page")
        #expect(late == 1)
        #expect(recovery.generation(for: "second") == 0)
        recovery.restarted("first")
        let twice = await recovery.observe("first", generation: 1, token: "old-page")
        #expect(twice == 2)
    }

    @MainActor
    @Test func observerLimitIsPerExtensionAndCancellationReleasesCapacity() {
        let recovery = ExtensionWorkerRecovery()
        var retired = 0, rejected = 0, replacement = 0, other = 0
        for index in 0..<ExtensionWorkerRecovery.observerLimit {
            recovery.observe("first", generation: 0, token: "port-\(index)", lifetime: nil) { _ in retired += 1 }
        }
        recovery.observe("first", generation: 0, token: "overflow", lifetime: nil) {
            #expect($0 == nil); rejected += 1
        }
        #expect(rejected == 1)
        #expect(retired == 0, "Overflow must not evict working ports")
        recovery.observe("second", generation: 0, token: "other", lifetime: nil) { _ in other += 1 }
        #expect(other == 0, "Another extension has its own capacity")
        recovery.observe("first", generation: 0, token: "port-0", lifetime: nil) { _ in replacement += 1 }
        #expect(retired == 1, "Replacing a token at capacity must remain possible")
        #expect(replacement == 0)
        recovery.cancel("first", token: "port-1")
        #expect(retired == 2)
        recovery.observe("first", generation: 0, token: "new", lifetime: nil) { _ in replacement += 1 }
        #expect(replacement == 0)
        recovery.restarted("first")
        #expect(retired == ExtensionWorkerRecovery.observerLimit)
        #expect(replacement == 2)
        #expect(rejected == 1, "A rejected observer is never queued")
        #expect(other == 0)
        recovery.unregister("second")
        #expect(other == 1)
    }

    @MainActor
    @Test func cancellationDoesNotAdvanceNativeGeneration() {
        let recovery = ExtensionWorkerRecovery()
        var value: Int?, replies = 0
        recovery.observe("first", generation: 0, token: "closing-page", lifetime: nil) { value = $0; replies += 1 }
        recovery.cancel("first", token: "closing-page")
        #expect(value == nil)
        #expect(replies == 1)
        #expect(recovery.generation(for: "first") == 0)
    }

    @MainActor
    @Test func workerOnlyWakeRetiresOldPortsButKeepsTheConnectionWakingIt() {
        let recovery = ExtensionWorkerRecovery(), oldWorker = UUID(), freshWorker = UUID()
        var old: [Int?] = [], waking: [Int?] = []
        recovery.observe("first", generation: 0, token: "old-port", lifetime: oldWorker) { old.append($0) }
        recovery.observe("first", generation: 0, token: "new-port", lifetime: nil) { waking.append($0) }
        recovery.createdWorker("first", lifetime: freshWorker)
        #expect(old == [0])
        #expect(waking.isEmpty)
        #expect(recovery.generation(for: "first") == 0)
        recovery.createdWorker("first", lifetime: freshWorker)
        #expect(old == [0], "A repeated creation report is not another restart")
        #expect(waking.isEmpty)
        recovery.createdWorker("first", lifetime: UUID())
        #expect(waking == [0], "The fresh port retires only on the following worker")
    }

    @MainActor
    @Test func reloadingSameContextRetiresPortsWithoutStalingCachedShims() {
        let recovery = ExtensionWorkerRecovery()
        var old: [Int?] = [], fresh: [Int?] = []
        recovery.observe("first", generation: 0, token: "old", lifetime: UUID()) { old.append($0) }
        recovery.restarted("first", replacingContext: false)
        #expect(old == [0])
        #expect(recovery.generation(for: "first") == 0)
        recovery.observe("first", generation: 0, token: "fresh", lifetime: nil) { fresh.append($0) }
        recovery.createdWorker("first", lifetime: UUID())
        #expect(fresh.isEmpty)
        recovery.cancel("first", token: "fresh")
    }

    @MainActor
    @Test func unregisterCancelsPendingObserversWithoutClaimingRestart() {
        let recovery = ExtensionWorkerRecovery()
        recovery.restarted("first")
        var replies: [Int?] = [], other: [Int?] = []
        recovery.observe("first", generation: 1, token: "pending", lifetime: nil) { replies.append($0) }
        recovery.observe("second", generation: 0, token: "pending", lifetime: nil) { other.append($0) }
        recovery.unregister("first")
        #expect(replies.count == 1)
        #expect(replies[0] == nil)
        recovery.createdWorker("first", lifetime: UUID())
        #expect(replies.count == 1)
        #expect(recovery.generation(for: "first") == 1, "Cleanup must preserve a previous context generation")
        #expect(other.isEmpty, "Another extension's subscriptions are retained")
        recovery.cancel("second", token: "pending")
        #expect(other.count == 1)
    }

    @MainActor
    @Test func liveFixtureParsesWithoutWebKitErrors() async throws {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ExtensionWorkerRecovery/extension")
        let fixture = try await WKWebExtension(resourceBaseURL: folder)
        #expect(fixture.errors.isEmpty, "The live fixture must not create WebKit manifest errors")
    }

    private func drain(_ js: JSContext) {
        for _ in 0..<40 { js.evaluateScript("void 0") }
        #expect(js.exception?.toString() == nil)
    }
}
