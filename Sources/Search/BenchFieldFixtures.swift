import AppKit

@MainActor
enum BenchFieldFixtures {
    static let answer = FieldAnswer(kind: .sum, expression: "12 * 7 + 3", answer: "87", copy: "87")
    static let place = FieldPlaceItem(place: .history, id: "h1", title: "Swift Forums", detail: "forums.swift.org/latest",
                                      aside: "Yesterday", url: URL(string: "https://forums.swift.org/latest")!)
    static let file = FieldPlaceItem(place: .downloads, id: "d1", title: "Quarterly report final v2.pdf", detail: "~/Downloads",
                                     aside: "2.4 MB", url: URL(fileURLWithPath: "/tmp/none.pdf"), missing: true)

    static var rows: [Suggestion] {
        var keyed = Suggestion(key: "github.com", title: "GitHub", url: URL(string: "https://github.com")!, kind: .open)
        keyed.keys = "⌘1"
        var action = Suggestion(key: "Copy Link", title: "Copy this page's address", url: FieldAction.nowhere, kind: .action("copy"))
        action.symbol = "link"
        return [
            Suggestion(key: "swift observation", title: "Google", url: URL(string: "https://www.google.com/search?q=swift")!, kind: .search),
            Suggestion(key: "swift observation macro", title: "", url: URL(string: "https://www.google.com/search?q=swift+o")!, kind: .suggested),
            keyed,
            Suggestion(key: "developer.apple.com/documentation/observation", title: "Observation | Apple Developer Documentation",
                       url: URL(string: "https://developer.apple.com/documentation/observation")!, kind: .visited),
            Suggestion(key: "news.ycombinator.com", title: "Hacker News", url: URL(string: "https://news.ycombinator.com")!, kind: .bookmark),
            action,
            Suggestion(key: "sig", title: "Email signature", url: FieldAction.nowhere, kind: .snippet(Snippet(title: "Email signature", keyword: "sig", text: "Best"))),
            Suggestion(key: answer.answer, title: answer.expression, url: FieldAction.nowhere, kind: .answer(answer)),
            Suggestion(key: place.title, title: place.detail, url: place.url, kind: .placed(place)),
            Suggestion(key: file.title, title: file.detail, url: file.url, kind: .placed(file)),
        ]
    }

    static let lit: Set<Int> = [2, 9]

    static var nowRows: [Suggestion] {
        func now(_ title: String, _ detail: String, _ symbol: String) -> Suggestion {
            var made = Suggestion(key: title, title: detail, url: FieldAction.nowhere, kind: .action("now:" + symbol))
            made.symbol = symbol
            return made
        }
        return [
            Suggestion(key: "github.com", title: "GitHub", url: URL(string: "https://github.com")!, kind: .open),
            now("Join Design review", "In 5 minutes · Google Meet", "video"),
            now("Lunch", "In 40 minutes", "calendar"),
            now("swift.org/blog", "Copied a moment ago", "link"),
            now("Quarterly report final v2.pdf", "Downloaded a moment ago", "arrow.down.circle"),
            now("Review: Plain symbols on Now rows", "GitHub · asks for your review", "arrow.triangle.pull"),
            Suggestion(key: "news.ycombinator.com", title: "Hacker News", url: URL(string: "https://news.ycombinator.com")!, kind: .visited),
        ]
    }

    static let nowLit: Set<Int> = [2]

    static var menuItems: [FieldMenuItem] {
        [
            FieldMenuItem(id: "copy", title: "Copy Link", symbol: "link", keys: "⇧⌘C") {},
            FieldMenuItem(id: "pin", title: "Pin Tab", symbol: "pin", keys: "") {},
            FieldMenuItem(id: "reader", title: "Open in Reader", symbol: "doc.plaintext", keys: "⇧⌘R") {},
            FieldMenuItem(id: "share", title: "Share…", symbol: "square.and.arrow.up") {},
        ]
    }

    static var question: AgentQuestion {
        var question = AgentQuestion(kind: .approval(.send), title: "Send the form on example.com?")
        question.site = "example.com"
        question.quote = "Subscribe to our newsletter"
        question.reason = "You asked me to sign up for updates."
        return question
    }

    static let buttons = [
        Extensions.Button(id: "a", name: "Ad Guard", label: "Ad Guard", icon: nil, badge: "", enabled: true, pinned: true),
        Extensions.Button(id: "b", name: "Bitwarden", label: "Bitwarden", icon: nil, badge: "3", enabled: true, pinned: false),
        Extensions.Button(id: "c", name: "Cookie Editor", label: "Cookie Editor", icon: nil, badge: "", enabled: false, pinned: false),
        Extensions.Button(id: "d", name: "Dark Reader", label: "Dark Reader", icon: nil, badge: "12", enabled: true, pinned: true),
    ]

    static var holds: [AnyObject] = []

    static func column(_ views: [NSView], spacing: CGFloat = 0, width: CGFloat, heights: [CGFloat]) -> NSView {
        let stage = KitFlippedView()
        var y: CGFloat = 0
        for (view, height) in zip(views, heights) {
            stage.addSubview(view)
            view.frame = NSRect(x: 0, y: y, width: width, height: height)
            y += height + spacing
        }
        stage.frame = NSRect(x: 0, y: 0, width: width, height: max(0, y - spacing))
        return Fixed(stage)
    }

    final class Fixed: NSView {
        init(_ inner: NSView) {
            super.init(frame: inner.frame)
            addSubview(inner)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override var fittingSize: NSSize { subviews.first?.frame.size ?? .zero }
        override var intrinsicContentSize: NSSize { fittingSize }
    }

    static func padded(_ view: NSView, _ size: NSSize, pad: CGFloat = 8) -> NSView {
        let stage = KitFlippedView(frame: NSRect(x: 0, y: 0, width: size.width + pad * 2, height: size.height + pad * 2))
        stage.addSubview(view)
        view.frame = NSRect(x: pad, y: pad, width: size.width, height: size.height)
        return Fixed(stage)
    }

    static func row(_ views: [NSView], spacing: CGFloat, pad: CGFloat) -> NSView {
        let stage = KitFlippedView()
        var x = pad
        var tallest: CGFloat = 0
        for view in views {
            let size = view.intrinsicContentSize
            stage.addSubview(view)
            view.frame = NSRect(x: x, y: pad, width: size.width, height: size.height)
            x += size.width + spacing
            tallest = max(tallest, size.height)
        }
        for view in views { view.frame.origin.y = pad + ((tallest - view.frame.height) / 2).rounded(.toNearestOrAwayFromZero) }
        stage.frame = NSRect(x: 0, y: 0, width: x - spacing + pad, height: tallest + pad * 2)
        return Fixed(stage)
    }

    static let names = ["field-rows", "now-rows", "field-chips", "field-slab", "field-bar", "field-menu",
                        "extension-icons", "fetch-doors", "recent-downloads",
                        "agent-card", "agent-badge"]

    static func surface(_ name: String, _ request: [String: Any], browser: Browser?) -> NSView? {
        let ink = KitInk(lift: request["lift"] as? Double ?? 0)
        switch name {
        case "field-rows":
            let views = rows.enumerated().map { index, offer -> NSView in
                let row = FieldRowView(offer: offer, height: 38, lit: lit.contains(index))
                row.copyAnswer = { _ in }
                return row
            }
            return column(views, width: 560, heights: views.map { _ in 38 })
        case "now-rows":
            let views = nowRows.enumerated().map { index, offer -> NSView in
                FieldRowView(offer: offer, height: 38, lit: nowLit.contains(index))
            }
            return column(views, width: 560, heights: views.map { _ in 38 })
        case "field-chips":
            let chips = row(FieldPlace.browsable.map { PlaceChipView(place: $0) as NSView } + [FieldKeyCap("Tab"), FieldKeyCap("⌘↩")], spacing: 8, pad: 0)
            let offers = FieldPlace.browsable.map { PlaceOfferRowView(place: $0) as NSView }
            return column([chips] + offers, spacing: 8, width: 560, heights: [chips.fittingSize.height] + offers.map { _ in 38 })
        case "field-slab":
            let slabs = [FieldSlabView(), FieldSlabView(faint: true)]
            return padded(column(slabs, spacing: 10, width: 540, heights: [38, 38]), NSSize(width: 540, height: 86))
        case "field-bar":
            guard let browser else { return nil }
            let bar = FieldBarView(browser: browser, menu: browser.fieldMenu)
            return column([bar], width: 560, heights: [FieldBarView.height])
        case "field-menu":
            let menu = FieldMenu()
            menu.open(heading: "Actions for GitHub", items: menuItems)
            holds.append(menu)
            return column([FieldMenuListView(menu: menu, rowHeight: 38, headerHeight: 28)], width: 560, heights: [220])
        case "extension-icons":
            let icons = (buttons.map { ExtensionIconView(button: $0, size: 15) } + buttons.map { ExtensionIconView(button: $0, size: 16) })
            for icon in icons { icon.ink = ink }
            return row(icons, spacing: 10, pad: 8)
        case "fetch-doors":
            guard let browser else { return nil }
            let states: [(Bool, Double?, Bool)] = [(false, nil, false), (true, 0.4, false), (true, 0.02, false), (true, nil, true)]
            let doors = states.map { state -> FetchDoorView in
                let fetches = Fetches()
                fetches.benchState(showing: state.0, fraction: state.1, done: state.2)
                holds.append(fetches)
                let door = FetchDoorView(browser: browser, fetches: fetches, always: true)
                door.ink = ink
                return door
            }
            return row(doors, spacing: 8, pad: 6)
        case "recent-downloads":
            guard let browser else { return nil }
            if let stage = request["stage"] as? String, Fetches.benchStages.contains(stage) { browser.fetches.benchStage(stage, loot: browser.loot) }
            let list = RecentDownloadsView(browser: browser, loot: browser.loot, fetches: browser.fetches)
            list.prepare()
            let size = list.fittingSize
            let glass = KitGlass.floating(radius: 16)
            glass.hold(list)
            return padded(glass, size)
        case "agent-card":
            guard let browser else { return nil }
            AgentDesk.shared.benchAsk(question)
            let card = AgentCardView(browser: browser, desk: .shared)
            return padded(card, NSSize(width: 460, height: card.intrinsicContentSize.height))
        case "agent-badge":
            let badge = AgentActingBadgeView(doing: "Filling in the form")
            return padded(badge, badge.intrinsicContentSize)
        default:
            return nil
        }
    }
}

extension Bench {
    static func postReturn(_ held: [String], to window: NSWindow) {
        var flags: NSEvent.ModifierFlags = []
        if held.contains("option") { flags.insert(.option) }
        if held.contains("command") { flags.insert(.command) }
        if held.contains("shift") { flags.insert(.shift) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }
}
