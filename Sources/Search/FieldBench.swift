import AppKit

struct FixedCalendar: CalendarSource {
    let events: [CalendarEvent]
    var access = true
    var list: [MeetingCalendar] = []
    var hasAccess: Bool { access }
    func requestAccess() async -> Bool { access }
    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        events.filter { $0.end > start && $0.start < end }
    }
    func calendars() -> [MeetingCalendar] { list }
}

final class FixedBoard: CopiedBoard {
    var change = 0
    let link: String
    let free: Bool
    var secret: Bool { false }

    init(link: String, free: Bool) {
        self.link = link
        self.free = free
    }

    func looksLikeLink() async -> Bool { true }
    func text() -> String? { link }
}

extension Bench {
    static func fieldHost(in view: NSView?) -> NSView? {
        guard let view else { return nil }
        if view is FieldHost.Layer { return view }
        for sub in view.subviews { if let found = fieldHost(in: sub) { return found } }
        return nil
    }

    func fieldCommand(_ request: [String: Any], browser: Browser, _ answer: @escaping ([String: Any]) -> Void) {
        guard Store.testing else {
            answer(["error": "fieldrows only works on a --test run"])
            return
        }
        let args = request["args"] as? [String] ?? []
        func state(_ extra: [String: Any] = [:]) -> [String: Any] {
            var out: [String: Any] = [
                "typed": browser.typed,
                "pointed": browser.pointed ?? -2,
                "picked": browser.picked ?? -1,
                "rows": browser.offers.map { offer -> [String] in
                    [offer.primary, offer.secondary, String(describing: offer.kind).components(separatedBy: "(")[0], offer.url.absoluteString]
                },
                "sections": browser.fieldSections.map { ["title": $0.title, "from": $0.range.lowerBound, "to": $0.range.upperBound] },
                "place": browser.fieldPlace?.rawValue ?? "",
                "placeOffer": browser.placeOffer?.rawValue ?? "",
                "siteOffer": browser.siteOffer?.name ?? "",
                "showing": browser.fieldShowing,
                "editing": browser.editing,
                "idle": browser.returnIsIdle,
                "focusedMs": browser.fieldTimes.focused.map { (($0 - browser.fieldTimes.asked) * 1000).rounded() } ?? -1,
                "drawnMs": browser.fieldTimes.drawn.map { (($0 - browser.fieldTimes.asked) * 1000).rounded() } ?? -1,
                "layout": FieldLayout.frames.filter { $0.key.hasPrefix("field.") }.mapValues { [$0.minX, $0.minY, $0.width, $0.height] },
                "edges": ColumnEdges.seen.filter { $0.key.hasPrefix("field.") },
                "host": Bench.fieldHost(in: browser.window?.contentView).map { view -> [Double] in
                    let box = view.convert(view.bounds, to: nil)
                    let height = view.window?.contentView?.bounds.height ?? 0
                    return [box.minX, height - box.maxY, box.width, box.height]
                } ?? [],
                "movedAfterDrawn": browser.fieldTimes.drawn.map { drawn in
                    FieldLayout.changed.filter { $0.key.hasPrefix("field.") && $0.value > drawn }.map { [$0.key, String(Int((($0.value - drawn) * 1000).rounded()))] }
                } ?? [],
            ]
            out.merge(extra) { _, new in new }
            return out
        }
        func menuState() -> [String: Any] {
            ["menu": browser.fieldMenu.showing, "heading": browser.fieldMenu.heading,
             "items": browser.fieldMenu.shown.map { [$0.title, $0.keys] }, "tabs": browser.tabs.count,
             "editing": browser.editing]
        }
        switch args.first ?? "state" {
        case "state":
            answer(state())
        case "type":
            if !browser.fieldShowing { browser.edit() }
            browser.typed = args.dropFirst().joined(separator: " ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { answer(state()) }
        case "pick":
            browser.picked = Int(args.dropFirst().first ?? "")
            answer(state())
        case "walk":
            browser.walk(Int(args.dropFirst().first ?? "") ?? 1)
            answer(state())
        case "point":
            browser.pointed = Int(args.dropFirst().first ?? "")
            answer(state())
        case "return":
            browser.submit()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(state(menuState())) }
        case "answer":
            answer(state(["copied": AnswerBoard.written, "announced": browser.announcement ?? "",
                          "editing": browser.editing, "ending": browser.ending ?? ""]))
        case "launch":
            browser.launch()
            browser.fieldRose()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                answer(state(["editing": browser.editing, "launching": browser.launching]))
            }
        case "return-aside":
            browser.submit(aside: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(state(["copied": AnswerBoard.written, "announced": browser.announcement ?? "",
                              "editing": browser.editing, "tabs": browser.tabs.count]))
            }
        case "click":
            let index = Int(args.dropFirst().first ?? "") ?? 0
            guard browser.offers.indices.contains(index) else {
                answer(["error": "no row \(index)"])
                return
            }
            browser.take(browser.offers[index])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(state(["copied": AnswerBoard.written, "announced": browser.announcement ?? "",
                              "editing": browser.editing]))
            }
        case "actions":
            browser.fieldActions()
            answer(state(menuState()))
        case "menu":
            answer(state(menuState()))
        case "query":
            browser.fieldMenu.query = args.dropFirst().joined(separator: " ")
            answer(state(menuState()))
        case "action":
            let title = args.dropFirst().joined(separator: " ")
            guard let item = browser.fieldMenu.shown.first(where: { $0.title == title }) else {
                answer(["error": "no action called \(title)"])
                return
            }
            browser.fieldMenu.take(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(state(menuState())) }
        case "close":
            browser.dismiss()
            answer(state())
        case "copied":
            let board = FixedBoard(link: args.dropFirst().first ?? "", free: args.dropFirst(2).first != "asks")
            CopiedLink.shared.use(board)
            board.change += 1
            browser.noticeClipboard()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(state()) }
        case "download":
            let file = Store.file("bench-download.txt")
            try? Data("bench".utf8).write(to: file)
            browser.loot.add(Keep(name: args.dropFirst().first ?? "report.pdf", from: "", path: file.path, date: Date()))
            browser.retype()
            answer(state())
        case "meeting":
            let minutes = Double(args.dropFirst().first ?? "") ?? 30
            let start = Date().addingTimeInterval(minutes * 60)
            let event = CalendarEvent(id: "bench", title: args.dropFirst(2).first ?? "Design sync", start: start,
                                      end: start.addingTimeInterval(1800), location: "https://meet.google.com/abc-defg-hij",
                                      people: [MeetingPerson(name: "Dana Reyes", email: "dana@example.com")])
            browser.prefs.nextMeeting = true
            Meetings.shared.use(FixedCalendar(events: [event]))
            Task {
                await Meetings.shared.refresh()
                answer(["next": Meetings.shared.next?.event.title ?? "", "link": Meetings.shared.next?.link?.absoluteString ?? ""])
            }
        case "join":
            browser.joinNextMeeting()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                answer(["tabs": browser.tabs.map { $0.shownURL?.absoluteString ?? "" }, "active": browser.active?.shownURL?.absoluteString ?? ""])
            }
        case "favorite":
            browser.toggleFavorite()
            answer(state(["favorites": Favorites.shared.list.map(\.title)]))
        case "favorite-move":
            browser.moveFavorite(by: Int(args.dropFirst().first ?? "") ?? 1)
            answer(state(["favorites": Favorites.shared.list.map(\.title)]))
        case "picture":
            guard let path = args.dropFirst().first else {
                answer(["error": "fieldrows picture PATH"])
                return
            }
            let size = NSSize(width: 640, height: 474)
            let menu = browser.fieldMenu
            let host = FieldPicture(browser: browser, menu: menu, size: size)
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSApp.effectiveAppearance
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let picture = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    answer(["error": "nothing drawn"])
                    return
                }
                host.cacheDisplay(in: host.bounds, to: picture)
                try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                window.contentView = nil
                answer(["saved": path])
            }
        case "pagetext":
            let words = args.dropFirst().joined(separator: " ")
            Task {
                let count = await browser.history.pages.count()
                let hits = await browser.history.pages.search(words)
                answer(["pages": count, "hits": hits.map { ["url": $0.url.absoluteString, "title": $0.title, "snippet": $0.snippet, "opening": $0.opening.absoluteString] }])
            }
        case "forget":
            browser.clearHistory()
            answer(state())
        case "place":
            guard let place = FieldPlace(rawValue: args.dropFirst().first ?? "") else {
                answer(["error": "fieldrows place history|bookmarks|downloads|snippets"])
                return
            }
            browser.enterPlace(place)
            answer(state())
        case "places":
            answer(state(["copied": AnswerBoard.written, "announced": browser.announcement ?? "",
                          "undo": browser.announcedUndo != nil, "files": PlaceFiles.done,
                          "tabs": browser.tabs.map { $0.shownURL?.absoluteString ?? "" },
                          "active": browser.active?.shownURL?.absoluteString ?? "",
                          "history": browser.history.everything().map(\.url.absoluteString),
                          "bookmarks": Bookmarks.urls(browser.bookmarks.roots).map(\.absoluteString),
                          "downloads": browser.loot.kept.map(\.name)]))
        case "undo":
            browser.undoAnnounced()
            answer(state())
        case "downloadrows":
            let box = FieldLeaveBench.omnibox(in: browser)
            let shown = (box?.kitSubviews(of: FieldPlaceRowView.self) ?? [])
                .filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
                .map { ($0.convert($0.bounds, to: nil).maxY, $0) }
                .sorted { $0.0 > $1.0 }
                .map { $0.1 }
            answer(state(["drawnRows": shown.map { row -> [String: Any] in
                var said = row.bench
                said["lit"] = row.lit
                return said
            }, "built": box?.kitSubviews(of: FieldRowSlot.self).filter { $0.superview != nil }.count ?? 0,
               "idle": browser.returnIsIdle, "returnWord": browser.pickedOffer?.placed?.returnWord ?? "",
               "downloadsTab": browser.pageTab(.downloads) != nil, "tabs": browser.tabs.count]))
        case "rowmenu":
            guard let item = browser.pickedOffer?.placed, let view = browser.window?.contentView,
                  let menu = browser.downloadsContextMenu(item, from: view) else {
                answer(["error": "no download row is lit"])
                return
            }
            answer(state(["items": menu.items.map { $0.isSeparatorItem ? "-" : $0.title },
                          "ids": menu.items.map { $0.accessibilityIdentifier() }]))
        case "command":
            guard let command = Command.named(args.dropFirst().first ?? "") else {
                answer(["error": "fieldrows command ID"])
                return
            }
            command.run(browser)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(state()) }
        case "keepmany":
            let count = Int(args.dropFirst().first ?? "") ?? 100
            let folder = Store.file("bench-downloads")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for index in 0..<count {
                let file = folder.appendingPathComponent("file-\(index).txt")
                try? Data("bench".utf8).write(to: file)
                browser.loot.add(Keep(name: "file-\(index).txt", from: "files.example", path: file.path,
                                      date: Date().addingTimeInterval(-Double(count - index) * 60)))
            }
            browser.retype()
            answer(state())
        case "scrollend":
            if let list = FieldLeaveBench.omnibox(in: browser)?.kitSubviews(of: NSScrollView.self).first(where: { $0.documentView?.frame.height ?? 0 > $0.contentView.bounds.height }),
               let page = list.documentView {
                page.scroll(NSPoint(x: 0, y: page.frame.height - list.contentView.bounds.height))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { answer(state()) }
        case "visit":
            let rest = Array(args.dropFirst())
            guard rest.count >= 2, let url = URL(string: rest[0]), let minutes = Double(rest[1]) else {
                answer(["error": "fieldrows visit URL MINUTES_AGO TITLE"])
                return
            }
            browser.history.take(url, title: rest.dropFirst(2).joined(separator: " "), count: 1,
                                 last: Date().addingTimeInterval(-minutes * 60))
            browser.history.settle()
            answer(state())
        case "keep":
            let rest = Array(args.dropFirst())
            guard rest.count >= 2, let minutes = Double(rest[1]) else {
                answer(["error": "fieldrows keep NAME MINUTES_AGO [HOST] [gone]"])
                return
            }
            let folder = Store.file("bench-downloads")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(rest[0])
            if rest.dropFirst(3).first != "gone" { try? Data("bench".utf8).write(to: file) }
            browser.loot.add(Keep(name: rest[0], from: rest.count > 2 ? rest[2] : "", path: file.path,
                                  date: Date().addingTimeInterval(-minutes * 60)))
            browser.retype()
            answer(state())
        case "remember":
            browser.prefs.remembersPageText = args.dropFirst().first != "off"
            answer(["on": browser.prefs.remembersPageText])
        case "drawn":
            answer(["drawn": FieldLeaveBench.drawn(in: browser) as Any])
        case "hold":
            OmniboxView.holdsWhileLeaving = args.dropFirst().first != "off"
            answer(["hold": OmniboxView.holdsWhileLeaving])
        case "clickout":
            FieldLeaveBench.clickOutside(browser)
            answer(["drawn": FieldLeaveBench.drawn(in: browser) as Any])
        case "line":
            guard let path = args.dropFirst().first else {
                answer(["error": "fieldrows line PATH"])
                return
            }
            answer(["saved": FieldLeaveBench.line(browser, to: URL(fileURLWithPath: path))])
        default:
            answer(["error": "fieldrows state|type TEXT|pagetext WORDS|forget|remember on|off"])
        }
    }
}

final class FieldPicture: NSView {
    init(browser: Browser, menu: FieldMenu, size: NSSize) {
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
        layer?.backgroundColor = KitColor.ground.cgColor
        var y: CGFloat = 0
        if let place = browser.fieldPlace {
            let glass = FieldLine.symbol("magnifyingglass", size: 16, tint: KitColor.ink.withAlphaComponent(0.8))
            let chip = PlaceChipView(place: place)
            let typed = FieldLine.label(browser.typed.isEmpty ? "Search \(place.title)" : browser.typed, size: 20,
                                        color: browser.typed.isEmpty ? KitColor.ink.withAlphaComponent(0.35) : KitColor.ink)
            var x: CGFloat = 18
            for view in [glass, chip, typed] as [NSView] {
                let fit = view.fittingSize
                let width = view === typed ? max(0, size.width - 18 - x) : fit.width
                view.frame = NSRect(x: x, y: (60 - fit.height) / 2, width: width, height: fit.height)
                addSubview(view)
                x += width + 12
            }
            y = 60
            if browser.offers.isEmpty {
                let empty = FieldLine.label(place.empty(for: browser.typed), size: 14, color: KitColor.muted)
                let fit = empty.fittingSize
                empty.frame = NSRect(x: 17, y: y + (38 - fit.height) / 2, width: size.width - 34, height: fit.height)
                addSubview(empty)
                y += 38
            }
        }
        let bar = FieldBarView(browser: browser, menu: menu)
        let barTop = size.height - FieldBarView.height - 11
        if menu.showing {
            let list = FieldMenuListView(menu: menu, rowHeight: 38, headerHeight: 28)
            list.frame = NSRect(x: 0, y: y, width: size.width, height: barTop - 11 - y)
            addSubview(list)
        } else {
            let slab = FieldSlabTrack()
            addSubview(slab)
            var lit: CGRect?
            for (index, offer) in browser.offers.enumerated() {
                if let section = browser.fieldSections.first(where: { $0.range.lowerBound == index }) {
                    let title = FieldLine.label(section.title, size: 13, color: KitColor.ink.withAlphaComponent(0.75))
                    let fit = title.fittingSize
                    title.frame = NSRect(x: 15, y: y + (28 - fit.height) / 2, width: size.width - 30, height: fit.height)
                    addSubview(title)
                    y += 28
                }
                let row = FieldRowView(offer: offer, height: 38, lit: browser.fieldRow == index)
                row.frame = NSRect(x: 7, y: y, width: size.width - 14, height: 38)
                addSubview(row)
                if browser.fieldRow == index { lit = row.frame }
                y += 38
            }
            slab.frame = bounds
            slab.show(lit, at: browser.fieldRow, faint: false)
        }
        bar.frame = NSRect(x: 12, y: barTop, width: size.width - 24, height: FieldBarView.height)
        addSubview(bar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
}
