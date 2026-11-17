import Foundation

enum CertificateHolder: Hashable, Sendable {
    case space(UUID)
    case passing(UUID)
}

struct CertificateException: Codable, Equatable, Sendable {
    var host: String
    var port: Int
    var chain: [String]
    var until: Date
}

final class CertificateExceptions {
    static let publicLifetime: TimeInterval = 7 * 24 * 60 * 60
    static let localLifetime: TimeInterval = 30 * 24 * 60 * 60
    static let skew: TimeInterval = 24 * 60 * 60

    static func lifetime(for host: String) -> TimeInterval {
        Address.isLocal(host: normal(host)) ? localLifetime : publicLifetime
    }

    static func normal(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func fileName(for space: UUID) -> String {
        space == Space.firstID ? "certificates.json" : "certificates-\(space.uuidString).json"
    }

    static func isKept(_ name: String) -> Bool {
        name == "certificates.json" || (name.hasPrefix("certificates-") && name.hasSuffix(".json") && !name.contains(".unreadable-"))
    }

    let folder: URL
    var now: () -> Date

    private var ledgers: [CertificateHolder: [CertificateException]] = [:]

    init(folder: URL, now: @escaping () -> Date = { Date() }) {
        self.folder = folder
        self.now = now
    }

    func file(for space: UUID) -> URL {
        folder.appendingPathComponent(Self.fileName(for: space))
    }

    func covers(_ holder: CertificateHolder, host: String, port: Int, chain: [String]) -> Bool {
        guard !chain.isEmpty else { return false }
        let host = Self.normal(host)
        return live(holder).contains { $0.host == host && $0.port == port && $0.chain == chain }
    }

    func excuse(_ holder: CertificateHolder, host: String, port: Int, chain: [String]) {
        guard !chain.isEmpty else { return }
        let host = Self.normal(host)
        guard !host.isEmpty else { return }
        var list = live(holder).filter { !($0.host == host && $0.port == port && $0.chain == chain) }
        list.append(CertificateException(host: host, port: port, chain: chain, until: now().addingTimeInterval(Self.lifetime(for: host))))
        set(list, for: holder)
    }

    func exceptions(_ holder: CertificateHolder) -> [CertificateException] {
        live(holder)
    }

    func clearEverything() {
        for holder in Array(ledgers.keys) { ledgers[holder] = [] }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where Self.isKept(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    func clear(_ holder: CertificateHolder, where belongs: (String) -> Bool) {
        let list = live(holder)
        let left = list.filter { !belongs($0.host) }
        guard left.count != list.count else { return }
        set(left, for: holder)
    }

    func forget(space: UUID) {
        ledgers[.space(space)] = nil
        try? FileManager.default.removeItem(at: file(for: space))
    }

    func drop(passing id: UUID) {
        ledgers[.passing(id)] = nil
    }

    private func live(_ holder: CertificateHolder) -> [CertificateException] {
        let stored = ledgers[holder]
        let list = stored ?? read(holder)
        let at = now()
        let kept = list.filter { at < $0.until && $0.until.timeIntervalSince(at) <= Self.lifetime(for: $0.host) + Self.skew }
        if kept.count != list.count {
            set(kept, for: holder)
        } else if stored == nil {
            ledgers[holder] = kept
        }
        return kept
    }

    private func read(_ holder: CertificateHolder) -> [CertificateException] {
        guard case .space(let id) = holder else { return [] }
        let file = file(for: id)
        guard let data = try? Data(contentsOf: file) else { return [] }
        guard let list = try? JSONDecoder().decode([CertificateException].self, from: data) else {
            Store.quarantine(file)
            return []
        }
        return list
    }

    private func set(_ list: [CertificateException], for holder: CertificateHolder) {
        ledgers[holder] = list
        guard case .space(let id) = holder else { return }
        let file = file(for: id)
        guard !list.isEmpty else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
