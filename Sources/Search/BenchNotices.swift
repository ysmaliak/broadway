import AppKit

@MainActor
enum BenchNotices {
    static let verbs: Set<String> = ["notices"]
    private static var window: NSWindow?
    private static var stack: BarStack?
    private static var card: AgentCardView?

    private static var notes: [NSView] { (stack?.shown.map(\.view) ?? []) + [card].compactMap { $0 } }

    static func run(_ verb: String, _ request: [String: Any], _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { answer(["error": "notices only works on a --test run"]); return }
        switch request["action"] as? String ?? "show" {
        case "close":
            close()
            answer(["closed": true])
        case "pose":
            let share = CGFloat(request["share"] as? Double ?? 1)
            let leaving = request["leaving"] as? Bool ?? false
            for view in notes { NoticeMotion.pose(view, share: share, leaving: leaving) }
            window?.contentView?.displayIfNeeded()
            CATransaction.flush()
            answer(["posed": Double(share), "leaving": leaving, "count": notes.count])
        case "run":
            let leaving = request["leaving"] as? Bool ?? false
            for view in notes {
                if leaving { NoticeMotion.show(view, false) } else { NoticeMotion.enter(view) }
            }
            answer(["animations": notes.map(animations), "reduced": Motion.reduced, "calm": Motion.calm])
        default:
            answer(show(request))
        }
    }

    private static func animations(_ view: NSView) -> [[String: Any]] {
        guard let layer = view.layer else { return [] }
        return (layer.animationKeys() ?? []).compactMap { key -> [String: Any]? in
            guard let animation = layer.animation(forKey: key) else { return nil }
            return ["view": String(describing: type(of: view)), "key": key, "seconds": animation.duration,
                    "path": (animation as? CAPropertyAnimation)?.keyPath ?? "", "fadeOnly": Motion.staysUnderReduce(animation)]
        }
    }

    private static func close() {
        window?.orderOut(nil)
        window = nil
        stack = nil
        card = nil
    }

    private static func show(_ request: [String: Any]) -> [String: Any] {
        close()
        let dark = request["look"] as? String == "dark"
        let size = NSSize(width: 720, height: 520)
        let made = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        made.isReleasedWhenClosed = false
        made.hasShadow = false
        made.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let ground = KitBox(fill: dark ? NSColor(white: 0.09, alpha: 1) : .white)
        made.contentView = ground
        let bars = BarStack(frame: ground.bounds)
        bars.autoresizingMask = [.width, .height]
        ground.addSubview(bars)
        var question = AgentQuestion(kind: .choice(["Use the work account", "Use the personal account", "Stop here"]),
                                     title: "Which account should this order go on?")
        question.asker = "An agent"
        AgentDesk.shared.benchAsk(question)
        var shown: [BarStack.Bar] = []
        if let browser = Browsers.front ?? Browsers.primary {
            let agent = AgentCardView(browser: browser, desk: .shared)
            ground.addSubview(agent)
            agent.layoutSubtreeIfNeeded()
            let height = agent.intrinsicContentSize.height
            let width = min(AgentCardView.widest, size.width - 40)
            let tall = height == NSView.noIntrinsicMetric ? 120 : height
            agent.frame = NSRect(x: (size.width - width) / 2, y: ground.isFlipped ? size.height - 14 - tall : 14, width: width, height: tall)
            card = agent
            bars.bottom = 14 + agent.frame.height + bars.spacing
        }
        let offer = OfferBarView("Always open example.test in Work?", choices: [.init("Not Now") {}, .init("Always", .primary) {}])
        let note = CapsuleNote("Closed 3 tabs", size: 12, trailing: "Undo")
        shown.append(.init(view: offer, kind: .offer))
        shown.append(.init(view: FormFill.surface("done"), kind: .action))
        shown.append(.init(view: note, kind: .action))
        bars.show(shown)
        bars.layoutSubtreeIfNeeded()
        stack = bars
        let area = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        made.setFrame(NSRect(x: area.minX + 40, y: area.maxY - 80 - size.height, width: size.width, height: size.height), display: true)
        made.benchShowBehind()
        window = made
        return ["number": made.windowNumber, "size": [size.width, size.height], "dark": dark, "count": notes.count,
                "pid": ProcessInfo.processInfo.processIdentifier]
    }
}
