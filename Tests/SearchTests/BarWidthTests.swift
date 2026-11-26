import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct BarWidthTests {
    private let long = "Page not working? Ad Shield, Quiet Pages, Tracker Tamer and Cookie Calm still block here. Pause them from their own buttons."

    private func stack(page: CGRect) -> BarStack {
        _ = NSApplication.shared
        let stack = BarStack(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        stack.page = page
        return stack
    }

    private func offer() -> OfferBarView {
        OfferBarView(long, choices: [.init("Not Now") {}, .init("Allow Ads Here", .primary) {}])
    }

    private func line() -> AskLine {
        let made = AskLine(symbol: nil, text: long, trailing: 9)
        made.keys = [KitGlassKey(title: "Not Now") {}, KitGlassKey(title: "Allow Ads Here", kind: .primary) {}]
        return made
    }

    private func check(_ view: NSView, in page: CGRect) {
        let stack = stack(page: page)
        stack.show([BarStack.Bar(view: view, kind: .offer)])
        stack.layoutSubtreeIfNeeded()
        let frame = view.frame
        #expect(frame.width <= page.width - 2 * BarStack.margin + 0.5)
        #expect(frame.minX >= page.minX + BarStack.margin - 0.5)
        #expect(frame.maxX <= page.maxX - BarStack.margin + 0.5)
        #expect(abs(frame.midX - page.midX) <= 1)
        #expect(view.toolTip == long)
        #expect(view.accessibilityLabel() == long)
    }

    @Test func aLongOfferInANarrowWindowStaysOnThePageBesideTheSidebar() {
        check(offer(), in: CGRect(x: 240, y: 0, width: 400, height: 480))
        check(line(), in: CGRect(x: 240, y: 0, width: 400, height: 480))
    }

    @Test func theSameHoldsWithTheSidebarOnTheRightOrFolded() {
        check(offer(), in: CGRect(x: 0, y: 0, width: 400, height: 480))
        check(line(), in: CGRect(x: 6, y: 0, width: 628, height: 480))
    }

    @Test func theWordsTruncateAndTheButtonsStayWhole() {
        let made = line()
        let stack = stack(page: CGRect(x: 240, y: 0, width: 400, height: 480))
        stack.show([BarStack.Bar(view: made, kind: .offer)])
        stack.layoutSubtreeIfNeeded()
        made.layoutSubtreeIfNeeded()
        for key in made.keys {
            #expect(abs(key.frame.width - key.intrinsicContentSize.width) <= 1)
            #expect(key.frame.maxX <= made.bounds.width)
        }
        #expect(made.question.frame.height <= QuestionView.height(made.question, width: .greatestFiniteMagnitude) + 0.5)
        #expect(made.question.frame.width < QuestionView.width(made.question))
    }

    @Test func aFormBarTruncatesItsWordsLikeTheOthers() {
        let made = FormGlassBar()
        made.items = [KitLabel(long, font: .systemFont(ofSize: 13)), KitGlassKey(title: "Not Now") {}, KitGlassKey(title: "Keep", kind: .primary) {}]
        check(made, in: CGRect(x: 240, y: 0, width: 400, height: 480))
        made.layoutSubtreeIfNeeded()
        for key in made.items.dropFirst() {
            #expect(abs(key.frame.width - key.intrinsicContentSize.width) <= 1)
            #expect(key.frame.maxX <= made.bounds.width)
        }
    }

    @Test func aCaptureQuestionWrapsInsteadSoItsLastWordStays() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let made = CaptureQuestionView(browser: browser, ask: Browser.CaptureAsk(host: "meet.example.com", wants: "camera"))
        let page = CGRect(x: 240, y: 0, width: 300, height: 480)
        let stack = stack(page: page)
        stack.show([BarStack.Bar(view: made, kind: .question)])
        stack.layoutSubtreeIfNeeded()
        #expect(made.frame.width <= page.width - 2 * BarStack.margin + 0.5)
        #expect(made.frame.height > made.fit(nil).height)
        #expect(made.toolTip == nil)
    }

    @Test func anAnnouncementInTheShellsLayersStaysOnThePage() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let page = CGRect(x: 240, y: 0, width: 400, height: 480)
        let upper = ShellUpperLayer(browser: browser)
        let lower = ShellLowerLayer(browser: browser)
        upper.paneSpot = { page }
        lower.paneSpot = { page }
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 640, height: 480), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        for layer in [lower, upper] as [NSView] {
            layer.frame = window.contentView!.bounds
            window.contentView?.addSubview(layer)
        }
        browser.announce(long)
        for layer in [lower, upper] as [NSView] {
            layer.needsLayout = true
            layer.layoutSubtreeIfNeeded()
        }
        let notes = [lower, upper].flatMap { layer in Self.notes(in: layer).map { layer.convert($0.bounds, from: $0) } }
        let note = try? #require(notes.first)
        #expect(notes.count == 1)
        if let note {
            #expect(note.minX >= page.minX + BarStack.margin - 0.5)
            #expect(note.maxX <= page.maxX - BarStack.margin + 0.5)
        }
    }

    @Test func theBarsAreLaidOutAgainWhenThePageMovesSideways() {
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let stage = ShellStageLayer(browser: browser)
        stage.frame = NSRect(x: 240, y: 0, width: 400, height: 480)
        var heard = 0
        stage.onSpot = { heard += 1 }

        stage.setFrameOrigin(NSPoint(x: 0, y: 0))
        stage.setFrameOrigin(NSPoint(x: 0, y: 0))

        #expect(heard == 1)
    }

    private static func notes(in view: NSView) -> [CapsuleNote] {
        view.subviews.flatMap { sub in (sub as? CapsuleNote).map { [$0] } ?? notes(in: sub) }
    }

    @Test func aShortBarKeepsItsOwnWidthAndNoTooltip() {
        let made = OfferBarView("Turn on Developer Mode?", choices: [.init("Turn On", .primary) {}])
        let stack = stack(page: CGRect(x: 240, y: 0, width: 400, height: 480))
        stack.show([BarStack.Bar(view: made, kind: .offer)])
        stack.layoutSubtreeIfNeeded()
        #expect(abs(made.frame.width - made.intrinsicContentSize.width) <= 1)
        #expect(made.toolTip == nil)
    }
}
