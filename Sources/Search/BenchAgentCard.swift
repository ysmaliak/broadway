import AppKit

@MainActor
enum BenchAgentCard {
    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "agentcard only works on a --test run"]) }
        func sessions() -> [AgentSession] {
            browser.agentSessions(links: AgentLinks.shared.links, front: browser.agentsInFront)
        }
        func found() -> AgentSession? {
            guard let prefix = (request["link"] as? String)?.lowercased(), !prefix.isEmpty else { return nil }
            return sessions().first { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        }
        if request.keys.contains("reduced") {
            if let on = request["reduced"] as? Bool {
                Store.settings.set(on, forKey: "motion.testReduced")
            } else {
                Store.settings.removeObject(forKey: "motion.testReduced")
            }
        }
        switch request["action"] as? String {
        case "open":
            guard let session = found() else { return answer(["error": "agentcard open LINK"]) }
            KitChange.eased { AgentsFolds.shared.toggle(session.id) }
        case "lead":
            guard let session = found() else { return answer(["error": "agentcard lead LINK"]) }
            browser.pressAgent(session)
        case "close":
            guard let session = found() else { return answer(["error": "agentcard close LINK"]) }
            browser.closeAgentTabs(session)
        case "shut":
            AgentsFolds.shared.open = []
        case "whole":
            guard let session = found() else { return answer(["error": "agentcard whole LINK"]) }
            AgentsFolds.shared.whole.insert(session.id)
        case "wheel":
            return wheel(request, browser: browser) { answer(state(browser, sessions()).merging($0) { _, new in new }) }
        case "offset":
            guard let window = browser.window ?? Links.window, let content = window.contentView,
                  let area = content.kitSubviews(of: AgentsAreaView.self).first(where: { $0.fixed == nil && $0.window != nil }),
                  let y = request["y"] as? Double
            else { return answer(["error": "agentcard offset Y"]) }
            area.benchOffset(CGFloat(y))
        case "pointer":
            guard let window = browser.window ?? Links.window, let content = window.contentView else { return answer(["error": "no window"]) }
            if let at = request["at"] as? [Double], at.count == 2 {
                KitHoverView.pointerStandIn = (window, NSPoint(x: at[0], y: content.bounds.height - at[1]))
            } else {
                KitHoverView.pointerStandIn = nil
            }
            for view in content.kitSubviews(of: KitHoverView.self) { view.settleHover() }
        case "retitle":
            guard let tab = agentTab(request, sessions()), let title = request["title"] as? String,
                  let quoted = try? String(data: JSONSerialization.data(withJSONObject: [title]), encoding: .utf8)
            else { return answer(["error": "agentcard retitle TAB TITLE"]) }
            tab.web.evaluateJavaScript("document.title = \(quoted)[0]") { _, _ in }
        case "closetab":
            guard let tab = agentTab(request, sessions()) else { return answer(["error": "agentcard closetab TAB"]) }
            browser.closeAgentTab(tab)
        default:
            break
        }
        answer(state(browser, sessions()))
    }

    static func agentTab(_ request: [String: Any], _ sessions: [AgentSession]) -> Tab? {
        guard let prefix = (request["tab"] as? String)?.lowercased(), !prefix.isEmpty else { return nil }
        return sessions.flatMap(\.tabs).first { $0.id.uuidString.lowercased().hasPrefix(prefix) }
    }

    static func sideOffset(_ window: NSWindow) -> Double? {
        guard let content = window.contentView else { return nil }
        let page = content.kitSubviews(of: SidePageView.self).first { $0.preview == nil && !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
        return page.map { Double($0.listOffset) }
    }

    static func wheel(_ request: [String: Any], browser: Browser, _ done: @escaping ([String: Any]) -> Void) {
        guard let window = browser.window ?? Links.window, let content = window.contentView,
              let area = content.kitSubviews(of: AgentsAreaView.self).first(where: { $0.fixed == nil && $0.window != nil && !$0.isHiddenOrHasHiddenAncestor })
        else { return done(["error": "no card"]) }
        let point: NSPoint
        if let at = request["at"] as? [Double], at.count == 2 {
            point = NSPoint(x: at[0], y: content.bounds.height - at[1])
        } else {
            let card = area.convert(area.cardFrameInColumn, from: area.superview)
            let middle = area.convert(NSPoint(x: card.midX, y: card.maxY - AgentsLayout.rim - AgentsLayout.row / 2), to: nil)
            point = middle
        }
        KitHoverView.pointerStandIn = (window, point)
        for view in content.kitSubviews(of: KitHoverView.self) { view.settleHover() }
        let hit = content.hitTest(point)
        let dy = request["dy"] as? Double ?? 8
        let steps = request["steps"] as? Int ?? 6
        let momentum = request["momentum"] as? Int ?? 0
        let gap = (request["gap"] as? Double ?? 16) / 1000
        let mode = request["mode"] as? String ?? "full"
        var events: [(phase: Int64, momentum: Int64, delta: Double)] = []
        switch mode {
        case "legacy":
            events = Array(repeating: (0, 0, dy), count: steps)
        case "begin":
            events = [(128, 0, 0), (1, 0, 0)] + Array(repeating: (2, 0, dy), count: steps)
        case "end":
            events = (momentum > 0 ? [] : Array(repeating: (2, 0, 0), count: 3)) + [(4, 0, 0)]
        default:
            events = [(128, 0, 0), (1, 0, 0)] + Array(repeating: (2, 0, dy), count: steps)
                + (momentum > 0 ? [] : Array(repeating: (2, 0, 0), count: 3)) + [(4, 0, 0)]
        }
        if mode != "begin", mode != "legacy", momentum > 0 {
            events += [(0, 1, dy)] + (1..<max(2, momentum)).map { n in (0, 2, dy * pow(0.8, Double(n))) } + [(0, 3, 0)]
        }
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let before = ["cardBefore": area.benchScroll["offset"] ?? 0, "sideBefore": sideOffset(window) ?? -1] as [String: Any]
        var trace: [[Double]] = []
        var phases: [[Double]] = []
        func send(_ index: Int) {
            guard index < events.count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    var said = before
                    said["sideAfter"] = sideOffset(window) ?? -1
                    said["hit"] = hit.map { String(describing: type(of: $0)) } ?? ""
                    said["trace"] = trace
                    said["phases"] = phases
                    said["live"] = area.benchScroll["live"] ?? false
                    done(said)
                }
                return
            }
            let event = events[index]
            let delta = -event.delta
            if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(delta.rounded()), wheel2: 0, wheel3: 0) {
                cg.location = CGPoint(x: window.frame.minX + point.x, y: screenHeight - (window.frame.minY + point.y))
                cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: mode == "legacy" ? 0 : 1)
                cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: event.phase)
                cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: event.momentum)
                cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: delta)
                if mode == "legacy" { cg.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(delta.rounded())) }
                cg.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                if let made = NSEvent(cgEvent: cg) {
                    (content.hitTest(point) ?? hit)?.scrollWheel(with: made)
                    phases.append([Double(made.phase.rawValue), Double(made.momentumPhase.rawValue), Double(made.scrollingDeltaY),
                                   made.hasPreciseScrollingDeltas ? 1 : 0, area.benchScroll["offset"] as? Double ?? 0])
                }
            }
            let scroll = area.benchScroll
            let spot = NSPoint(x: point.x, y: content.bounds.height - point.y)
            let view = scroll["view"] as? [Double] ?? [0, 0, 0, 0]
            let seen = NSRect(x: view[0], y: view[1], width: view[2], height: view[3]).contains(spot)
            let rows = (scroll["rows"] as? [[String: Any]] ?? []).filter { !($0["leaving"] as? Bool ?? false) }
            let follows = rows.allSatisfy { row in
                let box = row["box"] as? [Double] ?? [0, 0, 0, 0]
                let under = seen && NSRect(x: box[0], y: box[1], width: box[2], height: box[3]).contains(spot)
                return (row["hover"] as? Bool ?? false) == under
            }
            trace.append([Double(index), scroll["offset"] as? Double ?? 0, sideOffset(window) ?? -1, follows ? 1 : 0])
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) { send(index + 1) }
        }
        send(0)
    }

    static func state(_ browser: Browser, _ sessions: [AgentSession]) -> [String: Any] {
        let pending = AgentDesk.shared.pending
        let sections = browser.agentSections(sessions)
        let agents: [[String: Any]] = zip(sessions, sections).map { session, section in
            let lead = section.headed ? browser.agentLead(session, pending: pending) : nil
            let state = session.state(pending: pending)
            return ["id": session.id.uuidString, "title": session.link.title, "headed": section.headed, "open": section.open,
                    "fold": section.rows, "rows": AgentsLayout.rows(section), "count": AgentsLayout.count(section).map { $0 as Any } ?? NSNull(),
                    "lead": lead?.id.uuidString ?? "", "leadTitle": lead.map(Browser.agentTabName) ?? "",
                    "line": AgentsLayout.headline(state, tab: lead.map(Browser.agentTabName), acting: lead?.agentActing),
                    "tabs": session.tabs.map { $0.id.uuidString }]
        }
        var said: [String: Any] = ["agents": agents, "folded": AgentsFolds.shared.folded, "reduced": Motion.reduced,
                                   "active": browser.activeID?.uuidString ?? ""]
        if let card = AgentChrome.bench(browser)["card"] { said["card"] = card }
        if let window = browser.window ?? Links.window, let content = window.contentView {
            func box(_ view: NSView) -> [Double] {
                let frame = view.convert(view.bounds, to: nil)
                return [frame.minX, window.frame.height - frame.maxY, frame.width, frame.height].map(Double.init)
            }
            said["folders"] = content.kitSubviews(of: GroupHeadingView.self).filter { !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }.map { heading in
                ["name": heading.group?.name ?? "", "box": box(heading), "countBox": box(heading.chipFold), "countText": heading.chipFold.text,
                 "countShown": heading.chipFold.showing] as [String: Any]
            }
        }
        return said
    }
}
