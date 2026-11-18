import Foundation

enum LiveDocuments {
    static let notionHosts: Set<String> = ["notion.so", "app.notion.com"]
    static let docsKinds: Set<String> = ["document", "spreadsheets", "presentation", "drawings", "forms", "file"]

    static func identity(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        let site = Address.withoutWWW(host)
        if notionHosts.contains(site) || site.hasSuffix(".notion.site") {
            return notion(url).map { "notion:" + $0 }
        }
        if site == "docs.google.com" || site == "drive.google.com" {
            return drive(url, docs: site == "docs.google.com").map { "drive:" + $0 }
        }
        return nil
    }

    static func notion(_ url: URL) -> String? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard !query.contains(where: { $0.name == "p" }), let last = url.path().split(separator: "/").last else { return nil }
        let segment = last.lowercased()
        let hex = Set("0123456789abcdef")
        if segment.count >= 36 {
            let tail = String(segment.suffix(36))
            let parts = tail.split(separator: "-", omittingEmptySubsequences: false)
            if parts.map(\.count) == [8, 4, 4, 4, 12], parts.allSatisfy({ $0.allSatisfy(hex.contains) }),
               segment.count == 36 || segment.dropLast(36).hasSuffix("-") {
                return parts.joined()
            }
        }
        guard segment.count >= 32 else { return nil }
        let tail = String(segment.suffix(32))
        guard tail.allSatisfy(hex.contains), segment.count == 32 || segment.dropLast(32).hasSuffix("-") else { return nil }
        return tail
    }

    static func driveID(_ text: String?) -> String? {
        guard let text, text.count >= 20,
              text.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" })
        else { return nil }
        return text
    }

    static func drive(_ url: URL, docs: Bool) -> String? {
        var path = url.path().split(separator: "/").map(String.init)
        var at = 0
        while at + 1 < path.count {
            if path[at] == "u", Int(path[at + 1]) != nil { path.removeSubrange(at...at + 1) } else { at += 1 }
        }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if path == ["open"] || (!docs && path == ["uc"]) {
            return driveID(query.first { $0.name == "id" }?.value)
        }
        if docs {
            guard path.count >= 3, docsKinds.contains(path[0]), path[1] == "d" else { return nil }
            return driveID(path[2])
        }
        if path.count >= 3, path[0] == "file", path[1] == "d" { return driveID(path[2]) }
        if path.count >= 3, path[0] == "drive", path[1] == "folders" { return driveID(path[2]) }
        return nil
    }

    static func document(_ key: String) -> Bool {
        let identity = LiveIdentity.of(key)
        return identity.hasPrefix("drive:") || identity.hasPrefix("notion:")
    }

    static func edited(_ date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "Edited just now" }
        if minutes < 60 { return minutes == 1 ? "Edited 1 minute ago" : "Edited \(minutes) minutes ago" }
        let hours = minutes / 60
        if hours < 48 { return hours == 1 ? "Edited 1 hour ago" : "Edited \(hours) hours ago" }
        return "Edited \(hours / 24) days ago"
    }

    static func byline(_ item: LiveItem, now: Date = Date()) -> String? {
        guard document(item.key), let kind = item.label, let updated = item.updated else { return nil }
        return "\(kind) · \(edited(updated, now: now))"
    }

    static func spoken(_ item: LiveItem, now: Date = Date()) -> String? {
        guard document(item.key), let kind = item.label, let updated = item.updated else { return nil }
        return "\(kind), \(edited(updated, now: now).lowercased())"
    }
}
