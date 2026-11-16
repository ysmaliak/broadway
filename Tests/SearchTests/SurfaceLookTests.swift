import AppKit
import Testing
@testable import Search

@MainActor
@Suite(.sharedWorld) struct SurfaceLookTests {
    private func titles(_ keys: [KitGlassKey]) -> [String] { keys.map(\.title) }

    private func laid(_ view: AskLine) -> NSSize {
        let size = view.fit(nil)
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        return size
    }

    @Test func aPageQuestionEndsWithItsMainAction() {
        let browser = Browser(record: WindowRecord())
        let camera = CaptureQuestionView(browser: browser, ask: Browser.CaptureAsk(host: "meet.example.com", wants: "camera", once: false, keeps: true))
        let place = CaptureQuestionView(browser: browser, ask: Browser.CaptureAsk(host: "meet.example.com", wants: "location", once: true, keeps: true))

        #expect(titles(camera.keys) == ["Don't Allow", "Allow"])
        #expect(titles(place.keys) == ["Don't Allow", "Always Allow", "Allow Once"])
        #expect(camera.keys.last?.kind == .primary)
        #expect(place.keys.last?.kind == .primary)
        #expect(place.keys.dropLast().allSatisfy { $0.kind == .secondary })
    }

    @Test func aPasswordOfferEndsWithSaveOrUpdate() {
        let browser = Browser(record: WindowRecord())
        let login = Login(host: "example.com", user: "ada@example.com", password: "x")
        let new = PasswordOfferView(browser: browser, offer: Browser.Offer(login: login, changed: false))
        let changed = PasswordOfferView(browser: browser, offer: Browser.Offer(login: login, changed: true))

        #expect(titles(new.keys) == ["Never Here", "Not Now", "Save"])
        #expect(titles(changed.keys) == ["Not Now", "Update"])
        #expect(new.keys.last?.kind == .primary)
        #expect(changed.keys.last?.kind == .primary)
    }

    @Test func theKeepOfferEndsWithKeep() {
        let forms = FormFill()
        defer { withExtendedLifetime(forms) {} }
        let bar = FormFillBar(forms: forms)
        let address = AutofillAddress(name: "Dana Scully", line1: "12 Orchard Lane", city: "Bristol", postal: "BS1 4DJ")

        bar.kind = .offer(FormFill.Offer(tab: UUID(), keep: .address(address)))

        let keys = bar.items.compactMap { $0 as? KitGlassKey }
        #expect(titles(keys) == ["Not Now", "Keep"])
        #expect(keys.last?.kind == .primary)
    }

    @Test func aOneLineBarHasOneHeightOneGapBetweenKeysAndAnEvenEnd() {
        let browser = Browser(record: WindowRecord())
        let login = Login(host: "example.com", user: "ada@example.com", password: "x")
        let bars: [AskLine] = [
            CaptureQuestionView(browser: browser, ask: Browser.CaptureAsk(host: "meet.example.com", wants: "location", once: true, keeps: true)),
            PasswordOfferView(browser: browser, offer: Browser.Offer(login: login, changed: false)),
            ShieldOfferView(browser: browser, shield: Shield.shared, host: "news.example.com"),
        ]

        for bar in bars {
            let size = laid(bar)
            let frames = bar.keys.map(\.frame)

            #expect(size.height == SurfaceLook.bar)
            #expect(frames.allSatisfy { $0.height == SurfaceLook.key })
            for (left, right) in zip(frames, frames.dropFirst()) {
                #expect(abs(right.minX - left.maxX - SurfaceLook.keyGap) <= 0.5)
            }
            #expect(abs(size.width - (frames.last?.maxX ?? 0) - SurfaceLook.barTrail) <= 0.5)
            #expect(abs((frames.last?.minY ?? 0) - SurfaceLook.barTrail) <= 0.5)
        }
    }

    @Test func anOfferBarKeepsTheBarMeasureAndEndsWithItsMainAction() {
        let bar = DeveloperOfferView.make(key: "localhost:3000", turnOn: {}, notNow: {})
        bar.frame = NSRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.layoutSubtreeIfNeeded()

        let frames = bar.buttons.map(\.frame)

        #expect(bar.buttons.map { $0.accessibilityLabel() } == ["Not Now", "Turn On"])
        #expect(bar.intrinsicContentSize.height == SurfaceLook.bar)
        #expect(frames.allSatisfy { $0.height == SurfaceLook.key })
        #expect(abs(frames[1].minX - frames[0].maxX - SurfaceLook.keyGap) <= 0.5)
        #expect(abs(bar.bounds.width - frames[1].maxX - SurfaceLook.barTrail) <= 0.5)
        #expect(abs(frames[1].minY - SurfaceLook.barTrail) <= 0.5)
    }

    @Test func theFormBarsKeysAreOneGapApartAndWordsStandOff() {
        let forms = FormFill()
        defer { withExtendedLifetime(forms) {} }
        let bar = FormFillBar(forms: forms)
        bar.kind = .done(FormFill.Done(tab: UUID(), filled: 5, stays: 2))
        bar.frame = NSRect(origin: .zero, size: bar.intrinsicContentSize)
        bar.layoutSubtreeIfNeeded()

        let frames = bar.items.map(\.frame)

        #expect(bar.intrinsicContentSize.height == SurfaceLook.bar)
        #expect(abs(frames[1].minX - frames[0].maxX - SurfaceLook.wordsToKeys) <= 0.5)
        #expect(abs(frames[2].minX - frames[1].maxX - SurfaceLook.keyGap) <= 0.5)
        #expect(abs(bar.bounds.width - frames[2].maxX - SurfaceLook.barTrail) <= 1)
    }

    @Test func theMainKeyCarriesItsOwnInkSoItReadsWhenItsWindowIsBehind() {
        for dark in [false, true] {
            #expect(KitGlass.keyInk(.primary, dark: dark) == KitPill.fill(.primary, dark: dark))
            #expect(KitGlass.keyInk(.secondary, dark: dark) == nil)
            #expect((KitGlass.keyInk(.destructive, dark: dark)?.alphaComponent ?? 0) > 0.8)
        }
        let face = KitGlassFace(KitSymbol("phone.down.fill", style: KitSymbol.Style(size: 13)))

        face.plate = KitGlass.keyInk(.destructive, dark: false)
        face.frame = NSRect(x: 0, y: 0, width: 32, height: 32)
        face.layoutSubtreeIfNeeded()

        let holder = face.contentView
        #expect(holder?.layer?.backgroundColor != nil)
        #expect(holder?.layer?.cornerRadius == 16)
    }

    @Test func anAnswerKeysWordIsInkAtTheKeysSizeAndAHintStaysQuiet() {
        let answer = CommandHintView("⌘↩", "Send", answers: true)
        let hint = CommandHintView("⌘C", "Copy")

        #expect(answer.word.color == KitColor.ink)
        #expect(answer.word.font.pointSize == BroadwaySize.small.font)
        #expect(hint.word.color == KitColor.muted)
        #expect(hint.word.font.pointSize == 11)
    }

    @Test func thePagesOwnRowsComeBeforeInspectElement() {
        #expect(PageView.pageRowsIndex(["WKMenuItemIdentifierReload", nil, "WKMenuItemIdentifierInspectElement"]) == 2)
        #expect(PageView.pageRowsIndex(["WKMenuItemIdentifierGoBack", "WKMenuItemIdentifierReload"]) == 2)
        #expect(PageView.pageRowsIndex([]) == 0)
    }

    @Test func theBookmarkCardsFieldsAreOneMeasure() {
        let browser = Browser(record: WindowRecord())
        let bookmarks = Bookmarks()
        let before = Set(bookmarks.roots.map(\.id))
        let made = bookmarks.insert(Bookmark(id: UUID(), title: "Swift Forums", url: "https://forums.swift.org", children: nil), into: nil)
        defer { for node in bookmarks.roots where !before.contains(node.id) { bookmarks.remove(node.id) } }
        let card = BookmarkCardView(browser: browser, bookmarks: bookmarks, id: made.id, close: {})
        card.frame = NSRect(origin: .zero, size: card.intrinsicContentSize)
        card.layoutSubtreeIfNeeded()

        #expect(card.name.frame.height == SurfaceLook.field)
        #expect(card.folder.frame.height == SurfaceLook.field)
        #expect(card.name.frame.minX == card.folder.frame.minX)
        #expect(card.name.frame.maxX == card.folder.frame.maxX)
        #expect(card.name.frame.maxX == card.bounds.width - SurfaceLook.pad)
        #expect(card.name.field.font == SurfaceLook.fieldFont)
    }

    @Test func bufferingAndGoLiveShareALineAtTheScrubbersEnds() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 225)

        let waiting = FloatLayout.waiting(in: bounds)
        let live = FloatLayout.live(in: bounds)

        #expect(waiting.midY == live.midY)
        #expect(waiting.height == FloatLayout.line)
        #expect(waiting.minX == bounds.minX + FloatLayout.scrubSide)
        #expect(live.maxX == bounds.maxX - FloatLayout.scrubSide)
    }

    @Test func aCutAddressNeverLeavesAFullStopBeforeTheEllipsis() {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12)]
        let text = "https://developer.apple.com/documentation/appkit/nsglasseffectview"

        for width in stride(from: CGFloat(120), through: 380, by: 7) {
            let cut = KitTruncate.middleParts(text, attributes: attributes, to: width)

            #expect(!cut.cut || !cut.head.hasSuffix("."))
            #expect(cut.width <= width)
        }
    }
}
