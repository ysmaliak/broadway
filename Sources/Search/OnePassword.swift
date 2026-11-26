import Foundation
import Observation

struct OnePasswordItem: Equatable, Hashable, Sendable {
    var account: String
    var id: String

    var accountArguments: [String] { account.isEmpty ? [] : ["--account", account] }
}

struct OnePasswordRun: Sendable {
    var status: Int32?
    var out: Data
    var said: String
    var late: Bool

    var ok: Bool { status == 0 && !late }
}

enum OnePasswordLookup: Equatable {
    case found([Kept])
    case late
    case trouble(String)
}

enum OnePasswordState: Equatable {
    case checking
    case ready(Int)
    case missing
    case noAccounts
    case quiet
    case trouble(String)
}

enum OnePassword {
    static let places = ["/opt/homebrew/bin/op", "/usr/local/bin/op"]
    nonisolated(unsafe) static var standIn: String?
    nonisolated(unsafe) static var listBound: TimeInterval = 5
    nonisolated(unsafe) static var askBound: TimeInterval = 60
    nonisolated(unsafe) static var checkBound: TimeInterval = 5
    static let outLimit = 32 << 20

    static let integration = "Turn on Integrate with 1Password CLI in the 1Password app, in Settings › Developer"
    static let notInstalled = "Install 1Password CLI from 1Password's website"

    static func program() -> String? {
        if Store.testing, let standIn { return FileManager.default.isExecutableFile(atPath: standIn) ? standIn : nil }
        let own = Bundle.main.url(forAuxiliaryExecutable: "op")?.path
        return (places + [own].compactMap { $0 }).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func environment() -> [String: String] {
        var home = NSHomeDirectory()
        var name = NSUserName()
        if let entry = getpwuid(getuid()) {
            home = String(cString: entry.pointee.pw_dir)
            name = String(cString: entry.pointee.pw_name)
        }
        return ["HOME": home, "USER": name, "LOGNAME": name, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
    }

    static func run(_ arguments: [String], bound: TimeInterval) async -> OnePasswordRun? {
        guard let path = program() else { return nil }
        return await withCheckedContinuation { done in
            DispatchQueue.global(qos: .userInitiated).async {
                done.resume(returning: runNow(path, arguments, bound: bound))
            }
        }
    }

    static func runNow(_ path: String, _ arguments: [String], bound: TimeInterval) -> OnePasswordRun {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let lock = NSLock()
        var got = Data(), said = Data()
        let drained = DispatchSemaphore(value: 0)
        func drain(_ pipe: Pipe, limit: Int, into keep: @escaping (Data) -> Void) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    drained.signal()
                } else {
                    lock.lock()
                    keep(chunk)
                    lock.unlock()
                }
            }
        }
        drain(out, limit: outLimit) { chunk in if got.count < outLimit { got.append(chunk) } }
        drain(err, limit: 1 << 16) { chunk in if said.count < 1 << 16 { said.append(chunk) } }
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do {
            try process.run()
        } catch {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return OnePasswordRun(status: nil, out: Data(), said: "", late: false)
        }
        var late = false
        if ended.wait(timeout: .now() + bound) == .timedOut {
            late = true
            process.terminate()
            if ended.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                ended.wait()
            }
        }
        let end = DispatchTime.now() + 2
        if drained.wait(timeout: end) == .timedOut || drained.wait(timeout: end) == .timedOut {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }
        lock.lock()
        defer { lock.unlock() }
        return OnePasswordRun(status: late ? nil : process.terminationStatus, out: got,
                              said: String(decoding: said, as: UTF8.self), late: late)
    }

    static func accounts(_ data: Data) -> [String]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        return list.map { row in
            for key in ["account_uuid", "user_uuid", "url", "shorthand"] {
                if let value = row[key] as? String, !value.isEmpty { return value }
            }
            return ""
        }
    }

    static func place(_ href: String) -> (host: String, port: Int?, clear: Bool)? {
        var text = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let found = url.host()?.lowercased(), !found.isEmpty
        else { return nil }
        let host = found.hasPrefix("www.") ? String(found.dropFirst(4)) : found
        return (host, SentSignIn.port(of: url), scheme == "http")
    }

    static func items(_ data: Data, account: String) -> [Kept]? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        var kept: [Kept] = []
        for row in list {
            guard let id = row["id"] as? String, !id.isEmpty else { continue }
            if let category = row["category"] as? String, category.uppercased() != "LOGIN" { continue }
            let user = (row["additional_information"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var hrefs = (row["urls"] as? [[String: Any]])?.compactMap { $0["href"] as? String } ?? []
            if let url = row["url"] as? String { hrefs.append(url) }
            var seen = Set<String>()
            for href in hrefs {
                guard let place = place(href), seen.insert("\(place.host)|\(place.port ?? 0)|\(place.clear)").inserted else { continue }
                kept.append(Kept(host: place.host, user: user, used: nil, clear: place.clear, port: place.port,
                                 item: OnePasswordItem(account: account, id: id)))
            }
        }
        return kept
    }

    static func password(_ data: Data) -> String? {
        let read = try? JSONSerialization.jsonObject(with: data)
        let fields = (read as? [[String: Any]]) ?? (read as? [String: Any]).map { [$0] } ?? []
        let valued = fields.filter { ($0["value"] as? String).map { !$0.isEmpty } ?? false }
        let picked = valued.first { ($0["purpose"] as? String)?.uppercased() == "PASSWORD" }
            ?? valued.first { ($0["label"] as? String)?.lowercased() == "password" }
            ?? (valued.count == 1 ? valued.first : nil)
        return picked?["value"] as? String
    }

    static func code(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...10).contains(text.count), text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return text
    }

    static func words(_ run: OnePasswordRun) -> String {
        if run.late { return "1Password didn't answer in time" }
        let said = run.said.lowercased()
        if said.contains("no accounts configured") || said.contains("no account found") { return integration }
        if said.contains("dismissed") || said.contains("denied") || said.contains("cancel") { return "1Password wasn't unlocked" }
        if said.contains("not currently signed in") || said.contains("not signed in") || said.contains("sign in") { return "1Password isn't signed in. Open the 1Password app and unlock it." }
        if said.contains("connect") || said.contains("isn't running") || said.contains("is not running") { return "The 1Password app isn't open" }
        return "1Password refused it"
    }

    static func everything() async -> OnePasswordLookup {
        guard program() != nil else { return .trouble(notInstalled) }
        guard let listed = await run(["account", "list", "--format", "json"], bound: askBound) else { return .trouble(notInstalled) }
        guard listed.ok else { return .trouble(words(listed)) }
        guard let accounts = accounts(listed.out) else { return .trouble("1Password gave an answer Broadway couldn't read") }
        guard !accounts.isEmpty else { return .trouble(integration) }
        var all: [Kept] = []
        for account in accounts {
            let arguments = ["item", "list", "--categories", "Login", "--format", "json"] + (account.isEmpty ? [] : ["--account", account])
            guard let found = await run(arguments, bound: askBound) else { return .trouble(notInstalled) }
            guard found.ok else { return .trouble(words(found)) }
            guard let kept = items(found.out, account: account) else { return .trouble("1Password gave an answer Broadway couldn't read") }
            all += kept
        }
        return .found(all)
    }

    enum Fetched: Equatable {
        case login(Login)
        case refused(String, locked: Bool)
    }

    static func fetch(_ kept: Kept) async -> Fetched {
        guard let item = kept.item else { return .refused("1Password refused it", locked: false) }
        guard let read = await run(["item", "get", item.id, "--fields", "type=concealed", "--reveal", "--format", "json"] + item.accountArguments, bound: askBound)
        else { return .refused(notInstalled, locked: false) }
        guard read.ok else {
            let why = words(read)
            return .refused(why, locked: read.late || why == "1Password wasn't unlocked")
        }
        guard let password = password(read.out) else { return .refused("1Password gave an answer Broadway couldn't read", locked: false) }
        return .login(Login(host: kept.host, user: kept.user, password: password, used: nil, clear: kept.clear, port: kept.port))
    }

    static func login(_ kept: Kept) async -> Login? {
        guard case .login(let login) = await fetch(kept) else { return nil }
        return login
    }

    static func oneTimeCode(_ item: OnePasswordItem) async -> String? {
        guard let read = await run(["item", "get", item.id, "--otp"] + item.accountArguments, bound: askBound), read.ok else { return nil }
        return code(read.out)
    }

    static func check() async -> OnePasswordState {
        guard program() != nil else { return .missing }
        guard let version = await run(["--version"], bound: checkBound) else { return .missing }
        if version.late { return .quiet }
        guard version.ok, String(decoding: version.out, as: UTF8.self).first?.isNumber == true else {
            return .trouble("The 1Password command line tool didn't answer as expected")
        }
        guard let listed = await run(["account", "list", "--format", "json"], bound: checkBound) else { return .missing }
        if listed.late { return .quiet }
        guard listed.ok else { return .trouble(words(listed)) }
        guard let accounts = accounts(listed.out) else { return .trouble("1Password gave an answer Broadway couldn't read") }
        return accounts.isEmpty ? .noAccounts : .ready(accounts.count)
    }
}

@MainActor
final class OnePasswordLookups {
    static let shared = OnePasswordLookups()

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func take() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if done { return false }
            done = true
            return true
        }
    }

    var keepFor: TimeInterval = 120
    private var held: (at: Date, kept: [Kept])?
    private var running: Task<OnePasswordLookup, Never>?

    func forget() {
        held = nil
        running = nil
    }

    func lookup(_ place: URL) async -> OnePasswordLookup {
        if let held, Date().timeIntervalSince(held.at) < keepFor {
            return .found(held.kept.filter { AgentSignInMatch.fits($0, page: place) })
        }
        let task = running ?? Task.detached { await OnePassword.everything() }
        running = task
        let bound = OnePassword.listBound
        let first: OnePasswordLookup? = await withCheckedContinuation { done in
            let once = Once()
            Task { @MainActor in
                let value = await task.value
                if once.take() { done.resume(returning: value) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(bound))
                if once.take() { done.resume(returning: nil) }
            }
        }
        guard let first else {
            Task { [weak self] in
                let ended = await task.value
                self?.settle(task, ended)
            }
            return .late
        }
        settle(task, first)
        guard case .found(let all) = first else { return first }
        return .found(all.filter { AgentSignInMatch.fits($0, page: place) })
    }

    private func settle(_ task: Task<OnePasswordLookup, Never>, _ ended: OnePasswordLookup) {
        if running == task { running = nil }
        if case .found(let all) = ended { held = (Date(), all) }
    }
}

@MainActor
@Observable
final class OnePasswordSetup {
    static let shared = OnePasswordSetup()

    private(set) var state: OnePasswordState?
    @ObservationIgnored private var asking = 0

    func check() {
        asking += 1
        let ask = asking
        state = .checking
        Task { [weak self] in
            let found = await OnePassword.check()
            guard let self, ask == self.asking else { return }
            self.state = found
        }
    }

    func off() {
        asking += 1
        state = nil
        OnePasswordLookups.shared.forget()
    }

    static func words(_ state: OnePasswordState?) -> String {
        switch state {
        case nil: return "Uses the 1Password command line tool"
        case .checking: return "Looking for 1Password"
        case .ready(let count): return count == 1 ? "Ready, with 1 account. 1Password asks for Touch ID when it is locked." : "Ready, with \(count) accounts. 1Password asks for Touch ID when it is locked."
        case .missing: return "The 1Password command line tool isn't on this Mac. \(OnePassword.notInstalled)."
        case .noAccounts: return OnePassword.integration
        case .quiet: return "1Password didn't answer. Open the 1Password app and check again."
        case .trouble(let words): return words
        }
    }
}
