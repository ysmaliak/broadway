import AppKit
import WebKit
import Testing
@testable import Search

@Suite(.sharedWorld, .timeLimit(.minutes(5)))
@MainActor
final class AgentFindTests {
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

    private func page(_ body: String, more: [String: LocalPageServer.Page] = [:]) async throws -> (tab: Tab, id: String) {
        var pages = more
        pages["/page"] = .init(type: "text/html", body: "<!doctype html><html lang=\"en\"><title>Zone</title>" + body)
        server = try LocalPageServer(pages)
        _ = await box.call("open", ["url": "http://127.0.0.1:\(server.port)/page"], task: task)
        let tab = try #require(browser.tabs.first { $0.agent })
        let id = String(tab.id.uuidString.prefix(8)).lowercased()
        _ = await box.call("wait", ["tab": id], task: task)
        return (tab, id)
    }

    private func value(_ tab: Tab, _ script: String) async -> String? {
        (try? await tab.web.evaluateJavaScript(script)) as? String
    }

    static let mail = """
    <main><h1>Zone</h1>
    <section><h2>Mail</h2><p>Email <b>Sending</b> is on for this zone</p><button>Configure</button></section>
    <aside><p>Status: Email Sending paused last week</p><a href="/details">Details</a></aside>
    <button>Save draft</button><button>Send now</button><a href="/settings">Settings</a><button>Archive</button>
    </main>
    """

    @Test func wordsInPlainTextAnswerWithTheLinesAndTheControlNearEach() async throws {
        let (_, id) = try await page(Self.mail)

        let found = await box.call("locate", ["tab": id, "text": "Email Sending"], task: task)

        #expect(!found.failed, "\(found.text ?? "")")
        let text = found.text ?? ""
        #expect(text.contains("Email Sending is on for this zone"), "\(text)")
        #expect(text.contains("Status: Email Sending paused last week"), "\(text)")
        #expect(text.contains("button \"Configure\""), "\(text)")
        #expect(text.contains("link \"Details\""), "\(text)")
        #expect(found.data?["count"] as? Int == 0)
        #expect((found.data?["elements"] as? [Any])?.isEmpty == true)
        let lines = try #require(found.data?["text"] as? [[String: Any]])
        #expect(lines.count == 2)
        let near = try #require(lines.first?["near"] as? [String: Any])
        #expect(near["name"] as? String == "Configure")
        #expect((near["ref"] as? String)?.hasPrefix("e") == true)
        #expect(lines.first?["in_view"] as? Bool == true)
    }

    @Test func aMissNamesTheClosestNamesOnThePageWithTheirRefs() async throws {
        let (_, id) = try await page(Self.mail)

        let none = await box.call("locate", ["tab": id, "text": "Save drafts now"], task: task)

        #expect(none.failed)
        #expect(none.code == "not_found")
        let hint = none.hint ?? ""
        #expect(hint.contains("button \"Save draft\""), "\(hint)")
        #expect(hint.contains("@e"), "\(hint)")
        let closest = try #require(none.data?["closest"] as? [[String: Any]])
        #expect(closest.count <= 3 && !closest.isEmpty)
        #expect(closest.first?["name"] as? String == "Save draft")
    }

    @Test func aMissSaysAFrameFromAnotherSiteWasNotSearched() async throws {
        let body = "<button>Archive</button><script>document.write('<iframe src=\"http://localhost:' + location.port + '/inner\"></iframe>')</script>"
        let (_, id) = try await page(body, more: ["/inner": .init(type: "text/html", body: "<!doctype html><button>Pay invoice</button>")])
        try await Task.sleep(for: .milliseconds(500))

        let none = await box.call("locate", ["tab": id, "text": "Pay invoice"], task: task)

        #expect(none.failed, "\(none.text ?? "")")
        #expect(none.hint?.contains("--frames") == true, "\(none.hint ?? "")")
    }

    @Test func clickWithWordsThatFitNothingNamesTheClosestAndClicksNothing() async throws {
        let (tab, id) = try await page("<button onclick=\"window.hit = 'yes'\">Delete account</button><button>Download data</button>")

        let none = await box.call("click", ["tab": id, "ref": "Delet acount"], task: task)

        #expect(none.failed)
        #expect(none.code == "not_found")
        #expect(none.hint?.contains("button \"Delete account\"") == true, "\(none.hint ?? "")")
        #expect(await value(tab, "String(window.hit)") == "undefined")
    }

    @Test func clickOnWordsThatArePageTextSaysSoAndClicksNothing() async throws {
        let (tab, id) = try await page(Self.mail + "<script>document.addEventListener('click', function () { window.hit = 'yes'; });</script>")

        let none = await box.call("click", ["tab": id, "ref": "Email Sending"], task: task)

        #expect(none.failed)
        #expect(none.code == "not_found")
        #expect(none.hint?.contains("broadway find \"Email Sending\"") == true, "\(none.hint ?? "")")
        #expect(await value(tab, "String(window.hit)") == "undefined")
    }

    @Test func readFindWithNoLineGivesTheClosestLines() {
        let text = "Order total 609.00\nShipping to Lisbon\nPaid by card"

        let none = BrowserToolbox.lines(of: text, holding: "shiping to lisbon")

        #expect(none.failed)
        #expect(none.hint?.contains("Shipping to Lisbon") == true, "\(none.hint ?? "")")
    }

    static let cards = """
    <div class="card"><h3>Billing address</h3><p>12 Rua Augusta</p><button onclick="window.gone = 'billing'">Edit</button></div>
    <div class="card"><h3>Shipping address</h3><p>4 Rua do Ouro</p><button onclick="window.gone = 'shipping'">Edit</button></div>
    """

    @Test func severalFitsComeWithWhatToChooseBy() async throws {
        let (_, id) = try await page(Self.cards)

        let both = await box.call("click", ["tab": id, "ref": "Edit"], task: task)

        #expect(both.code == "ambiguous")
        let hint = both.hint ?? ""
        #expect(hint.contains("Billing address"), "\(hint)")
        #expect(hint.contains("Shipping address"), "\(hint)")
        #expect(hint.contains("in view"), "\(hint)")
        let candidates = try #require(both.data?["candidates"] as? [[String: Any]])
        #expect(candidates.first?["heading"] as? String == "Billing address")
        #expect(candidates.first?["in_view"] as? Bool == true)
    }

    @Test func inTakesWordsAndActsOnlyInsideThem() async throws {
        let (tab, id) = try await page(Self.cards)

        let said = await box.call("click", ["tab": id, "target": ["words": "Edit", "in": "Shipping address"]], task: task)

        #expect(!said.failed, "\(said.text ?? "")")
        #expect(await value(tab, "String(window.gone)") == "shipping")
    }

    @Test func findTakesWordsForInToo() async throws {
        let (_, id) = try await page(Self.cards)

        let found = await box.call("locate", ["tab": id, "text": "Edit", "in": "Billing address"], task: task)

        #expect(!found.failed, "\(found.text ?? "")")
        #expect(found.data?["count"] as? Int == 1)
    }

    @Test func closestNamesShareWordsFirstThenSpelling() {
        let names: [(ref: String, role: String, name: String)] = [
            ("e1", "button", "Archive"), ("e2", "button", "Save draft"), ("e3", "button", "Send now"),
            ("e4", "link", "Settings"), ("e5", "button", "Save"),
        ]

        let found = AgentNear.closest("save drafts", among: names)

        #expect(found.map(\.ref) == ["e2", "e5"])
        #expect(AgentNear.closest("Setings", among: names).first?.ref == "e4")
        #expect(AgentNear.closest("zzzz qqqq", among: names).isEmpty)
    }
    @Test func textNextToASignUpFormIsFound() async throws {
        let (_, id) = try await page("<h1>Sign up</h1><form>\n<input id=\"pass\" type=\"password\" value=\"hunter2-secret\">\n<input id=\"card\" autocomplete=\"cc-number\" value=\"4242424242424242\">\n<input id=\"plain\" placeholder=\"plain\" value=\"\">\n<button id=\"inside\" type=\"button\" onclick=\"document.title='leaked'\">Inside</button>\n</form>\n<button id=\"go\" type=\"button\" onclick=\"document.title='clicked'\">Go</button>\n<button id=\"mark\" type=\"button\" onclick=\"document.title='marked'\">Mark seen</button>\n<p>the price is 12 dollars</p>")

        let said = await box.call("locate", ["tab": id, "text": "price"], task: task)

        #expect(!said.failed, "\(said.text ?? "") \(said.hint ?? "")")
        #expect(said.text?.contains("the price is 12 dollars") == true, "\(said.text ?? "")")
    }
}
