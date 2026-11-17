import Foundation

enum LiveRefs {
    struct Known: Equatable {
        var updated: Date?
        var branch: LiveBranch?
        var signs: PullSigns.Read? = nil
        var read: Date
        var state: PullPageState? = nil
    }

    struct Page: Equatable {
        var branch: LiveBranch?
        var signs: PullSigns.Read?
        var state: PullPageState? = nil
    }

    static func page(in html: String, repository: String, number: Int? = nil) -> Page {
        Page(branch: branch(in: html, repository: repository), signs: PullSigns.page(html).map(PullSigns.read),
             state: state(in: html, number: number))
    }

    static func state(in html: String, number: Int? = nil) -> PullPageState? {
        let statuses: [String: PullPageState] = ["pullOpened": .open, "pullMerged": .merged, "pullClosed": .closed, "draft": .draft]
        let header = #"data-component="(?:PH_LeadingVisual|PageHeader[^"]*)"[^>]*>\s*<span[^>]*?data-component="StateLabel"[^>]*?data-status="([A-Za-z]+)""#
        if let said = first(header, in: html), let state = statuses[said] { return state }
        guard let number else { return nil }
        let states: [String: PullPageState] = ["OPEN": .open, "MERGED": .merged, "CLOSED": .closed]
        let after = #""number"\s*:\s*\#(number)\s*,[^{}]*?"state"\s*:\s*"(OPEN|MERGED|CLOSED)""#
        let before = #""state"\s*:\s*"(OPEN|MERGED|CLOSED)"[^{}]*?"number"\s*:\s*\#(number)\s*[,}]"#
        return (first(after, in: html) ?? first(before, in: html)).flatMap { states[$0] }
    }

    private static func first(_ pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[range])
    }

    static func signed(_ item: inout LiveItem, _ signs: PullSigns.Read?) {
        guard let signs else { return }
        item.activity = signs.activity
        item.unanswered = signs.unanswered > 0 ? signs.unanswered : nil
        item.signsRead = true
    }

    static func kept(_ item: LiveItem) -> PullSigns.Read? {
        item.signsRead == true ? PullSigns.Read(activity: item.activity, unanswered: item.unanswered ?? 0) : nil
    }

    static func due(_ known: Known, at now: Date) -> Bool {
        (known.signs?.unanswered ?? 0) > 0 && now.timeIntervalSince(known.read) >= fresh
    }

    static let width = 4
    static let budget: TimeInterval = 6
    static let fresh: TimeInterval = 600
    static let stale: TimeInterval = 1800

    @MainActor static var known: [String: Known] = [:]

    static func place(of key: String) -> (repository: String, number: Int)? {
        guard let url = URL(string: key) else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let number = Int(parts[3]) else { return nil }
        return ("\(parts[0])/\(parts[1])", number)
    }

    static func open(_ item: LiveItem) -> Bool {
        item.label != PullState.merged && item.label != PullState.closed
    }

    static func branch(in html: String, repository: String) -> LiveBranch? {
        if let base = string("baseBranch", in: html), let head = string("headBranch", in: html), !base.isEmpty, !head.isEmpty {
            let owner = string("headRepositoryOwnerLogin", in: html)
            let name = string("headRepositoryName", in: html) ?? repository.split(separator: "/").last.map(String.init)
            let from = owner.flatMap { owner in name.map { "\(owner)/\($0)" } }
            var branch = made(repository: repository, base: base, head: head, from: from)
            if let stack = stack(in: html) {
                branch.stack = stack.number
                branch.position = stack.position
            }
            return branch
        }
        return linked(html, repository: repository)
    }

    static func stack(in html: String) -> (number: Int, position: Int)? {
        guard let regex = try? NSRegularExpression(pattern: #""stack"\s*:\s*\{"#) else { return nil }
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let found = Range(match.range, in: html), let open = html[found].lastIndex(of: "{"),
                  let object = object(in: html, from: open),
                  let stack = (try? JSONSerialization.jsonObject(with: Data(object.utf8))) as? [String: Any],
                  let number = stack["number"] as? Int, let position = stack["position"] as? Int else { continue }
            return (number, position)
        }
        return nil
    }

    private static func object(in html: String, from open: String.Index) -> Substring? {
        var depth = 0
        var quoted = false
        var escaped = false
        var at = open
        while at < html.endIndex {
            let character = html[at]
            if quoted {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { quoted = false }
            } else if character == "\"" {
                quoted = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return html[open...at] }
            }
            at = html.index(after: at)
        }
        return nil
    }

    static func made(repository: String, base: String, head: String, from: String?) -> LiveBranch {
        guard let from, from.lowercased() != repository.lowercased() else {
            return LiveBranch(repository: repository, base: base, head: head, stackRead: true)
        }
        return LiveBranch(repository: repository, base: base, head: "\(from):\(head)", stackRead: true)
    }

    private static func string(_ field: String, in html: String) -> String? {
        let pattern = "\"\(field)\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\")"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(html[range].utf8), options: .fragmentsAllowed)) as? String
    }

    private static func linked(_ html: String, repository: String) -> LiveBranch? {
        guard let start = html.range(of: "wants to merge") else { return nil }
        let rest = String(html[start.upperBound...].prefix(4000))
        guard let regex = try? NSRegularExpression(pattern: #"href="/([^/"]+)/([^/"]+)/tree/([^"]+)""#) else { return nil }
        let found = regex.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)).prefix(2).compactMap { match -> (String, String)? in
            guard let owner = Range(match.range(at: 1), in: rest), let name = Range(match.range(at: 2), in: rest),
                  let branch = Range(match.range(at: 3), in: rest) else { return nil }
            let decoded = String(rest[branch]).replacingOccurrences(of: "&amp;", with: "&").removingPercentEncoding ?? String(rest[branch])
            return ("\(rest[owner])/\(rest[name])", decoded)
        }
        guard found.count == 2, found[0].0.lowercased() == repository.lowercased() else { return nil }
        return made(repository: repository, base: found[0].1, head: found[1].1, from: found[1].0)
    }

    static func current(_ known: Known, for item: LiveItem, at now: Date) -> Bool {
        if let updated = item.updated { return known.updated == updated }
        return now.timeIntervalSince(known.read) < fresh
    }

    static func young(_ read: Date?, at now: Date, within: TimeInterval) -> Bool {
        guard let read, read <= now else { return false }
        return now.timeIntervalSince(read) < within
    }

    private struct Held {
        var branch: LiveBranch?
        var signs: PullSigns.Read?
        var read: Date
        var kept: Bool
    }

    private struct Want {
        var index: Int
        var url: URL
        var repository: String
    }

    private static func line(_ repository: String, _ branch: String) -> String { "\(repository.lowercased())\u{0}\(branch)" }

    @MainActor
    static func filled(_ items: [LiveItem], previous: [LiveItem], host: String? = nil, also: String? = nil, limit: Int = .max, at now: Date = Date(), width: Int = width,
                       budget: TimeInterval = budget, again: Set<String> = [],
                       fetch: @escaping @Sendable (URL) async -> (Data, Int)?) async -> [LiveItem] {
        let before = Dictionary(previous.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var out = items
        var listed: [Want] = []
        var held: [Int: Held] = [:]
        var hard: [Int] = []
        for (index, item) in items.enumerated() where index < limit {
            guard open(item), let place = place(of: item.key), let url = URL(string: item.key),
                  host == nil || url.host() == host || also != nil && url.host() == also else { continue }
            listed.append(Want(index: index, url: url, repository: place.repository))
            if again.contains(LiveIdentity.of(item.key)) {
                hard.append(index)
            } else if let known = known[item.key] {
                if current(known, for: item, at: now), !due(known, at: now) {
                    held[index] = Held(branch: known.branch, signs: known.signs, read: known.read, kept: false)
                } else {
                    hard.append(index)
                }
            } else if let old = before[item.key], let branch = old.branch, branch.stackRead == true, let signs = kept(old),
                      let updated = item.updated, old.updated == updated, let read = old.pageRead {
                held[index] = Held(branch: branch, signs: signs, read: read, kept: true)
            } else {
                hard.append(index)
            }
        }
        func reading(_ index: Int) -> LiveBranch? {
            let key = items[index].key
            return held[index]?.branch ?? known[key]?.branch ?? before[key]?.branch
        }
        var heads: [String: Int] = [:]
        for want in listed {
            guard let branch = reading(want.index) else { continue }
            heads[line(branch.repository, branch.head)] = heads[line(branch.repository, branch.head)] ?? want.index
        }
        var chained: Set<Int> = []
        for want in listed {
            guard let branch = reading(want.index), let below = heads[line(branch.repository, branch.base)], below != want.index else { continue }
            if let stack = branch.stack, stack == reading(below)?.stack { continue }
            chained.insert(want.index)
            chained.insert(below)
        }
        var chain: [Int] = []
        var aged: [Int] = []
        for want in listed {
            guard let reused = held[want.index] else { continue }
            if !young(reused.read, at: now, within: stale) {
                aged.append(want.index)
            } else if chained.contains(want.index), !young(reused.read, at: now, within: fresh) {
                chain.append(want.index)
            }
        }
        let called = Set(hard.filter { again.contains(LiveIdentity.of(items[$0].key)) })
        let suspect = hard.filter { !called.contains($0) && chained.contains($0) }
        let plain = hard.filter { !called.contains($0) && !chained.contains($0) }
        let order = hard.filter { called.contains($0) } + suspect + plain + chain + aged
        let asked = Set(order)
        for want in listed where !asked.contains(want.index) {
            guard let reused = held[want.index] else { continue }
            let item = items[want.index]
            out[want.index].branch = reused.branch ?? out[want.index].branch
            signed(&out[want.index], reused.signs)
            out[want.index].pageRead = reused.read
            if reused.kept { known[item.key] = Known(updated: item.updated, branch: reused.branch, signs: reused.signs, read: reused.read) }
        }
        guard !order.isEmpty else { return out }
        let places = Dictionary(listed.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let began = ContinuousClock.now
        var moved: Set<String> = []
        func take(_ wants: [Want]) async -> Set<Int> {
            let found = await read(wants.map { ($0.url, $0.repository) }, width: width, budget: budget - (ContinuousClock.now - began).seconds,
                                   fetch: fetch)
            var missed: Set<Int> = []
            for want in wants {
                let item = items[want.index]
                let staleBranch = known[item.key]?.branch ?? before[item.key]?.branch
                let staleSigns = known[item.key]?.signs ?? before[item.key].flatMap(kept)
                let page = found[want.url]
                out[want.index].branch = page?.branch ?? staleBranch
                signed(&out[want.index], page?.signs ?? staleSigns)
                guard let page, page.branch != nil || page.signs != nil || page.state != nil else {
                    out[want.index].pageRead = known[item.key]?.read ?? before[item.key]?.pageRead
                    missed.insert(want.index)
                    continue
                }
                known[item.key] = Known(updated: item.updated, branch: page.branch ?? staleBranch, signs: page.signs ?? staleSigns, read: now,
                                        state: page.state)
                out[want.index].pageRead = now
                if let fresh = page.branch, let old = staleBranch, old.stackRead == true,
                   old.stack != fresh.stack || old.position != fresh.position {
                    for stack in [old.stack, fresh.stack].compactMap({ $0 }) { moved.insert(line(fresh.repository, String(stack))) }
                }
            }
            return missed
        }
        _ = await take(order.compactMap { places[$0] })
        guard !moved.isEmpty else { return out }
        let members = listed.filter { want in
            guard !asked.contains(want.index), let branch = out[want.index].branch, let stack = branch.stack else { return false }
            return moved.contains(line(branch.repository, String(stack)))
        }
        guard !members.isEmpty else { return out }
        let missed = (ContinuousClock.now - began).seconds < budget ? await take(members) : Set(members.map(\.index))
        for index in missed {
            known[items[index].key]?.read = .distantPast
            out[index].pageRead = nil
        }
        return out
    }

    static func read(_ wanted: [(URL, String)], width: Int, budget: TimeInterval,
                     fetch: @escaping @Sendable (URL) async -> (Data, Int)?) async -> [URL: Page] {
        await withTaskGroup(of: (URL, Page?)?.self) { group in
            var found: [URL: Page] = [:]
            var next = 0
            var running = 0
            group.addTask {
                try? await Task.sleep(for: .seconds(budget))
                return nil
            }
            func one(_ url: URL, _ repository: String) -> @Sendable () async -> (URL, Page?)? {
                {
                    guard let (data, status) = await fetch(url), status == 200 else { return (url, nil) }
                    return (url, page(in: String(decoding: data, as: UTF8.self), repository: repository,
                                      number: place(of: url.absoluteString)?.number))
                }
            }
            while next < wanted.count, running < max(1, width) {
                group.addTask(operation: one(wanted[next].0, wanted[next].1))
                next += 1
                running += 1
            }
            while let result = await group.next() {
                guard let (url, page) = result else { break }
                running -= 1
                if let page { found[url] = page }
                if next < wanted.count {
                    group.addTask(operation: one(wanted[next].0, wanted[next].1))
                    next += 1
                    running += 1
                } else if running == 0 {
                    break
                }
            }
            group.cancelAll()
            return found
        }
    }
}

private extension Duration {
    var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
}
