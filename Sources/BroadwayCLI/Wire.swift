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
    private var bytes = Data()
    private var looked = 0
    private var limit: Double?

    init?(path: String) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else {
            close(fd)
            return nil
        }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
        }
        let joined = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard joined == 0 else {
            close(fd)
            return nil
        }
        var quiet: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        self.fd = fd
    }

    static func blocked(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return errno == EPERM || errno == EACCES }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
        }
        let joined = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
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
        if let named { return Place(socket: named, wakes: false, world: nil, bundle: bundle, named: true) }
        if let folder = folder(world: world) {
            return Place(socket: "\(support)/Broadway (\(folder))/broadway.sock", wakes: bundle != nil, world: folder, bundle: bundle, named: false)
        }
        return Place(socket: "\(support)/Broadway/broadway.sock", wakes: true, world: nil, bundle: bundle, named: false)
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

    func reach(console: Console?) throws -> Link {
        if let link = connect() { return link }
        if Link.boxed(socket) { throw sandboxed }
        guard wakes else { throw notRunning }
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
                hint: "Run this command outside the sandbox, or let it reach \(socket). In Codex, approve it to run without the sandbox or turn on network access.")
    }

    var notRunning: Failure {
        if world != nil { return Failure("not_running", "That world of Broadway isn't running", hint: "Start it first, or leave out --world") }
        if socket.hasSuffix("broadway.sock"), !wakes, !named { return Failure("not_running", "Broadway isn't running") }
        return Failure("not_running", "Nothing is listening at \(socket)", hint: "Check --socket or BROADWAY_SOCKET, or open Broadway")
    }
}
