import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentCoverTests {
    private let task = UUID()
    private var browser: Browser!
    private var box: BrowserToolbox!
    private var server: LocalPageServer!

    init() async throws {
        addTeardownBlock { await self.tearDown() }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        browser = Browser(record: WindowRecord())
        box = BrowserToolbox()
        box.browser = browser
        browser.prefs.agentMode = .auto
        AgentSites.shared.reset()
    }

    private func tearDown() async {
        for question in AgentDesk.shared.pending { AgentDesk.shared.take(question.id, .dropped) }
        AgentDesk.shared.drop(task: task)
        server?.stop()
        AgentSites.shared.reset()
        browser?.closeAll()
        browser = nil
    }

    private func page(_ body: String) async throws -> (tab: Tab, id: String) {
        server = try LocalPageServer(["/page": .init(type: "text/html", body: "<!doctype html><html lang=\"en\"><title>Shop</title><body style=\"margin:0\">" + body + "</body></html>")])
        _ = await box.call("open", ["url": server.url("/page").absoluteString], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    private func value(_ tab: Tab, _ script: String) async -> String? {
        (try? await tab.web.evaluateJavaScript(script)) as? String
    }

    static let buy = "<div style=\"height:1500px\"></div><button onclick=\"window.bought = 'yes'\">Show more</button><div style=\"height:1500px\"></div>"

    @Test func aCookieNoticeOverTheTargetIsNamedWithItsButtons() async throws {
        let notice = """
        <div id="onetrust-banner-sdk" style="position:fixed;top:30vh;bottom:0;left:0;right:0;background:#fff">
        <p>We use cookies to make this site work</p><button>Accept all</button><button>Reject all</button><button aria-label="Close">×</button>
        </div>
        """
        let (tab, id) = try await page(Self.buy + notice)

        let said = await box.call("click", ["tab": id, "ref": "Show more"], task: task)

        #expect(said.failed)
        #expect(said.code == "not_actionable")
        #expect(said.text?.contains("cookie notice") == true, "\(said.text ?? "")")
        let hint = said.hint ?? ""
        #expect(hint.contains("\"Accept all\""), "\(hint)")
        #expect(hint.contains("\"Reject all\""), "\(hint)")
        #expect(hint.contains("\"Close\""), "\(hint)")
        #expect(hint.contains("@e"), "\(hint)")
        let by = try #require(said.data?["by"] as? [String: Any])
        #expect(by["cookies"] as? Bool == true)
        #expect((by["buttons"] as? [[String: Any]])?.count == 3)
        #expect(await value(tab, "String(window.bought)") == "undefined")
    }

    @Test func aModalOverABackdropIsNamedWithItsButtons() async throws {
        let modal = """
        <div style="position:fixed;inset:0;background:rgba(0,0,0,.4)"></div>
        <div role="dialog" aria-modal="true" style="position:fixed;top:10px;left:10px;width:320px;height:160px;background:#fff">
        <h2>Sign in to keep going</h2><button>Not now</button><button>Sign in</button>
        </div>
        """
        let (tab, id) = try await page(Self.buy + modal)

        let said = await box.call("click", ["tab": id, "ref": "Show more"], task: task)

        #expect(said.failed)
        #expect(said.code == "not_actionable")
        #expect(said.text?.contains("Sign in to keep going") == true, "\(said.text ?? "")")
        #expect(said.hint?.contains("\"Not now\"") == true, "\(said.hint ?? "")")
        #expect(said.text?.contains("cookie") == false)
        #expect(await value(tab, "String(window.bought)") == "undefined")
    }

    @Test func aStickyBarDoesNotCoverATargetBroughtToTheMiddle() async throws {
        let bar = "<div style=\"position:sticky;top:0;height:90px;background:#eee\">Header bar</div>"
        let (tab, id) = try await page(bar + Self.buy)

        let said = await box.call("click", ["tab": id, "ref": "Show more"], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        #expect(await value(tab, "String(window.bought)") == "yes")
    }
}
