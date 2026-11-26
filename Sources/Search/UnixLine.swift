import Foundation

final class LineConnection {
    private final class Shut {
        let fd: Int32
        var holders = 1

        init(_ fd: Int32) { self.fd = fd }

        func release() {
            holders -= 1
            if holders == 0 { Darwin.close(fd) }
        }
    }

    private let fd: Int32
    let peer: Int32
    private let source: DispatchSourceRead
    private let shut: Shut
    private var bytes = Data()
    private var closed = false
    private var queue: [Data] = []
    private var offset = 0
    private var writer: DispatchSourceWrite?
    private var stall: DispatchSourceTimer?
    private var movedAt = Date()
    var onLine: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    static let longest = 4_000_000
    static var stallLimit: TimeInterval = 10

    var waiting: Int { queue.reduce(0) { $0 + $1.count } - offset }

    init(fd: Int32, peer: Int32 = 0) {
        self.fd = fd
        self.peer = peer
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var quiet: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))
        var room: Int32 = 1 << 20
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &room, socklen_t(MemoryLayout<Int32>.size))
        let shut = Shut(fd)
        self.shut = shut
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.read() }
        source.setCancelHandler { shut.release() }
        source.resume()
    }

    private func read() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(fd, &chunk, chunk.count)
        if count == 0 || (count < 0 && errno != EAGAIN) { return close() }
        guard count > 0 else { return }
        bytes.append(contentsOf: chunk[0..<count])
        while let newline = bytes.firstIndex(of: 0x0A) {
            let line = bytes[bytes.startIndex..<newline]
            bytes = Data(bytes[bytes.index(after: newline)...])
            if line.isEmpty { continue }
            guard let found = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                send(["error": "not a JSON object"])
                continue
            }
            onLine?(found)
        }
        if bytes.count > LineConnection.longest {
            send(["error": "request too long"])
            close()
        }
    }

    func send(_ object: [String: Any]) {
        guard !closed, var out = try? JSONSerialization.data(withJSONObject: object) else { return }
        out.append(0x0A)
        if queue.isEmpty { movedAt = Date() }
        queue.append(out)
        flush()
    }

    private func flush() {
        while let first = queue.first {
            let wrote = first.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset) }
            if wrote > 0 {
                movedAt = Date()
                offset += wrote
                if offset == first.count {
                    queue.removeFirst()
                    offset = 0
                }
                continue
            }
            if wrote < 0, errno == EINTR { continue }
            if wrote < 0, errno != EAGAIN { return drop() }
            break
        }
        if queue.isEmpty { quiet() } else { wait() }
    }

    private func wait() {
        if writer == nil {
            let made = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: .main)
            let shut = shut
            shut.holders += 1
            made.setEventHandler { self.flush() }
            made.setCancelHandler { shut.release() }
            made.resume()
            writer = made
        }
        if stall == nil {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            let beat = min(0.5, Self.stallLimit / 2)
            timer.schedule(deadline: .now() + beat, repeating: beat)
            timer.setEventHandler {
                guard Date().timeIntervalSince(self.movedAt) >= Self.stallLimit else { return }
                self.drop()
            }
            timer.resume()
            stall = timer
        }
    }

    private func quiet() {
        writer?.cancel()
        writer = nil
        stall?.cancel()
        stall = nil
    }

    private func drop() {
        queue = []
        offset = 0
        quiet()
        close()
    }

    func close() {
        guard !closed else { return }
        closed = true
        source.cancel()
        onClose?()
    }
}

final class UnixLineServer {
    private let path: String
    private var listener: Int32 = -1
    private var accepting: DispatchSourceRead?
    private var connections: [ObjectIdentifier: LineConnection] = [:]
    private var bound: FileMark?
    private var keeping: DispatchSourceTimer?
    var connected: ((LineConnection) -> Void)?

    struct FileMark: Equatable {
        var device: UInt64
        var inode: UInt64

        init?(_ path: String) {
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            device = UInt64(info.st_dev)
            inode = UInt64(info.st_ino)
        }
    }

    init(path: String) {
        self.path = path
    }

    var running: Bool { accepting != nil }

    var holdsPath: Bool { bound != nil && FileMark(path) == bound }

    func start() -> Bool {
        guard !running else { return true }
        guard let fd = listening() else { return false }
        take(fd)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.keep() }
        timer.resume()
        keeping = timer
        return true
    }

    func keep() {
        guard running, !holdsPath, !Self.answering(path), let fd = listening() else { return }
        accepting?.cancel()
        take(fd)
    }

    static func answering(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { return false }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    private func take(_ fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in self?.accept() }
        source.setCancelHandler { close(fd) }
        source.resume()
        accepting = source
        listener = fd
        bound = FileMark(path)
    }

    private func listening() -> Int32? {
        let folder = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        unlink(path)
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
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let mask = umask(0o177)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        umask(mask)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            return nil
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    func stop() {
        let mine = holdsPath
        keeping?.cancel()
        keeping = nil
        accepting?.cancel()
        accepting = nil
        listener = -1
        bound = nil
        connections.values.forEach { $0.close() }
        connections = [:]
        if mine { unlink(path) }
    }

    private func accept() {
        let fd = Darwin.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        var uid = uid_t(0)
        var gid = gid_t(0)
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            close(fd)
            return
        }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) != 0 { pid = 0 }
        let connection = LineConnection(fd: fd, peer: pid)
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        let before = connection.onClose
        connection.onClose = { [weak self] in
            before?()
            self?.connections[key] = nil
        }
        connected?(connection)
    }
}
