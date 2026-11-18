import Foundation

enum LiveLimit {
    static let first: TimeInterval = 600
    static let longest: TimeInterval = 3600

    static func header(_ headers: [String: String], _ name: String) -> String? {
        headers.first { $0.key.lowercased() == name }?.value.trimmingCharacters(in: .whitespaces)
    }

    static func retryAfter(_ headers: [String: String], now: Date = Date()) -> TimeInterval? {
        guard let said = header(headers, "retry-after"), !said.isEmpty else { return nil }
        if let seconds = TimeInterval(said), seconds >= 0 { return seconds }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(identifier: "GMT")
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: said) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    static func miss(status: Int?, headers: [String: String], page: Bool, now: Date = Date()) -> LiveMiss? {
        let wait = retryAfter(headers, now: now)
        let spent = header(headers, "x-ratelimit-remaining") == "0"
        let refused = status == 403 && (wait != nil || spent || page)
        guard status == 429 || refused || page && (status ?? 200) >= 400 else { return nil }
        return LiveMiss(cause: .limited, wait: wait)
    }

    static func wait(_ miss: LiveMiss, previous: TimeInterval?) -> TimeInterval {
        if let said = miss.wait { return max(0, said) }
        guard let previous else { return first }
        return min(longest, max(first, previous * 2))
    }

    static func holds(_ folder: LiveFolder, at now: Date) -> Bool {
        guard folder.why == .limited, let until = folder.limitedUntil else { return false }
        return until > now
    }
}

@MainActor
enum LiveWords {
    static func limited(_ site: String, until: Date?, now: Date) -> String {
        "\(site) is limiting requests. Trying again \(soon(until, now: now))."
    }

    static func soon(_ until: Date?, now: Date) -> String {
        guard let until, until > now else { return "in a moment" }
        let minutes = Int((until.timeIntervalSince(now) / 60).rounded(.up))
        if minutes < 60 { return minutes == 1 ? "in 1 minute" : "in \(minutes) minutes" }
        let hours = Int((Double(minutes) / 60).rounded())
        return hours == 1 ? "in 1 hour" : "in \(hours) hours"
    }

    static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "Read just now" }
        if minutes < 60 { return minutes == 1 ? "Read 1 minute ago" : "Read \(minutes) minutes ago" }
        let hours = minutes / 60
        if hours < 48 { return hours == 1 ? "Read 1 hour ago" : "Read \(hours) hours ago" }
        return "Read \(hours / 24) days ago"
    }

    static func failure(_ folder: LiveFolder, now: Date) -> String? {
        guard folder.state == .failed else { return nil }
        let site = folder.source.siteName
        switch folder.why {
        case .offline: return "You're offline"
        case .limited: return limited(site, until: folder.limitedUntil, now: now)
        case .unread, .other, nil: return "Couldn't read \(site)"
        }
    }

    static func settings(_ folder: LiveFolder, reading: Bool, now: Date) -> String {
        if reading { return "Reading now…" }
        guard folder.state == .failed, !folder.paused else {
            guard let good = folder.good else { return folder.paused ? "Not yet, and paused" : "Not yet" }
            let said = LiveFolderRows.ago(good, now: now)
            return said.prefix(1).uppercased() + said.dropFirst()
        }
        let read = folder.good.map { ago($0, now: now) } ?? "Not read yet"
        let site = folder.source.siteName
        switch folder.why {
        case .offline: return "\(read). You're offline."
        case .limited: return "\(read). \(limited(site, until: folder.limitedUntil, now: now))"
        case .unread, .other, nil: return "\(read). Couldn't read \(site) just now."
        }
    }
}

@MainActor
enum LiveAge {
    static let least: TimeInterval = 600

    static var every: TimeInterval { LivePace.seen }

    static func old(_ folder: LiveFolder, at now: Date) -> Bool {
        guard !folder.paused, let good = folder.good else { return false }
        return now.timeIntervalSince(good) >= max(2 * every, least)
    }

    static func words(_ folder: LiveFolder, at now: Date) -> String? {
        guard old(folder, at: now), let good = folder.good else { return nil }
        return LiveWords.ago(good, now: now)
    }
}
