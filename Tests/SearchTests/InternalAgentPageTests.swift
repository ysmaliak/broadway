import AppKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class InternalAgentPageTests {
    private var browser: Browser!
    private var box: BrowserToolbox!

    init() {
        keepSetting(Shared.prefs, \.agentMode, "agents.mode")
        addTeardownBlock { self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        browser.prefs.agentMode = .bypass
        box = BrowserToolbox()
        box.browser = browser
    }

    private func tearDown() {
        browser.closeAll()
        browser = nil
        box = nil
    }

    @Test func everyInternalKindHasItsCanonicalAddressInAllTabReaders() async throws {
        let pages = InternalPage.Kind.allCases.map { InternalPage($0, $0 == .settings ? "privacy" : nil) }.filter { !InternalPage.retired($0.url) }
        let tabs = pages.map { page in
            let tab = Tab()
            tab.restore(url: URL(string: "https://example.com/old")!, title: "Old")
            tab.show(page)
            return tab
        }
        let blank = Tab()
        let web = Tab()
        web.restore(url: URL(string: "https://example.com/page")!, title: "Web")
        browser.showRow(tabs + [blank, web], active: blank.id)
        let call = PersonCall(noun: "tabs", verb: "list", arguments: [:], browser: browser, box: box)

        let mcp = await box.call("tabs", [:], task: nil)
        let cli = try await PersonCommands.find("tabs", "list")!.run(call)
        let mcpRows = try #require(ToolReply.data(mcp)["tabs"] as? [[String: Any]])
        let cliRows = try #require(cli["tabs"] as? [[String: Any]])
        let watchRows = PersonTabs.everyTab(call).map { PersonWatch.tabRow($0, box: box) }

        for rows in [mcpRows, cliRows, watchRows] {
            for (tab, page) in zip(tabs, pages) {
                let row = rows.first { $0["id"] as? String == PersonCommands.short(tab.id) }
                #expect((row?["url"] as? String) == page.url.absoluteString)
            }
            #expect((rows.first { $0["id"] as? String == PersonCommands.short(blank.id) }?["url"] as? String) == "")
            #expect((rows.first { $0["id"] as? String == PersonCommands.short(web.id) }?["url"] as? String) == "https://example.com/page")
        }
    }

    @Test func internalPagesRefuseToolsAndCLIArrangementButAllowMetadata() async throws {
        let tab = Tab()
        tab.show(InternalPage(.history))
        tab.agent = true
        browser.showRow([tab], active: tab.id)
        let id = PersonCommands.short(tab.id)
        let arguments: [String: Any] = ["tab": id, "url": "https://example.com/", "ref": "@e1"]
        let call = PersonCall(noun: "tabs", verb: "select", arguments: arguments, browser: browser, box: box)

        for name in ["navigate", "close", "snapshot", "text", "screenshot", "click", "type", "press", "scroll", "wait", "console", "network"] {
            let result = await box.call(name, arguments, task: nil)
            #expect(result.failed, "\(name)")
            #expect(result.text?.contains("person-only") == true, "\(name)")
        }
        for name in ["broadway://history", "broadway://settings/privacy"] {
            let result = await box.call("open", ["url": name], task: nil)
            #expect(result.failed)
            #expect(throws: (any Error).self) { try PersonTabs.webAddress(name) }
        }

        let error = #expect(throws: (any Error).self) { try PersonTabs.find(call, id) }
        #expect((error as? PersonRefusal)?.code == "person_only")
        let metadata = try await PersonCommands.find("tabs", "show")!.run(call)
        #expect((metadata["url"] as? String) == "broadway://history")
        #expect(tab.page == InternalPage(.history))
        #expect(tab.built == nil)
        #expect(browser.tabs.contains { $0 === tab })
    }
}
