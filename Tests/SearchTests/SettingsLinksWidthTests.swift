import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
struct SettingsLinksWidthTests {
    private func settle(_ window: NSWindow) async throws {
        try await Task.sleep(for: .milliseconds(200))
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
    }

    @Test func openingLinksAndARuleKeepsTheWindowsWidth() async throws {
        let browser = Browser(record: WindowRecord())
        let rule = LinkRules.shared.add(LinkRule(match: .site("example.com"), target: .window(nil)))
        let window = SettingsWindow.frame(browser, asked: "general")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        addTeardownBlock {
            LinkRules.shared.remove(rule.id)
            window.contentViewController = nil
            window.close()
            browser.closeAll()
        }
        let split = try #require(window.contentViewController as? SettingsSplit)
        try await settle(window)
        let opened = window.frame.width

        split.shell.go(to: .links)
        try await settle(window)
        let onLinks = window.frame.width
        split.shell.openLinkRule(rule.id)
        try await settle(window)
        let onRule = window.frame.width
        split.shell.go(to: .general)
        try await settle(window)
        let after = window.frame.width

        #expect(opened == SettingsSize.opening.width)
        #expect(onLinks == opened)
        #expect(onRule == opened)
        #expect(after == opened)
    }

    @Test func theTryFieldsFillTheirRowAndOtherFieldsKeepTheirWidth() throws {
        let browser = Browser(record: WindowRecord())
        let rule = LinkRules.shared.add(LinkRule(match: .site("example.com"), target: .window(nil)))
        addTeardownBlock {
            LinkRules.shared.remove(rule.id)
            browser.closeAll()
        }
        let shell = SettingsShell()
        let page = SettingsPageView(browser: browser, shell: shell)
        page.linkDraft.more[rule.id] = true
        func widths() -> [String: [CGFloat]] {
            var found: [String: [CGFloat]] = [:]
            for field in page.kitSubviews(of: NSTextField.self) where field.isEditable {
                found[field.accessibilityLabel() ?? ""] = field.constraints.filter { $0.firstAttribute == .width && $0.secondItem == nil && $0.isActive }
                    .map(\.constant)
            }
            return found
        }

        shell.go(to: .links)
        page.rebuild()
        let links = widths()
        shell.openLinkRule(rule.id)
        page.rebuild()
        let one = widths()

        #expect(links["Address"] == [])
        #expect(one["Try it"] == [])
        #expect(one[LinkRuleWords.field] == [300])
        #expect(one["Note"] == [300])
        #expect(one["Find"] == [300])
    }
}
