import Darwin

public enum UnixAddress {
    public static func call(_ fd: Int32, _ path: String, _ call: (Int32, UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let room = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < room else { return nil }
        withUnsafeMutablePointer(to: &address.sun_path) { sun in
            sun.withMemoryRebound(to: CChar.self, capacity: room) { _ = strlcpy($0, path, room) }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { call(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
