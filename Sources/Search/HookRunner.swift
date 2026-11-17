import Darwin
import Foundation

struct HookOutcome: Equatable, Sendable {
    enum End: Equatable, Sendable {
        case exited(Int32)
        case signalled(Int32)
        case timedOut
        case notStarted(String)
    }

    var end: End
    var output = Data()
    var overflow = false
    var complaint = ""

    var missed: Bool {
        switch end {
        case .exited: false
        case .signalled, .timedOut, .notStarted: true
        }
    }
}

enum HookRunner {
    static let outputLimit = 64 * 1024
    static let complaintLimit = 2048
    static let path = "/usr/bin:/bin:/usr/sbin:/sbin"

    static func environment(home: URL) -> [String: String] {
        ["HOME": home.path, "PATH": path, "LANG": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory()]
    }

    static func run(_ program: URL, input: Data, seconds: Double, home: URL) -> HookOutcome {
        var stdin: [Int32] = [-1, -1]
        var stdout: [Int32] = [-1, -1]
        var stderr: [Int32] = [-1, -1]
        guard pipe(&stdin) == 0 else { return HookOutcome(end: .notStarted("No pipe")) }
        guard pipe(&stdout) == 0 else {
            close(stdin[0]); close(stdin[1])
            return HookOutcome(end: .notStarted("No pipe"))
        }
        guard pipe(&stderr) == 0 else {
            for fd in stdin + stdout { close(fd) }
            return HookOutcome(end: .notStarted("No pipe"))
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdout[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderr[1], 2)
        posix_spawn_file_actions_addchdir_np(&actions, home.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        var every = sigset_t()
        sigfillset(&every)
        sigdelset(&every, SIGKILL)
        sigdelset(&every, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &every)

        let target = program.path
        let words = [target]
        let settings = environment(home: home).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let started = withCStrings(words) { argv in
            withCStrings(settings) { envp in
                posix_spawn(&pid, target, &actions, &attributes, argv, envp)
            }
        }
        close(stdin[0])
        close(stdout[1])
        close(stderr[1])
        guard started == 0 else {
            close(stdin[1]); close(stdout[0]); close(stderr[0])
            return HookOutcome(end: .notStarted(String(cString: strerror(started))))
        }

        let feed = stdin[1]
        let out = stdout[0]
        let err = stderr[0]
        _ = fcntl(feed, F_SETNOSIGPIPE, 1)
        for fd in [feed, out, err] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

        var outcome = HookOutcome(end: .timedOut)
        var sent = 0
        var feeding = feed
        if input.isEmpty {
            close(feed)
            feeding = -1
        }
        var reading = (out: out, err: err)
        let deadline = Date().addingTimeInterval(seconds)
        var status: Int32 = 0
        var exited = false
        var buffer = [UInt8](repeating: 0, count: 16_384)

        func drain(_ fd: inout Int32, into keep: (ArraySlice<UInt8>) -> Void) {
            guard fd >= 0 else { return }
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    keep(buffer[0..<count])
                    continue
                }
                if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    close(fd)
                    fd = -1
                }
                return
            }
        }

        func take() {
            drain(&reading.out) { bytes in
                if outcome.output.count <= outputLimit {
                    outcome.output.append(contentsOf: bytes.prefix(outputLimit + 1 - outcome.output.count))
                }
                if outcome.output.count > outputLimit { outcome.overflow = true }
            }
            var said = Data(outcome.complaint.utf8)
            drain(&reading.err) { bytes in
                said.append(contentsOf: bytes)
                if said.count > complaintLimit { said = said.suffix(complaintLimit) }
            }
            outcome.complaint = String(decoding: said, as: UTF8.self)
        }

        func give() {
            guard feeding >= 0 else { return }
            while sent < input.count {
                let count = input.withUnsafeBytes { raw in
                    write(feeding, raw.baseAddress!.advanced(by: sent), input.count - sent)
                }
                if count > 0 {
                    sent += count
                    continue
                }
                if count < 0, errno == EAGAIN || errno == EINTR { return }
                break
            }
            close(feeding)
            feeding = -1
        }

        while true {
            give()
            take()
            if waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                take()
                break
            }
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { break }
            var watch: [pollfd] = []
            if reading.out >= 0 { watch.append(pollfd(fd: reading.out, events: Int16(POLLIN), revents: 0)) }
            if reading.err >= 0 { watch.append(pollfd(fd: reading.err, events: Int16(POLLIN), revents: 0)) }
            if feeding >= 0 { watch.append(pollfd(fd: feeding, events: Int16(POLLOUT), revents: 0)) }
            let wait = Int32(min(left * 1000, 20).rounded(.up))
            if watch.isEmpty {
                usleep(useconds_t(wait) * 1000)
            } else {
                _ = poll(&watch, nfds_t(watch.count), wait)
            }
        }

        if feeding >= 0 { close(feeding) }
        if !exited {
            kill(-pid, SIGTERM)
            kill(pid, SIGTERM)
            let grace = Date().addingTimeInterval(0.3)
            while Date() < grace, waitpid(pid, &status, WNOHANG) != pid { usleep(10_000) }
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
            take()
            outcome.end = .timedOut
        } else {
            let signal = status & 0x7f
            outcome.end = signal == 0 ? .exited((status >> 8) & 0xff) : .signalled(signal)
        }
        if reading.out >= 0 { close(reading.out) }
        if reading.err >= 0 { close(reading.err) }
        return outcome
    }

    private static func withCStrings<Result>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> Result) -> Result {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }
}
