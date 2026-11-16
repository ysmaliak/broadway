import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct PlainSymbolsTests {
    private func all(in view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { all(in: $0) }
    }

    private func symbols(in view: NSView) -> [KitSymbol] {
        all(in: view).compactMap { $0 as? KitSymbol }
    }

    private func plated(_ symbol: KitSymbol, within root: NSView) -> Bool {
        var view: NSView? = symbol
        while let here = view, here !== root {
            if let box = here as? KitBox, box.fill != nil || !box.gradient.isEmpty { return true }
            if let parent = here.superview {
                let frame = symbol.convert(symbol.bounds, to: parent)
                for sibling in parent.subviews where sibling !== here {
                    guard let box = sibling as? KitBox, box.fill != nil || !box.gradient.isEmpty else { continue }
                    if box.frame.contains(frame) && box.frame.width < 60 { return true }
                }
            }
            if here.layer?.backgroundColor.map({ $0.alpha > 0 }) == true { return true }
            view = here.superview
        }
        return false
    }

    private func nowOffer(_ symbol: String) -> Suggestion {
        var offer = Suggestion(key: "Join Design review", title: "In 10 minutes · Google Meet", url: FieldAction.nowhere,
                               kind: .action("now:meeting:x"))
        offer.symbol = symbol
        return offer
    }

    private func laidOut(_ offer: Suggestion, lit: Bool = false) -> FieldRowView {
        let row = FieldRowView(offer: offer, height: 38, lit: lit)
        row.frame = NSRect(x: 0, y: 0, width: 560, height: 38)
        row.layoutSubtreeIfNeeded()
        return row
    }

    private func label(_ text: String, in view: NSView) -> KitLabel? {
        all(in: view).compactMap { $0 as? KitLabel }.first { $0.text == text }
    }

    @Test(arguments: ["calendar", "link", "arrow.down.circle"])
    func aNowRowDrawsItsSymbolWithNoBackground(symbol: String) throws {
        let offer = nowOffer(symbol)

        let row = laidOut(offer)

        let icon = try #require(symbols(in: row).first { $0.name == symbol })
        #expect(!plated(icon, within: row))
        #expect(icon.tint == KitColor.muted)
        #expect(!all(in: row).contains { ($0 as? KitBox)?.fill != nil })
    }

    @Test func aNowRowLinesUpWithASiteRow() throws {
        let site = Suggestion(key: "github.com", title: "GitHub", url: URL(string: "https://github.com")!, kind: .open)
        let now = nowOffer("calendar")

        let siteRow = laidOut(site)
        let nowRow = laidOut(now)

        let siteText = try #require(label("github.com", in: siteRow))
        let nowText = try #require(label("Join Design review", in: nowRow))
        #expect(siteText.frame.minX == nowText.frame.minX)
        let mark = try #require(all(in: siteRow).first { $0 is FieldMark })
        let icon = try #require(symbols(in: nowRow).first { $0.name == "calendar" })
        #expect(abs(mark.frame.midX - icon.frame.midX) <= 0.5)
        #expect(abs(mark.frame.midY - icon.frame.midY) <= 0.5)
        #expect(icon.frame.width <= mark.frame.width)
    }

    @Test func theMeetingCardShowsItsServiceSymbolWithNoTile() throws {
        let surface = MeetingAlerts.surface("two")

        surface.layoutSubtreeIfNeeded()

        let services = symbols(in: surface).filter { ["video", "phone", "headphones", "calendar"].contains($0.name) }
        #expect(!services.isEmpty)
        for symbol in services {
            #expect(!plated(symbol, within: surface))
            #expect(symbol.tint == KitColor.muted)
        }
    }

    @Test func aMeetingShowsItsCallInOutlineAndACalendarWithoutALink() {
        let now = Date()
        func meeting(_ link: String) -> Meeting {
            Meeting(event: CalendarEvent(id: link, title: "Design review", start: now.addingTimeInterval(300),
                                         end: now.addingTimeInterval(2100), url: URL(string: link)))
        }

        let meet = meeting("https://meet.google.com/abc-defg-hij")
        let plain = Meeting(event: CalendarEvent(id: "plain", title: "Lunch", start: now.addingTimeInterval(300), end: now.addingTimeInterval(2100)))

        #expect(meet.symbol == "video")
        #expect(plain.symbol == "calendar")
        #expect(NowBoard.meetingRow(meet, at: now)?.symbol == "video")
        #expect(NowBoard.meetingRow(meet, at: now.addingTimeInterval(-1800))?.symbol == "calendar")
    }

    @Test func aQuickActionWithNoSiteShowsItsSymbolWithNoTile() throws {
        let view = QuickActionIconView()
        let action = QuickAction(id: "doc", name: "New Doc", aliases: [], address: "docs.new")

        view.show(action, site: nil)

        let symbol = try #require(symbols(in: view).first)
        #expect(!plated(symbol, within: view))
        #expect(!all(in: view).contains { $0 is KitBox })
    }
}
