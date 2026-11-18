import Foundation

enum LiveCause: String, Codable, Equatable {
    case offline, limited, unread, other
}

struct LiveMiss: Equatable {
    var cause: LiveCause = .other
    var wait: TimeInterval? = nil
}

struct LiveRead: Equatable {
    enum Feed: Equatable { case entries, empty, notFeed }

    var items: [LiveItem]
    var source: LiveSource? = nil
    var missed: [PullList: LiveMiss] = [:]
    var signedOut: Set<PullList> = []
    var whole = true
    var marked = false
    var feed: Feed? = nil
    var more: String? = nil
    var noCycle = false
}

extension LiveReader.Answer {
    var found: [LiveItem]? {
        switch self {
        case .items(let items, _): return items
        case .read(let read): return read.items
        case .signIn, .sso, .failed, .missed: return nil
        }
    }

    func more(_ page: URL) -> LiveReader.Answer {
        guard case .read(var read) = self, read.more != nil else { return self }
        read.more = page.absoluteString
        return .read(read)
    }

    var whole: Bool {
        switch self {
        case .items: return true
        case .read(let read): return read.whole && read.missed.isEmpty && read.signedOut.isEmpty
        case .signIn, .sso, .failed, .missed: return false
        }
    }
}

enum LiveTrust {
    static let pause: Duration = .seconds(2)
    static let notFeeds = 3
    static let emptyFeeds = 2

    static func on(_ item: LiveItem, _ list: PullList) -> Bool {
        item.on.map { $0.contains(list) } ?? true
    }

    static func unproved(_ before: [LiveItem], _ read: LiveRead) -> Bool {
        read.items.isEmpty && !before.isEmpty && !read.marked && read.feed == nil
    }

    static func leaving(_ before: [LiveItem], found: [LiveItem], known: Set<String>) -> [String] {
        let present = Set(found.map { LiveIdentity.of($0.key) })
        return before.compactMap { item in
            let identity = LiveIdentity.of(item.key)
            guard !present.contains(identity), !known.contains(identity),
                  item.label != PullState.merged, item.label != PullState.closed else { return nil }
            return identity
        }
    }

    static func agreed(first: [LiveItem], second: [LiveItem]) -> [LiveItem] {
        var out = second
        var present = Set(second.map { LiveIdentity.of($0.key) })
        for (index, item) in first.enumerated() where present.insert(LiveIdentity.of(item.key)).inserted {
            out.insert(item, at: min(index, out.count))
        }
        return out
    }

    static func looked(_ had: [LiveItem], known: Set<String>, pause: Duration = pause,
                       read: () async -> LiveReader.Answer) async -> LiveReader.Answer {
        let first = await read()
        guard case .read(let seen) = first, seen.whole else { return first }
        let empty = unproved(had, seen)
        guard empty || !leaving(had, found: seen.items, known: known).isEmpty else { return first }
        try? await Task.sleep(for: pause)
        let second = await read()
        if empty { return second }
        guard case .read(var again) = second else {
            var held = seen
            held.whole = false
            return .read(held)
        }
        again.items = agreed(first: seen.items, second: again.items)
        return .read(again)
    }

    static func kept(_ before: [LiveItem], _ read: LiveRead) -> Set<String> {
        let failed = Set(read.missed.keys).union(read.signedOut)
        return Set(before.filter { item in !read.whole || failed.contains { on(item, $0) } }.map { LiveIdentity.of($0.key) })
    }

    static func after(_ folder: LiveFolder, _ answer: LiveReader.Answer, now: Date, online: Bool = true) -> LiveFolder {
        var next = folder
        switch answer {
        case .items(let items, let source):
            if let source { next.source = source }
            let cut = LiveMerge.cuts(next, fetched: items)
            next = LiveMerge.merged(next, fetched: items, now: now)
            next.notFeeds = nil
            next.emptyFeeds = nil
            next.more = cut ? next.source.reading(at: now)?.absoluteString : nil
            next.noCycle = nil
        case .read(let read):
            next = taken(folder, read, now: now, online: online)
        case .signIn:
            next.state = .signIn
            next.sso = nil
            next.read = now
        case .sso(let sso, let seen):
            if !seen.isEmpty {
                let keys = Set(seen.map { LiveIdentity.of($0.key) })
                next = LiveMerge.merged(next, fetched: seen + next.items.filter { !keys.contains(LiveIdentity.of($0.key)) }, now: now,
                                        complete: false)
            }
            next.state = .signIn
            next.sso = sso
            next.read = now
        case .failed:
            next = missed(folder, LiveMiss(), now: now, online: online)
        case .missed(let miss):
            next = missed(folder, miss, now: now, online: online)
        }
        if next.state == .fine {
            next.good = now
            next.cause = nil
        }
        if next.state != .failed {
            next.limitedUntil = nil
            next.limitWait = nil
            next.cause = nil
        }
        return next
    }

    static func missed(_ folder: LiveFolder, _ miss: LiveMiss, now: Date, online: Bool = true) -> LiveFolder {
        var next = folder
        next.state = .failed
        next.sso = nil
        next.read = now
        let cause = online ? miss.cause : .offline
        next.cause = cause.rawValue
        if cause == .limited {
            let wait = LiveLimit.wait(miss, previous: folder.limitWait)
            next.limitedUntil = now.addingTimeInterval(wait)
            next.limitWait = wait
        } else {
            next.limitedUntil = nil
            next.limitWait = nil
        }
        return next
    }

    private static func taken(_ folder: LiveFolder, _ given: LiveRead, now: Date, online: Bool) -> LiveFolder {
        var read = given
        var notFeeds: Int?
        var emptyFeeds: Int?
        if folder.source.kind == .feed, let feed = read.feed {
            switch feed {
            case .notFeed:
                let count = (folder.notFeeds ?? 0) + 1
                guard count >= Self.notFeeds else {
                    var next = missed(folder, LiveMiss(cause: .unread), now: now, online: online)
                    next.notFeeds = count
                    next.emptyFeeds = nil
                    return next
                }
                read.marked = true
            case .empty where !folder.items.isEmpty:
                let count = (folder.emptyFeeds ?? 0) + 1
                guard count >= Self.emptyFeeds else {
                    var next = missed(folder, LiveMiss(cause: .unread), now: now, online: online)
                    next.emptyFeeds = count
                    next.notFeeds = nil
                    return next
                }
                read.marked = true
            case .empty, .entries:
                read.marked = true
            }
        } else if read.feed == .notFeed {
            read.source = nil
        }
        if unproved(folder.items, read) { return missed(folder, LiveMiss(cause: .unread), now: now, online: online) }
        let protected = kept(folder.items, read)
        var fetched = read.items
        var present = Set(fetched.map { LiveIdentity.of($0.key) })
        var added = false
        for (index, item) in folder.items.enumerated() where protected.contains(LiveIdentity.of(item.key))
            && present.insert(LiveIdentity.of(item.key)).inserted {
            fetched.insert(item, at: min(index, fetched.count))
            added = true
        }
        if added, fetched.contains(where: { $0.branch?.stack != nil }) { fetched = LiveStacks.arranged(fetched) }
        var next = folder
        if let source = read.source { next.source = source }
        let complete = read.whole && read.missed.isEmpty && read.signedOut.isEmpty
        let cut = LiveMerge.cuts(next, fetched: fetched)
        next = LiveMerge.merged(next, fetched: fetched, now: now, complete: complete)
        next.notFeeds = notFeeds
        next.emptyFeeds = emptyFeeds
        next.more = read.more ?? (cut ? next.source.reading(at: now)?.absoluteString : complete ? nil : folder.more)
        next.noCycle = read.noCycle && next.items.isEmpty ? true : nil
        if !read.signedOut.isEmpty {
            next.state = .signIn
        } else if let first = PullList.allCases.first(where: { read.missed[$0] != nil }), let miss = read.missed[first] {
            next = missed(next, miss, now: now, online: online)
        }
        return next
    }
}
