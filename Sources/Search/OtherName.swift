import Foundation
import Security

struct SentAddress: Equatable {
    var url: URL
    var at: Date
}

enum OtherName {
    static let within: TimeInterval = 90
    static let faults: Set<LoadFault> = [.cannotFindHost, .dnsFailed, .cannotConnect, .untrusted]

    static func counts(_ fault: LoadFault) -> Bool {
        faults.contains(fault)
    }

    static func countsTrust(_ code: Int?) -> Bool {
        guard let code else { return false }
        return code == Int(errSecHostNameMismatch) || code == Int(errSecNotTrusted)
    }

    static func due(_ sent: SentAddress, now: Date) -> Bool {
        let age = now.timeIntervalSince(sent.at)
        return age >= 0 && age <= within
    }

    static func host(for raw: String) -> String? {
        let host = raw.lowercased()
        guard !host.contains(":"), !Address.isLocal(host: host), LocalNetwork.reach(host) == .internet else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }),
              let last = labels.last, last.allSatisfy({ $0.isLetter }) else { return nil }
        guard labels[0] == "www" else { return "www." + host }
        return labels.count >= 3 ? labels.dropFirst().joined(separator: ".") : nil
    }

    static func of(_ url: URL) -> URL? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.port == nil,
              let name = url.host(percentEncoded: false), let other = host(for: name),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = other
        return parts.url
    }

    static func sameHost(_ one: URL?, _ other: URL?) -> Bool {
        guard let one = one?.host(percentEncoded: false)?.lowercased(), let other = other?.host(percentEncoded: false)?.lowercased() else { return false }
        return one == other
    }

    static func sameAddress(_ one: URL, _ other: URL) -> Bool {
        one.scheme?.lowercased() == other.scheme?.lowercased() && sameHost(one, other) && one.port == other.port
    }
}

struct SiteName: Codable, Equatable {
    var typed: String
    var named: String
    var at: Date
}

enum SiteNames {
    static let most = 500

    static func remembered(_ list: [SiteName], typed: String, named: String, at: Date) -> [SiteName] {
        let typed = typed.lowercased(), named = named.lowercased()
        guard typed != named else { return list }
        var kept = list.filter { $0.typed != typed && $0.typed != named }
        kept.append(SiteName(typed: typed, named: named, at: at))
        if kept.count > most { kept.removeFirst(kept.count - most) }
        return kept
    }

    static func answered(_ list: [SiteName], host: String) -> [SiteName] {
        let host = host.lowercased()
        return list.filter { $0.typed != host }
    }

    static func sent(_ url: URL, by list: [SiteName]) -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.port == nil,
              let host = url.host(percentEncoded: false)?.lowercased(),
              let pair = list.last(where: { $0.typed == host }),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.host = pair.named
        return parts.url ?? url
    }

    static func forgotten(_ list: [SiteName], site: String) -> [SiteName] {
        let bare = Address.withoutWWW(site.lowercased())
        func touches(_ host: String) -> Bool {
            let one = Address.withoutWWW(host)
            return one == bare || one.hasSuffix("." + bare)
        }
        return list.filter { !touches($0.typed) && !touches($0.named) }
    }

    static func committed(_ list: [SiteName], at host: String, after detour: Detour?, privately: Bool, now: Date) -> [SiteName] {
        guard !privately else { return list }
        let host = host.lowercased()
        let kept = answered(list, host: host)
        guard let detour, detour.kind == .otherName, detour.to.host(percentEncoded: false)?.lowercased() == host,
              let typed = detour.from.host(percentEncoded: false) else { return kept }
        return remembered(kept, typed: typed, named: host, at: now)
    }

    static func forgotten(_ list: [SiteName], since date: Date) -> [SiteName] {
        list.filter { $0.at < date }
    }
}

@MainActor
enum SiteNameBook {
    private static var file: URL { Store.file("site-names.json") }
    private static var loaded: [SiteName]?
    static var pending: SentAddress?

    static var all: [SiteName] {
        if let loaded { return loaded }
        let read = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([SiteName].self, from: $0) } ?? []
        loaded = read
        return read
    }

    private static func keep(_ list: [SiteName]) {
        guard list != all else { return }
        loaded = list
        let snapshot = list
        Disk.write(file) { try? JSONEncoder().encode(snapshot) }
    }

    static func committed(at host: String, after detour: Detour?, privately: Bool) {
        guard !privately else { return }
        keep(SiteNames.committed(all, at: host, after: detour, privately: privately, now: Date()))
    }

    static func sent(_ url: URL) -> URL {
        SiteNames.sent(url, by: all)
    }

    static func forget() {
        loaded = []
        pending = nil
        Disk.remove(file)
    }

    static func forget(site: String) {
        keep(SiteNames.forgotten(all, site: site))
    }

    static func forget(since date: Date) {
        keep(SiteNames.forgotten(all, since: date))
    }

    static func claim(_ url: URL?, now: Date = Date()) -> SentAddress? {
        guard let sent = pending else { return nil }
        guard OtherName.due(sent, now: now) else {
            pending = nil
            return nil
        }
        guard let url, OtherName.sameAddress(sent.url, url) else { return nil }
        pending = nil
        return sent
    }
}
