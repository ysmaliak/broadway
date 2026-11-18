import AppKit
import Foundation

@MainActor
enum TabsBench {
    static func run(_ verb: String, _ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "\(verb) only works on a --test run"]); return }
        let args = request["args"] as? [String] ?? []
        switch verb {
        case "folders": folders(args, browser: browser, answer)
        case "searchfolder": searchFolder(args, browser: browser, answer)
        case "live": live(args, browser: browser, answer)
        case "route": route(args, browser: browser, answer)
        case "card": card(args, browser: browser, answer)
        case "icon": icon(args, browser: browser, answer)
        default: answer(["error": "unknown command “\(verb)”"])
        }
    }

    static func tab(_ id: String, in browser: Browser) -> Tab? {
        browser.tabs.first { Bench.short($0) == id }
    }

    private static func folder(_ name: String, in browser: Browser) -> TabGroup? {
        browser.tabGroups.first { $0.name == name }
    }

    private static func icon(_ args: [String], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        func word(_ icon: TabIcon?) -> String { icon?.emoji ?? icon?.symbol ?? "" }
        func target(_ kind: String, _ name: String) -> IconPicker.Target? {
            if kind == "tab" { return tab(name, in: browser).map { .tab($0.id) } }
            if kind == "space" {
                return Int(name).flatMap { browser.spaces.indices.contains($0 - 1) ? .space(browser.spaces[$0 - 1].id) : nil }
            }
            return browser.tabGroups.first { $0.name == name }.map { .folder($0.id) }
        }
        switch args.first {
        case "set":
            guard args.count == 5, let aim = target(args[1], args[2]) else { answer(["error": "icon set tab ID|folder NAME|space N emoji|symbol VALUE"]); return }
            browser.setIcon(args[3] == "emoji" ? TabIcon(emoji: args[4]) : TabIcon(symbol: args[4]), of: aim)
        case "clear":
            guard args.count == 3, let aim = target(args[1], args[2]) else { answer(["error": "icon clear tab ID|folder NAME"]); return }
            browser.setIcon(nil, of: aim)
        case "pick":
            guard args.count == 3, let aim = target(args[1], args[2]) else { answer(["error": "icon pick tab ID|folder NAME"]); return }
            browser.iconPicker.pick(aim)
        case "find":
            browser.iconPicker.query = args.dropFirst().joined(separator: " ")
        case "close":
            browser.iconPicker.close()
        default:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            answer(["tabs": browser.tabs.filter { $0.customIcon != nil }.map { [Bench.short($0), word($0.customIcon), $0.pin == nil ? "tab" : "pin"] },
                    "folders": browser.tabGroups.filter { $0.icon != nil }.map { [$0.name, word($0.icon)] },
                    "spaces": browser.spaces.map { [$0.name, word($0.shownIcon)] },
                    "picking": browser.iconPicker.target != nil, "query": browser.iconPicker.query])
        }
    }

    private static func card(_ args: [String], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let cards = browser.hoverCards
        let frame = CGRect(x: 10, y: 120, width: 220, height: 34)
        func state() -> [String: Any] {
            var kind = ""
            if case .tab? = cards.kind { kind = "tab" }
            if case .folder? = cards.kind { kind = "folder" }
            return ["kind": kind, "popup": KitPopup.current(in: browser.window) != nil, "picture": cards.picture != nil, "title": cards.title,
                    "frame": [cards.frame.minX, cards.frame.minY, cards.frame.maxX, cards.frame.maxY], "query": cards.query, "selection": cards.selection,
                    "entries": cards.entries.map(\.words), "active": browser.active?.label ?? ""]
        }
        switch args.first {
        case "tab":
            guard args.count == 2, let page = tab(args[1], in: browser) else { answer(["error": "card tab ID"]); return }
            cards.enter(.tab(page.id), frame: frame)
            cards.show(.tab(page.id))
        case "folder":
            guard args.count == 2, let group = browser.tabGroups.first(where: { $0.name == args[1] }) else { answer(["error": "card folder NAME"]); return }
            cards.enter(.folder(group.id), frame: frame)
            cards.show(.folder(group.id))
        case "type":
            guard args.count == 2 else { answer(["error": "card type TEXT"]); return }
            cards.press(.text(args[1]))
        case "key":
            let keys: [String: HoverCards.Key] = ["up": .up, "down": .down, "left": .left, "right": .right, "enter": .enter, "escape": .escape, "delete": .delete]
            guard args.count == 2, let key = keys[args[1]] else { answer(["error": "card key up|down|left|right|enter|escape|delete"]); return }
            cards.press(key)
        case "hover":
            guard args.count == 2, let page = tab(args[1], in: browser), let row = Bench.hoverRows[page.id] else { answer(["error": "card hover ID, on a row in the column"]); return }
            Bench.bodies = [:]
            let dwell = HoverCards.dwell
            HoverCards.dwell = 0.3
            row(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                var seen = state()
                seen["bodies"] = Bench.bodies
                row(false)
                HoverCards.dwell = dwell
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    seen["after"] = state()["kind"]
                    answer(seen)
                }
            }
            return
        case "plain":
            guard Store.testing else { answer(["error": "card plain is for test runs"]); return }
            cards.plainGround = args.dropFirst().first != "off"
        case "off":
            cards.dismiss()
        default:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(state()) }
    }

    private static func route(_ args: [String], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let store = LinkRules.shared
        let usage = "route add SITE space NAME|window [N]|peek|ask | pattern TEXT space NAME | rule KIND TEXT anywhere|apps|broadway|app:BUNDLE:NAME TARGET | remove SITE | clear | default front|ask|space NAME | decide URL [alt] | arrive URL [BUNDLE NAME] [alt]"
        func target(_ rest: ArraySlice<String>) -> LinkRule.Target? {
            switch rest.first {
            case "space":
                guard rest.count == 2, let space = browser.spaces.first(where: { $0.name == rest.last }) else { return nil }
                return .space(space.id, folder: nil)
            case "window":
                let chosen = rest.count == 2 ? Int(rest.last ?? "").flatMap { Browsers.all.indices.contains($0 - 1) ? Browsers.all[$0 - 1].record.id : nil } : nil
                return .window(chosen)
            case "app":
                let said = Array(rest)
                guard said.count == 3 else { return nil }
                return .app(bundleID: said[1], name: said[2])
            case "peek": return .peek
            case "ask": return .ask
            case "front": return .frontSpace
            case "open": return .whereOpen
            default: return nil
            }
        }
        var extra: [String: Any] = [:]
        switch args.first {
        case "add":
            guard args.count >= 3, let site = LinkRouter.site(typed: args[1]), let to = target(args.dropFirst(2)) else { answer(["error": usage]); return }
            store.always(site, to: to)
        case "pattern":
            guard args.count >= 3, let to = target(args.dropFirst(2)) else { answer(["error": usage]); return }
            store.add(LinkRule(match: .pattern(args[1]), target: to))
        case "rule":
            guard args.count >= 5, let kind = LinkRule.Match.Kind(rawValue: args[1]), let to = target(args.dropFirst(4)) else { answer(["error": usage]); return }
            let said = args[3].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let from: LinkRule.From = switch said.first {
            case "apps": .otherApps
            case "broadway": .insideBroadway
            case "app" where said.count == 3: .app(bundleID: said[1], name: said[2])
            default: .anywhere
            }
            store.add(LinkRule(match: .make(kind, args[2]), from: from, target: to))
        case "remove":
            guard args.count == 2 else { answer(["error": usage]); return }
            store.forget(args[1])
        case "clear":
            store.replaceAll([])
        case "default":
            switch args.dropFirst().first {
            case "ask": store.set { $0.outsideDefault = .ask }
            case "space":
                guard let space = browser.spaces.first(where: { $0.name == args.last }) else { answer(["error": "no space"]); return }
                store.set { $0.outsideDefault = .space(space.id) }
            default: store.set { $0.outsideDefault = .front }
            }
        case "decide":
            guard args.count >= 2, let url = URL(string: args[1]) else { answer(["error": usage]); return }
            let (decision, _) = Browsers.decide(IncomingLink(url: url, source: .unknownApp, chooses: args.dropFirst(2).contains("alt")), from: browser)
            extra = ["steps": decision.steps, "url": decision.url.absoluteString]
        case "arrive":
            guard args.count >= 2, let url = URL(string: args[1]) else { answer(["error": usage]); return }
            let source: IncomingLink.Source = args.count >= 4 ? .app(bundleID: args[2], name: args[3]) : .unknownApp
            Links.arrived(url, from: source, chooses: args.last == "alt")
        default:
            break
        }
        answer(["routes": store.rules.map { ["site": LinkRouter.words($0.match), "to": LinkRouter.words($0.target, world: Browsers.linkWorld(from: browser))] },
                "suggested": store.suggestions(for: browser).map(\.site),
                "recent": store.recent.map { ["site": $0.site, "from": $0.from, "went": $0.went] },
                "notice": browser.linkNotice?.text ?? "",
                "chooser": LinkChooser.shown?.rows.map(\.title) ?? [],
                "chooserLit": LinkChooser.shown?.choosing.lit ?? -1,
                "chooserLitShown": LinkChooser.shown?.litShown ?? true,
                "peek": browser.peekTab?.address?.absoluteString ?? ""].merging(extra) { $1 })
    }

    private static func live(_ args: [String], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let live = LiveFolders.shared
        func stacks(_ id: UUID) -> [[String: Any]] {
            guard let group = browser.tabGroups.first(where: { $0.id == id }) else { return [] }
            return browser.stackTops(in: group).map { ["id": String($0.key.uuidString.prefix(8)).lowercased(), "folded": $0.value] }
        }
        func state() -> [String: Any] {
            ["on": browser.prefs.liveFolders, "folders": live.folders.map { folder in
                ["name": folder.name, "kind": folder.source.kind.rawValue, "address": folder.source.address,
                 "space": browser.spaces.first { $0.id == folder.space }?.name ?? "",
                 "state": folder.state.rawValue, "paused": folder.paused, "hidden": folder.hidden.count,
                 "status": folder.status ?? "", "sso": folder.sso?.url ?? "", "ssoOrg": folder.sso?.org ?? "",
                 "note": folder.note.map { "\($0)" } ?? "", "lists": folder.source.pullLists?.map(\.rawValue) ?? [],
                 "statuses": folder.source.linearStatuses?.map(\.rawValue) ?? [], "empty": folder.source.emptyWording,
                 "items": folder.items.map { ["title": $0.title, "label": $0.label ?? "", "byline": $0.byline ?? "",
                                              "checks": $0.checks?.rawValue ?? "", "list": $0.list?.rawValue ?? "", "url": $0.key,
                                              "fresh": $0.fresh, "merging": live.turning($0.key), "claimed": live.claimedRow($0.key), "draft": $0.draft == true,
                                              "unanswered": $0.unanswered ?? 0, "signsRead": $0.signsRead == true] as [String: Any] },
                 "fresh": folder.freshCount,
                 "age": LiveAge.words(folder, at: Date()) ?? "", "cause": folder.cause ?? "", "more": folder.more ?? "",
                 "failure": folder.state == .failed ? LiveWords.failure(folder, now: Date()) : "",
                 "good": folder.good.map { $0.timeIntervalSince1970 } ?? 0, "lost": live.lost,
                 "order": folder.order ?? [],
                 "stacks": stacks(folder.id),
                 "tabs": browser.tabs(in: folder.id).map { ["id": Bench.short($0), "label": $0.label, "key": $0.liveKey ?? "", "badge": $0.liveItem?.label ?? "", "asleep": $0.asleep, "fresh": $0.liveItem?.fresh == true,
                                                          "unanswered": $0.liveItem?.unanswered ?? 0] as [String: Any] }] as [String: Any]
            }, "now": IntegrationNow.rows(from: live.folders).map { [$0.title, $0.detail, $0.id] },
             "suggested": Dictionary(browser.spaces.map { space in
                 (space.name, LiveSuggestions.now(for: browser, space: space.id).map { [$0.title, $0.line] })
             }) { first, _ in first },
             "space": browser.spaces.first { $0.id == browser.spaceID }?.name ?? ""]
        }
        switch args.first {
        case "offer":
            LiveOffers.shared.bench(Array(args.dropFirst()), browser: browser, answer)
            return
        case "on": browser.prefs.liveFolders = true
        case "off": browser.prefs.liveFolders = false
        case "add":
            guard args.count == 3, let source = LiveSource.from(args[2]) else { answer(["error": "live add NAME SOURCE"]); return }
            live.add(name: args[1], source: source, space: browser.spaceID)
        case "add-page":
            guard args.count == 4, let kind = LiveSource.Kind(rawValue: args[2]) else { answer(["error": "live add-page NAME KIND URL"]); return }
            live.add(name: args[1], source: LiveSource(kind: kind, address: args[3]), space: browser.spaceID)
        case "linear-cookie", "github-cookie":
            guard Store.testing, args.count == 2 else { answer(["error": "live linear-cookie|github-cookie VALUE|-, test runs only"]); return }
            let store = Spaces.store(for: browser.spaceID).httpCookieStore
            let site = args[0] == "linear-cookie" ? "linear.app" : "github.com"
            let name = args[0] == "linear-cookie" ? "session" : "user_session"
            Task { @MainActor in
                for cookie in await store.allCookies() where cookie.domain.lowercased().hasSuffix(site) {
                    await store.deleteCookie(cookie)
                }
                if args[1] != "-", let cookie = HTTPCookie(properties: [.domain: "." + site, .path: "/", .name: name,
                                                                        .value: args[1], .secure: "TRUE"]) {
                    await store.setCookie(cookie)
                }
                answer(state())
            }
            return
        case "lists":
            guard args.count == 3, let folder = live.folders.first(where: { $0.name == args[1] }) else {
                answer(["error": "live lists NAME LIST,LIST"]); return
            }
            let lists = args[2].split(separator: ",").compactMap { PullList.named(String($0)) }
            live.setLists(folder.id, lists)
        case "statuses":
            guard args.count == 3, let folder = live.folders.first(where: { $0.name == args[1] }) else {
                answer(["error": "live statuses NAME STATUS,STATUS"]); return
            }
            live.setStatuses(folder.id, args[2].split(separator: ",").compactMap { LinearStatus.named(String($0)) })
        case "force":
            guard Store.testing, args.count == 3, let folder = live.folders.first(where: { $0.name == args[1] }) else {
                answer(["error": "live force NAME waiting|fine|signIn|sso|failed, test runs only"]); return
            }
            switch args[2] {
            case "fine": live.apply(.items([], nil), to: folder.id)
            case "signIn": live.apply(.signIn, to: folder.id)
            case "sso": live.apply(.sso(LiveSSO(org: "Acme", url: "https://github.com/orgs/acme/sso?return_to=%2Fpulls"), []), to: folder.id)
            case "failed": live.apply(.failed, to: folder.id)
            case "waiting": live.forget(folder.id)
            case "offline": live.apply(.missed(LiveMiss(cause: .offline)), to: folder.id)
            case "limited": live.apply(.missed(LiveMiss(cause: .limited, wait: 600)), to: folder.id)
            case "unread": live.apply(.missed(LiveMiss(cause: .unread)), to: folder.id)
            case "old": live.apply(.items(folder.items, nil), to: folder.id, now: Date().addingTimeInterval(-3 * 3600))
            case "more":
                live.apply(.read(LiveRead(items: folder.items, marked: true, more: folder.source.address)), to: folder.id)
            case "rows":
                let rows = [(41, "Cache the build graph", "dana"), (52, "Retry uploads on 502", "lee"), (57, "Teach the rocket to count", "sam")]
                live.apply(.items(rows.map { number, title, author in
                    LiveItem(key: "https://github.com/acme/rocket/pull/\(number)", title: title, author: author, list: .created)
                }, nil), to: folder.id)
            default: answer(["error": "live force NAME waiting|fine|signIn|failed|offline|limited|unread|old|more|rows"]); return
            }
            browser.syncLive()
        case "unfold":
            guard let name = args.dropFirst().first, let folder = live.folders.first(where: { $0.name == name }) else {
                answer(["error": "no live folder"]); return
            }
            browser.unfoldFolder(folder.id)
        case "fold":
            guard let name = args.dropFirst().first, let folder = live.folders.first(where: { $0.name == name }),
                  let index = browser.tabGroups.firstIndex(where: { $0.id == folder.id }) else {
                answer(["error": "no live folder"]); return
            }
            browser.tabGroups[index].collapsed = true
        case "heading":
            guard let name = args.dropFirst().first, let folder = live.folders.first(where: { $0.name == name }) else {
                answer(["error": "no live folder"]); return
            }
            let headings = browser.window?.contentView?.kitSubviews(of: GroupHeadingView.self) ?? []
            guard let heading = headings.first(where: { $0.group?.id == folder.id && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }) else {
                answer(["error": "no heading on screen"]); return
            }
            heading.layoutSubtreeIfNeeded()
            let pill = (heading.status as? LiveStatusView)?.pill
            let frame = pill.map { heading.convert($0.bounds, from: $0) } ?? .zero
            let bar = (heading.status as? LiveStatusView)?.loading
            let barFrame = bar.map { heading.convert($0.bounds, from: $0) } ?? .zero
            answer(["width": heading.bounds.width, "pill": pill != nil && !pill!.isHiddenOrHasHiddenAncestor,
                    "title": pill?.title ?? "", "label": pill?.accessibilityLabel() ?? "", "tip": pill?.toolTip ?? "",
                    "pillFrame": [frame.minX, frame.minY, frame.width, frame.height],
                    "loading": bar != nil && !bar!.isHiddenOrHasHiddenAncestor && barFrame.width > 0,
                    "loadingFrame": [barFrame.minX, barFrame.minY, barFrame.width, barFrame.height],
                    "spoken": (heading.status as? LiveStatusView)?.accessibilityLabel() ?? "",
                    "nameEnd": heading.nameHost.frame.maxX, "chip": heading.showsCount, "count": heading.count])
            return
        case "sign-in":
            guard let name = args.dropFirst().first, let folder = live.folders.first(where: { $0.name == name }) else {
                answer(["error": "no live folder"]); return
            }
            browser.signInToLive(folder.id)
        case "stack":
            func chevrons(_ view: NSView) -> [StackFoldButton] {
                view.subviews.flatMap { ($0 as? StackFoldButton).map { [$0] } ?? chevrons($0) }
            }
            let shown = browser.window?.contentView.map(chevrons)?.filter { !$0.isHiddenOrHasHiddenAncestor } ?? []
            guard let chevron = shown.first else { answer(["error": "no stack chevron on screen"]); return }
            let pressed = chevron.accessibilityPerformPress()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                var out = state()
                out["pressed"] = pressed
                out["label"] = chevron.accessibilityLabel() ?? ""
                out["chevrons"] = shown.count
                answer(out)
            }
            return
        case "now":
            answer(["rows": browser.nowRows().map { [$0.key, $0.title, $0.url.absoluteString] }])
            return
        case "menu":
            answer(["items": LiveMenu.menu(for: browser).items.map(\.title)])
            return
        case "update":
            guard let name = args.dropFirst().first, let folder = live.folders.first(where: { $0.name == name }) else {
                answer(["error": "no live folder"]); return
            }
            live.update(folder.id)
            Task { @MainActor in
                while live.reading.contains(folder.id) { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(200))
                answer(state())
            }
            return
        case "merged":
            guard args.count == 2, let url = tab(args[1], in: browser)?.liveKey.flatMap(URL.init(string:)) ?? URL(string: args[1]),
                  PullPageRelay.pull(url) else {
                answer(["error": "live merged ID|URL, a pull request row"]); return
            }
            live.pageMerged(url, space: browser.spaceID)
            browser.syncLive()
        case "page":
            guard args.count == 3, let said = PullPageState(rawValue: args[1]),
                  let url = tab(args[2], in: browser)?.liveKey.flatMap(URL.init(string:)) ?? URL(string: args[2]), PullPageRelay.pull(url) else {
                answer(["error": "live page draft|open|merged|closed ID|URL, a pull request row"]); return
            }
            live.pageSays(said, at: url, space: browser.spaceID)
            browser.syncLive()
        case "seen":
            guard args.count == 2, let url = URL(string: args[1]) else { answer(["error": "live seen URL"]); return }
            live.landed(url, space: browser.spaceID)
        case "hide":
            guard args.count == 2, let page = tab(args[1], in: browser) else { answer(["error": "live hide ID"]); return }
            browser.close(page)
        case "remove":
            guard let name = args.dropFirst().first, let folder = live.folders.first(where: { $0.name == name }) else {
                answer(["error": "no live folder"]); return
            }
            live.remove(folder.id)
        default:
            break
        }
        DispatchQueue.main.async { answer(state()) }
    }

    private static func searchFolder(_ args: [String], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        func state() -> [String: Any] {
            ["folders": browser.tabGroups.map { group in
                ["name": group.name, "query": group.query ?? "", "tabs": browser.tabs(in: group.id).map(\.label)] as [String: Any]
            }]
        }
        switch args.first {
        case "click":
            guard args.count == 3, let source = tab(args[1], in: browser), let url = URL(string: args[2]) else {
                answer(["error": "searchfolder click SOURCE URL"]); return
            }
            let opened = browser.open(url, foreground: false, from: source, mayWait: true, link: true)
            browser.fileSearchResult(opened, from: source)
        case "filter":
            browser.folderFromSearch(args.dropFirst().joined(separator: " "))
        case "ungroup":
            guard let found = args.dropFirst().first.flatMap({ folder($0, in: browser) }) else { answer(["error": "no folder"]); return }
            browser.removeTabGroup(found.id)
        default:
            break
        }
        answer(state())
    }

    private static func folders(_ args: [String], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        func state() -> [String: Any] {
            ["rows": browser.folderRows.map { row in
                ["name": row.group.name, "depth": row.depth, "kind": row.kind == .heading ? "heading" : "tabs",
                 "collapsed": row.group.collapsed,
                 "tabs": row.kind == .tabs ? browser.visibleTabs(in: row.group).map(Bench.short) : []] as [String: Any]
            }, "order": browser.tabs.map(Bench.short)]
        }
        guard let action = args.first else { answer(state()); return }
        let rest = Array(args.dropFirst())
        switch action {
        case "new":
            guard let name = rest.first else { answer(["error": "folders new NAME [PARENT]"]); return }
            browser.newFolder(inside: rest.dropFirst().first.flatMap { folder($0, in: browser)?.id }, named: name, editing: false)
        case "with":
            guard let name = rest.first else { answer(["error": "folders with NAME ID…"]); return }
            browser.newFolder(with: rest.dropFirst().compactMap { tab($0, in: browser) }, named: name, editing: false)
        case "nest":
            guard rest.count == 2, let child = folder(rest[0], in: browser) else { answer(["error": "folders nest NAME PARENT|top"]); return }
            browser.nest(child.id, in: rest[1] == "top" ? nil : folder(rest[1], in: browser)?.id)
        case "whole":
            guard let found = rest.first.flatMap({ folder($0, in: browser) }) else { answer(["error": "no folder"]); return }
            browser.toggleFolderWhole(found.id)
        case "sleep":
            guard let found = rest.first.flatMap({ folder($0, in: browser) }) else { answer(["error": "no folder"]); return }
            browser.sleepFolder(found.id)
        case "remove":
            guard let found = rest.first.flatMap({ folder($0, in: browser) }) else { answer(["error": "no folder"]); return }
            browser.removeTabGroup(found.id)
        case "level":
            guard rest.count == 2, let page = tab(rest[0], in: browser), let steps = Int(rest[1]) else {
                answer(["error": "folders level ID STEPS"]); return
            }
            browser.shiftLevel(page, by: steps)
        default:
            answer(["error": "folders [new|with|nest|whole|sleep|remove|level]"]); return
        }
        answer(state())
    }
}
