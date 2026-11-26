import AppKit
import Foundation
import Synchronization
import Testing
@testable import Search

actor WorldTurn {
    static let shared = WorldTurn()

    private var taken = false
    private var queue: [CheckedContinuation<Void, Never>] = []

    func take() async {
        guard taken else {
            taken = true
            return
        }
        await withCheckedContinuation { queue.append($0) }
    }

    func give() {
        guard !queue.isEmpty else {
            taken = false
            return
        }
        queue.removeFirst().resume()
    }
}

final class Teardowns: @unchecked Sendable {
    @TaskLocal static var current: Teardowns?

    private let lock = NSLock()
    private var blocks: [@MainActor () async throws -> Void] = []

    func add(_ block: @escaping @MainActor () async throws -> Void) {
        lock.withLock { blocks.append(block) }
    }

    func run() async {
        while let block = lock.withLock({ blocks.popLast() }) {
            do {
                try await block()
            } catch {
                Issue.record(error, "teardown failed")
            }
        }
    }
}

@MainActor
enum MainLoopKeeper {
    private static var observer: CFRunLoopObserver?
    private static var depth = 0
    private static var claimed = false

    static func claim() {
        guard !claimed else { return }
        claimed = true
        _ = NSApplication.shared
        _ = NSApp.nextEvent(matching: .any, until: .distantPast, inMode: .default, dequeue: false)
    }

    static func install() {
        guard observer == nil else { return }
        claim()
        let activities = CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue
        let made = CFRunLoopObserverCreateWithHandler(nil, activities, true, Int.min) { _, activity in
            MainActor.assumeIsolated { MainLoopKeeper.saw(activity) }
        }
        observer = made
        CFRunLoopAddObserver(CFRunLoopGetMain(), made, .commonModes)
    }

    private static func saw(_ activity: CFRunLoopActivity) {
        if activity == .entry {
            depth += 1
            return
        }
        depth -= 1
        guard depth < 0 else { return }
        depth = 0
        while true {
            CFRunLoopRun()
        }
    }
}

struct SharedWorld: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func prepare(for test: Test) async throws {
        await MainActor.run { MainLoopKeeper.claim() }
    }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        await MainActor.run {
            MainLoopKeeper.install()
            _ = Shared.prefs
        }
        await WorldTurn.shared.take()
        await SessionWorld.reset()
        TurnLog.took(test)
        let started = ProcessInfo.processInfo.systemUptime
        let turn = HeldTurn()
        let name = test.name
        let watch = Task {
            try await Task.sleep(for: Self.limit)
            Issue.record("\(name) held the world over \(Self.limit); the world was handed on so the run goes on")
            await turn.give()
        }
        let before = await TurnLog.state()
        let teardowns = Teardowns()
        var failure: (any Error)?
        do {
            try await Teardowns.$current.withValue(teardowns) { try await function() }
        } catch {
            failure = error
        }
        await teardowns.run()
        watch.cancel()
        await TurnLog.leaks(test, before: before)
        TurnLog.note(test, since: started)
        await turn.give()
        if let failure { throw failure }
    }

    static let limit: Duration = .seconds(60)
}

final class HeldTurn: Sendable {
    private let given = Mutex(false)

    func give() async {
        let first = given.withLock { given in
            defer { given = true }
            return !given
        }
        if first { await WorldTurn.shared.give() }
    }
}

@MainActor
enum SessionWorld {
    static let files: Set<String> = ["spaces.json", "pins.json", "windows.json"]

    static func reset() {
        Browser.nextEra()
        let folder = Store.folder
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where files.contains(name) || (name.hasPrefix("session") && (name.hasSuffix(".json") || name.hasSuffix(".plist"))) {
            Disk.remove(folder.appendingPathComponent(name))
        }
        Disk.drain()
        Pins.unload()
        SessionStates.unload()
        Spaces.known = [Space.firstID: Space.first()]
        Spaces.current = Space.firstID
        Store.settings.removeObject(forKey: "space.current")
        Store.settings.removeObject(forKey: "spaces.orderKept")
    }
}

enum TurnLog {
    private static let path = ProcessInfo.processInfo.environment["BROADWAY_TEST_TURNS"]
    private static let lock = NSLock()

    private static let audits = ProcessInfo.processInfo.environment["BROADWAY_TEST_LEAKS"] != nil

    static func state() async -> [String: String] {
        guard audits, let world = Store.world else { return [:] }
        let kept = Store.settings.persistentDomain(forName: "com.ysmaliak.broadway.test.\(world)") ?? [:]
        let open = await MainActor.run { Browsers.all.filter(\.isOpen).count }
        return kept.mapValues { String(describing: $0) }.merging(["(open browsers)": "\(open)"]) { $1 }
    }

    static func leaks(_ test: Test, before: [String: String]) async {
        guard audits else { return }
        let after = await state()
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }.sorted()
        guard !changed.isEmpty else { return }
        write("leak\t\(test.id.description)\t\(changed.joined(separator: ","))\n")
    }

    static func took(_ test: Test) {
        write("held\t\(test.id.description)\n")
    }

    static func note(_ test: Test, since started: TimeInterval) {
        let seconds = ProcessInfo.processInfo.systemUptime - started
        write(String(format: "%.3f\t%@\n", seconds, test.id.description))
    }

    private static func write(_ line: String) {
        guard let path else { return }
        lock.withLock {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }
}

extension Trait where Self == SharedWorld {
    static var sharedWorld: Self { SharedWorld() }
}

func addTeardownBlock(sourceLocation: SourceLocation = #_sourceLocation,
                      _ block: @escaping @MainActor () async throws -> Void) {
    guard let teardowns = Teardowns.current else {
        Issue.record("teardown needs a suite in the shared world", sourceLocation: sourceLocation)
        return
    }
    teardowns.add(block)
}

@MainActor
enum KeptSettings {
    static var domain: [String: Any] {
        let suite = Store.world == "test" ? "com.ysmaliak.broadway.test" : "com.ysmaliak.broadway.test.\(Store.world ?? "")"
        return Store.settings.persistentDomain(forName: suite) ?? [:]
    }

    static func snapshot(_ keys: [String]) -> [(String, Any?)] {
        let stored = domain
        return keys.map { ($0, stored[$0]) }
    }

    static func restore(_ kept: [(String, Any?)]) {
        for (key, value) in kept {
            if let value {
                Store.settings.set(value, forKey: key)
            } else {
                Store.settings.removeObject(forKey: key)
            }
        }
    }
}

@MainActor
func keepSettings(sourceLocation: SourceLocation = #_sourceLocation, _ keys: String...) {
    let kept = KeptSettings.snapshot(keys)
    addTeardownBlock(sourceLocation: sourceLocation) { KeptSettings.restore(kept) }
}

@MainActor
func keepSetting<Owner: AnyObject, Value>(sourceLocation: SourceLocation = #_sourceLocation,
                                          _ owner: Owner, _ path: ReferenceWritableKeyPath<Owner, Value>,
                                          _ keys: String...) {
    let value = owner[keyPath: path]
    let kept = KeptSettings.snapshot(keys)
    addTeardownBlock(sourceLocation: sourceLocation) {
        owner[keyPath: path] = value
        KeptSettings.restore(kept)
    }
}

final class Expectation: @unchecked Sendable {
    let description: String
    var isInverted = false
    var expectedFulfillmentCount = 1
    private let lock = NSLock()
    private var fulfilled = 0

    init(description: String) {
        self.description = description
    }

    var isFulfilled: Bool { lock.withLock { fulfilled >= expectedFulfillmentCount } }

    func fulfill() {
        lock.withLock { fulfilled += 1 }
    }
}

func fulfillment(of expectations: [Expectation], timeout: TimeInterval,
                 sourceLocation: SourceLocation = #_sourceLocation) async {
    let deadline = Date().addingTimeInterval(timeout)
    let inverted = expectations.filter(\.isInverted)
    let awaited = expectations.filter { !$0.isInverted }
    defer {
        for expectation in inverted where expectation.isFulfilled {
            Issue.record("\(expectation.description) was fulfilled", sourceLocation: sourceLocation)
        }
    }
    if awaited.isEmpty {
        while Date() < deadline, !inverted.contains(where: \.isFulfilled) {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return
    }
    while let waiting = awaited.first(where: { !$0.isFulfilled }) {
        guard Date() < deadline else {
            Issue.record("timed out waiting for \(waiting.description)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
