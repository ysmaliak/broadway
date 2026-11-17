import Foundation

enum SignInKeeping {
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    static let refresh: TimeInterval = 24 * 60 * 60
    static let settle: TimeInterval = 30
    static let deadline: TimeInterval = 2

    struct Place: Hashable, Sendable {
        var name: String
        var domain: String
        var path: String
    }

    struct Crumb: Codable, Hashable, Sendable {
        var name: String
        var value: String
        var domain: String
        var path: String
        var secure: Bool
        var httpOnly: Bool
        var sameSite: String?

        var place: Place { Place(name: name, domain: domain.lowercased(), path: path) }
    }

    struct Seen: Sendable {
        var crumb: Crumb
        var sessionOnly: Bool
    }

    struct Shelved: Codable, Sendable {
        var written: Date
        var crumbs: [Crumb]
    }

    enum Reading: Equatable {
        case nothing
        case putBack(written: Date, crumbs: [Crumb])
        case discard
    }

    enum Step: Equatable {
        case write
        case remove
        case nothing
    }

    static func keepable(_ seen: [Seen]) -> Set<Crumb> {
        Set(seen.filter(\.sessionOnly).map(\.crumb))
    }

    static func encode(_ crumbs: Set<Crumb>, at now: Date) -> Data? {
        let sorted = crumbs.sorted { ($0.domain, $0.path, $0.name) < ($1.domain, $1.path, $1.name) }
        return try? JSONEncoder().encode(Shelved(written: now, crumbs: sorted))
    }

    static func reading(_ data: Data?, now: Date, fresh: Bool) -> Reading {
        guard let data else { return .nothing }
        guard !fresh, let shelved = try? JSONDecoder().decode(Shelved.self, from: data) else { return .discard }
        let age = now.timeIntervalSince(shelved.written)
        guard age <= lifetime, age >= -refresh else { return .discard }
        return .putBack(written: shelved.written, crumbs: shelved.crumbs)
    }

    static func toPutBack(_ crumbs: [Crumb], present: Set<Place>) -> [Crumb] {
        var taken = present
        return crumbs.filter { taken.insert($0.place).inserted }
    }

    static func step(kept: Set<Crumb>, last: Set<Crumb>, written: Date?, now: Date, force: Bool, fresh: Bool) -> Step {
        guard let written else { return fresh || kept.isEmpty ? .nothing : .write }
        if fresh || kept.isEmpty { return .remove }
        if force || kept != last { return .write }
        return now.timeIntervalSince(written) >= refresh ? .write : .nothing
    }
}
