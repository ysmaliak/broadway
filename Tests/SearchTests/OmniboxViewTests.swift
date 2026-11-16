import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld)
@MainActor
struct OmniboxViewTests {
    private func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    private func offer(_ name: String) -> Suggestion {
        Suggestion(key: "\(name).example", title: name, url: URL(string: "https://\(name).example/")!, kind: .visited)
    }

    @Test func theListPlacesHeadsAndRowsUnderEachOther() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let list = FieldListView(browser: browser, rowHeight: 38, headerHeight: 28, measure: "omniboxtest")
        list.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = window(list)
        defer { window.close() }

        browser.offers = [offer("a"), offer("b"), offer("c")]
        browser.fieldSections = [FieldSection(title: "First", range: 0..<2), FieldSection(title: "Second", range: 2..<3)]
        list.needsLayout = true
        window.layoutIfNeeded()

        let head = try #require(FieldLayout.frames["omniboxtest.head.First"])
        let first = try #require(FieldLayout.frames["omniboxtest.row.0"])
        let second = try #require(FieldLayout.frames["omniboxtest.row.1"])
        let later = try #require(FieldLayout.frames["omniboxtest.head.Second"])
        let last = try #require(FieldLayout.frames["omniboxtest.row.2"])
        #expect(head.height == 28)
        #expect(first.minY - head.minY == 28)
        #expect(first.minX == 7 && first.width == 586 && first.height == 38)
        #expect(second.minY - first.minY == 38)
        #expect(later.minY - second.minY == 38)
        #expect(last.minY - later.minY == 28)
    }

    @Test func theListFollowsTheOffersItIsShowing() throws {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let list = FieldListView(browser: browser, rowHeight: 38, headerHeight: 28, measure: "omniboxfollow")
        list.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let window = window(list)
        defer { window.close() }
        browser.offers = [offer("a")]
        browser.fieldSections = []
        list.needsLayout = true
        window.layoutIfNeeded()

        browser.offers = [offer("a"), offer("b")]
        let invalidated = list.needsLayout
        window.layoutIfNeeded()

        #expect(invalidated)
        let row = try #require(FieldLayout.frames["omniboxfollow.row.1"])
        #expect(row.height == 38)
    }

    @Test func theChipSizesToTheSiteAndSaysWhatItSearches() throws {
        let site = try #require(SiteSearch.builtIn.first)

        let chip = SiteChipView(site: site)

        #expect(chip.intrinsicContentSize.height == 22)
        #expect(chip.intrinsicContentSize.width > 36)
        #expect(chip.accessibilityLabel() == "Searching \(site.name)")
    }

    @Test func theFieldShowsWhatTheBrowserCompletesAndAsksForActionsInTheMenu() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let field = AddressTextField(keys: AddressFieldKeys(browser: browser))

        field.update(browser: browser, tab: nil, search: nil, prompt: AddressTextField.prompt, live: false)
        let typedText = field.stringValue
        field.update(browser: browser, tab: nil, search: "rel", prompt: AddressTextField.prompt, live: false)

        #expect(typedText == browser.completed)
        #expect(field.stringValue == "rel")
        #expect(field.placeholderAttributedString?.string == "Search actions")
        #expect(field.delegate === field.keys)
    }

    @Test func theFieldOverAPageLetsClicksThroughOnlyWhileShown() {
        _ = NSApplication.shared
        let browser = Browser(record: WindowRecord())
        defer { browser.closeAll() }
        let layer = FieldHost.Layer(browser: browser)
        layer.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = window(layer)
        defer { window.close() }

        layer.set(false, animated: false)
        window.layoutIfNeeded()

        #expect(layer.hitTest(NSPoint(x: 450, y: 300)) == nil)
        #expect(layer.hitTest(NSPoint(x: 10, y: 590)) == nil)
    }

    private func pageBrowser() -> Browser {
        let browser = Browser(record: WindowRecord())
        browser.open(URL(string: "https://a.example/")!, foreground: true)
        browser.open(URL(string: "https://b.example/")!, foreground: true)
        return browser
    }

    private func drawn(_ view: OmniboxView) -> [String] {
        let seen = view.benchDrawn
        let rows = seen["rows"] as? [String] ?? []
        let heads = seen["heads"] as? [String] ?? []
        return [seen["text"] as? String ?? "", seen["placeholder"] as? String ?? "", seen["bar"] as? String ?? "",
                heads.joined(separator: "|"), rows.joined(separator: "|")]
    }

    @Test func thePanelKeepsWhatItDrewWhileItLeaves() throws {
        _ = NSApplication.shared
        let browser = pageBrowser()
        defer { browser.closeAll() }
        let view = OmniboxView(browser: browser)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = window(view)
        defer { window.close() }

        browser.edit()
        window.layoutIfNeeded()
        let open = drawn(view)
        browser.dismiss()
        window.layoutIfNeeded()
        let leaving = drawn(view)

        #expect(open[0] == "https://b.example/")
        #expect(open[3] == "This Page")
        #expect(open[4].contains("Copy Address"))
        #expect(browser.typed.isEmpty && !browser.fieldShowing)
        #expect(leaving == open)
        #expect(view.benchDrawn["still"] as? Bool == true)
    }

    @Test func thePanelKeepsWhatWasTypedAndItsRowsWhileItLeaves() throws {
        _ = NSApplication.shared
        let browser = pageBrowser()
        defer { browser.closeAll() }
        let view = OmniboxView(browser: browser)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = window(view)
        defer { window.close() }

        browser.edit()
        browser.typed = "a.exa"
        window.layoutIfNeeded()
        let open = drawn(view)
        let other = try #require(browser.tabs.first { $0.id != browser.activeID && !$0.isBlank })
        browser.select(other)
        window.layoutIfNeeded()
        let leaving = drawn(view)
        browser.fieldRested()
        window.layoutIfNeeded()
        let rested = drawn(view)

        #expect(open[0].hasPrefix("a.exa"))
        #expect(!browser.fieldShowing)
        #expect(leaving == open)
        #expect(rested == open)
    }

    @Test func openingAgainWhileItLeavesShowsTheFreshField() throws {
        _ = NSApplication.shared
        let browser = pageBrowser()
        defer { browser.closeAll() }
        let view = OmniboxView(browser: browser)
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = window(view)
        defer { window.close() }

        browser.edit()
        browser.typed = "zzqx"
        window.layoutIfNeeded()
        let typed = drawn(view)
        browser.dismiss()
        window.layoutIfNeeded()
        browser.edit()
        window.layoutIfNeeded()
        let again = drawn(view)

        #expect(typed[0] == "zzqx")
        #expect(again[0] == "https://b.example/")
        #expect(again[3] == "This Page")
        #expect(again[4].contains("Copy Address"))
        #expect(view.benchDrawn["still"] as? Bool == false)
    }
}
