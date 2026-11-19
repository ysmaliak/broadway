import AppKit

enum AgentMood: String, Equatable {
    case reading, typing, waving, done, failed

    var title: String {
        switch self {
        case .reading: return "Reading"
        case .typing: return "Typing"
        case .waving: return "Needs you"
        case .done: return "Done"
        case .failed: return "Couldn't finish"
        }
    }

    static func doing(_ doing: String) -> AgentMood {
        doing.hasPrefix("Typing") || doing.hasPrefix("Pressing") ? .typing : .reading
    }
}

struct TaskFolder: Identifiable {
    let id: UUID
    let name: String
    let tabs: [Tab]
    let folded: Bool
    let needsYou: Bool
}

@MainActor
enum AgentBoard {
    private static var clock: Timer?
    private static var sweeping = false
    private static let homes = NSHashTable<Browser>.weakObjects()

    static func note(_ browser: Browser) { homes.add(browser) }

    static var browsers: [Browser] {
        let open = Browsers.all.filter { !$0.keepsNothing }
        return open + homes.allObjects.filter { home in !open.contains { $0 === home } }
    }

    static func allTabs(of task: UUID) -> [(tab: Tab, browser: Browser)] {
        browsers.flatMap { browser in
            (browser.tabs + browser.parkedAgentTabs).filter { $0.agent && $0.agentTask == task }.map { ($0, browser) }
        }
    }

    static func finish(_ task: UUID, mood: AgentMood, at now: Date = Date()) {
        for found in allTabs(of: task) where found.tab.agentFinished == nil {
            found.tab.agentFinished = now
            found.tab.agentMood = mood
            found.tab.agentActing = nil
            found.tab.driving = false
            found.tab.agentDialog?.answer(ok: false)
            found.tab.agentDialog = nil
        }
        AgentDesk.shared.drop(task: task)
        AgentLinks.shared.end(task, mood == .failed ? .failed(nil) : .done(nil), at: now)
    }

    static func startClock() {
        guard clock == nil else { return }
        AgentLinks.wire()
        CodexDesktop.shared.wake()
        AgentDesk.shared.told = { question in
            guard !NSApp.isActive else { return }
            let who = question.task.flatMap { AgentLinks.shared.link($0) }.map { "\($0.title) needs you" } ?? "An agent needs you"
            SiteNotifications.shared.post(id: question.id.uuidString, title: who, body: question.title,
                                          origin: question.site.map { "https://\($0)" } ?? "broadway://agents", tag: "", info: ["search.kind": "agent"])
        }
        clock = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard !sweeping else { return }
                sweeping = true
                Task { @MainActor in
                    await AgentLinks.sweepAll()
                    AgentAwake.refresh()
                    sweeping = false
                }
            }
        }
    }
}

extension Browser {
    var parkedAgentTabs: [Tab] { parked.values.flatMap(\.tabs).filter(\.agent) }

    var taskFolders: [TaskFolder] {
        let linked = Set(AgentLinks.shared.links.map(\.id))
        let working = tabs.filter { $0.agent && $0.agentTask != nil && $0.pin == nil && !linked.contains($0.agentTask!) }
        guard working.count >= 2 else { return [] }
        var order: [UUID] = []
        var members: [UUID: [Tab]] = [:]
        for tab in working {
            guard let task = tab.agentTask else { continue }
            if members[task] == nil { order.append(task) }
            members[task, default: []].append(tab)
        }
        return order.compactMap { task in
            guard let tabs = members[task], tabs.count >= 2 else { return nil }
            return TaskFolder(id: task, name: "Task", tabs: tabs, folded: ai.foldedTasks.contains(task),
                              needsYou: tabs.contains { $0.agentMood == .waving })
        }
    }

    var gatheredTabs: Set<Tab.ID> { Set(taskFolders.flatMap(\.tabs).map(\.id)).union(linkedTabs) }

    func settle(on tab: Tab) {
        if !tab.agent { return select(tab) }
        if let back = tabs.filter({ !$0.agent && !$0.asleep }).max(by: { $0.touched < $1.touched }) {
            select(back)
        } else {
            newTab()
        }
    }

    func toggleTaskFolder(_ task: UUID) {
        if ai.foldedTasks.remove(task) == nil { ai.foldedTasks.insert(task) }
    }

    func closeAgentTab(_ tab: Tab) {
        if tabs.contains(where: { $0.id == tab.id }) {
            close(tab)
        } else {
            closeParkedAgentTab(tab)
        }
    }

    func closeTaskTabs(_ task: UUID) {
        for found in AgentBoard.allTabs(of: task) where found.browser === self { closeAgentTab(found.tab) }
    }

    func keepAgentTab(_ tab: Tab) {
        guard tab.agent else { return }
        tab.agent = false
        tab.bench = false
        tab.agentTask = nil
        tab.agentFinished = nil
        tab.agentMood = nil
        tab.agentActing = nil
        tab.driving = false
        tab.agentSeen = true
        if let url = tab.address, !tab.shy { history.record(url, title: tab.title, space: spaceOf(tab)) }
        writeSession(now: true)
        if let space = parked.first(where: { $0.value.tabs.contains { $0 === tab } })?.key, let row = parked[space] {
            writeSession(now: true, space: space, row: row)
        }
        revision &+= 1
    }

    func keepTaskTabs(_ task: UUID) {
        for found in AgentBoard.allTabs(of: task) where found.browser === self { keepAgentTab(found.tab) }
    }

}

extension Bench {
    static func row(_ window: NSWindow) -> [String: Any] {
        ["number": window.windowNumber, "kind": "\(type(of: window))", "visible": window.isVisible, "level": window.level.rawValue,
         "frame": [window.frame.minX, window.frame.minY, window.frame.width, window.frame.height], "room": window is AgentPageRoom]
    }

    func agent(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        let task = (request["task"] as? String).flatMap(UUID.init(uuidString:))
        func state() -> [String: Any] {
            ["folders": browser.taskFolders.map { folder in
                ["id": folder.id.uuidString, "name": folder.name, "needsYou": folder.needsYou, "folded": folder.folded,
                 "tabs": folder.tabs.map { $0.id.uuidString }] as [String: Any]
             },
             "agentTabs": browser.tabs.filter(\.agent).map { tab in
                 ["id": tab.id.uuidString, "task": tab.agentTask?.uuidString ?? "", "mood": tab.agentMood?.rawValue ?? "",
                  "seen": tab.agentSeen, "active": tab.id == browser.activeID, "driving": tab.driving] as [String: Any]
             },
             "links": AgentLinks.shared.links.map(AgentLinks.shared.row),
             "askingSpaces": browser.agentAskingSpaces.map(\.uuidString),
             "area": browser.agentSessions(links: AgentLinks.shared.links, front: true).map { session in
                 let said = session.state(pending: AgentDesk.shared.pending)
                 return ["id": session.id.uuidString, "name": session.link.name, "title": session.link.title, "status": said.line,
                         "mood": said.mood.rawValue, "face": session.face(said).rawValue, "attention": said.attention, "accent": session.link.accent,
                         "tabs": session.tabs.map { $0.id.uuidString }] as [String: Any]
             },
             "folded": AgentsFolds.shared.folded,
             "row": {
                 let pending = AgentDesk.shared.pending
                 let voice = AgentsLayout.voice(browser.agentSessions(links: AgentLinks.shared.links, front: true).map {
                     ($0.link.title, $0.state(pending: pending))
                 })
                 return ["title": voice.title, "line": voice.line, "attention": voice.attention] as [String: Any]
             }(),
             "height": AgentsAreaView.height(of: browser, column: 800),
             "chrome": AgentChrome.bench(browser),
             "sizes": browser.agentSections(browser.agentSessions(links: AgentLinks.shared.links, front: true)).map { section in
                 ["rows": AgentsLayout.rows(section), "headed": section.headed, "whole": section.whole] as [String: Any]
             },
             "listed": browser.displayedTabs.filter { browser.gatheredTabs.contains($0.id) == false }.map { $0.id.uuidString },
             "pointer": browser.active.flatMap { AgentPointers.shared.shown[$0.id] }.map { ["kind": $0.kind.rawValue, "name": $0.name,
                                                                                             "x": $0.target.minX, "y": $0.target.minY] as [String: Any] } ?? [:]]
        }
        func card(_ prefix: String?) -> AgentSession? {
            guard let prefix = prefix?.lowercased() else { return nil }
            return browser.agentSessions(links: AgentLinks.shared.links, front: true).first { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        }
        switch request["action"] as? String {
        case "state":
            answer(state())
        case "takeover":
            answer(["changed": browser.takeOver()])
        case "handback":
            answer(["changed": browser.handBack()])
        case "call":
            let box = BrowserToolbox()
            box.browser = browser
            let name = request["name"] as? String ?? ""
            let data = (request["arguments"] as? String ?? "{}").data(using: .utf8) ?? Data()
            let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            Task { @MainActor in
                let outcome = await box.call(name, arguments, task: task.flatMap { TaskLedger.shared.entry($0) == nil ? nil : $0 })
                answer(["text": outcome.text ?? "", "failed": outcome.failed, "image": outcome.imagePNG?.count ?? 0])
            }
        case "questions":
            answer(["questions": AgentDesk.shared.pending.map { question in
                ["id": question.id.uuidString, "title": question.title, "quote": question.quote, "reason": question.reason,
                 "site": question.site ?? "", "label": question.quoteLabel, "card": AgentDesk.benchRow(question)["card"] ?? [:]] as [String: Any]
            }])
        case "answer":
            guard let first = AgentDesk.shared.front else { return answer(["error": "no question"]) }
            let said: AgentAnswer
            switch request["with"] as? String {
            case "yes": said = .yes
            case "always": said = .always
            case "never": said = .never
            case "no": said = .no
            default:
                guard let index = (request["with"] as? String).flatMap(Int.init) else { return answer(["error": "agent answer yes|no|always|never|N"]) }
                said = .picked(index)
            }
            AgentDesk.shared.take(first.id, said)
            answer(["answered": first.title])
        case "mode":
            guard let mode = (request["mode"] as? String).flatMap(AgentMode.init(rawValue:)) else { return answer(["error": "agent mode ask|auto|bypass"]) }
            browser.prefs.agentMode = mode
            answer(["mode": mode.rawValue])
        case "finish":
            guard let task else { return answer(["error": "agent finish TASK"]) }
            AgentBoard.finish(task, mood: request["failed"] as? Bool == true ? .failed : .done)
            answer(state())
        case "fold":
            AgentsFolds.shared.toggle()
            answer(state())
        case "press":
            browser.pressAgents()
            answer(state())
        case "hover":
            guard let window = browser.window ?? Links.window, let root = window.contentView else { return answer(["error": "agent hover needs a window"]) }
            if let at = request["at"] as? [Double], at.count == 2 {
                KitHoverView.pointerStandIn = (window, NSPoint(x: at[0], y: Double(window.frame.height) - at[1]))
            } else {
                KitHoverView.pointerStandIn = nil
            }
            func settle(_ view: NSView, inside: Bool) {
                let within = inside || view is AgentsAreaView
                if within { (view as? KitHoverView)?.settleHover() }
                for sub in view.subviews { settle(sub, inside: within) }
            }
            settle(root, inside: false)
            answer(state())
        case "whole":
            guard let found = card(request["link"] as? String) else { return answer(["error": "agent whole LINK"]) }
            AgentsFolds.shared.whole.insert(found.id)
            answer(state())
        case "stage":
            guard let window = browser.window ?? Links.window else { return answer(["error": "agent stage needs a window"]) }
            window.level = request["shown"] as? Bool == true ? .normal : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
            if let size = request["size"] as? [Double], size.count == 2 {
                window.setFrame(NSRect(x: 40, y: 40, width: size[0], height: size[1]), display: true)
            }
            if let dark = request["dark"] as? Bool { NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
            NSApp.unhideWithoutActivation()
            window.orderFrontRegardless()
            answer(["window": window.windowNumber, "pid": Int(getpid())])
        case "row":
            guard let found = card(request["link"] as? String), let index = request["index"] as? Int, found.tabs.indices.contains(index) else {
                return answer(["error": "agent row LINK N"])
            }
            browser.bring(found.tabs[index])
            answer(state())
        case "heading":
            guard let found = card(request["link"] as? String) else { return answer(["error": "agent heading LINK"]) }
            browser.pressAgent(found)
            answer(state())
        case "closelink":
            guard let found = card(request["link"] as? String) else { return answer(["error": "agent closelink LINK"]) }
            for tab in found.tabs { browser.closeAgentTab(tab) }
            Task { @MainActor in
                await AgentLinks.sweepAll()
                answer(state())
            }
        case "codex":
            if let running = request["running"] as? Bool { CodexDesktop.shared.running = { running } }
            CodexDesktop.shared.update()
            answer(state())
        case "codexopen":
            guard let found = card(request["link"] as? String) else { return answer(["error": "agent codexopen LINK"]) }
            var opened = ""
            CodexDesktop.shared.opener = { opened = $0.absoluteString }
            CodexDesktop.shared.reveal(found.link)
            CodexDesktop.shared.opener = { NSWorkspace.shared.open($0) }
            answer(["opened": opened])
        case "linksweep":
            Task { @MainActor in
                await AgentLinks.sweepAll(at: Date().addingTimeInterval(request["after"] as? Double ?? 0))
                answer(state())
            }
        case "sweep":
            Task { @MainActor in
                let said = await AgentEndTabs.settle(at: Date().addingTimeInterval(request["after"] as? Double ?? 0))
                var shown = state()
                shown["swept"] = said.object
                answer(shown)
            }
        case "windows":
            answer(["windows": NSApp.windows.map(Self.row)])
        case "screens":
            var moved: [[String: Any]] = []
            for window in NSApp.windows where window.isVisible {
                guard let screen = NSScreen.main else { break }
                let was = window.frame
                window.setFrame(window.constrainFrameRect(was, to: screen), display: false)
                if window.frame != was { moved.append(Self.row(window)) }
            }
            NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApp)
            answer(["moved": moved, "windows": NSApp.windows.map(Self.row)])
        case "look":
            let prefix = (request["tab"] as? String ?? "").lowercased()
            if !prefix.isEmpty, let tab = browser.tabs.first(where: { $0.id.uuidString.lowercased().hasPrefix(prefix) }) {
                browser.select(tab)
            } else if let active = browser.active {
                browser.settle(on: active)
            }
            answer(["active": browser.active.map { $0.id.uuidString } ?? ""])
        default:
            answer(["error": "agents state|takeover|handback|call|questions|answer|mode|finish|fold|press|hover|whole|stage|row|heading|closelink|codex|codexopen|linksweep|sweep|windows|screens|look"])
        }
    }
}
