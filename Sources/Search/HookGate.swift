import Foundation

struct HookScene: Equatable {
    var agent = false
    var privately = false
    var scripted = false

    static let outside = HookScene()

    var allowed: Bool { !agent && !privately && !scripted }

    @MainActor
    static func of(_ tab: Tab?, in browser: Browser?) -> HookScene? {
        guard let tab else { return nil }
        return HookScene(agent: tab.agent || tab.agentHere || tab.agentTask != nil,
                         privately: tab.shy || browser?.isPrivate == true || !tab.store.isPersistent,
                         scripted: tab.bench)
    }
}

enum HookReading<Answer> {
    case nothing
    case answer(Answer)
    case wrong(String)
}

enum HookRan: Sendable {
    case changed
    case missing
    case refused
    case ran(HookOutcome)
}

@MainActor
enum HookGate {
    static var home = FileManager.default.homeDirectoryForCurrentUser
    static var room: URL { Store.file("hook-runs") }
    private(set) static var asked: [[String: Any]] = []

    static func forgetAsked() { asked = [] }

    nonisolated static func inside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    static func allows(_ program: URL) -> Bool {
        guard Store.testing else { return true }
        return inside(program, Store.folder)
    }

    static func input(_ event: HookEvent, _ fields: [String: Any]) -> Data? {
        var payload = fields
        payload["event"] = event.rawValue
        payload["version"] = 1
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    static func ask<Answer>(_ event: HookEvent, _ fields: [String: Any], scene: HookScene?, book: HookBook = .shared,
                            only: UUID? = nil, read: @escaping ([String: Any]) -> HookReading<Answer>, done: @escaping (Answer?) -> Void) {
        guard let scene, scene.allowed else { return done(nil) }
        let hooks = book.ready(for: event).filter { allows($0.program) && (only == nil || $0.id == only) }
        guard !hooks.isEmpty, let input = input(event, fields) else { return done(nil) }
        let home = home
        let room = room
        func next(_ index: Int) {
            guard index < hooks.count else { return done(nil) }
            let hook = hooks[index]
            if Store.testing {
                var seen = fields
                seen["event"] = event.rawValue
                seen["hook"] = hook.id.uuidString
                asked.append(seen)
            }
            Task.detached(priority: .userInitiated) {
                let ran = HookGate.run(hook, input: input, home: home, room: room)
                await MainActor.run {
                    switch settle(hook, ran, book: book, read: read) {
                    case .answer(let answer): done(answer)
                    case .nothing, .wrong: next(index + 1)
                    }
                }
            }
        }
        next(0)
    }

    nonisolated static func run(_ hook: Hook, input: Data, home: URL, room: URL) -> HookRan {
        let program = hook.program
        guard FileManager.default.fileExists(atPath: program.path) else { return .missing }
        guard hook.event.bound else {
            return .ran(HookRunner.run(program, input: input, seconds: hook.event.seconds, home: home))
        }
        guard let hash = hook.hash, let data = try? Data(contentsOf: program) else { return .changed }
        guard Hook.hash(of: data) == hash else { return .changed }
        try? FileManager.default.createDirectory(at: room, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let copy = room.appendingPathComponent(UUID().uuidString.lowercased())
        guard FileManager.default.createFile(atPath: copy.path, contents: data, attributes: [.posixPermissions: 0o700]) else { return .refused }
        defer { try? FileManager.default.removeItem(at: copy) }
        return .ran(HookRunner.run(copy, input: input, seconds: hook.event.seconds, home: home))
    }

    static func settle<Answer>(_ hook: Hook, _ ran: HookRan, book: HookBook, now: Date = Date(),
                               read: ([String: Any]) -> HookReading<Answer>) -> HookReading<Answer> {
        switch ran {
        case .changed:
            book.mark(hook.id, changed: true)
            book.note(hook.id, HookResult(at: now, problem: HookBook.changedWords), missed: false)
            return .wrong(HookBook.changedWords)
        case .missing:
            book.note(hook.id, HookResult(at: now, problem: "The program isn't there any more"), missed: false)
            return .wrong("The program isn't there any more")
        case .refused:
            book.note(hook.id, HookResult(at: now, problem: "Broadway couldn't make a copy to run"), missed: false)
            return .wrong("Broadway couldn't make a copy to run")
        case .ran(let outcome):
            if hook.event.bound { book.mark(hook.id, changed: false) }
            let reading = reading(outcome, read: read)
            var problem: String?
            switch (outcome.end, reading) {
            case (.timedOut, _): problem = "Timed out"
            case (.signalled, _): problem = "Crashed"
            case (.notStarted(let why), _): problem = "Couldn't start: \(why)"
            case (.exited(let code), _) where code != 0: problem = "Exited with code \(code)"
            case (_, .wrong(let why)): problem = why
            default: break
            }
            book.note(hook.id, HookResult(at: now, problem: problem, said: outcome.complaint), missed: outcome.missed)
            return reading
        }
    }

    static func reading<Answer>(_ outcome: HookOutcome, read: ([String: Any]) -> HookReading<Answer>) -> HookReading<Answer> {
        guard case .exited(0) = outcome.end else { return .nothing }
        guard !outcome.overflow else { return .wrong("Its answer was over 64 KB") }
        let text = String(decoding: outcome.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .nothing }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return .wrong("Its answer wasn't a JSON object")
        }
        guard !object.isEmpty else { return .nothing }
        return read(object)
    }
}
