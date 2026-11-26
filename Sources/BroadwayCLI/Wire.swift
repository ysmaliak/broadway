import Darwin
import Foundation

final class Link {
    struct Watch {
        var socket: String
        var deadline: Date?
        var reads: Bool
        var first = 3.0
        var every = 10.0
        var patience = 10.0
    }

    nonisolated(unsafe) static var watch: Watch?
    nonisolated(unsafe) static var halted: Failure?

    let fd: Int32
    var watched = true
    var forwarded = false
    private var bytes = Data()
    private var looked = 0
    private var limit: Double?

    init?(path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard UnixAddress.call(fd, path, { Darwin.connect($0, $1, $2) }) == 0 else {
            close(fd)
            return nil
        }
        var quiet: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        self.fd = fd
        var peer: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0, peer > 0, let found = AgentAncestor.process(peer) {
            forwarded = AgentAncestor.carrier(found.name)
        }
    }

    static func blocked(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno == EPERM || errno == EACCES }
        defer { close(fd) }
        guard let joined = UnixAddress.call(fd, path, { Darwin.connect($0, $1, $2) }) else { return false }
        return joined != 0 && (errno == EPERM || errno == EACCES)
    }

    static let witness = "/var/run/mDNSResponder"

    static func boxed(_ path: String) -> Bool {
        blocked(path) || blocked(witness)
    }

    func patience(_ seconds: Double) {
        limit = seconds
        watched = false
    }

    static func alive(_ socket: String, within seconds: Double) -> Bool {
        guard let ping = Link(path: socket) else { return false }
        defer { close(ping.fd) }
        ping.patience(seconds)
        guard ping.send(["op": "status"]) else { return false }
        return ping.line() != nil
    }

    private func waitForBytes() -> Bool {
        let began = Date()
        var heard = began
        var pinged: Date?
        while true {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 250)
            if ready > 0 { return true }
            if ready < 0, errno != EINTR { return true }
            let now = Date()
            if let limit, now.timeIntervalSince(began) >= limit { return false }
            guard watched, let watch = Link.watch else { continue }
            if let deadline = watch.deadline, now >= deadline {
                Link.halted = Failure("deadline", "Broadway didn't finish in time",
                                      hint: watch.reads ? "Raise --timeout, or try again" : "It may or may not have happened, so look before you repeat it. Raise --timeout for a longer wait.",
                                      retrySafe: watch.reads, exit: .unanswered)
                return false
            }
            let quiet = now.timeIntervalSince(max(heard, pinged ?? heard))
            guard quiet >= (pinged == nil ? watch.first : watch.every) else { continue }
            if Link.alive(watch.socket, within: watch.patience) {
                pinged = Date()
                heard = pinged ?? heard
                continue
            }
            Link.halted = Failure("not_answering", "Broadway isn't answering, and may be waiting on a system prompt",
                                  hint: "Look at the Mac's screen for a question from macOS or Broadway, then try again. broadway doctor checks the rest.",
                                  retrySafe: watch.reads, exit: .unanswered)
            return false
        }
    }

    @discardableResult
    func send(_ object: [String: Any]) -> Bool {
        var object = object
        if forwarded, let agent = object["agent"] as? [String: Any] { object["agent"] = AgentAncestor.forwarded(agent, host: AgentAncestor.hostName()) }
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        return sendRaw(data)
    }

    @discardableResult
    func sendRaw(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let wrote = Darwin.write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                if wrote <= 0 { return false }
                sent += wrote
            }
            return true
        }
    }

    func line() -> Data? {
        while true {
            if let newline = bytes[(bytes.startIndex + looked)...].firstIndex(of: 0x0A) {
                let found = Data(bytes[bytes.startIndex..<newline])
                bytes = Data(bytes[bytes.index(after: newline)...])
                looked = 0
                return found
            }
            looked = bytes.count
            guard waitForBytes() else { return nil }
            var chunk = [UInt8](repeating: 0, count: 262_144)
            let count = read(fd, &chunk, chunk.count)
            if count <= 0 { return nil }
            bytes.append(contentsOf: chunk[0..<count])
        }
    }

    func object() -> [String: Any]? {
        line().flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}

struct Place {
    var socket: String
    var wakes: Bool
    var world: String?
    var bundle: String?
    var named: Bool
    var overSSH = false
    var starting = false

    static func home(_ environment: [String: String]) -> String {
        environment["BROADWAY_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
    }

    static func folder(world: String?) -> String? {
        guard let world else { return nil }
        return String(world.lowercased().filter { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" })
    }

    static func resolve(socket flag: String?, world: String?, environment: [String: String], binary: String) -> Place {
        let bundle = Self.bundle(of: binary)
        let named = flag ?? environment["BROADWAY_SOCKET"].flatMap { $0.isEmpty ? nil : $0 }
        let support = NSHomeDirectory() + "/Library/Application Support"
        let overSSH = environment["SSH_CONNECTION"].map { !$0.isEmpty } == true
        if let named { return Place(socket: named, wakes: false, world: nil, bundle: bundle, named: true, overSSH: overSSH) }
        if let folder = folder(world: world) {
            return Place(socket: "\(support)/Broadway (\(folder))/broadway.sock", wakes: bundle != nil, world: folder, bundle: bundle, named: false, overSSH: overSSH)
        }
        return Place(socket: "\(support)/Broadway/broadway.sock", wakes: true, world: nil, bundle: bundle, named: false, overSSH: overSSH)
    }

    static func bundle(of binary: String) -> String? {
        guard let range = binary.range(of: ".app/Contents/Helpers/", options: .backwards) else { return nil }
        return String(binary[..<range.lowerBound]) + ".app"
    }

    func wakeArguments(flag: String) -> [String] {
        if let world, let bundle { return ["-n", "-g", "-j", "--env", "SEARCH_PROBE=\(world)", bundle, "--args", flag] }
        if let bundle { return ["-g", "-j", bundle, "--args", flag] }
        return ["-g", "-j", "-b", "com.ysmaliak.broadway", "--args", flag]
    }

    func connect() -> Link? { Link(path: socket) }

    func whyNot(boxed: (String) -> Bool = Link.boxed, elsewhere: () -> String? = { Place.runningElsewhere() }) -> Failure? {
        if let owner = Self.foreignOwner(socket) { return otherUser(owner) }
        if boxed(socket) { return sandboxed }
        if overSSH, !starting, let owner = elsewhere() { return otherUser(owner) }
        guard wakes else { return notRunning }
        if overSSH, !starting { return notStarted }
        return nil
    }

    func reach(console: Console?) throws -> Link {
        if let link = connect() { return link }
        if let why = whyNot() { throw why }
        console?.progress(console?.err.dim("Starting Broadway…") ?? "")
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = wakeArguments(flag: "--hidden-wake")
        open.standardError = FileHandle.nullDevice
        open.standardOutput = FileHandle.nullDevice
        try? open.run()
        open.waitUntilExit()
        for _ in 0..<300 {
            if let link = connect() { return link }
            usleep(100_000)
        }
        throw Failure("not_running", "Broadway didn't start", hint: "Open it from Applications, or run broadway doctor")
    }

    var sandboxed: Failure {
        Failure("sandboxed", "A sandbox kept broadway from reaching Broadway",
                hint: "Run this command outside the sandbox, or let it reach \(socket). In Codex, approve running it outside the sandbox, or set sandbox_workspace_write.network_access = true in ~/.codex/config.toml.")
    }

    var notStarted: Failure {
        Failure("not_running", "Broadway isn't running, and a command over ssh doesn't start it",
                hint: "Run broadway serve there to start it hidden and keep it open, or ask the person to open Broadway")
    }

    func otherUser(_ owner: String) -> Failure {
        Failure("other_user", "Broadway here belongs to \(owner), another user of this Mac, and only that user can reach it",
                hint: "Run broadway as \(owner), such as ssh \(owner)@\(AgentAncestor.hostName() ?? "this-mac") broadway status")
    }

    static func foreignOwner(_ socket: String, owner: (String) -> uid_t? = Place.owner, me: uid_t = getuid(), name: (uid_t) -> String? = Place.userName) -> String? {
        var path = (socket as NSString).standardizingPath
        while !path.isEmpty, path != "/" {
            if let found = owner(path) {
                guard found != me, found != 0 else { return nil }
                return name(found) ?? "uid \(found)"
            }
            path = (path as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func owner(_ path: String) -> uid_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_uid : nil
    }

    static func userName(_ uid: uid_t) -> String? {
        guard let entry = getpwuid(uid), let name = entry.pointee.pw_name else { return nil }
        return String(cString: name)
    }

    static func runningElsewhere(apps: () -> [(uid: uid_t, name: String)] = Place.apps, me: uid_t = getuid(), name: (uid_t) -> String? = Place.userName) -> String? {
        guard let found = apps().first(where: { $0.uid != me && $0.uid != 0 && $0.name == "Broadway" }) else { return nil }
        return name(found.uid) ?? "uid \(found.uid)"
    }

    static func apps() -> [(uid: uid_t, name: String)] {
        let room = proc_listallpids(nil, 0)
        guard room > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(room) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 1 else { return nil }
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return nil }
            let command = withUnsafeBytes(of: info.pbsi_comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            return (info.pbsi_uid, command)
        }
    }

    var notRunning: Failure {
        if world != nil { return Failure("not_running", "That world of Broadway isn't running", hint: "Start it first, or leave out --world") }
        if socket.hasSuffix("broadway.sock"), !wakes, !named { return Failure("not_running", "Broadway isn't running") }
        return Failure("not_running", "Nothing is listening at \(socket)", hint: "Check --socket or BROADWAY_SOCKET, or open Broadway")
    }
}
