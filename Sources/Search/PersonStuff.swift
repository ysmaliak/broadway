import AppKit
import Foundation

@MainActor
enum PersonStuff {
    private static func short(_ id: UUID) -> String { PersonCommands.short(id) }

    static func stableID(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return String(String(hash, radix: 16).prefix(8))
    }

    private static func address(_ text: String?) -> String {
        text.flatMap(URL.init(string:)).map { AgentSecrets.shown($0) } ?? ""
    }

    private static func allBookmarks(_ browser: Browser) -> [(node: Bookmark, path: [String])] {
        func walk(_ nodes: [Bookmark], _ path: [String]) -> [(node: Bookmark, path: [String])] {
            nodes.flatMap { node in [(node, path)] + walk(node.children ?? [], path + [node.title]) }
        }
        return walk(browser.bookmarks.roots, [])
    }

    private static func bookmark(_ call: PersonCall, _ named: String) throws -> Bookmark {
        try PersonCommands.pick(allBookmarks(call.browser).map(\.node), id: \.id, named: named, what: "bookmark")
    }

    private static func bookmarkFolder(_ call: PersonCall, _ named: String) throws -> Bookmark {
        let folders = allBookmarks(call.browser).map(\.node).filter(\.isFolder)
        if let exact = folders.first(where: { $0.title.lowercased() == named.lowercased() }) { return exact }
        return try PersonCommands.pick(folders, id: \.id, named: named, what: "bookmark folder")
    }

    private static func row(_ node: Bookmark, _ path: [String]) -> [String: Any] {
        ["id": short(node.id), "title": node.title, "url": address(node.url), "folder": path.joined(separator: "/"), "isFolder": node.isFolder]
    }

    private static func running(_ browser: Browser, _ named: String) throws -> FetchEntry {
        try PersonCommands.pick(browser.fetches.entries, id: \.id, named: named, what: "download under way")
    }

    private static func finished(_ browser: Browser, _ named: String) throws -> Keep {
        let found = browser.loot.kept.filter { stableID($0.path).hasPrefix(named.lowercased()) }
        if found.count > 1 { throw PersonRefusal.ambiguous("id", named, found.count) }
        guard let only = found.first else { throw PersonRefusal.missing("download", named) }
        return only
    }

    private static func moment(_ text: String) throws -> Date {
        guard let unit = text.last, let amount = Double(text.dropLast()), amount > 0,
              let seconds = ["m": 60.0, "h": 3600.0, "d": 86400.0][String(unit)] else {
            throw PersonRefusal.usage("--since is a time like 30m, 2h or 7d")
        }
        return Date().addingTimeInterval(-amount * seconds)
    }

    private static func withheld(_ text: String) -> String {
        text.components(separatedBy: .newlines).map { MemoryFilter.secret(in: $0) == nil ? $0 : "(a line that looks secret is withheld)" }.joined(separator: "\n")
    }

    private static func chat(_ call: PersonCall, kind: ChatKind? = nil, excluding: ChatKind? = nil) throws -> Chat {
        ChatStore.shared.load()
        let chats = ChatStore.shared.chats.filter { (kind == nil || $0.kind == kind) && $0.kind != excluding }
        return try PersonCommands.pick(chats, id: \.id, named: try call.need("id"), what: "chat")
    }

    private static func stopped(_ call: PersonCall) throws {
        let wanted = try call.need("id").lowercased()
        if AgentSessions.shared.live.keys.contains(where: { $0.uuidString.lowercased().hasPrefix(wanted) }) {
            throw PersonRefusal("refused", "It's running. Stop it first with broadway session stop.")
        }
    }

    private static func words(_ found: Chat) -> [String: Any] {
        let lines = found.messages.map { message -> [String: Any] in
            var row: [String: Any] = ["role": message.role.rawValue, "at": PersonCommands.stamp(message.at), "text": withheld(message.text)]
            if !message.steps.isEmpty { row["steps"] = message.steps.count }
            if let failed = message.failed { row["failed"] = withheld(failed) }
            return row
        }
        let text = found.messages.map { "\($0.role == .user ? "You" : "Broadway"): \(withheld($0.text))" }.joined(separator: "\n\n")
        return ["id": short(found.id), "title": found.title, "kind": found.kind.rawValue, "website": true, "messages": lines, "text": text]
    }

    private static func live(_ call: PersonCall) throws -> LiveFolder {
        try PersonCommands.pick(LiveFolders.shared.folders, id: \.id, named: try call.need("id"), what: "Live Folder")
    }

    private static func statuses(_ call: PersonCall, in folder: LiveFolder) throws -> [LinearStatus] {
        guard folder.source.linearStatuses != nil else {
            throw PersonRefusal("refused", "\(folder.name) has no statuses to choose",
                                hint: "Only Linear folders of assigned, created or cycle issues choose their statuses")
        }
        let named = call.strings("status")
        guard !named.isEmpty else {
            throw PersonRefusal.usage("Name at least one status", hint: "Choose from triage, backlog, todo and progress")
        }
        return try named.map { word in
            guard let status = LinearStatus.named(word) else {
                throw PersonRefusal("refused", "There is no status called \(word)", hint: "Choose from triage, backlog, todo and progress")
            }
            return status
        }
    }

    private static func fetch(_ call: PersonCall, can: (FetchEntry) -> Bool, _ act: (Browser, FetchEntry) -> Void) throws -> [String: Any] {
        let entry = try running(call.browser, try call.need("id"))
        guard can(entry) else { throw PersonRefusal("refused", "That can't be done to \(entry.name) as it stands") }
        act(call.browser, entry)
        return ["id": short(entry.id), "name": entry.name, "message": "Done"]
    }

    private static func kept(_ call: PersonCall, _ what: String) async throws {
        guard let tab = call.tab?.tab, let none = await call.box.nothingKept(tab, what: what) else { return }
        throw PersonRefusal(none.code ?? ToolCode.nothingKept.rawValue, none.text ?? "", hint: none.hint)
    }

    private static func filling(_ call: PersonCall, _ work: (Tab) async -> ToolOutcome) async throws -> [String: Any] {
        let page = try call.page
        guard !page.tab.asleep, page.tab.isWeb else { throw PersonRefusal("not_a_page", "That tab isn't showing a web page") }
        guard page.tab.pageAddress == call.askedAt else { throw PersonRefusal("refused", "The page changed, so nothing was filled. Look again.") }
        let outcome = await work(page.tab)
        if outcome.failed {
            let text = outcome.text ?? "That didn't work"
            throw PersonRefusal(outcome.code ?? ToolFailure.code(text), text, hint: outcome.hint)
        }
        return ToolReply.data(outcome)
    }

    static let verbs: [PersonVerb] = [
        PersonVerb("bookmarks", "list", .look) { call in
            var found = allBookmarks(call.browser)
            if let query = call.string("query") { found = call.browser.bookmarks.matches(query) }
            if let folder = call.string("folder") {
                let inside = try bookmarkFolder(call, folder)
                found = found.filter { $0.path.last == inside.title }
            }
            return ["bookmarks": found.map { row($0.node, $0.path) }]
        },
        PersonVerb("bookmarks", "add", .arrange) { call in
            let url = try PersonTabs.webAddress(try call.need("url"))
            let folder = try call.string("folder").map { try bookmarkFolder(call, $0) }
            let bookmarks = call.browser.bookmarks
            guard let made = bookmarks.add(url, title: call.string("title") ?? url.host() ?? url.absoluteString) else {
                throw PersonRefusal("refused", "That page is already bookmarked")
            }
            if let folder { bookmarks.move(made.id, into: folder.id) }
            return ["id": short(made.id)]
        },
        PersonVerb("bookmarks", "folder", .arrange) { call in
            let parent = try call.string("in").map { try bookmarkFolder(call, $0).id }
            let made = call.browser.bookmarks.insert(Bookmark.folder(try call.need("name"), []), into: parent)
            return ["id": short(made.id)]
        },
        PersonVerb("bookmarks", "rename", .arrange) { call in
            let node = try bookmark(call, try call.need("id"))
            call.browser.bookmarks.update(node.id, title: try call.need("title"), url: nil)
            return ["id": short(node.id), "message": "Renamed"]
        },
        PersonVerb("bookmarks", "move", .arrange) { call in
            let node = try bookmark(call, try call.need("id"))
            let folder = try call.string("folder").map { try bookmarkFolder(call, $0) }
            if let folder, Bookmarks.holds(folder.id, node) { throw PersonRefusal("refused", "A folder can't go inside itself") }
            call.browser.bookmarks.move(node.id, into: folder?.id)
            return ["id": short(node.id), "message": "Moved"]
        },
        PersonVerb("bookmarks", "open", .arrange) { call in
            let node = try bookmark(call, try call.need("id"))
            guard let url = node.url.flatMap(URL.init(string:)) else { throw PersonRefusal("refused", "That is a folder") }
            let tab = call.browser.open(try PersonTabs.webAddress(url.absoluteString), foreground: false, atEnd: true)
            return ["id": short(tab.id)]
        },
        PersonVerb("bookmarks", "delete", .erase, first: { _ = try bookmark($0, try $0.need("id")) }) { call in
            let node = try bookmark(call, try call.need("id"))
            call.browser.bookmarks.remove(node.id)
            return ["id": short(node.id), "message": "Deleted"]
        },
        PersonVerb("downloads", "list", .look) { call in
            let browser = call.browser
            let going = browser.fetches.entries.map { entry -> [String: Any] in
                let state: String
                switch entry.state {
                case .downloading: state = "downloading"
                case .pausing: state = "pausing"
                case .paused: state = "paused"
                case .resuming: state = "resuming"
                case .failed: state = "failed"
                }
                return ["id": short(entry.id), "state": state, "name": entry.name, "progress": entry.fraction.map { "\(Int($0 * 100))%" } ?? "",
                        "bytes": entry.completedBytes, "total": entry.totalBytes, "error": entry.errorDescription ?? "", "path": ""]
            }
            let done = browser.loot.kept.map { keep -> [String: Any] in
                ["id": stableID(keep.path), "state": keep.stillThere ? "done" : "gone", "name": keep.name, "progress": "",
                 "from": keep.from, "date": PersonCommands.stamp(keep.date), "path": keep.path]
            }
            return ["downloads": going + done]
        },
        PersonVerb("downloads", "pause", .arrange) { call in try fetch(call, can: \.canPause) { $0.pauseDownload($1) } },
        PersonVerb("downloads", "resume", .arrange) { call in try fetch(call, can: \.canResume) { $0.resumeDownload($1) } },
        PersonVerb("downloads", "retry", .arrange) { call in try fetch(call, can: \.canRetry) { $0.retryDownload($1) } },
        PersonVerb("downloads", "cancel", .erase, first: { _ = try running($0.browser, try $0.need("id")) }) { call in try fetch(call, can: { _ in true }) { $0.cancelDownload($1) } },
        PersonVerb("downloads", "forget", .erase, first: { _ = try finished($0.browser, try $0.need("id")) }) { call in
            let keep = try finished(call.browser, try call.need("id"))
            call.browser.loot.forget(keep)
            return ["name": keep.name, "message": "Off the list. The file stays."]
        },
        PersonVerb("downloads", "clear", .erase) { call in
            let count = call.browser.loot.kept.count
            call.browser.loot.forgetAll()
            return ["forgotten": count, "message": "The list is empty. The files stay."]
        },
        PersonVerb("files", "list", .look) { call in
            let all = FileItem.merged(downloads: call.browser.loot.kept, uploads: Uploads.shared.kept)
            return ["files": FileItem.found(all, matching: call.string("query") ?? "").map {
                ["kind": $0.kind == .downloaded ? "downloaded" : "given", "name": $0.name, "site": $0.source, "path": $0.path, "date": PersonCommands.stamp($0.date)]
            }]
        },
        PersonVerb("history", "list", .tool) { call in
            var arguments: [String: Any] = [:]
            if let query = call.string("query") { arguments["query"] = query }
            if let limit = call.number("limit") { arguments["limit"] = limit }
            return try await PersonCommands.tool(call, "history", arguments)
        },
        PersonVerb("history", "delete", .erase, first: { call in
            let ways = [call.string("url"), call.string("site"), call.string("since")].compactMap { $0 }.count
            guard ways == 1 else { throw PersonRefusal.usage("Say one of: an address, --site or --since. broadway history clear clears all of it.") }
            if let since = call.string("since") { _ = try moment(since) }
        }) { call in
            let history = call.browser.history
            let before = history.everything().count
            if let text = call.string("url") {
                guard let url = Address.url(from: text) else { throw PersonRefusal("refused", "That isn't a web address") }
                history.forget(History.identity(for: url))
            } else if let host = call.string("site")?.lowercased() {
                let bare = PageIndex.bare(host)
                for trace in history.everything() {
                    guard let there = trace.url.host()?.lowercased() else { continue }
                    let site = PageIndex.bare(there)
                    if site == bare || site.hasSuffix("." + bare) { history.forget(trace.key) }
                }
                history.forget(site: host)
                call.browser.forgetVideoTraces(of: host)
            } else if let since = call.string("since") {
                let date = try moment(since)
                history.forget(since: date)
                call.browser.forgetVideoTraces(since: date)
            }
            return ["deleted": before - history.everything().count, "message": "Deleted \(before - history.everything().count)"]
        },
        PersonVerb("history", "clear", .erase) { call in
            let before = call.browser.history.everything().count
            call.browser.clearHistory()
            return ["deleted": before, "message": "History is empty"]
        },
        PersonVerb("tasks", "list", .look) { _ in
            ChatStore.shared.load()
            return ["tasks": AgentSessions.shared.list()]
        },
        PersonVerb("tasks", "show", .look) { call in words(try chat(call, kind: .task)) },
        PersonVerb("tasks", "delete", .erase, first: { try stopped($0)
            _ = try chat($0, kind: .task)
        }) { call in
            let found = try chat(call, kind: .task)
            ChatStore.shared.delete(found.id)
            return ["id": short(found.id), "message": "Deleted"]
        },
        PersonVerb("live", "list", .look) { _ in
            ["folders": LiveFolders.shared.folders.map {
                ["id": short($0.id), "name": $0.name, "state": $0.status ?? "fine", "items": $0.items.count, "fresh": $0.freshCount, "source": $0.source.address] as [String: Any]
            }]
        },
        PersonVerb("live", "show", .look) { call in
            let found = try live(call)
            var shown: [String: Any] = ["website": true, "name": found.name, "state": found.status ?? "fine", "items": found.items.map {
                ["title": $0.title, "label": $0.label ?? "", "byline": $0.byline ?? "", "checks": $0.checks?.rawValue ?? "", "url": address($0.key), "fresh": $0.fresh] as [String: Any]
            }]
            if let lists = found.source.pullLists { shown["lists"] = lists.map(\.title) }
            if let statuses = found.source.linearStatuses {
                shown["statuses"] = statuses.map(\.title)
                shown["leftOut"] = found.source.leftOut.map(\.title)
            }
            return shown
        },
        PersonVerb("live", "statuses", .arrange, first: { call in
            _ = try statuses(call, in: try live(call))
        }) { call in
            let found = try live(call)
            let chosen = try statuses(call, in: found)
            LiveFolders.shared.setStatuses(found.id, chosen)
            let left = LiveFolders.shared.folder(found.id)?.source.leftOut ?? []
            return ["id": short(found.id), "statuses": LinearStatus.ordered(chosen).map(\.title), "leftOut": left.map(\.title),
                    "message": left.isEmpty ? "Shows every open status" : "Leaves out \(LinearStatus.words(left))"]
        },
        PersonVerb("live", "add", .arrange, first: { call in
            guard call.browser.prefs.liveFolders else {
                throw PersonRefusal("refused", "Live folders are off", hint: "Turn them on with broadway settings set live.on true")
            }
        }) { call in
            guard let source = LiveSource.from(try call.need("source")) else { throw PersonRefusal("refused", "That isn't an address") }
            let space = try call.string("space").map { try PersonTabs.space(call, $0).id } ?? call.browser.spaceID
            let made = LiveFolders.shared.add(name: try call.need("name"), source: source, space: space)
            return ["id": short(made.id)]
        },
        PersonVerb("live", "rename", .arrange) { call in
            let found = try live(call)
            LiveFolders.shared.rename(found.id, to: try call.need("name"))
            return ["id": short(found.id), "message": "Renamed"]
        },
        PersonVerb("live", "pause", .arrange) { call in
            let found = try live(call)
            LiveFolders.shared.pause(found.id, true)
            return ["id": short(found.id), "message": "Paused"]
        },
        PersonVerb("live", "resume", .arrange) { call in
            let found = try live(call)
            LiveFolders.shared.pause(found.id, false)
            return ["id": short(found.id), "message": "Reading again"]
        },
        PersonVerb("live", "update", .arrange) { call in
            if call.string("id") != nil {
                LiveFolders.shared.update(try live(call).id)
            } else {
                LiveFolders.shared.updateAll()
            }
            return ["message": "Reading now"]
        },
        PersonVerb("live", "delete", .erase, first: { _ = try live($0) }) { call in
            let found = try live(call)
            LiveFolders.shared.remove(found.id)
            return ["id": short(found.id), "message": "Deleted"]
        },
        PersonVerb("logins", "list", .look) { call in
            var kept = Vault.all()
            if let site = call.string("site")?.lowercased() { kept = kept.filter { $0.host.lowercased().contains(site) } }
            return ["logins": kept.map { ["site": $0.host, "user": $0.user, "used": PersonCommands.stamp($0.used)] }]
        },
        PersonVerb("fill", "login", .person(.signIn), tabbed: true) { call in
            let account = call.string("account")
            return try await filling(call) { await call.box.signIn($0, account: account, task: nil, asked: true) }
        },
        PersonVerb("fill", "details", .person(.address), tabbed: true, first: { try await kept($0, "details") }) { call in
            try await filling(call) { await call.box.autofill($0, what: "details", task: nil, asked: true) }
        },
        PersonVerb("fill", "card", .person(.address), tabbed: true, first: { try await kept($0, "card") }) { call in
            try await filling(call) { await call.box.autofill($0, what: "card", task: nil, asked: true) }
        },
    ]
}
