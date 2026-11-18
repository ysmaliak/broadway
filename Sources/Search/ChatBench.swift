import AppKit

@MainActor
enum ChatBench {
    static var fakes: [Plan: FakeProvider] = [:]

    static let long = """
    The page sets out how the old bridge was built, in three stages.

    1. The footings went down in dry summers, when the river was low.
    2. The arches were raised on timber frames, one span a year.
    3. The road on top came last, with a stone rail on each side.

    A few points worth keeping:

    - It took **eleven years** from the first stone to the opening.
    - The builders kept a ledger, quoted at [the town's page](https://town.example/bridge).
    - A word too long to break: Pneumonoultramicroscopicsilicovolcanoconiosisandthensomemoreletters

    ```
    span = 18.5 m
    arches = 7
    ```

    It closed to carts in the end, and only people on foot cross it now.
    """

    static func run(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else { return answer(["error": "chatcolumn only works on a --test run"]) }
        switch request["action"] as? String ?? "state" {
        case "fake":
            let mode = request["mode"] as? String ?? "echo"
            let fake = FakeProvider(plan: .claude, echoes: mode == "echo")
            switch mode {
            case "hang": fake.script = [.emit(.started(model: nil)), .emit(.text("Working on it")), .hang]
            case "steps":
                fake.script = [.emit(.started(model: nil)),
                               .emit(.toolStarted(id: "1", name: "Read the page", summary: "")), .emit(.toolFinished(id: "1", failed: false)),
                               .emit(.toolStarted(id: "2", name: "Looked for dates", summary: "")), .emit(.toolFinished(id: "2", failed: false)),
                               .emit(.text("The page is a short history of the old bridge, from its footings to the day it closed to carts.")),
                               .emit(.finished(ProviderUsage()))]
            case "long": fake.script = [.emit(.started(model: nil)), .emit(.text(long)), .emit(.finished(ProviderUsage()))]
            case "signedOut": fake.script = [.emit(.started(model: nil)), .fail(.notSignedIn(.claude))]
            case "act":
                fake.script = [.emit(.started(model: nil)), .emit(.toolStarted(id: "1", name: "snapshot", summary: "Reading The Old Bridge")),
                               .emit(.toolFinished(id: "1", failed: false)), .emit(.toolStarted(id: "2", name: "click", summary: "Clicking Arches")), .hang]
            case "slow": fake.script = [.emit(.started(model: nil)), .wait(1.5), .emit(.text("Slow answer")), .emit(.finished(ProviderUsage()))]
            default: break
            }
            let codex = FakeProvider(plan: .chatGPT, echoes: true)
            codex.fakeStatus.connected = request["codex"] as? Bool ?? false
            let mac = FakeProvider(plan: .thisMac, echoes: true)
            mac.fakeStatus.connected = request["mac"] as? Bool ?? false
            fakes = [.claude: fake, .chatGPT: codex, .thisMac: mac]
            for (plan, provider) in fakes { Plans.shared.standIn(provider, for: plan) }
            browser.prefs.askAndChat = true
            if let agents = request["agents"] as? Bool { browser.prefs.agentsOn = agents }
            AgentTasks.shared.helperCommand = request["helper"] as? String
            browser.prefs.aiPlan = .claude
            Task { @MainActor in
                await Plans.shared.refresh()
                answer(state(browser))
            }
            return
        case "requests":
            var out: [String: Any] = [:]
            for (plan, fake) in fakes {
                out[plan.rawValue] = fake.requests.map { ["tools": $0.tools == .none ? "none" : "mcp", "prompt": $0.prompt] }
            }
            return answer(out)
        case "queue":
            browser.ai.chatDraft = request["text"] as? String ?? ""
            browser.sendChat(queue: true)
        case "open":
            let title = request["title"] as? String ?? ""
            guard let chat = browser.chatList.first(where: { $0.title == title }) else { return answer(["error": "no chat called \(title)"]) }
            browser.open(chat: chat)
        case "stop":
            browser.stopChat()
        case "width":
            browser.prefs.sidePanelWidth = CGFloat(request["width"] as? Double ?? Double(Preferences.sidePanelWidths.lowerBound))
        case "steps":
            for view in columns(in: browser.window?.contentView) {
                for turn in view.thread.document.subviews {
                    for row in turn.subviews.compactMap({ $0 as? ChatStepsRow }) { row.action?() }
                }
            }
        case "picture":
            let path = request["path"] as? String ?? ""
            let whole = request["whole"] as? Bool ?? false
            let target: NSView? = whole ? browser.window?.contentView : columns(in: browser.window?.contentView).first
            return answer(["made": target.map { picture($0, to: path) } ?? false])
        case "top":
            for view in columns(in: browser.window?.contentView) {
                let scroll = view.thread.scroll
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        default:
            break
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(state(browser)) }
    }

    static func picture(_ view: NSView, to path: String) -> Bool {
        view.layoutSubtreeIfNeeded()
        guard !path.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            if let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = context
                Palette.NS.ground.setFill()
                NSRect(origin: .zero, size: rep.size).fill()
                context.flushGraphics()
            }
            NSGraphicsContext.restoreGraphicsState()
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    static func columns(in view: NSView?) -> [ChatColumnView] {
        guard let view else { return [] }
        if let column = view as? ChatColumnView { return [column] }
        return view.subviews.flatMap(columns)
    }

    static func state(_ browser: Browser) -> [String: Any] {
        var out = browser.chatState()
        out["list"] = browser.chatList.map(\.title)
        out["sidePanel"] = browser.sidePanel == .chat ? "chat" : browser.sidePanel == nil ? "none" : "other"
        if let column = columns(in: browser.window?.contentView).first, let window = column.window {
            func spot(_ view: NSView) -> [Int] {
                let r = view.convert(view.bounds, to: nil)
                return [Int(r.minX), Int(window.frame.height - r.maxY), Int(r.width), Int(r.height)]
            }
            out["column"] = spot(column)
            out["composer"] = spot(column.composer)
            out["focused"] = window.firstResponder === column.composer.text
            out["following"] = column.thread.following
            out["turnFrames"] = column.thread.document.subviews.filter { !$0.isHidden }.map(spot)
            out["widest"] = column.thread.document.subviews.map { Int($0.frame.maxX) }.max() ?? 0
            out["documentWidth"] = Int(column.thread.document.frame.width)
            out["listRows"] = column.list.map { $0.isHidden ? 0 : $0.rows.count } ?? 0
        }
        out["window"] = browser.window?.windowNumber ?? 0
        return out
    }
}
