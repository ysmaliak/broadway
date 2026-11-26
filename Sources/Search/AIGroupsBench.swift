import Foundation

@MainActor
enum AIGroupsBench {
    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "aigroups only works on a --test run"]); return }
        let args = request["args"] as? [String] ?? []
        let settings = AIGroups.shared
        switch args.first {
        case "fake":
            settings.standIn = FakeGroupEngine()
            if args.count > 1, let quiet = Double(args[1]) { settings.quiet = quiet }
            if args.count > 2, let gap = Double(args[2]) { settings.gap = gap }
        case "openrouter":
            guard let key = request["key"] as? String, !key.isEmpty else { answer(["error": "aigroups openrouter MODEL needs a key"]); return }
            let model = args.dropFirst().first ?? OpenRouterModels.naming
            let base = (request["base"] as? String).flatMap(URL.init(string:))
            settings.standIn = nil
            let effort = request["effort"] as? String ?? OpenRouterModels.namingEffort
            settings.namerStandIn = OpenRouterNamer(key: key, model: model, effort: effort.isEmpty ? OpenRouterModels.namingEffort : effort,
                                                    client: OpenRouterClient(base: base, seconds: 30))
        case "key":
            let keys = OpenRouterKey.shared
            switch args.dropFirst().first {
            case "save":
                Task {
                    let saved = await keys.save(request["key"] as? String ?? "")
                    answer(["saved": saved, "present": keys.present, "trouble": keys.trouble ?? ""])
                }
                return
            case "remove":
                keys.remove()
            case "fail":
                keys.failed(.noCredit)
            default:
                break
            }
            answer(["present": keys.present, "trouble": keys.trouble ?? "", "checking": keys.state == .checking])
            return
        case "mac":
            settings.standIn = nil
            settings.namerStandIn = nil
        case "jev":
            guard let bench = OpenRouterBench(request) else { answer(["error": "aigroups jev needs a key"]); return }
            settings.standIn = bench
            answer(bench.said); return
        case "folder-fake":
            let fake = FakeGroupEngine()
            fake.delay = args.dropFirst().first.flatMap(Double.init) ?? 0
            fake.failing = args.dropFirst(2).first == "fail"
            FolderEmojis.shared.standIn = fake
        case "folder-unavailable":
            FolderEmojis.shared.standIn = nil
        case "on", "off":
            settings.on = args[0] == "on"
        case "emoji":
            settings.emoji = args.dropFirst().first != "off"
        case "rename", "ungroup":
            guard args.count >= 2, let group = browser.tabGroups.first(where: { $0.name == args[1] }) else {
                answer(["error": "aigroups rename NAME NEW | ungroup NAME"]); return
            }
            if args[0] == "rename", args.count == 3 {
                browser.renameTabGroup(group.id, to: args[2])
            } else {
                browser.removeTabGroup(group.id)
            }
        case "hold", "release":
            guard args.count >= 2, let index = browser.tabGroups.firstIndex(where: { $0.name == args[1] || $0.id.uuidString == args[1] }) else {
                answer(["error": "aigroups hold NAME [free] | release NAME [NEW [EMOJI]]"]); return
            }
            let id = browser.tabGroups[index].id
            if args[0] == "hold" {
                settings.veil(id, held: args.dropFirst(2).first != "free")
            } else {
                if args.count >= 3 {
                    browser.tabGroups[index].name = args[2]
                    if args.count >= 4 {
                        browser.tabGroups[index].icon = TabIcon(emoji: args[3])
                        browser.tabGroups[index].aiEmoji = args[3]
                    }
                }
                settings.unveil(id)
            }
        case "stop":
            guard args.count == 2, let seconds = Double(args[1]) else { answer(["error": "aigroups stop SECONDS"]); return }
            settings.stop = seconds
        case "trial":
            guard let plan = request["trial"] as? [String: Any] else { answer(["error": "aigroups trial needs a trial"]); return }
            Task { answer(await trial(plan, browser: browser)) }
            return
        case "name":
            guard let listed = request["tabs"] as? [[String: Any]] else { answer(["error": "aigroups name needs tabs"]); return }
            let tabs = listed.compactMap {
                AIGroupTab(id: UUID(), title: $0["title"] as? String ?? "", url: URL(string: $0["url"] as? String ?? ""), by: $0["by"] as? String ?? "")
            }
            Task {
                AIGroupTrace.begin()
                let grouper = settings.grouper(for: browser)
                let current = (request["current"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let query = (request["query"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let ask = AIGroupNameAsk(tabs: tabs, current: current, currentEmoji: request["currentEmoji"] as? String,
                                         emoji: settings.emoji, query: query)
                let remote = settings.namerStandIn as? OpenRouterNamer
                let before = remote?.spent ?? 0
                let started = Date()
                let said = await grouper.renamed(settings.namerEngine(), ask)
                let seconds = Date().timeIntervalSince(started)
                answer(["name": said.name?.name ?? current ?? "", "emoji": said.name?.emoji ?? (said.name == nil ? ask.currentEmoji ?? "" : ""),
                        "how": said.how, "cost": (remote?.spent ?? 0) - before, "seconds": seconds, "trace": AIGroupTrace.end()])
            }
            return
        case "ask":
            guard CLIGuard.realAllowed, MacGroupEngine.available else { answer(["error": "aigroups ask needs SEARCH_REAL_MODEL=1 and This Mac's model"]); return }
            let instructions = request["instructions"] as? String ?? ""
            let prompt = request["prompt"] as? String ?? ""
            let fields = request["fields"] as? [[String: Any]] ?? []
            Task {
                do {
                    answer(["said": try await MacGroupEngine.probe(instructions: instructions, prompt: prompt, fields: fields,
                                                                   most: request["most"] as? Int ?? 200)])
                } catch {
                    answer(["error": error.localizedDescription])
                }
            }
            return
        case "regroup":
            Task {
                let outcome = await settings.grouper(for: browser).regroup()
                answer(["joined": outcome.joined, "formed": outcome.formed, "renamed": outcome.renamed, "note": settings.note ?? ""])
            }
            return
        case "state", nil:
            break
        default:
            answer(["error": "aigroups fake [QUIET GAP] | mac | trial | name | on | off | emoji on|off | rename NAME NEW | ungroup NAME | hold NAME [free] | release NAME [NEW [EMOJI]] | stop SECONDS | regroup | state"])
            return
        }
        let grouper = settings.grouper(for: browser)
        answer(["on": settings.active(browser), "engine": settings.deciding?.rawValue ?? "", "namer": settings.naming?.rawValue ?? "",
                "namerModel": (settings.namerStandIn as? OpenRouterNamer)?.model ?? "", "keySaved": OpenRouterKey.shared.present,
                "passes": grouper.passes, "busy": grouper.busy, "folderEmojiBusy": FolderEmojis.shared.busy,
                "note": settings.note ?? "", "nameAsks": grouper.nameAsks,
                "groups": browser.tabGroups.map { group in
                    ["id": group.id.uuidString, "name": group.name, "ai": group.ai, "emoji": group.icon?.emoji ?? "",
                     "userNamed": group.userNamed, "refused": group.aiRefused, "query": group.query ?? "",
                     "how": grouper.how[group.id] ?? "", "veiled": settings.veils(group, in: browser),
                     "tabs": browser.tabs.filter { $0.groupID == group.id }.map { Bench.short($0) }] as [String: Any]
                }])
    }

    private static var seeded: Set<UUID> = []

    private static func idle(_ grouper: AIGrouper, within seconds: Double) async {
        let until = Date().addingTimeInterval(seconds)
        var quiet = 0
        while Date() < until, quiet < 4 {
            try? await Task.sleep(for: .milliseconds(100))
            quiet = grouper.busy || !(grouper.pending[grouper.browser?.spaceID ?? UUID()] ?? [:]).isEmpty ? 0 : quiet + 1
        }
    }

    static func trial(_ plan: [String: Any], browser: Browser) async -> [String: Any] {
        let settings = AIGroups.shared
        let started = Date()
        for tab in browser.tabs where seeded.contains(tab.id) { tab.groupID = nil }
        browser.tabGroups.removeAll()
        for tab in browser.tabs.filter({ seeded.contains($0.id) }) { browser.close(tab) }
        seeded = []
        settings.forget(browser)
        MacGroupEngine.forget()
        settings.told(nil)
        settings.quiet = plan["quiet"] as? Double ?? 0.05
        settings.gap = plan["gap"] as? Double ?? 0
        let grouper = settings.grouper(for: browser)
        var keys: [UUID: String] = [:]
        var made: [String: Tab] = [:]
        var homes: [String: UUID] = [:]
        let listed = plan["tabs"] as? [[String: Any]] ?? []
        func seed(_ key: String) -> Tab? {
            if let found = made[key] { return found }
            guard let entry = listed.first(where: { $0["key"] as? String == key }), let url = URL(string: entry["url"] as? String ?? "") else { return nil }
            let tab = browser.makeTab()
            browser.prepare(tab)
            tab.restore(url: url, title: entry["title"] as? String ?? "")
            tab.cameBack = false
            if let by = entry["by"] as? String, !by.isEmpty { tab.madeBy = (url, by) }
            browser.insert(tab, at: browser.tabs.count)
            if let home = entry["born"] as? String, let id = homes[home] {
                tab.groupID = id
                tab.bornIn = id
                browser.arrangeGroupedTabs()
            }
            seeded.insert(tab.id)
            keys[tab.id] = key
            made[key] = tab
            return tab
        }
        for folder in plan["folders"] as? [[String: Any]] ?? [] {
            var group = TabGroup(id: UUID(), name: folder["name"] as? String ?? "Folder", collapsed: false)
            group.ai = folder["ai"] as? Bool ?? true
            group.userNamed = folder["userNamed"] as? Bool ?? false
            group.pinned = false
            if let mark = folder["emoji"] as? String {
                group.icon = TabIcon(emoji: mark)
                group.aiEmoji = mark
            }
            browser.tabGroups.append(group)
            homes[group.name] = group.id
            for key in folder["keys"] as? [String] ?? [] { seed(key)?.groupID = group.id }
        }
        browser.arrangeGroupedTabs()
        grouper.membershipChanged()
        await idle(grouper, within: 5)
        AIGroupTrace.begin()
        for batch in plan["batches"] as? [[String]] ?? [] {
            for key in batch {
                guard let tab = seed(key) else { continue }
                grouper.landed(tab)
            }
            await idle(grouper, within: plan["wait"] as? Double ?? 180)
        }
        let trace = AIGroupTrace.end()
        var loose: [String] = []
        for tab in browser.tabs where seeded.contains(tab.id) && tab.groupID == nil { loose.append(keys[tab.id] ?? "?") }
        return ["seconds": Date().timeIntervalSince(started), "note": settings.note ?? "", "loose": loose, "trace": trace,
                "passes": grouper.passes, "nameAsks": grouper.nameAsks,
                "groups": browser.tabGroups.map { group in
                    ["name": group.name, "emoji": group.icon?.emoji ?? "", "ai": group.ai, "userNamed": group.userNamed,
                     "how": grouper.how[group.id] ?? "",
                     "keys": browser.tabs.filter { $0.groupID == group.id }.map { keys[$0.id] ?? "?" }] as [String: Any]
                }]
    }
}
