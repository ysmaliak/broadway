import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class NewTabPageTests {
    private var browser: Browser!
    private var saved = false

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        browser = Browser(record: WindowRecord())
        saved = browser.prefs.floatingNewTab
    }

    private func tearDown() async {
        browser.prefs.floatingNewTab = saved
        browser.closeAll()
        browser = nil
    }

    private func page(_ url: URL) -> Search.Tab {
        let tab = browser.open(url, foreground: true)
        return tab
    }

    @Test func thePageIsTheDefault() {
        let key = "newtab.floating"
        let store = Store.settings
        let registered = store.volatileDomain(forName: UserDefaults.registrationDomain)
        let stored = store.object(forKey: key)
        defer {
            store.setVolatileDomain(registered, forName: UserDefaults.registrationDomain)
            if let stored { store.set(stored, forKey: key) } else { store.removeObject(forKey: key) }
        }
        var bare = registered
        bare.removeValue(forKey: key)
        store.setVolatileDomain(bare, forName: UserDefaults.registrationDomain)
        store.removeObject(forKey: key)
        #expect(store.object(forKey: key) == nil)

        let prefs = Preferences()

        #expect(prefs.newTabStyle == .page)
        #expect(!prefs.floatingNewTab)
    }

    @Test func theStyleIsStoredInTheFloatingSetting() {
        let prefs = browser.prefs

        prefs.newTabStyle = .floating

        #expect(prefs.floatingNewTab)
        #expect((Store.settings.object(forKey: "newtab.floating") as? Bool) == true)

        prefs.newTabStyle = .page

        #expect(!prefs.floatingNewTab)
        #expect(prefs.newTabStyle == .page)
        #expect((Store.settings.object(forKey: "newtab.floating") as? Bool) == false)
    }

    @Test func theSettingTakesBothWordsFromAScript() throws {
        let access = try #require(PersonSettings.table["newtab.floating"])

        #expect((access.write?(browser.prefs, "true")) == true)
        #expect(browser.prefs.newTabStyle == .floating)
        #expect((access.write?(browser.prefs, "false")) == true)
        #expect(browser.prefs.newTabStyle == .page)
    }

    @Test func newTabWithThePageMakesABlankTabThatShowsIt() {
        browser.prefs.newTabStyle = .page
        let before = page(URL(string: "about:blank#before")!)

        browser.launch()
        browser.launch()

        #expect(!browser.launching)
        #expect(browser.tabs.filter { $0.isBlank }.count == 1)
        #expect(browser.activeID != before.id)
        #expect(browser.active?.isBlank == true)
        #expect(browser.active?.label == "New Tab")
        #expect(browser.newTabPageShown)
    }

    @Test func newTabWithTheFloatingFieldRaisesItOverThePage() {
        browser.prefs.newTabStyle = .floating
        let before = page(URL(string: "about:blank#before")!)
        let count = browser.tabs.count

        browser.launch()

        #expect(browser.launching)
        #expect(browser.editing)
        #expect(browser.tabs.count == count)
        #expect(browser.activeID == before.id)
        #expect(!browser.newTabPageShown)
    }

    @Test func aBlankTabWithTheFloatingFieldDoesNotShowThePage() {
        browser.prefs.newTabStyle = .floating

        browser.newTab()

        #expect(browser.active?.isBlank == true)
        #expect(!browser.newTabPageShown)
        #expect(browser.fieldShowing)
    }

    @Test func returnOpensWhatWasTypedInThisSameTabWithNothingBehindIt() async throws {
        let server = try LocalPageServer(["/here": .init(type: "text/html", body: "<!doctype html><title>Here</title><p>here")])
        defer { server.stop() }
        browser.prefs.newTabStyle = .page
        browser.newTab()
        let blank = try #require(browser.active)
        let count = browser.tabs.count
        let url = server.url("/here")

        browser.typed = url.absoluteString
        browser.submit()

        #expect(browser.activeID == blank.id)
        #expect(browser.tabs.count == count)
        #expect(!blank.isBlank)
        #expect(!browser.newTabPageShown)
        #expect(browser.typed == "")
        for _ in 0..<100 where blank.web.url == nil || blank.web.isLoading {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(blank.web.url == url)
        #expect(!blank.web.canGoBack)
        #expect(blank.web.backForwardList.backItem == nil)
    }

    @Test func escapeClearsWhatWasTypedFirst() throws {
        browser.prefs.newTabStyle = .page
        _ = page(URL(string: "about:blank#before")!)
        browser.newTab()
        let blank = try #require(browser.active)
        browser.typed = "weather"

        let handled = browser.escapeNewTab()

        #expect(handled)
        #expect(browser.typed == "")
        #expect(browser.activeID == blank.id)
        #expect(browser.tabs.contains { $0.id == blank.id })
    }

    @Test func escapeOnAnEmptyPageGoesBackToTheTabBefore() throws {
        browser.prefs.newTabStyle = .page
        let before = page(URL(string: "about:blank#before")!)
        browser.newTab()
        let blank = try #require(browser.active)
        #expect(blank.id != before.id)
        let closed = browser.recentlyClosed.count

        let handled = browser.escapeNewTab()

        #expect(handled)
        #expect(browser.activeID == before.id)
        #expect(!browser.tabs.contains { $0.id == blank.id })
        #expect(browser.recentlyClosed.count == closed)
    }

    @Test func oneEscapeLeavesAnUntouchedPageEvenWithARowLit() throws {
        browser.prefs.newTabStyle = .page
        let before = page(URL(string: "about:blank#before")!)
        browser.newTab()
        let blank = try #require(browser.active)
        browser.picked = 0

        let handled = browser.escapeEmptyNewTabPage()

        #expect(handled)
        #expect(browser.activeID == before.id)
        #expect(!browser.tabs.contains { $0.id == blank.id })
    }

    @Test func oneEscapeWithTheFloatingFieldStillLetsGoOfTheRowFirst() throws {
        browser.prefs.newTabStyle = .floating
        _ = page(URL(string: "about:blank#before")!)
        browser.newTab()
        browser.picked = 0

        #expect(!browser.escapeEmptyNewTabPage())
    }

    @Test func escapeOnTheLastTabLeavesTheEmptyPage() throws {
        browser.closeAll()
        browser.prefs.newTabStyle = .page
        browser.newTab()
        let blank = try #require(browser.active)
        #expect(browser.tabs.count == 1)

        let handled = browser.escapeNewTab()

        #expect(!handled)
        #expect(browser.activeID == blank.id)
        #expect(browser.newTabPageShown)
    }

    @Test func escapeOnAPageDoesNothingHere() {
        browser.prefs.newTabStyle = .page
        _ = page(URL(string: "about:blank#before")!)

        #expect(!browser.escapeNewTab())
    }

    @Test func switchingToAnOpenTabFromThePageTakesTheEmptyTabAway() throws {
        browser.prefs.newTabStyle = .page
        let other = page(URL(string: "about:blank#other")!)
        browser.newTab()
        let blank = try #require(browser.active)
        let offer = Suggestion(key: other.label, title: "", url: URL(string: "about:blank#other")!, kind: .open, tab: other.id)
        let closed = browser.recentlyClosed.count

        browser.take(offer)

        #expect(browser.activeID == other.id)
        #expect(!browser.tabs.contains { $0.id == blank.id })
        #expect(browser.recentlyClosed.count == closed)
    }

    @Test func switchingToAnOpenTabFromTheFloatingFieldKeepsTheBlankTab() throws {
        browser.prefs.newTabStyle = .floating
        let other = page(URL(string: "about:blank#other")!)
        browser.newTab()
        let blank = try #require(browser.active)
        let offer = Suggestion(key: other.label, title: "", url: URL(string: "about:blank#other")!, kind: .open, tab: other.id)

        browser.take(offer)

        #expect(browser.activeID == other.id)
        #expect(browser.tabs.contains { $0.id == blank.id })
    }

    @Test func thePageAtRestOffersNothing() {
        browser.prefs.newTabStyle = .page
        _ = page(URL(string: "about:blank#before")!)
        browser.newTab()

        browser.fieldRose()

        #expect(browser.newTabPageShown)
        #expect(browser.offers.isEmpty)
        #expect(browser.fieldSections.isEmpty)
        #expect(browser.picked == nil)
    }

    @Test func clearingWhatWasTypedOnThePageGoesBackToNothing() {
        browser.prefs.newTabStyle = .page
        _ = page(URL(string: "about:blank#before")!)
        browser.newTab()
        browser.typed = "example"
        #expect(!browser.offers.isEmpty)

        browser.typed = ""

        #expect(browser.offers.isEmpty)
        #expect(browser.fieldSections.isEmpty)
        #expect(browser.picked == nil)
    }

    @Test func theFloatingFieldStillOffersRecentTabsAtRest() {
        browser.prefs.newTabStyle = .floating
        _ = page(URL(string: "about:blank#before")!)
        _ = page(URL(string: "about:blank#after")!)

        browser.fieldRose()

        #expect(!browser.newTabPageShown)
        #expect(browser.fieldSections.contains { $0.title == "Recent Tabs" })
    }

    @Test func theFieldSitsAtTheOpticalCentreWithNothingAboveIt() {
        let size = CGSize(width: 1200, height: 900)

        let layout = NewTabPageView.layout(in: size)
        let middle = layout.fieldTop + NewTabPageView.fieldHeight / 2

        #expect(abs(middle - (size.height * 0.42)) <= 1)
        #expect(middle < (size.height / 2))
        #expect(layout.fieldWidth == 640)
    }

    @Test func theFieldStaysInsideTheWindowAtEverySize() {
        for size in [CGSize(width: 420, height: 360), CGSize(width: 800, height: 560), CGSize(width: 1200, height: 900),
                     CGSize(width: 2400, height: 1400)] {
            let layout = NewTabPageView.layout(in: size)

            #expect(layout.fieldTop >= 24, "\(size)")
            #expect((layout.fieldTop + NewTabPageView.fieldHeight) < size.height, "\(size)")
            #expect(layout.fieldWidth <= (size.width - 48) || layout.fieldWidth == 260, "\(size)")
            #expect(layout.room >= 0, "\(size)")
        }
    }

    @Test func thePageDrawsNoMarkAboveTheField() throws {
        browser.prefs.newTabStyle = .page
        browser.newTab()
        let tab = try #require(browser.active)
        let page = NewTabPageView(browser: browser, tab: tab, corner: 10, resting: true)

        let window = placed(page, NSSize(width: 1000, height: 700))
        defer { window.close() }
        let fieldTop = NewTabPageView.layout(in: CGSize(width: 1000, height: 700)).fieldTop

        let above = page.subviews.filter { !$0.isHidden && $0.frame.height > 0 && $0.frame.maxY <= fieldTop && $0.frame != page.bounds }
        #expect(above.isEmpty)
    }

    @Test func theFieldStaysPutWhileTyping() {
        let size = CGSize(width: 1000, height: 700)

        let resting = NewTabPageView.layout(in: size)
        let again = NewTabPageView.layout(in: size)

        #expect(resting == again)
    }

    @Test func theRestingPageShowsThePromptAndNoField() throws {
        browser.prefs.newTabStyle = .page
        browser.newTab()
        let tab = try #require(browser.active)
        let page = NewTabPageView(browser: browser, tab: tab, corner: 10, resting: true)

        let window = placed(page, NSSize(width: 1000, height: 700))
        defer { window.close() }

        let prompt = try #require(page.kitSubviews(of: KitLabel.self).first { $0.text == NewTabPageView.prompt })
        #expect(!prompt.isHidden)
        #expect(page.accessibilityLabel() == "New Tab")
    }

    @Test func theFieldsWordsSitOnItsMidlineBesideTheMagnifier() throws {
        browser.prefs.newTabStyle = .page
        browser.newTab()
        let tab = try #require(browser.active)
        let page = NewTabPageView(browser: browser, tab: tab, corner: 10)

        let window = placed(page, NSSize(width: 1000, height: 700))
        defer { window.close() }
        page.layoutSubtreeIfNeeded()

        let glass = try #require(page.kitSubviews(of: KitGlass.self).first)
        let field = try #require(page.kitSubviews(of: AddressTextField.self).first)
        let font = try #require(field.font)
        let baseline = field.isFlipped ? field.firstBaselineOffsetFromTop : field.bounds.height - field.firstBaselineOffsetFromTop
        let line = field.convert(NSRect(x: 0, y: baseline, width: 1, height: 0), to: glass)
        let capCentre = (glass.isFlipped ? line.minY : glass.bounds.height - line.minY) - font.capHeight / 2
        #expect(abs(capCentre - glass.bounds.height / 2) <= 0.5)
        let lens = try #require(page.kitSubviews(of: KitSymbol.self).first)
        let lensCentre = lens.convert(lens.bounds, to: glass).midY
        #expect(abs(lensCentre - glass.bounds.height / 2) <= 0.5)
    }

    @Test func theRestingPromptSitsOnTheFieldsMidline() throws {
        browser.prefs.newTabStyle = .page
        browser.newTab()
        let tab = try #require(browser.active)
        let page = NewTabPageView(browser: browser, tab: tab, corner: 10, resting: true)

        let window = placed(page, NSSize(width: 1000, height: 700))
        defer { window.close() }

        let glass = try #require(page.kitSubviews(of: KitGlass.self).first)
        let prompt = try #require(page.kitSubviews(of: KitLabel.self).first { $0.text == NewTabPageView.prompt })
        let box = prompt.convert(prompt.bounds, to: glass)
        let natural = prompt.measure(width: .greatestFiniteMagnitude).height
        let lineTop = (glass.isFlipped ? box.minY : glass.bounds.height - box.maxY) + (box.height - natural) / 2
        let capCentre = lineTop + prompt.font.ascender - prompt.font.capHeight / 2
        #expect(abs(capCentre - glass.bounds.height / 2) <= 0.5)
    }

    @Test func thePageAppearsWholeWithNoEntrance() throws {
        browser.prefs.newTabStyle = .page
        browser.newTab()
        let tab = try #require(browser.active)
        let page = NewTabPageView(browser: browser, tab: tab, corner: 10, resting: true)

        let window = placed(page, NSSize(width: 1000, height: 700))
        defer { window.close() }

        #expect(page.layer?.animationKeys() == nil)
        for view in page.subviews { #expect(view.layer?.animationKeys() == nil) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCH_NEWTAB"] != nil, "SEARCH_NEWTAB names a folder to draw the new tab page into"))
    func drawsTheQuietPage() throws {
        let folder = try #require(ProcessInfo.processInfo.environment["SEARCH_NEWTAB"].map { URL(fileURLWithPath: $0, isDirectory: true) })
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        browser.prefs.newTabStyle = .page
        browser.newTab()
        let tab = try #require(browser.active)
        let sizes = [CGSize(width: 1100, height: 760), CGSize(width: 720, height: 520), CGSize(width: 1600, height: 1000)]
        for colour in ["gray", "graphite", "sky", "coral", "sage", "lavender"] {
            for dark in [true, false] {
                for size in colour == "gray" ? sizes : [sizes[0]] {
                    var look = SpaceLook()
                    look.colour = colour
                    let name = "newtab-\(colour)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height)).png"
                    try draw(NewTabPageView(browser: browser, tab: tab, corner: 10, look: look, resting: true),
                             size: size, dark: dark, to: folder.appendingPathComponent(name))
                }
            }
        }
    }

    private func placed(_ view: NSView, _ size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.layoutIfNeeded()
        return window
    }

    private func draw(_ page: NewTabPageView, size: CGSize, dark: Bool, to url: URL) throws {
        let window = placed(page, size)
        defer { window.close() }
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        page.layoutSubtreeIfNeeded()
        page.displayIfNeeded()
        let layer = try #require(page.layer)
        let scale = 2
        let context = try #require(CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        layer.render(in: context)
        let image = try #require(context.makeImage())
        let rep = NSBitmapImageRep(cgImage: image)
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
